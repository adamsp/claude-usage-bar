# claude-usage-bar
Claude Code current-session-usage in your MacOS status bar.

Shows a percentage value for your current session usage in the status bar. If you click on this, it shows progress bars and usage data for the current session and your weekly consumption, along with reset times.

You can update the refresh cadence by modifying the `REFRESH_INTERVAL_SECONDS` value.

<img src="./screenshot.png" alt="Screenshot of the status bar app running">

# Installation

`./install.sh` will build the binary, generate a plist file so it runs on login, and run the app.