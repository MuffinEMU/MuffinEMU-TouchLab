# TouchLab → MuffinEMU checklist

Tick every box, in order. Each maps to a section of [INTEGRATION.md](INTEGRATION.md).

## Before touching anything
- [ ] Read INTEGRATION.md end to end, including §3 (ground rules).
- [ ] `df -h`: enough room for a worktree? If not, plan API commits (§4.0).
- [ ] `git fetch origin`; note `origin/main`'s sha. If it isn't `4c70e7d3`, re-read every edit site before editing.
- [ ] Worktree/branch `feature/touchlab-controls` from `origin/main`. Not the shared checkout's `HEAD`, not `main`.
- [ ] Repo-local identity = kiddreads (`git config user.name kiddreads`, `user.email 285094405+kiddreads@users.noreply.github.com`).
- [ ] TouchLab checkout is clean and pushed; `swift run touchlab-check` passes there.

## Wiring (one commit per bullet group is fine; each with a `Release-note:` trailer)
- [ ] `tools/export-to-muffinemu.sh <worktree>`: `src/ios/Packages/MuffinTouchLab/` + `VENDORED.md` exist.
- [ ] `project.yml`: `MuffinTouchLab` package (path) + `TouchLabCore` and `TouchLabUI` dependencies. `Packages/` not in `sources`.
- [ ] `App/TouchLabPads.swift` added from `integration/MuffinEMU/TouchLabPads.swift`.
- [ ] `PadDiagnostics.ActivePad.touchLab` added; overlay's expected-pad logic knows about it.
- [ ] `EmulatorViewOptimized`: `touchLabScheme`, `touchLabScreens`, `topBarHeight` state.
- [ ] `PadSystem.touchLab` + precedence Melo › TouchLab › preview › MuffinEMU.
- [ ] `.touchLabScreenFrame(.tv)` on both `MetalViewIOS` sites; `.touchLabScreenFrame(.gamepad)` on `padScreen` (after `.gesture`).
- [ ] `.onPreferenceChange(TouchLabScreenFramesKey.self)` on `screenLayoutComposition`, writing only when changed.
- [ ] Renderer checked: aspect-fit or fill? `imageIsAspectFit` set to match.
- [ ] Top bar height measured via preference; passed as `topInset`.
- [ ] Mount branch between Melo and MuffinEMU; `enabled: !isPaused && !isEditingControlLayout`.
- [ ] In-game layout panel: TouchLab branch (style, size, opacity, Float camera, Adaptive reset, Done, no-drag note).
- [ ] Settings: Control style picker (MuffinEMU default first) + summary; choosing a style turns melo-controls off; MuffinEMU-only rows hidden while a style is chosen.
- [ ] CI: `touchlab-check` step before the app build.
- [ ] Controls help page + README: short player-facing section; says MuffinEMU's own controls are still the default.

## Must remain true
- [ ] `TouchLabSettings.defaultScheme == ""`: MuffinEMU's own pad is still the default.
- [ ] Melo-Controller, preview pad and MuffinEMU pad code paths unchanged apart from the enum case/branch additions.
- [ ] `git grep -n "import TouchLab"`: only `App/TouchLabPads.swift`.
- [ ] No `@State` writes of `EmulatorViewOptimized` in any input callback.
- [ ] No `.scaleEffect` / gestures / negative padding around `TouchPad`.
- [ ] Deployment target still iOS 15; no iOS 16+ API without `if #available`.
- [ ] Diff has no names, ticket ids, AI mentions or local paths: `git diff origin/main | grep -nE "/Users/|/Volumes/|BW-[0-9]|Claude|Co-Authored"` is empty.
- [ ] Every commit: kiddreads author, `Release-note:` trailer, no AI trailers.

## Build and hand-off
- [ ] `swift run --package-path src/ios/Packages/MuffinTouchLab touchlab-check`: 0 failed.
- [ ] `gh workflow run build-ios-app.yml --ref feature/touchlab-controls`: green; build log has no new warnings from TouchLabPads.swift.
- [ ] `auto-<sha>` pre-release IPA link + [DEVICE-TEST.md](DEVICE-TEST.md) handed to the owner.
- [ ] Device results recorded per style; failures fixed on the branch and re-tested.
- [ ] Merge only when the owner says so, using the kiddreads-authored merge procedure (INTEGRATION.md §3 rule 6). Never the PR merge button.
- [ ] After merge: note whether the `ios27-sdk` branch needs `main` merged in (ask the owner).
