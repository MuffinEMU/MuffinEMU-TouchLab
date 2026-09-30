# Integrating TouchLab into MuffinEMU

This is the complete guide for adding the four TouchLab control styles — **Zone, Float,
Adaptive, Frame** — to MuffinEMU. Read all of it before changing anything. The companion
files are [`CHECKLIST.md`](CHECKLIST.md) (tick-list for the whole job) and
[`DEVICE-TEST.md`](DEVICE-TEST.md) (the on-device test script).

First written against `kiddreads/MuffinEMU` **main @ `4c70e7d3`** and verified again
against **main @ `8de67090`** (every anchor below still held; see "Corrections from the
first integration" at the end). If main has moved, re-read each site before editing: the
line numbers here are hints, not addresses.

---

## 1. The goal, exactly

**Add all four styles as options. Replace nothing.**

- MuffinEMU's own pad (`OptimizedControlPanel`) **stays the default** for everyone,
  including every existing install. A fresh install and an upgraded install both open
  on MuffinEMU's own pad.
- Melo-Controller and the preview pad keep working exactly as they do today, with their
  existing settings keys and their existing top-bar button.
- The four TouchLab styles are chosen in **Settings › On-screen Controls › Control style**
  and in the in-game layout panel.
- Everything is built so that making a TouchLab style the default later is a **one-value
  change** (§9). Do not make that change.
- It must work on **every device MuffinEMU runs on, iOS 15 through iOS 27**: every iPhone
  and iPad that runs iOS 15+, any screen size, any iPad window size, with and without a
  home-button safe area. MuffinEMU is landscape-only; TouchLab also lays out correctly in
  portrait, which costs nothing and protects against a future orientation change.

Out of scope: drag-to-move / per-button editing for TouchLab styles (the layout panel
offers size and opacity for them, see §5.6), external-display dual-screen polish beyond
"doesn't break" (§6), changing anything about the other three pads.

---

## 2. What you are integrating

A Swift package, `MuffinTouchLab`, with two library products:

| Product | Platform | What it is |
|---|---|---|
| `TouchLabCore` | any | Touch model, the four schemes, `PadMixer`, stick maths, layouts. No UIKit. |
| `TouchLabUI` | iOS | `TouchPadView` (one UIView that owns every finger), `TouchPad` (SwiftUI wrapper), screen-frame helpers. |

Plus `touchlab-check` (behaviour + layout checks, runs on macOS) and `touchlab-render`
(SVG previews).

### The contract

The pad produces exactly four kinds of output, through a `PadOutput`:

```
setButton(PadButton, pressed:)   -> cemu_bridge_set_button_state
setStick(PadStick, StickValue)   -> cemu_bridge_set_stick_axis   (already +y up, never negate)
setTouchscreen(CGPoint?)         -> cemu_bridge_set_pad_touch    (normalised 0...1 in the GamePad view; nil = up)
releaseAll()                     -> cemu_bridge_release_all_buttons (+ touch up)
```

`PadMixer` pairs every press with its release **by construction**. A button is held while
any finger holds it, and a finger ending removes everything it contributed. No scheme can
leave a button held after its finger has gone. The adapter is a pass-through: don't add
de-duplication, timers or release logic on the MuffinEMU side.

### Why it is UIKit inside

MuffinEMU's own pad has lost buttons to SwiftUI hit testing more than once (see the
`.position()` + negative-padding note in `ControllerPad.swift`). TouchLab has no per-button
hit testing: one `UIView` receives raw touches and `PadEngine` decides what each finger
means. The consequences:

- **Don't** wrap `TouchPad` in gestures, `.contentShape`, `.padding(-x)`, `.scaleEffect`
  or `.allowsHitTesting` tricks. Size is the `scale` parameter. Visibility is mounting or
  not mounting it. Inertness is `enabled: false`.
- The view only takes touches a control (or the GamePad touchscreen) wants. Everything
  else falls through to whatever is underneath, including the top bar.
- Every stuck-input path is handled inside the view: `touchesCancelled`, leaving the
  window, `willResignActive` and `dismantleUIView` all release everything.

