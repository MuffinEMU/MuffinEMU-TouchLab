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
    // Both centre dots are named, L3 on the d-pad as R3 is on the diamond; the flat look names neither
    // on the d-pad, as it always drew it. HOME keeps half a button clear of the bottom edge in the polished
    // look (it sat 0.21 of a button off it, 7 pt on a phone with no home indicator).
    for d in TargetDevice.all {
        let ctx = d.context(.single)
        var flat = ctx; flat.showcaseStyle = false
        for (c, polished) in [(ctx, true), (flat, false)] {
            let pad = ZonePad()
            let e = PadEngine(scheme: pad, output: ZoneRecorder(), context: c)
            let dots = e.render().filter { $0.role == .dot }
            check(dots.contains { $0.label == "L3" } == polished, "zone \(d.name): the d-pad's centre dot is \(polished ? "" : "not ")named L3")
            check(dots.contains { $0.label == "R3" }, "zone \(d.name): the diamond's centre dot is named R3")
            guard let home = pad.controls.first(where: { $0.button == .home }),
                  let face = pad.controls.first(where: { $0.button == .a }) else { continue }
            let clearance = (c.safeBounds.maxY - home.shape.boundingBox.maxY) / face.shape.boundingBox.width
            check(polished ? clearance >= 0.499 : abs(clearance - 0.2135) < 0.01, "zone \(d.name): HOME is \(clearance) of a button from the bottom edge")
        }
    }

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
