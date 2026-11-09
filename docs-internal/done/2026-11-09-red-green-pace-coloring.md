# PRD: Red only when ahead of the time curve; orange behind a setting

Status: implemented 9.11.2026.

## Problem and goals
The menu bar icon and popover bars turn red when the forecast usage at reset is 90% or more. That means red shows while Mario is still slightly *behind* the time curve. Orange (forecast 70–90%) adds noise.

Goals:
- Red means exactly "ahead of the time curve": used% > elapsed%.
- Orange is optional (new setting "Show orange warning"), default **off** → plain red/green.

## Non-goals
- Claude Code terminal statusline (own 10-step gradient): unchanged.
- 6-tier pace marker (time-curve tick colour, `PaceStatus`): unchanged.
- API-billing / static-threshold logic beyond what is listed below.

## Rules (projected = usedFraction / elapsedFraction)
Pace rule applies when pace coloring is on, 0 < t < 1, u > 0, and (t ≥ 0.15 or projected ≥ 1.5), the same warm-up as today.

| Orange setting | Green | Orange | Red |
|---|---|---|---|
| off (default) | projected ≤ 1.0 | – | projected > 1.0 |
| on | projected < 0.85 | 0.85 ≤ projected ≤ 1.0 | projected > 1.0 |

Fallback (warm-up, pace coloring off, or no reset time), based on used %:
- orange off: green < 90% used, red ≥ 90% used (remaining mode: red below 10% remaining).
- orange on: unchanged upstream thresholds (70/90 used, 30/10 remaining).

## Interface changes
- `UsageStatusCalculator.calculateStatus(..., showOrange: Bool = true)` (true keeps upstream tests and API; every app caller passes the profile setting, which defaults to off).
- `MenuBarIconConfig` and the multi-profile config gain `showOrangeWarning: Bool` (decode default `false`, encode it).
- Settings toggle under "pace coloring" in `AppearanceSettingsView` and `ManageProfilesView`; new localization keys (all locales, passes `validate_localizations.sh`).
- Callers: `MenuBarIconRenderer` (session/week/api), `PopoverContentView` (both bar views), `StatusBarUIManager` (provider rows).

## Edge cases
- Exactly on the curve (projected == 1.0) → green (orange when orange is on).
- Period over (t ≥ 1) or no elapsed data → fallback thresholds.
- Remaining-display mode: the pace rule uses used%/elapsed internally (callers already pass raw elapsed), so behaviour is the same.

## Implementation slices
1. Calculator + unit tests (`UsageStatusCalculatorTests`): update existing expectations, add orange-off/on cases at 0.84 / 0.85 / 1.0 / 1.01, warm-up, fallback.
2. Config field + Codable default + settings toggles + localization.
3. Wire the setting through all callers.
4. Docs: `CUSTOM-CHANGES.md`, CHANGELOG.

## Test plan
- `xcodebuild test -scheme "Claude Usage" -destination 'platform=macOS'` (calculator tests).
- `./scripts/validate_localizations.sh`.
- Build + reinstall via `./scripts/build-and-install.sh`; visually check icon is green when behind curve, red when ahead; toggle orange on → orange band appears.

## Rollout
- Default off → existing saved profiles decode without the key → red/green automatically on both Macs after install. The Mac mini needs its own rebuild/install.

## Open questions
- None blocking.