---

## 3. Ground rules for the MuffinEMU repo

These are not style preferences. Each one exists because breaking it has already cost
something.

1. **Never commit to `main` while working.** Every push to `main` builds and publishes a
   numbered public release (`vX.Y`). Work on a branch, e.g. `feature/touchlab-controls`.
2. **Feature branches do not build on push.** The workflow's `push` trigger only covers
   `main` and `ios27-sdk`. To get a test IPA from your branch, run
   `gh workflow run build-ios-app.yml --ref feature/touchlab-controls`. That run
   publishes an unnumbered `auto-<sha>` pre-release (the "Choose the version" step only
   numbers builds of `main`). **It also moves the rolling `nightly` pre-release to that
   build**: the "Update the rolling nightly" step runs for every non-PR build by design.
   Fine for an options-only change whose default is unchanged; know it happens. Opening a
   pull request into `main` also builds, but publishes nothing (the IPA is only a run
   artifact).
3. **Commit identity:** author and committer `kiddreads
   <285094405+kiddreads@users.noreply.github.com>`. **No AI co-author trailers, session
   trailers or "generated with" lines** in any commit, PR, release or file.
4. **Every commit carries a `Release-note:` trailer written for a player**, not a
   developer. Repeated trailers are one note wrapped across lines. `Release-note: skip`
   omits a commit (use it for build plumbing). Suggested note for the feature:
   ```
   Release-note: New control styles to try in Settings > On-screen Controls > Control
   Release-note: style: Zone, Float, Adaptive and Frame. MuffinEMU's own controls stay the
   Release-note: default.
   ```
5. **Public-repo hygiene.** Nothing committed (code comments, docs, site, release notes)
   may name a person, quote anyone, reference an issue tracker's ticket ids, mention AI
   sessions or agents, or contain local paths (`/Users/...`, `/Volumes/...`). Write
   comments about the code and the decision, not about who asked for it.
6. **Merging to `main` is the owner's call, after an on-device test.** Don't use GitHub's
   PR merge button or `PUT /pulls/N/merge`: they author the merge commit with the token
   account's profile name and email, which puts a personal name in public history. When
   the owner says to merge, let `POST /repos/{repo}/merges` (or a local merge) compute the
   tree. Then recreate the commit via `POST /git/commits` with the same tree and parents
   and an explicit kiddreads author/committer, and move the ref.
7. **Comment-only / docs-only commits** that must not cut a release go in with `[skip ci]`
   (docs and `*.md` are already in `paths-ignore`).
8. **Several agents share the local checkout.** Don't move `HEAD` in a shared tree, and
   don't revert changes you didn't make. Work in your own worktree or clone (§4.0).
9. **Never re-sync `src/` from upstream MeloCafe.** It's behind MuffinEMU; pulling from it
   is a regression. This job doesn't touch `src/` outside `src/ios` at all.
10. **A green build proves it compiles, not that touch works.** Only a finger on a device
    proves input. Hand the owner the `DEVICE-TEST.md` script and the test IPA, and don't
    call the job done before they've run it.

---

## 4. Step by step

### 4.0 Set up

- Check free disk space first (`df -h`). The machine this usually runs on is often nearly
  full. A full MuffinEMU worktree needs several hundred MB; a sparse one (below) is about
  30 MB. If there isn't room, commit through
  the GitHub API instead of a checkout (a helper for API commits as kiddreads may already
  exist on the machine; otherwise use `gh api` with `git/blobs`, `git/trees`,
  `git/commits` and `git/refs`).
- Branch from **current** `origin/main` (fetch first; a local clone may be days behind):
  ```
  git fetch origin
  git worktree add --no-checkout ../mfe-work -b feature/touchlab-controls origin/main
  cd ../mfe-work
  git sparse-checkout set --no-cone '/src/ios/' '/.github/' '/docs/docs/controls.html' '/README.md'
  git checkout
  ```
  This job only touches those paths, so the sparse checkout is enough. **Don't name the
  worktree `muffinemu-touchlab`**: macOS volumes are case-insensitive, so that is the same
  directory as a `MuffinEMU-TouchLab` checkout, `git worktree add` fails, and the
  `sparse-checkout` that follows is then run inside the TouchLab repo instead. (Undo with
  `git sparse-checkout disable`.)
