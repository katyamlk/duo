# Duo

Telegram, Instagram and Slack in one macOS window.

## Features

- One window with a Telegram / Instagram / Slack switcher (Cmd+1 / Cmd+2 / Cmd+3)
- Native macOS notifications from all three, with per-app toggles
- Unread counters on the switcher and the Dock icon
- Back / Forward / Home / Reload buttons, links and file previews open in separate windows
- Downloads go to ~/Downloads
- Dock icon follows the system theme (white in Light, black in Dark)
- Interface in Ukrainian or English
- Fast recovery after the Mac wakes from sleep
- No phantom "Now Playing" entries from idle web audio

## Build

Requires macOS 14+ and Apple Command Line Tools (`xcode-select --install`).

```
bash build.command      # builds and installs to ~/Applications/Duo.app
bash package.command    # creates ~/Downloads/Duo.dmg (Apple Silicon + Intel) for sharing
```

## Push changes

```
bash push.command
```

## Download

Latest build (Apple Silicon + Intel, macOS 14+):
https://github.com/katyamlk/duo/releases/latest/download/Duo.dmg

Open the .dmg, drag Duo to Applications. On first launch: System Settings > Privacy & Security > "Open Anyway".

## Release a new version

```
bash release.command "What changed"
```
