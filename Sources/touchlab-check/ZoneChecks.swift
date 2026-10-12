import CoreGraphics
import Foundation
import TouchLabCore

// Zone: the polish fixes, and per-button / per-group editing.

private final class ZoneRecorder: PadOutput {
    var held: Set<PadButton> = []
    func setButton(_ button: PadButton, pressed: Bool) { if pressed { held.insert(button) } else { held.remove(button) } }
    func setStick(_ stick: PadStick, _ value: StickValue) {}
    func setTouchscreen(_ point: CGPoint?) {}
    func releaseAll() { held = [] }
}

func runZoneChecks() {
    // A stick is drawn at the size it is caught at, on every device: the ring is the catchment
    // circle, and the knob fills the same share of it whatever size the arrangement settled on.
    for d in TargetDevice.all {
        for display in TargetDevice.Display.allCases {
            let ctx = d.context(display)
            let pad = ZonePad()
            let e = PadEngine(scheme: pad, output: ZoneRecorder(), context: ctx)
            let rings = e.render().filter { $0.role == .stickBase }
            let knobs = e.render().filter { $0.role == .stickKnob }
            let sticks = pad.controls.filter { if case .stick = $0.kind { return true } else { return false } }
            check(rings.count == 2 && knobs.count == 2 && sticks.count == 2, "zone \(d.name) \(display): both sticks are drawn")
            guard rings.count == 2, knobs.count == 2, sticks.count == 2 else { continue }
            for (ring, stick) in zip(rings, sticks) {
                check(abs(ring.shape.boundingBox.width - stick.shape.boundingBox.width) < 0.01,
                      "zone \(d.name) \(display): a stick's ring (\(ring.shape.boundingBox.width)) is drawn at its catchment (\(stick.shape.boundingBox.width))")
            }
            for (knob, stick) in zip(knobs, sticks) {
                let want = PadParts.knobDiameter / PadParts.stickBaseDiameter * stick.shape.boundingBox.width
                check(abs(knob.shape.boundingBox.width - want) < 0.01, "zone \(d.name) \(display): a knob keeps its share of the ring")
            }
        }
    }
}