- Set the repo-local identity (rule 3) in that worktree.

### 4.1 Vendor the package

From a TouchLab checkout that is committed and pushed:

```
tools/export-to-muffinemu.sh /path/to/muffinemu-worktree
```

This writes `src/ios/Packages/MuffinTouchLab/` (manifest, sources, licence) and
`VENDORED.md`, which records the TouchLab commit. It refuses to export uncommitted,
unpushed or failing code.

**Why vendored, not a remote package:** MuffinEMU is public and must build no matter
what happens to the TouchLab repo (visibility, CI billing, renames). Melo-Controller is a
remote package pinned by revision because it's a third-party project; TouchLab is
first-party code that ships inside MuffinEMU.

Then in `src/ios/project.yml`:

```yaml
packages:
  MeloController:
    url: https://github.com/stossy11/Melo-Controller
    revision: e39c6b7b87dc44dbbf548dc1e28fd6f0b0a5d609
  MuffinTouchLab:                       # add
    path: Packages/MuffinTouchLab       # add
```

and under `targets: MuffinEMU: dependencies:`:

```yaml
      - package: MuffinTouchLab
        product: TouchLabCore
      - package: MuffinTouchLab
        product: TouchLabUI
```

Don't add `Packages/` to `sources:`; it's a package, not app sources.

The project builds with a Swift 6.2+ Xcode on the `xcode-27` runner image, which has
exactly one (beta) Xcode. The package is Swift tools 5.9 and compiles in Swift 5 mode
there.

### 4.2 Add the drop-in file

Copy `integration/MuffinEMU/TouchLabPads.swift` to `src/ios/App/TouchLabPads.swift`
unchanged (then delete the header comment's first line). It contains:

- `TouchLabSettings`: keys, `defaultScheme = ""` (off), Adaptive's per-game storage and
  reset.
- `CemuBridgePadOutput`: the `PadOutput` over the bridge, with an explicit
  `PadButton → CemuBridgeButton` switch and the same diagnostic labels the other pads use.
- `TouchLabPadOverlay`: the mounted view. It reads MuffinEMU's existing size, opacity,
  haptics, deadzone, curve and gate keys, so those settings carry across styles.

TouchLab's CI compiles this exact file for iOS against stubs that mirror MuffinEMU's
declarations (`integration/MuffinEMU/compile-check/`). If it doesn't compile in MuffinEMU,
a real declaration has drifted from its stub. Fix the drop-in to match the real code, then
update the stub in TouchLab too.

This must be the **only** file that imports `TouchLabCore`/`TouchLabUI`. It also holds the
small helpers the rest of the app uses instead of importing (see 4.4): `touchLabTVScreen()`,
`touchLabGamePadScreen()`, `trackTouchLabScreens(_:imageIsAspectFit:)`, the
`TouchLabScreenState` wrapper struct, `TouchLabSettings.styles` / `summary(_:)` /
`cameraOptions` / `resetAdaptiveAll()`.

**Concurrency.** `PadDiagnostics` (and `UIScreen`) are main-actor isolated in the real app,
while `PadOutput` is not. The output therefore sends its diagnostics through
`Task { @MainActor in ... }` and reads a cached `renderScale` instead of `UIScreen.main`;
the bridge calls themselves stay direct and synchronous. The compile-check stub must carry
`@MainActor` on `PadDiagnostics` like the real one, or this class of error can't be caught
in CI. (It didn't at first.)

### 4.3 `PadDiagnostics.swift`

Add a case to `ActivePad`:

```swift
case touchLab = "TouchLab pad"
```

Read `PadDiagnosticsOverlay`. If it derives an "expected pad" from `useMeloControls` /
`previewPadEnabled`, extend it to know about the TouchLab setting too, so the overlay
never claims the wrong pad is live.

### 4.4 `ContentView.swift` — `EmulatorViewOptimized`

**a) State.** Next to the other pad `@AppStorage` properties (near
`@AppStorage(MeloControlsSetting.storageKey) private var useMeloControls`):

```swift
@AppStorage(TouchLabSettings.schemeKey) private var touchLabScheme = TouchLabSettings.defaultScheme
/// Where the TV / GamePad views are on screen, reported by the screens themselves.
/// Written only when the screen layout changes - never from the input path.
@State private var touchLabScreens = TouchLabScreens(frames: [:])
@State private var topBarHeight: CGFloat = 0
```

(The state's type is `TouchLabScreenState`, a wrapper struct in `TouchLabPads.swift`, so this
file needs no import.)

**b) `PadSystem`.** Add `case touchLab`. Precedence in `padSystem`:
**Melo-Controller › TouchLab › preview › MuffinEMU**:

