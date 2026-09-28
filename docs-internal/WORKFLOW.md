# Claude Usage Tracker — Custom Fork Workflow

## Overview

This is Mario's fork of [HamedElfayome/Claude-Usage-Tracker](https://github.com/HamedElfayome/Claude-Usage-Tracker).
We maintain custom modifications on top of the upstream releases.

## Remotes

| Remote     | URL                                                        | Purpose                    |
|------------|------------------------------------------------------------|----------------------------|
| `origin`   | `https://github.com/northpixelworks/Claude-Usage-Tracker.git` | Our fork — push changes here |
| `upstream` | `https://github.com/HamedElfayome/Claude-Usage-Tracker.git` | Original repo — pull updates from here |

## Daily Workflow

### Making Changes

1. **Edit code** — via Claude Code in the terminal or Xcode
2. **Build** — from terminal:
   ```bash
   cd ~/Developer/Claude-Usage-Tracker
   xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
   ```
3. **Install to /Applications** — must delete first to bust macOS cache:
   ```bash
   killall "Claude Usage"
   rm -rf "/Applications/Claude Usage.app"
   cp -R ~/Library/Developer/Xcode/DerivedData/Claude_Usage-*/Build/Products/Debug/Claude\ Usage.app "/Applications/Claude Usage.app"
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Claude Usage.app"
   open "/Applications/Claude Usage.app"
   ```
   **Important:** plain `cp -R` over the existing app causes macOS to cache the old binary. Always `rm -rf` first.
4. **Commit & push** — standard git workflow to `origin/main`

### Pulling Upstream Updates

When the original developer releases a new version:

```bash
cd ~/Developer/Claude-Usage-Tracker
git fetch upstream
git merge upstream/main
# Resolve any conflicts, then:
git push origin main
```

Then rebuild in Xcode.

## Important Notes

- **Do NOT use the in-app update button.** It pulls the official release binary from upstream, which would overwrite our custom build with the stock version.
- **Sparkle auto-download** is disabled in our fork. It still checks and notifies you about new versions — then you merge upstream and rebuild.
- The app is **not sandboxed** (it needs to read `~/.claude/.credentials.json`).
- Signing is set to automatic with the original dev's team ID (`T77ZWDC739`). You'll need to change this to your own Apple Developer team or use "Sign to Run Locally" in Xcode.

## Build Requirements

- macOS 14.0+ (Sonoma)
- Xcode with Swift 5.0+
- Swift Package dependency: **Sparkle** (resolved automatically by Xcode)

## Project Structure (Key Directories)

```
Claude Usage/
├── App/           → Entry point, AppDelegate
├── MenuBar/       → Menu bar UI, popover, status bar icons
├── Views/         → Settings views (SwiftUI)
├── Shared/
│   ├── Managers/  → ProfileManager, MenuBarManager, etc.
│   ├── Services/  → API calls, auth, notifications, statusline
│   ├── Models/    → ClaudeUsage, Profile, APIUsage
│   └── Storage/   → DataStore, ProfileStore
└── Resources/     → Localizations (10 languages)
```

## Custom Changes

See [CUSTOM-CHANGES.md](CUSTOM-CHANGES.md) for a detailed log of all modifications to the fork.
