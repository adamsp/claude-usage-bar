import AppKit
import Foundation

// Got rate limited at 2 mins and below. We attempt a refresh whenever the menu opens.
let REFRESH_INTERVAL_SECONDS = 180.0

// MARK: - Models

struct OAuthCredentials: Decodable {
    struct Inner: Decodable { let accessToken: String }
    let claudeAiOauth: Inner
}

struct Period: Decodable {
    let utilization: Double
    let resetsAt: String?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct UsageResponse: Decodable {
    let fiveHour: Period?
    let sevenDay: Period?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

// MARK: - Helpers

func getAccessToken() throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw NSError(domain: "ClaudeUsage", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Keychain access failed — sign in to Claude Code first"])
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return try JSONDecoder().decode(OAuthCredentials.self, from: data).claudeAiOauth.accessToken
}

func progressBar(_ pct: Double, width: Int = 20) -> String {
    let n = Int((min(pct, 100) / 100.0 * Double(width)).rounded())
    return "[\(String(repeating: "█", count: n))\(String(repeating: "░", count: width - n))]"
}

func resetLabel(_ iso: String?) -> String {
    guard let iso else { return "" }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = fmt.date(from: iso) else { return "" }
    let secs = Int(max(0, date.timeIntervalSinceNow))
    let h = secs / 3600
    let m = (secs % 3600) / 60
    if h >= 48 { return "resets in \(h / 24)d" }
    if h > 0   { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

func monoString(_ str: String) -> NSAttributedString {
    NSAttributedString(string: str, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    ])
}

func log(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: .now)
    fputs("[\(stamp)] \(msg)\n", stderr)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var sessionItem: NSMenuItem!
    var weeklyItem: NSMenuItem!
    var updatedItem: NSMenuItem!
    var lastFetched: Date?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…%"

        sessionItem = NSMenuItem()
        sessionItem.attributedTitle = monoString("Session (5h):  loading…")

        weeklyItem = NSMenuItem()
        weeklyItem.attributedTitle = monoString("Weekly (7d):   loading…")

        updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        updatedItem.isEnabled = false

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let menu = NSMenu()
        for item in [sessionItem!, weeklyItem!, .separator(), updatedItem!, .separator(), quitItem] {
            menu.addItem(item)
        }
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        Timer.scheduledTimer(withTimeInterval: REFRESH_INTERVAL_SECONDS, repeats: true) { [weak self] _ in self?.refresh() }

        // Timers don't fire while asleep and don't reliably resume on wake, so
        // refresh explicitly when the machine comes back.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc func didWake() {
        refresh()
    }

    func menuWillOpen(_: NSMenu) {
        let stale = lastFetched.map { Date().timeIntervalSince($0) > 30 } ?? true
        if stale { refresh() }
    }

    @objc func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let token: String
            do {
                token = try getAccessToken()
            } catch {
                log("token: \(error.localizedDescription)")
                return
            }

            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            // A fresh session per request: sleep/wake leaves the shared session's
            // pooled (HTTP/2) connection dead, and it gets reused for every
            // subsequent request — so every refresh after wake hangs, including
            // the one triggered by clicking the menu. An ephemeral session gives
            // each call its own connection pool. waitsForConnectivity lets a
            // wake refresh wait for the network to come back, and the resource
            // timeout caps it so a request can never hang forever.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = true
            let session = URLSession(configuration: config)

            session.dataTask(with: req) { data, resp, err in
                defer { session.finishTasksAndInvalidate() }

                if let err {
                    log("fetch: \(err.localizedDescription)")
                    return
                }
                let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard statusCode == 200 else {
                    log("HTTP \(statusCode)")
                    return
                }
                // Both period fields are optional, so a non-usage payload (e.g. an error
                // body) decodes "successfully" with everything nil. Require both 5hr and
                // 7day utilization values before updating the UI.
                guard let data,
                      let u = try? JSONDecoder().decode(UsageResponse.self, from: data),
                      let fhPct = u.fiveHour?.utilization,
                      let sdPct = u.sevenDay?.utilization else {
                    log("invalid response from server")
                    return
                }

                let time = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .short)

                DispatchQueue.main.async {
                    self.lastFetched = .now
                    self.statusItem.button?.title = "\(Int(fhPct))%"
                    self.sessionItem.attributedTitle = monoString(
                        "Session (5h):  \(progressBar(fhPct))  \(Int(fhPct))%  \(resetLabel(u.fiveHour?.resetsAt))"
                    )
                    self.weeklyItem.attributedTitle = monoString(
                        "Weekly (7d):   \(progressBar(sdPct))  \(Int(sdPct))%  \(resetLabel(u.sevenDay?.resetsAt))"
                    )
                    self.updatedItem.title = "Updated \(time)"
                }
            }.resume()
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