```swift
if useMeloControls { return .melo }
if TouchLabSettings.isTouchLab(touchLabScheme) { return .touchLab }
if previewPadEnabled { return .preview }
return .muffin
```

Melo stays first so its top-bar toggle keeps meaning what it means today: on is
Melo-Controller, off is back to whatever was chosen before. An unknown or empty scheme id
falls through to the old behaviour, so a bad stored value can never leave the user
without a pad.

**c) Tell TouchLab where the screens are.** Tag every place a screen view is built:

- In `screenView(main:)`: `MetalViewIOS(gameManager: gameManager).touchLabScreenFrame(.tv)`
- In `padScreen`: `PadMetalViewIOS().gesture(...).touchLabScreenFrame(.gamepad)`, with the
  modifier **after** `.gesture`, so it measures the same frame the drag gesture uses.
- In the `smallGamePadTopRight` branch of `screenLayoutComposition`, the bare
  `MetalViewIOS(...)` there also gets `.touchLabScreenFrame(.tv)` (its `padScreen` is
  already covered).

In the tagging steps above use the drop-in's helpers: `.touchLabTVScreen()` and
`.touchLabGamePadScreen()` (they are `touchLabScreenFrame(.tv)` / `(.gamepad)`). In the
`smallGamePadTopRight` branch put the modifier **after** `.frame(...)` so it measures the
final frame.

Then on `screenLayoutComposition` itself (after its `.ignoresSafeArea`), add:

```swift
.trackTouchLabScreens($touchLabScreens, imageIsAspectFit: { !FrameStretch.isEnabled })
```

Frames are in window coordinates; `TouchPad(rectSpace: .window)` converts them.
`TouchLabScreens.touchscreenRect` is the GamePad **view's** frame, not the fitted image.
That's deliberate: `sendPadTouch` maps a touch as a position inside that view's size times
`effectiveRenderScale`, and the adapter does the same, so both touch paths agree exactly.

**Renderer (checked):** the core letterboxes the 16:9 image (`fullscreen_scaling =
kKeepAspectRatio`) unless Settings > Graphics > "Frame stretching" is on
(`FrameStretch.isEnabled`, key `muffin.render.stretchToFit`), which fills the view.
Hence `imageIsAspectFit: { !FrameStretch.isEnabled }` above. It is read when the screen
layout changes, so toggling it takes effect at the next layout change. This only changes
what Frame avoids covering; input is unaffected.

**d) Top bar height.** The pads are mounted **above** the top bar in the ZStack, and
TouchLab places shoulders in the top corners, where the Back button is. Measure the top
bar instead of hard-coding it: `.reportTopBarBottom()` (in `App/TouchLabTopBar.swift`, a
small `PreferenceKey` with the same pattern as `touchLabScreenFrame`, no package import) on
the top-bar `HStack` after its `.padding(12).background(...).borderBottom(...)`, and
`.onPreferenceChange(TopBarBottomKey.self)` on the enclosing top-aligned `VStack`, writing
`topBarHeight` only when it changed. Measure the `HStack`, not the `VStack`: the `VStack`
is framed to fill the screen. Pass it to the overlay as `topInset`. (In landscape the
safe-area top is 0 on every device, so the inset is not double counted; in portrait it can
be, which only makes the controls sit slightly lower.) The layouts then keep every
control below it. With `topInset` wrong, the symptom is "Back / pause don't respond with
Zone or Float".

