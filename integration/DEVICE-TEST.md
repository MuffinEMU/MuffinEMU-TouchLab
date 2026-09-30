# On-device test: TouchLab styles in MuffinEMU

About 20 minutes. Use any game with 3D movement and a camera, and ideally one that uses
the GamePad touchscreen. Install the test IPA from the `auto-<sha>` pre-release over (or
beside) the current build.

Write down **pass / fail + what happened** for every line. "Felt off" is a valid result;
say what felt off.

## 0. Nothing changed by default
- [ ] Open a game without touching Settings: **MuffinEMU's own controls** are on screen, same as before.
- [ ] Melo-Controller top-bar button still switches to Melo-Controller and back.

## 1. Every style, every time (repeat for Zone, Float, Adaptive, Frame)
Settings › On-screen Controls › Control style › pick the style, then open a game.
- [ ] A, B, X, Y each do their action, one press = one action.
- [ ] D-pad: up / down / left / right, and a diagonal.
- [ ] L, R, ZL, ZR, +, −, HOME.
- [ ] Left stick walks in all directions; slow push = slow walk.
- [ ] Right stick turns the camera.
- [ ] L3 and R3 (Zone/Adaptive: centre dots; Float/Frame: double-tap-and-hold the stick).
- [ ] Hold the left stick and press A at the same time: both work.
- [ ] Hold the left stick and tap Back / pause in the top bar: the button responds.
- [ ] Tap the GamePad picture where there's no button: the game sees a touch in the right spot.
- [ ] Pause: controls go inert; resume: they work, nothing is stuck held.
- [ ] Swipe down Control Centre mid-press, then come back: nothing is stuck.

## 2. Style-specific
- **Zone:** roll a thumb from B to A without lifting (A takes over); rest a thumb between A and B (both pressed).
- **Float:** the stick appears under the thumb wherever it lands on the left; the knob stops at full push; a small dot marks the centre; nothing is drawn when not touching. Try Camera = Swipe in the layout panel.
- **Adaptive:** tap A a little off-centre 30+ times; the face buttons drift toward the thumb (slowly, a little). Reset in the layout panel puts them back.
- **Frame:** with both screens shown, controls sit beside the pictures and cover neither. With one screen, it falls back to the Zone layout.

## 3. Settings and panel
- [ ] Size and Opacity sliders change the TouchLab pad live.
- [ ] Layout panel: switching style there works; Done closes it; nothing pressed while dragging sliders.
- [ ] Switch back to "MuffinEMU (default)": the old pad returns exactly as before.

## 4. Devices (whatever is at hand)
- [ ] iPad (note model + iOS version)
- [ ] iPhone (note model + iOS version)
- [ ] An iOS 15 or 16 device if available
