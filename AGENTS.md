# Claude-Usage-Tracker Agent Instructions

<!-- BEGIN:cross-agent-agent-rules -->
## Cross-Agent Compatibility

This repository is used by multiple coding agents. `AGENTS.md` is the single instruction file; keep durable project instructions here.

### Start Here
- [README.md](README.md) — README.
- [ARCHITECTURE.md](ARCHITECTURE.md) — required reading: full app structure, data flow, modules, and gotchas.
- [CONTRIBUTING.md](CONTRIBUTING.md) — contributing guide.
- [SECURITY.md](SECURITY.md) — security policy.
- [docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md) — agent guide.

### Stack
| | |
|---|---|
| Language | Swift 5.x |
| UI | SwiftUI + AppKit |
| Build | Xcode (`Claude Usage.xcodeproj`) |
| Tests | XCTest (`Claude UsageTests/`) |
| CI | GitHub Actions (`.github/workflows/`) |

### Build / Dev / Test
```bash
# Build & run
open "Claude Usage.xcodeproj"   # then Cmd+B / Cmd+R in Xcode

# CLI build (release)
./scripts/build-and-install.sh

# Validate localizations
./scripts/validate_localizations.sh

# Tests
# Run via Xcode (Cmd+U) or: xcodebuild test -scheme "Claude Usage" -destination 'platform=macOS'
```

### Critical Gotchas
- **Reinstall:** always `rm -rf` old `.app` before `cp -R` — stale binary causes crashes.
- **Keychain truncation:** CLI credentials >2 KB may be truncated; app falls back to `~/.claude/.credentials.json`.
- **Headless / Remote Desktop:** status bar init may fail; `AppDelegate` auto-retries after 3 s.
- **`statusLevel` deprecated:** use `UsageStatusCalculator.calculateStatus()`, not `ClaudeUsage.statusLevel`.
- **Fork tracking:** all deviations from upstream documented in `docs-internal/CUSTOM-CHANGES.md`.

### Common Commands
- Xcode project: inspect schemes with `xcodebuild -list -project Claude Usage.xcodeproj` before building.

### Working Rules
- Keep changes small, reviewable, and tied to the requested behavior.
- Prefer existing architecture, naming, and helper patterns over new abstractions.
- Validate data at system boundaries instead of relying on guessed shapes.
- Update docs when behavior, commands, architecture, or setup changes.
- Run the narrowest relevant verification first, then broader checks when risk warrants it.
- If a command cannot run, record the blocker and the residual risk in the handoff.
<!-- END:cross-agent-agent-rules -->

## Notes

Add project-specific architecture, testing, release, and safety rules above or in linked docs as they become stable. Keep this file concise enough to fit comfortably in agent context.