**e) Mount.** In the pad block (`if !padControlsHidden { if useMeloControls { ... } else
if padSystem == .muffin { ... } }`), add a branch **between** the Melo and MuffinEMU ones:

```swift
} else if padSystem == .touchLab {
    TouchLabPadOverlay(
        schemeID: touchLabScheme,
        gameID: gameManager.currentGame?.id,
        screens: touchLabScreens,
        enabled: !isPaused && !isEditingControlLayout,
        topInset: topBarHeight
    )
    .onAppear { PadDiagnostics.shared.report(activePad: .touchLab) }
}
```

Don't add `.onDisappear { cemu_bridge_release_all_buttons() }`: `TouchPad` already
releases on dismantle. Adding it is harmless, but it's the kind of duplication that later
gets "fixed" in the wrong half.

**f) Preview composition.** Leave the `padSystem == .preview` branch alone. Since
`.touchLab` isn't `.preview`, TouchLab styles use `screenLayoutComposition` like
MuffinEMU's own pad does.

**g) Top-bar buttons.**
- The Melo toggle (`useMeloControls.toggle()`) needs no change. With a TouchLab style
  chosen, turning Melo on shows Melo; turning it off returns to the TouchLab style.
- "Hide controls to touch the GamePad screen" (`padControlsHidden`) needs no change. With
  TouchLab hidden, `padScreen`'s own drag gesture handles the touchscreen as before. Note
  that TouchLab styles already pass GamePad-screen touches through wherever no control is,
  so this button matters less with them.

### 4.5 In-game layout panel

`isEditingControlLayout` shows a panel. There's one branch for Melo and one for
MuffinEMU's pad (look for `if isEditingControlLayout, useMeloControls {` and the
following `} else if isEditingControlLayout {`). Add a TouchLab branch **before** the
generic one, matching the panel's existing look and dismiss behaviour. It contains:

(This is `TouchLabLayoutPanel` in `App/TouchLabControlsUI.swift`; ContentView only
mounts it, with `else if isEditingControlLayout, padSystem == .touchLab`.)

- **Control style** picker: MuffinEMU / Zone / Float / Adaptive / Frame. It writes
  `touchLabScheme`; picking "MuffinEMU" writes `""`. Changing style releases inputs via
  the pad's own teardown.
- **Size** slider → `ControllerLayoutSettings.scaleKey` (same range as today, 0.6–1.6)
- **Opacity** slider → `ControllerLayoutSettings.opacityKey`
- **Float only:** Camera = Floating stick / Swipe → `TouchLabSettings.floatCameraKey`
- **Adaptive only:** "Reset learned layout for this game" →
  `TouchLabSettings.resetAdaptive(gameID:)`
- **Done** (same as the existing panel)

A line of text explains that TouchLab styles don't support dragging individual buttons.
While the panel is open the pad is visible but inert (`enabled: false`), so a slider drag
can't press anything.

### 4.6 Settings — `Settings/OnScreenControlsSection.swift`

Add a **Control style** picker at the top of the section:

| Row | Stored value |
|---|---|
| MuffinEMU (default) | `""` |
| Zone | `"zone"` |
| Float | `"float"` |
| Adaptive | `"adaptive"` |
| Frame | `"frame"` |

- Under the picker, show the selected style's one-line summary (`SchemeInfo.summary`, or
  your own wording in the same spirit).
- Choosing a TouchLab style while "Use melo-controls" is on turns melo-controls **off**,
  because the user just picked something else. The reverse doesn't clear the style: Melo
  simply takes precedence while it's on.
- Rows that only apply to MuffinEMU's own pad (joystick mode, comfort controls, the
  per-control editor) are hidden or disabled while a TouchLab style is selected. Size,
  opacity, haptics, deadzone, curve and gate stay, because TouchLab reads them.
- The stick rows (gate, deadzone, fine control) are shown for TouchLab styles even with
  "Add analog sticks" off, because TouchLab always has sticks and reads the same keys.
  "Add analog sticks" and "Comfort controls" are hidden.
