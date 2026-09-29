# Upstream sync → v3.3.0 (selective integration)

**Started:** 2026-09-29 · **Branch:** `sync/upstream-3.3.0` · **Clone:** `~/Code/Claude-Usage-Tracker`

## Why
Installed fork (3.1.2-based) stops syncing after sleep. Upstream fixed this in v3.2.0 (#268) and shipped many more fixes. Goal: bring upstream v3.3.0 improvements in **without losing any fork customization**.

## Strategy
No wholesale merge: upstream built parallel versions of the fork's provider system (Codex), and credential Keychain storage. Merging both would double-migrate credentials. Keep the fork's architecture as base; cherry-pick standalone upstream commits; manually adapt credential/refresh fixes to `ProfileKeychainVault` / fork refresh path.

## Triage (upstream commits since merge-base e46c98e)

### Already in fork (earlier selective sync / audit)
36056d5, f6caf1d, 37d5ecd, 29f2dd8, b3b5797, 525345b, peak-hours removal (8d253ea, 9983056, fdc8b40, 54ed681).

### Skip (intentionally)
- 3763cd6 heartbeat analytics ping — phones home to upstream dev.
- a9fee08, 536044c, bbcf447, c8c4f39, a500363 — sponsor slot / buy-me-a-coffee reminder window.
- README/docs/CI/release bumps: 03b2360, 8601ddd, ba69fe2, 7134982, f5670bf, 5146e15, 5d5666f, 77934d8, 3e99b9f, 6b04b47, 980d1e6 (version part), e6180b2, 2b40dc3, 574eb37, 18d1f58, 89691d8, 0944dea, 36d3278, 2eb60cf, 22b14cf, 96b73c2, ab8dd1b, 300ac50, f4f0c68, 588775e.
- 52bc240 upstream multi-provider arch + Codex — fork already has Codex/Copilot providers (ideas may be ported, not the architecture).
- ba99f58, e38538e, 551faa6, 7c5c799, c66e0d9 upstream data-protection keychain migration — fork has its own vault (`profiles_v4`).

### Take / adapt
Full list with commit ids: `CUSTOM-CHANGES.md` §19.

## Root cause of "doesn't sync automatically"
1. Continuity check required a shared token; Claude Code rotates both tokens → mismatch → gates said "no credentials" → no refresh.
2. No token refresh at all; an idle CLI (sleep) leaves an expired token → dormant.
3. (latent) history blobs in UserDefaults → 4 MB limit silently drops credential writes.

## Progress log
- [x] Baseline build of fork main succeeds.
- [x] UI/crash fixes, languages, API service, sign-in, dormancy fix, Codex refresh, history files, right-click menu, Dynamic Island, statusline, thresholds, i18n parity.
- [x] Build green; tests: 211 passed, 1 stale threshold test updated.
- [ ] Independent review of credential changes → apply findings.
- [ ] Re-run tests, back up current app + prefs, install, verify live refresh.
- [ ] Merge to main + push (ask user).
