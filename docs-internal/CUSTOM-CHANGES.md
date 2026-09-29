# Custom Fork Changes

All modifications made to our fork of [HamedElfayome/Claude-Usage-Tracker](https://github.com/HamedElfayome/Claude-Usage-Tracker).
This file helps track what we've changed so upstream merges stay manageable.

---

## Audit fixes — 2026-09-06

Supersedes the peak-hour behavior described in historical entries below.

- Profile credential vault with verified, crash-safe revisions and migration from `profiles_v3` to redacted `profiles_v4` metadata. Failed migration preserves the original; failed secure reads block destructive writes. Uses the encrypted login Keychain, with normal macOS ACLs, for compatibility with unsigned fork builds.
- Automatic startup/pre-switch CLI sync and usage fallback only accept proven token continuity. If both tokens rotated or identity is absent, the user must explicitly reconnect; profile names/current selection never prove identity.
- One refresh implementation for single/multi/popover modes. Request generations and credential checks discard obsolete responses. The initiating profile owns all cached usage/history; current selection controls only display. Errors retain successful data and do not advance the success timestamp.
- Removed obsolete hardcoded peak-hour visuals, notifications, countdown timers, and translations. Kept provider-based usage, pace markers, and historical trends.
- Isolated test hosts from real startup/migration; added in-memory vault, mock HTTP, account-isolation, and asynchronous coordinator regressions. Cleaned actor-isolation/deprecation warnings and orphan Korean keys.

Validation and implementation details: [September audit fixes](done/2026-09-06-audit-fixes.md).

---

## 1. Peak Hours Visual Indicator

**Date:** 2026-03-30
**Purpose:** Make it immediately visible when Anthropic's peak hours are active, since usage costs more during that window (the 5-hour session depletes faster).

### What are peak hours?
- Weekdays (Mon–Fri), 5:00–11:00 AM Pacific Time
- For Vienna (CET/CEST): ~2:00–8:00 PM winter / ~3:00–9:00 PM summer
- Anthropic confirmed (March 2026) that token cost per session is inflated during this window

### Changes

**New file:** `Shared/Utilities/PeakHoursHelper.swift`
- `isPeakHours` — checks if current time is within peak window (converts to Pacific Time)
- `countdown()` — returns time remaining until peak ends (if active) or starts (if off-peak)
- `formatCountdown()` — formats interval as "Xh Ym"
- `localTargetTime()` — returns the end/start time in the user's local timezone ("HH:mm")
- `localScheduleString` — peak hours in local time, e.g. "15:00–21:00"
- `checkAndSendPeakWarning()` — sends macOS notification 15 min before peak starts (once per window)

**Modified:** `Shared/Extensions/Color+AppColors.swift`
- Added `peakAmber` color (warm yellow-orange, adapts to light/dark mode)
- Added `safeDynamic` on both `Color` and `NSColor` (used internally)

**Modified:** `MenuBar/PopoverContentView.swift`
- `PeakHoursBanner` — countdown banner with local end/start time
- `PeakStripes` — diagonal amber stripes on progress bars during peak
- `PopoverInfoFooter` — peak schedule line + weekly usage trend
- Bar colors remain green/orange/red (stripes overlay, don't replace)

**Modified:** `MenuBar/MenuBarIconRenderer.swift`
- Progress bar style (W): light grey striped background + amber stripes on fill during peak
- Battery style (S): light grey background fill + amber stripes on fill during peak

**Modified:** `MenuBar/MenuBarManager.swift`
- Hooked `PeakHoursHelper.checkAndSendPeakWarning()` into refresh cycle

---

## 2. Pace Guidance

**Date:** 2026-03-30
**Purpose:** Show how much faster or slower you need to use Claude to perfectly hit 100% by reset time.

**Modified:** `MenuBar/PopoverContentView.swift`
- `paceGuidanceText` / `paceGuidanceColor` in `UsageRow`
- Shows: "▸ You can go 2.5x faster" / "▸ Perfect pace" / "▸ Slow down to 70%"
- Only when >5% elapsed and >1% used

---

## 3. Peak Hours Notification

**Date:** 2026-03-30
**Purpose:** Get a macOS notification ~15 minutes before peak hours begin.

**Modified:** `Shared/Utilities/PeakHoursHelper.swift`
- `checkAndSendPeakWarning()` — fires once per peak window, triggered by refresh cycle

---

## 4. Peak Hours Schedule in Footer

**Date:** 2026-03-30
**Purpose:** Always-visible reference for when peak hours are in your local timezone.

**Modified:** `MenuBar/PopoverContentView.swift`
- `PopoverInfoFooter` — shows "Peak: 15:00–21:00 Mon–Fri" at bottom of popover

---

## 5. Weekly Usage Trend

**Date:** 2026-03-30
**Purpose:** Quick comparison of this week's usage vs last week.

**Modified:** `MenuBar/PopoverContentView.swift`
- `PopoverInfoFooter` — compares last 2 weekly snapshots, shows "↑ 12% more than last week"

---

## 6. Auto-Update Disabled

**Date:** 2026-03-30
**Purpose:** Prevent Sparkle auto-download from overwriting our custom build.

**Modified:** `Shared/Services/UpdateManager.swift`
- `automaticallyDownloadsUpdates = false` — still checks and notifies

---

## 7. German Localization

**Date:** 2026-03-30
**Purpose:** All custom peak/pace text was in English while the rest of the UI is German.

**Modified:** `Resources/de.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`
- Added `peak.*` keys: banner, footer, pace, notifications, tooltips
- German: "Stoßzeiten", "Du kannst 2.5x schneller arbeiten", "Perfektes Tempo für 100%", etc.

**Modified:** `MenuBar/PopoverContentView.swift`, `Shared/Utilities/PeakHoursHelper.swift`
- All hardcoded English strings replaced with `.localized` calls

---

## 8. Weekend Indicator

**Date:** 2026-03-30
**Purpose:** On weekends, show "Heute keine Stoßzeiten" instead of the peak schedule, so you know you can go full throttle.

**Modified:** `MenuBar/PopoverContentView.swift`
- `PopoverInfoFooter` checks `isWeekend` — swaps clock icon for sun icon and shows localized "no peak today"

---

## 9. Menu Bar Tooltips

**Date:** 2026-03-30
**Purpose:** Hovering over W or S icons shows usage % and peak status without opening the popover.

**Modified:** `MenuBar/StatusBarUIManager.swift`
- `button.toolTip` set on every icon update (both `updateAllButtons` and `updateButton`)
- Shows: "Session: 28% genutzt" + "Stoßzeiten aktiv — endet 21:00" during peak

**Modified:** `Shared/Utilities/PeakHoursHelper.swift`
- Added `tooltip(metricName:percentage:)` helper

---

## 10. Build Script

**Date:** 2026-03-30
**Purpose:** One command to build, install, and relaunch the custom app.

**New file:** `scripts/build-and-install.sh`
- Runs `xcodebuild`, kills old app, `rm -rf` + `cp -R` to `/Applications`, `lsregister`, launches

---

## 11. Elapsed Time Percentage on Usage Rows

**Date:** 2026-03-31
**Purpose:** Show how much of each time window (5h session, weekly) has elapsed, so you can compare usage % against time % at a glance.

### Changes

**Modified:** `MenuBar/PopoverContentView.swift`
- `UsageRow`: Added elapsed percentage display ("· X% elapsed") next to the reset time text
- Only shown when both `resetTime` and `periodDuration` are available (session + weekly all-models rows)
- Uses existing `rawElapsedFraction` computation

**Modified:** All 9 `Localizable.strings` files
- Added `menubar.elapsed_percentage` key (e.g. "%d%% elapsed", "%d%% verstrichen", etc.)

---

## 12. Peak Hours Countdown in Footer

**Date:** 2026-03-31
**Purpose:** Always show how long until peak hours start or end in the bottom footer, not just the schedule.

### Changes

**Modified:** `MenuBar/PopoverContentView.swift`
- `PopoverInfoFooter`: Added live countdown ("· starts in Xh Ym" / "· ends in Xh Ym") next to the peak schedule line
- Updates every 30 seconds via Timer
- Hidden on weekends

**Modified:** `en.lproj/Localizable.strings`, `de.lproj/Localizable.strings`
- Added `peak.footer.starts_in` and `peak.footer.ends_in` keys

---

## 13. Compact Reset + Elapsed Line

**Date:** 2026-04-02
**Purpose:** Reduce popover height by combining the reset time and elapsed percentage into a single line, separated by a pipe character.

**Modified:** `MenuBar/PopoverContentView.swift`
- `UsageRow`: Merged the "Zurücksetzen …" and "X% verstrichen" texts into one line: `Zurücksetzen Today 15:59  |  29% verstrichen`
- Falls back to showing either value alone when the other is unavailable

---

## 14. Peak Visuals Scoped to Claude Only

**Date:** 2026-04-02
**Purpose:** Peak-hour visuals represent Anthropic pricing behavior and should not affect Copilot or Codex displays.

### Changes

**Modified:** `MenuBar/PopoverContentView.swift`
- `UsageRow` now supports provider-gated peak stripes via `showPeakStripes`
- `SmartUsageDashboard` enables peak stripes only when `snapshot.provider == .claude`

**Modified:** `MenuBar/MenuBarIconRenderer.swift`
- Added `showPeakEffects` gating to peak-specific rendering in battery/progress styles
- Amber peak overlays/backgrounds now render only when `showPeakEffects` is enabled

**Modified:** `MenuBar/StatusBarUIManager.swift`
- Multi-profile renderer now passes `showPeakEffects: profile.providerKind == .claude`

---

## 15. Faster Startup Sync

**Date:** 2026-04-03
**Purpose:** Usage data took too long to appear in the menu bar after a PC restart. Stale cached data would sit for 4+ seconds before the first fresh API fetch completed.

### Root causes
- 1.0s intentional delay before first API fetch (over-conservative for launch-at-login)
- 3.0s delay on wake-from-sleep refresh
- Network-available callback debounced even when no successful refresh had occurred yet

### Changes

**Modified:** `MenuBar/MenuBarManager.swift`
- Reduced initial fetch delay from 1.0s → 0.3s (enough for run loop to stabilize)
- Reduced wake-from-sleep refresh delay from 3.0s → 1.0s
- Network-available callback now skips debounce and fetches immediately if no successful refresh has occurred this session (`lastSuccessfulRefreshTime == nil`)

---

## 16. Credit Balance Display Fix

**Date:** 2026-04-04
**Purpose:** Gifted API credits (and purchased credit balances) were invisible in the popover because the display was gated behind a spend-limit conditional, and CLI OAuth paths never fetched the data.

### Root causes
- Credit grant balance card was nested inside `costUsed`/`costLimit` check — only shown if a spend limit was enabled
- CLI OAuth auth path (Priority 2/3) never called `/overage_spend_limit` or `/overage_credit_grant` endpoints
- Accounts with gifted credits but no spend limit saw nothing
- `MenuBarManager.fetchUsageForProfile()` duplicated the priority chain without overage supplement
- CLI credentials went stale after re-auth; app never re-synced on non-first launch

### Changes

**Modified:** `Shared/Services/Providers/ClaudeUsageSnapshotAdapter.swift`
- Moved credit grant balance card out of the spend-limit conditional — now displays independently when `overageBalance` is present

**Modified:** `Shared/Services/ClaudeAPIService.swift`
- Added `supplementOverageData(_:sessionKey:organizationId:)` — public method to fetch overage + credit grant endpoints and merge into existing `ClaudeUsage`

**Modified:** `Shared/Services/Providers/ClaudeUsageProviderFetcher.swift`
- CLI OAuth branches (Priority 2/3) now call `supplementOverageIfNeeded()` to fetch overage data via session key when available
- Supplement only runs for CLI OAuth paths — session key path already fetches internally, avoiding duplicate requests

**Modified:** `MenuBar/MenuBarManager.swift`
- `fetchUsageForProfile()` now delegates to `ClaudeUsageProviderFetcher.fetchClaudeUsage()` instead of duplicating the priority chain

**Modified:** `Shared/Services/ProfileManager.swift`
- Added `refreshStaleCLICredentials()` — called on every `loadProfiles()`, re-syncs expired CLI tokens from system keychain

**Modified:** `Claude UsageTests/ProviderModelsTests.swift`
- Fixed `testCopilotDisplayName` — expected `"Copilot"` but source returns `"GitHub Copilot"`
- Fixed `testHasUsageCredentialsCopilot_withoutToken` — removed singleton dependency, now tests profile-level contract directly

---

## 17. Safe Upstream Sync (Selective Integration)

**Date:** 2026-04-23
**Purpose:** Pull useful upstream fixes from `hamed-elfayome/main` into this multi-provider fork without overwriting fork-specific provider work or doing a risky wholesale merge.

### Strategy
- Created a dedicated integration branch and committed the fork-only single-profile Codex/Copilot menu bar rendering fix first.
- Cherry-picked low-risk upstream commits in small batches.
- Manually ported only the overlapping menu bar/popover fixes that fit the fork’s provider-neutral architecture.
- Rebuilt after each batch and ran the XCTest suite before fast-forwarding `main`.

### Cherry-picked upstream fixes

**Imported:** `a7171bd` → local `02e298c`
- Added browser-compatible request headers (`User-Agent`, `Referer`, `Origin`) to `claude.ai` session-key requests.
- Fixes E3000 / false-expired-session failures after Anthropic tightened request validation.

**Imported:** `5d85258` → local `5177866`
- Added hard timeouts around `/usr/bin/security` subprocesses in `ClaudeCodeSyncService`.
- Prevents launch hangs and keychain stalls from blocking the app indefinitely.

**Imported:** `f6caf1d` → local `911b8f0`
- Fresh login page for embedded auth by clearing stale Claude/Anthropic cookies before loading login.
- Added real popup-based Google SSO handling and cookie-store observation.
- Conflict was merged manually to preserve the fork’s existing 1.5s polling fallback for SPA-style cookie creation.

**Imported:** `a3e0d65` → local `87795be`
- Manual session/API key entry is now always visible beneath sign-in instead of hidden inside a collapsed disclosure group.

**Imported:** `6727628` → local `60ae55b`
- Removed the incorrect CLI tracking note from `CLIAccountView`.

**Imported:** `554c793` → local `08d1a24`
- Added missing translations for multi-profile icon styles (`circles`, `bars`, `dots`, `percent`) in non-English locales.

### Manual adaptations from overlapping upstream work

**Adapted locally:** `37d5ecd`
- `AppDelegate` now always instantiates `MenuBarManager` before wizard/setup branching.
- Active Claude profile menu/refresh gating now honors valid system Keychain CLI credentials, not just profile-local credentials.
- Adaptation was scoped so Codex/Copilot logic and the fork’s faster 0.3s startup refresh remained intact.

**Adapted locally:** `29f2dd8`
- Added `.multiProfileConfigChanged` notification to separate “visual config tweak” from true single↔multi display mode changes.
- Multi-profile settings in `ManageProfilesView` now trigger incremental menu bar updates instead of full NSStatusItem teardown/recreation.
- Added `updateMultiProfileConfiguration(...)` in `StatusBarUIManager` for add/remove-only updates.

**Adapted locally:** `b3b5797`
- Added stable `autosaveName` values for single-profile metrics, multi-profile items, and default-logo status items.
- Adapted naming to the fork’s per-provider/per-metric status item model instead of upstream’s simpler structure.

**Adapted locally:** `36056d5`
- Popover hosting controller now uses `preferredContentSize`.
- Added shared `popoverArrowHeight` padding so content no longer collides with the menubar arrow region.

**Adapted locally:** `525345b`
- Switching between status items while the popover is open now uses synchronous close behavior to avoid EXC_BAD_ACCESS races.
- Detached popover window uses a separate window-oriented hosting controller to avoid layout/constraint cycles.

### Intentionally skipped
- Full menu bar refactors: `127247c`, `9983056`, `c6c962f`
- Statusline refactor chain: `025b428`, `930e300`, `59a326d`, `52a3759`, `f42bbcf`, `aaec4ef`
- Risky profile credential sync rewrites that assume upstream’s narrower provider model
- Any wholesale merge from upstream `main`

### Verification
- `xcodebuild -project 'Claude Usage.xcodeproj' -scheme 'Claude Usage' -sdk macosx build` → `BUILD SUCCEEDED`
- `xcodebuild test -project 'Claude Usage.xcodeproj' -scheme 'Claude Usage' -destination 'platform=macOS'` → `TEST SUCCEEDED`

---

## 18. Per-Profile Icon Style in Multi-Profile Mode

**Date:** 2026-04-24
**Purpose:** Allow each profile to independently choose its menu bar icon style in multi-profile mode, and add a Battery option so profiles can show individual metric bars instead of being forced into a single compact icon.

### Problem
Multi-profile mode had one global `MultiProfileIconStyle` applied to all profiles. The battery/progress bar styles from the per-profile Darstellung settings were ignored. Users who wanted individual batteries per profile saw concentric circles instead.

### Changes

**Modified:** `Shared/Models/MenuBarIconConfig.swift`
- Added `.battery` case to `MultiProfileIconStyle` — renders individual metric items per profile using the profile's Darstellung settings
- Added `multiProfileIconStyle: MultiProfileIconStyle?` to `MenuBarIconConfiguration` — per-profile override, falls back to global `MultiProfileDisplayConfig.iconStyle` when nil
- Custom Codable with backward compat (decodeIfPresent)

**Modified:** `MenuBar/StatusBarUIManager.swift`
- `multiProfileItemKeys(for:globalConfig:)` now creates one status item per enabled metric for battery-style profiles (session + week as separate bars), one item per profile for other styles
- New `renderBatteryMultiProfile()` — uses `MenuBarIconRenderer.createImage()` with the profile's own `MenuBarIconConfiguration` and a 2-letter profile prefix
- New `renderCompactMultiProfile()` — extracted from the old monolithic loop, handles concentric/progressBar/compact/percentage styles
- `setupMultiProfile()` and `updateMultiProfileConfiguration()` signatures updated to accept `MultiProfileDisplayConfig`

**Modified:** `MenuBar/MenuBarManager.swift`
- Updated `setupMultiProfileMode()` and `updateMultiProfileDisplay()` to pass `config` to new signatures

**Modified:** `Views/Settings/App/ManageProfilesView.swift`
- Replaced global `MultiProfileStylePicker` with per-profile style pickers shown under each selected profile
- Style picker appears indented below each profile's selection row when the profile is enabled for display

**Modified:** All 9 `Localizable.strings` files
- Added `multiprofile.style_battery` key (Battery / Batterie / Batería / etc.)

---

## 17. Single-Profile Peak Visual Scope Fix

**Date:** 2026-04-30
**Purpose:** Menu bar progress bars looked unfamiliar during peak hours because single-profile rendering still applied Anthropic peak-hour visuals by default. Multi-profile mode was already scoped correctly.

### Root cause
- `MenuBarIconRenderer.createImage()` defaults `showPeakEffects` to `true`
- Single-profile status bar updates did not pass a provider-specific value, so non-Claude active profiles could inherit Claude peak styling/tooltips during the peak window
- This was noticed in Vienna during the active peak-hours window on April 30, 2026

### Changes

**Modified:** `MenuBar/StatusBarUIManager.swift`
- Single-profile `updateAllButtons()` and `updateButton()` now pass `showPeakEffects: profile?.providerKind == .claude`
- Peak-hour tooltips are only used for Claude profiles; non-Claude profiles show a plain usage tooltip
- Keeps behavior aligned with the existing multi-profile provider gating from change #14

**Modified:** `Views/CommandPaletteView.swift`
- Fixed compile blockers encountered during reinstall:
  - Color-mode commands now use `MenuBarColorMode` instead of `StatuslineColorMode`
  - Replaced SwiftUI `.tertiaryLabel` references with `Color(nsColor: .tertiaryLabelColor)`

**Verification**
- Ran `./scripts/build-and-install.sh`
- Build succeeded, `/Applications/Claude Usage.app` was replaced, and the app relaunched
- Xcode still prints a CoreSimulator version warning, but it does not block the macOS app build

---

## 19. Upstream Sync to v3.3.0 (Selective Integration)

**Date:** 2026-09-29 · **Branch:** `sync/upstream-3.3.0` · **Task log:** [done/2026-09-29-upstream-sync-3.3.0.md](done/2026-09-29-upstream-sync-3.3.0.md)

Same strategy as §17: upstream built parallel versions of the fork's provider system and credential vault, so no wholesale merge. Fork architecture stays the base.

### Taken as-is (cherry-pick or upstream file)
- macOS 26 fixes: 72b7111, f71c5bf; UI: 3a1566e (Cmd+W), b7aa7ba, 20f4e9d (statusline 0700).
- Claude API service + usage model (b5780ee limits[], 80f5f4a Cloudflare cookies, Design/Fable weekly, tolerant decoding, 9ed6981/008da81) — fork deltas re-applied (`supplementOverageData`, `resolvedBalance`, redacted log).
- Auto-start (fd8fbca) and notification toggle (be984e0); a4eacd9 sign-in 401 retry.
- Statusline (weekly/extra usage, per-element colors), Dynamic Island + DynamicNotchKit (opt-in).
- Languages uk, zh-Hant, vi, tr, pt-BR; all 13 at key parity.

### Adapted to fork architecture
- Status items (6b3f7d0, 5af720b, 753539f): `isVisible = true`, fixed placeholder length, coarse pinned length via `setMultiProfileImage`.
- Popover (8eed38f, 2a3cc70, fc5eb1f): `showPopover(_:from:)` + `NSWindow.enableDisplayOnFullScreenSpaces()`.
- Sign-in (0925cb5, 7b5488c): 1 s `.common` polling + auto-reload.
- Right-click menu (c6c962f); history-to-files (c5d549f) incl. fork `providerHistory_*`.
- **Dormancy fix (c75607c/#268, eee15cf)**: `Profile.cliAccountUuid`; `ClaudeCodeSyncService.systemCredentialsBelong`, `hasUsableSystemCredentials`, `freshSystemCredentials` (mirror + one-shot idle refresh with keychain write-back, deduped); fresher-of file/keychain; atomic `add -U`.
- Codex refresh (52bc240 idea only): `CodexAuthService.freshCredentials(force:)`.
- Thresholds 70/90 (cfd39fe) keeping fork's early long-period pace coloring.

### Intentionally skipped
- 3763cd6 heartbeat analytics; sponsor/support popups (a9fee08, 536044c, bbcf447, c8c4f39, a500363).
- eb07cc9 / 3c9f9fa global showRemaining (fork keeps per-profile); be6d16f / c2f0895 active-profile underline.
- Upstream provider registry + Codex provider (52bc240) and data-protection keychain migration (ba99f58, e38538e, 551faa6, 7c5c799, c66e0d9) — fork has its own.
- Multi-account keychain pinning / switch refresh (a2769fd, ce1c081, 5042efc, ecb28dd, ac6013e, 2992d4e, 9d9467a, f14d4a1) and terminal launchers (7061028): depend on upstream's pinning model; revisit if multiple Claude accounts are used.

---

## Files Modified (summary)

| File | Change |
|------|--------|
| `Shared/Utilities/PeakHoursHelper.swift` | NEW — peak detection, countdown, notifications, tooltips |
| `Shared/Extensions/Color+AppColors.swift` | peakAmber, safeDynamic colors |
| `MenuBar/PopoverContentView.swift` | Banner, stripes, pace, footer (schedule + trend + weekend), elapsed %, peak countdown, compact reset+elapsed line |
| `MenuBar/MenuBarIconRenderer.swift` | Striped bars during peak (battery + progress bar) |
| `MenuBar/MenuBarManager.swift` | Peak warning notification hook |
| `MenuBar/StatusBarUIManager.swift` | Tooltips on menu bar icons |
| `Shared/Services/UpdateManager.swift` | Disabled auto-download |
| `Resources/en.lproj/Localizable.strings` | Peak hours localization keys |
| `Resources/de.lproj/Localizable.strings` | German translations |
| `scripts/build-and-install.sh` | NEW — build + install script |
| `Shared/Services/Providers/ClaudeUsageSnapshotAdapter.swift` | Credit balance shown independently |
| `Shared/Services/ClaudeAPIService.swift` | `supplementOverageData` for CLI OAuth paths |
| `Shared/Services/Providers/ClaudeUsageProviderFetcher.swift` | Overage supplement in CLI OAuth branches |
| `Shared/Services/ProfileManager.swift` | Auto-refresh stale CLI tokens on launch |
| `MenuBar/MenuBarManager.swift` | Delegates to provider fetcher, no more duplicated priority chain |
| `App/AppDelegate.swift` | Early `MenuBarManager` init for safer setup/headless flows |
| `MenuBar/StatusBarUIManager.swift` | Stable autosave names + incremental multi-profile updates |
| `MenuBar/PopoverContentView.swift` | Popover arrow padding for cleaner placement |
| `Shared/Extensions/Notification+Extensions.swift` | Added `multiProfileConfigChanged` |
| `Shared/Utilities/Constants.swift` | Added shared `popoverArrowHeight` constant |
| `Views/Settings/App/ManageProfilesView.swift` | Multi-profile tweaks now trigger incremental status-item updates |
| `Views/Settings/Credentials/ConsoleAuthWebView.swift` | Fresh login, popup SSO, cookie observer, polling fallback |
| `Views/Settings/Credentials/APIBillingView.swift` | Always-visible manual session key section |
| `Views/Settings/Credentials/PersonalUsageView.swift` | Always-visible manual session key section |
| `Views/Settings/Credentials/CLIAccountView.swift` | Removed incorrect tracking note |
| `Shared/Models/MenuBarIconConfig.swift` | `.battery` in `MultiProfileIconStyle`, per-profile `multiProfileIconStyle` override |
| `MenuBar/StatusBarUIManager.swift` | Per-profile battery rendering in multi-profile mode |
| `Views/Settings/App/ManageProfilesView.swift` | Per-profile icon style pickers |
| `MenuBar/StatusBarUIManager.swift` | Single-profile peak visuals/tooltips scoped to Claude only |
| `Views/CommandPaletteView.swift` | Command palette compile fixes for reinstall |

## 2026-09-27 local recovery

- Classify a Codex primary window lasting seven days as weekly, including when no secondary window exists. Regression coverage uses a weekly-only response.
- `openSettingsOnNextLaunch` opens settings once to recover from off-screen menu bar items on macOS 27.

- GitHub battery markers and pace colors now use the provider’s calendar-month duration in single and multi-profile modes. Battery and tooltip labels identify the monthly premium quota.