- Float's camera option and Adaptive's reset button, as in the in-game panel. Adaptive's
  button in Settings resets every game (no game is open there); the in-game panel resets
  the current game. The rows are `TouchLabStyleSettingsRows` in
  `App/TouchLabControlsUI.swift`, placed first in the section.
- The picker labels come from `touchLabStyleLabel`, which marks whichever style
  `TouchLabSettings.defaultScheme` names as "(default)", so promotion (§9) relabels itself.
- Keep `MeloControlsSetting` and the preview toggle exactly as they are.

### 4.7 CI

In `.github/workflows/build-ios-app.yml`, after "Select full Xcode and install build
tools" and before the long core build, add:

```yaml
      - name: TouchLab behaviour and layout checks
        run: |
          swift run --package-path src/ios/Packages/MuffinTouchLab \
            --scratch-path "$RUNNER_TEMP/touchlab-build" touchlab-check
```

It runs on the macOS runner in seconds and fails the build on any layout or input
regression in the vendored package.

The app step already uses a new Xcode (for the iOS 26+ SDK). The package targets iOS 15
with Swift tools 5.9, so it compiles in Swift 5 mode under any Xcode from 15 up. Don't
raise its tools version as part of this job.

### 4.8 Public docs

MuffinEMU's controls help page (`docs/docs/controls.html`) and README controls section
get a short, player-facing description of the four styles and where to switch. They must
say MuffinEMU's own controls are still the default. Follow the public-repo hygiene rule,
and credit nothing to third parties (TouchLab is first-party).

---

## 5. Behaviour spec (what "done" looks like)

| Situation | Expected |
|---|---|
| Fresh install / upgrade | MuffinEMU's own pad, as today. |
| Style = Zone/Float/Adaptive/Frame, Melo off | That style is on screen; nothing else is. |
| Melo on (any style chosen) | Melo-Controller. |
| Preview pad on, style = MuffinEMU | Preview pad, as today. Style = TouchLab wins over preview. |
| Paused | TouchLab pad drawn, takes no touches, nothing held. |
| Layout panel open | Pad drawn, inert; panel controls work. |
| "Hide controls" | No pad; GamePad screen touch works through MuffinEMU's own gesture. |
| Holding a stick, tap Back / pause | The button works (the pad only takes touches it wants). |
| Touch on the GamePad image where no control is | Wii U touchscreen touch, exactly where the finger is. |
| Screen layout changed / screens swapped | Pad re-lays out; Frame moves to the new margins. |
| App backgrounded mid-press, incoming call, Control Centre pull | Everything released; nothing held on return. |
| Switch style mid-game | Old pad releases everything; new pad appears. |
| Different game | Adaptive uses that game's learned layout (or home positions). |
| External display (`.dualScreen`) | No crash, pad works. Touchscreen passthrough only where a GamePad view is on this device. |
| iOS 15 device | Everything above, except the iOS 16+ system-gesture deferral if MuffinEMU uses it. |

---

## 6. Verification

1. **Static:** `git grep -n "import TouchLab"` shows only `App/TouchLabPads.swift`. No
   `release_all` / `set_pad_touch` calls were added outside it and the existing sites. No
   names, ticket ids or local paths in the diff (`git diff origin/main | grep -nE
   "/Users/|/Volumes/|BW-[0-9]"` is empty).
2. **Package:** `swift run --package-path src/ios/Packages/MuffinTouchLab touchlab-check`
   → `... passed, 0 failed`.
3. **Build:** `gh workflow run build-ios-app.yml --ref feature/touchlab-controls`, and it's
   green. Read the build log for new warnings from `TouchLabPads.swift`.
4. **Device:** hand over the `auto-<sha>` pre-release IPA with
   [`DEVICE-TEST.md`](DEVICE-TEST.md). Record the result per style. Anything failing gets
   fixed on the branch, and the device test runs again.
5. Only then ask the owner whether to merge (rule 6).

