// Reference integration for MuffinEMU - not compiled in this repo (it needs the bridge).
//
// Two pieces: an output that forwards to the cemu_bridge input API, and the mount in
// EmulatorViewOptimized next to the existing pad-system branch. PadButton and PadStick
// raw values ARE CemuBridgeButton / CemuBridgeStick values, so there is no label table.

import SwiftUI
import TouchLabCore
import TouchLabUI

/// PadOutput over the bridge. PadMixer has already de-duplicated and paired everything, so
/// this is a straight pass-through.
final class CemuBridgePadOutput: PadOutput {
    /// The GamePad render surface in PHYSICAL pixels - the same numbers passed to
    /// cemu_bridge_resize_render_surface() for the pad surface (points x the render scale
    /// in effect). cemu_bridge_set_pad_touch() expects positions in that space.
    var padSurfacePixels: () -> CGSize

    init(padSurfacePixels: @escaping () -> CGSize) {
        self.padSurfacePixels = padSurfacePixels
    }

    func setButton(_ button: PadButton, pressed: Bool) {
        PadDiagnostics.shared.recordInput(button.description, pressed)
        cemu_bridge_set_button_state(CemuBridgeButton(rawValue: UInt32(button.rawValue)), pressed)
    }

    func setStick(_ stick: PadStick, _ value: StickValue) {
        // StickValue is already the console's convention (+y up): no negation here.
        cemu_bridge_set_stick_axis(CemuBridgeStick(rawValue: UInt32(stick.rawValue)), Float(value.x), Float(value.y))
    }

    func setTouchscreen(_ point: CGPoint?) {
        guard let point else { cemu_bridge_set_pad_touch(0, 0, false); return }
        let px = padSurfacePixels()
        cemu_bridge_set_pad_touch(Double(point.x * px.width), Double(point.y * px.height), true)
    }

    func releaseAll() {
        cemu_bridge_release_all_buttons()
    }
}

// ---- Mount, in EmulatorViewOptimized, beside the existing pad branches ----
//
//     if !padControlsHidden {
//         if useMeloControls {
//             MeloControlsOverlay(...)
//         } else if padSystem == .touchLab {
//             TouchPad(schemeID: touchLabScheme,                // "zone" | "float" | "adaptive" | "frame"
//                      output: touchLabOutput,                    // one CemuBridgePadOutput, kept in @State
//                      touchscreenRect: gamepadScreenFrame,       // the GamePad MetalLayerView's frame,
//                      videoRects: [tvScreenFrame, gamepadScreenFrame].compactMap { $0 },  // in this ZStack's space
//                      scale: controlScale, opacity: controlOpacity, haptics: padHaptics)
//                 .ignoresSafeArea()
//                 .onAppear { PadDiagnostics.shared.report(activePad: .touchLab) }
//         } else if padSystem == .muffin {
//             OptimizedControlPanel(...)
//         }
//     }
//
// Notes for the real integration:
// - When TouchLab owns the GamePad touchscreen, the existing touch handler on the GamePad
//   render view must be off for that pad system, or both send cemu_bridge_set_pad_touch.
// - The stuck-button guard is inside TouchPadView (window removal, resign-active,
//   touchesCancelled, dismantleUIView). Nothing else needs to call release-all for it.
// - Adaptive: persist `AdaptivePad.learned` per game (onLearned) and pass it back in
//   through `AdaptivePad(learned:)`. TouchPad builds schemes from SchemeCatalog, so this
//   needs a TouchPadView held directly, or a catalog hook - not done yet.
// - Float's camera mode (.stick / .swipe) is likewise a constructor argument today.