---

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Buttons light up but the game ignores them | Output not reaching the bridge: check `CemuBridgePadOutput` is the `output`, and that PadDiagnostics' input count moves. |
| Every press releases instantly / flickers | Something rebuilt the pad per input: a `@State` write in the output path, or `revision` changing per input. |
| Back / pause dead with Zone or Float | `topInset` is 0 or too small; the shoulders cover the top bar. |
| GamePad touches land offset | `touchLabScreenFrame(.gamepad)` is on the wrong view, or `gamepadViewSize` isn't synced; compare with `sendPadTouch`. |
| Frame covers the picture / leaves big gaps | `imageIsAspectFit` wrong for the renderer (§4.4c). |
| Stick moves the wrong way vertically | Someone negated y. `StickValue` is already +y up. |
| Two touchscreen touches at once | Something else also sends `set_pad_touch` for the same finger. `padScreen`'s gesture is under TouchLab and shouldn't fire while TouchLab owns that rect. |
| Adaptive "forgets" | `gameID` nil (shares the `default` key) or the reset counter changed. |

---

## 8. Updating TouchLab later

Change TouchLab in its own repo, run its checks, push, re-run
`tools/export-to-muffinemu.sh`, and commit the vendored diff plus the new `VENDORED.md`
commit id in one MuffinEMU commit. Never hand-edit `src/ios/Packages/MuffinTouchLab`.

---

## 9. Promoting a style to the default (future — do not do now)

When the owner decides a TouchLab style should replace MuffinEMU's pad as the default:

1. Change `TouchLabSettings.defaultScheme` from `""` to that style's id. Users who never
   touched the setting get the new default. Anyone who explicitly chose something keeps
   their choice, because `@AppStorage` only uses the default when nothing is stored.
2. Relabel the Settings rows ("MuffinEMU (classic)", "Zone (default)", ...).
3. Update the controls help page and write a release note saying what changed and how to
   switch back.

Nothing else should need to move. If it does, this integration missed something; fix that
instead.

---

## 10. Known limitations (say them, don't hide them)

- No per-button drag editing for TouchLab styles (size and opacity only).
- Float's swipe camera is velocity-based and may feel different per game; the floating
  stick is the default.
- On a single 16:9 screen on a 4:3 iPad there's no real margin, so Frame falls back to
  Zone's layout. That's intended.
- Everything is compile- and logic-checked. The on-device test is the real proof.
- Build coverage: TouchLab's CI builds the package, the bench app and the drop-in with
  Xcode 16.4 (iOS 18 SDK) and Xcode 26.3 (iOS 26 SDK), deployment target iOS 15. The
  MuffinEMU workflow builds the app on the `xcode-27` image, so a MuffinEMU build is the
  first compile against the iOS 27 SDK. The package uses only long-stable UIKit /
  SwiftUI API (nothing newer than iOS 15, nothing deprecated), so no source changes are
  expected, but check that build's log for warnings.


---

## 11. Corrections from the first integration

Things the first real integration (against main @ `8de67090`) found that the guide had
wrong or didn't say, all folded into the sections above:

- The worktree directory name collided with the TouchLab checkout on a case-insensitive
  volume (4.0).
- A sparse worktree is enough and is ~30 MB (4.0).
- Branch builds also move the rolling `nightly` pre-release (3, rule 2).
- `PadDiagnostics` and `UIScreen` are main-actor isolated; the compile-check stub wasn't, so
  it missed a real-app compile error. Stub and drop-in fixed (4.2).
- ContentView can't use package types without importing them, so the drop-in carries
  wrappers (4.2, 4.4c). A plain `typealias` isn't enough: a property whose type lives in
  `TouchLabUI` makes the compiler warn in any file that doesn't import it, so the state is
  a wrapper struct (`TouchLabScreenState`).
- The renderer is aspect-fit unless "Frame stretching" is on; `imageIsAspectFit` follows it
  (4.4c).
- Settings hid the stick gate, deadzone and curve unless "Add analog sticks" was on, which
  would have hidden settings TouchLab reads (4.6).
- The CI step belongs after the Xcode select step, with a scratch path (4.7).
- The in-game top bar is a `VStack` framed to the whole screen; measure the inner `HStack`
  (4.4d).
