import CoreGraphics
import Foundation
import TouchLabCore

// Behaviour and layout checks. Exit status is the number of failures, so CI fails on any.

final class Recorder: PadOutput {
    var log: [String] = []
    var held: Set<PadButton> = []
    var sticks: [PadStick: StickValue] = [:]
    var screen: CGPoint?
    func setButton(_ button: PadButton, pressed: Bool) {
        log.append("\(button)\(pressed ? "+" : "-")")
        if pressed { held.insert(button) } else { held.remove(button) }
    }
    func setStick(_ stick: PadStick, _ value: StickValue) { sticks[stick] = value }
    func setTouchscreen(_ point: CGPoint?) { screen = point }
    func releaseAll() { log.append("releaseAll"); held = []; sticks = [:] }
}

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if ok { passes += 1 } else { failures += 1; print("FAIL: \(what())") }
}
func near(_ a: Double, _ b: Double, _ tol: Double = 0.02) -> Bool { abs(a - b) <= tol }

// MARK: Mixer

do {
    let r = Recorder(), m = PadMixer(output: r)
    m.update(1, .press(.a)); m.update(2, .press(.a))
    m.remove(1)
    check(r.held == [.a], "A must stay held while a second finger holds it")
    m.remove(2)
    check(r.held.isEmpty && r.log == ["A+", "A-"], "exactly one press and one release, got \(r.log)")

    m.update(3, Contribution(stick: .left, stickValue: StickValue(x: 0.5, y: 0)))
    m.update(4, Contribution(stick: .left, stickValue: StickValue(x: -1, y: 0)))
    check(r.sticks[.left] == StickValue(x: -1, y: 0), "newest finger owns the stick")
    m.remove(4)
    check(r.sticks[.left] == StickValue(x: 0.5, y: 0), "older finger takes the stick back")
    m.remove(3)
    check(r.sticks[.left] == .zero, "stick centres when its last finger lifts")

    m.update(5, .press(.b, .zr))
    m.reset()
    check(r.log.last == "releaseAll" && m.pressed.isEmpty, "reset releases everything")
}

// MARK: Stick and d-pad maths

do {
    let t = StickTuning(deadzone: 0.1, curve: 1, gate: .round)
    let up = StickMath.value(offset: CGPoint(x: 0, y: -100), travel: 100, tuning: t)
    check(near(up.y, 1) && near(up.x, 0), "finger up the screen = +y (console convention), got \(up)")
    let dz = StickMath.value(offset: CGPoint(x: 9, y: 0), travel: 100, tuning: t)
    check(dz == .zero, "inside deadzone = zero")
    let justOut = StickMath.value(offset: CGPoint(x: 15, y: 0), travel: 100, tuning: t)
    check(justOut.x > 0 && justOut.x < 0.1, "deadzone is rescaled, not a jump: \(justOut.x)")
    let oct = StickTuning(deadzone: 0, curve: 1, gate: .octagon)
    let flat = StickMath.value(offset: CGPoint(x: 200 * cos(CGFloat.pi / 8), y: -200 * sin(CGFloat.pi / 8)), travel: 100, tuning: oct)
    check(near(flat.magnitude, cos(Double.pi / 8), 0.01), "octagon flat caps at cos(22.5deg): \(flat.magnitude)")
    let diag = StickMath.value(offset: CGPoint(x: 200, y: -200), travel: 100, tuning: oct)
    check(near(diag.magnitude, 1, 0.01), "octagon vertex reaches full travel")

    func dirs(_ deg: Double) -> Set<PadButton> { DPadMath.directions(angle: CGFloat(deg * .pi / 180)) }
    check(dirs(0) == [.right] && dirs(90) == [.up] && dirs(180) == [.left] && dirs(-90) == [.down], "cardinals")
    check(dirs(20) == [.right], "20deg is still right (wide cardinals)")
    check(dirs(45) == [.right, .up] && dirs(-135) == [.left, .down] && dirs(135) == [.left, .up], "diagonals")
    check(dirs(-179) == [.left] && dirs(179) == [.left], "wraps at 180")
}

// MARK: Layouts on every device

for info in SchemeCatalog.all {
    for device in TargetDevice.all {
        for display in TargetDevice.Display.allCases {
            let scheme = SchemeCatalog.make(info.id) as! ControlScheme
            let ctx = device.context(display)
            scheme.layout(ctx)
            let where_ = "\(info.name) / \(device.name) / \(display.rawValue)"
            let problems = LayoutCheck.problems(scheme.controls, in: ctx.safeBounds)
            check(problems.isEmpty, "\(where_): \(problems.joined(separator: "; "))")

            // Every GamePad input must be reachable somehow.
            var reachable = Set<PadButton>()
            var stickCount = 0
            for c in scheme.controls {
                switch c.kind {
                case .button(let b): reachable.insert(b)
                case .dpad(let click, _, _, _):
                    reachable.formUnion([.up, .down, .left, .right]); if let click { reachable.insert(click) }
                case .stick(_, _, let click), .floatingStick(_, _, _, _, let click):
                    stickCount += 1; if let click { reachable.insert(click) }
                case .swipeStick: stickCount += 1
                }
            }
            let missing = Set(PadButton.allCases).subtracting(reachable)
            check(missing.isEmpty, "\(where_): unreachable \(missing.map(\.description).sorted())")
            check(stickCount == 2, "\(where_): \(stickCount) sticks")

            if let frame = scheme as? FramePad, frame.mode != .overlay {
                for c in scheme.controls where !c.isZone {
                    for v in ctx.videoRects where v.insetBy(dx: 1, dy: 1).intersects(c.shape.boundingBox) {
                        check(false, "\(where_): Frame control \(c.label) covers the video")
                    }
                }
            }
        }
    }
}

// MARK: Any window size
// iPad Split View, Slide Over, Stage Manager and iOS 26+ free-form windows can hand the pad
// almost any size. Sweep a grid of them: every layout must still fit without overlaps.

for info in SchemeCatalog.all {
    var bad: [String] = []
    var w: CGFloat = 480
    while w <= 1400 {
        var h: CGFloat = 300
        while h <= 1100 {
            let ctx = LayoutContext(size: CGSize(width: w, height: h),
                                    safeInsets: Insets(top: 20, left: 0, bottom: 20, right: 0))
            let scheme = SchemeCatalog.make(info.id) as! ControlScheme
            scheme.layout(ctx)
            let p = LayoutCheck.problems(scheme.controls, in: ctx.safeBounds)
            if !p.isEmpty { bad.append("\(Int(w))x\(Int(h)): \(p.first!)") }
            h += 80
        }
        w += 70
    }
    check(bad.isEmpty, "\(info.name): \(bad.count) window sizes fail, e.g. \(bad.prefix(3).joined(separator: " | "))")
}

// MARK: Stick spacing
// The hand-size setting moves the sticks apart or together. Every value the app's slider
// can send must still give a layout with no overlaps, on every target device, and must
// actually move the sticks where there is room to.

for device in TargetDevice.all {
    for id in ["zone", "adaptive", "frame"] {
        let base = device.context(.stacked)
        let home = SchemeCatalog.make(id) as! ControlScheme
        home.layout(base)
        let homeGap = abs(home.controls.first { $0.label == "R" && $0.role == .stickBase }!.shape.center.x
                          - home.controls.first { $0.label == "L" && $0.role == .stickBase }!.shape.center.x)
        var gaps: [CGFloat] = []
        for spacing: CGFloat in [-3, -1.5, 1.5] {
            var ctx = base
            ctx.stickSpacing = spacing
            let scheme = SchemeCatalog.make(id) as! ControlScheme
            scheme.layout(ctx)
            let p = LayoutCheck.problems(scheme.controls, in: ctx.safeBounds)
            check(p.isEmpty, "\(device.name) \(id) spacing \(spacing): \(p.first ?? "")")
            let gap = abs(scheme.controls.first { $0.label == "R" && $0.role == .stickBase }!.shape.center.x
                          - scheme.controls.first { $0.label == "L" && $0.role == .stickBase }!.shape.center.x)
            check(spacing < 0 ? gap <= homeGap + 0.5 : gap >= homeGap - 0.5,
                  "\(device.name) \(id) spacing \(spacing): moved the wrong way (\(homeGap) -> \(gap))")
            gaps.append(gap)
        }
        // More inward never ends up further apart than less inward.
        check(gaps[0] <= gaps[1] + 0.5, "\(device.name) \(id): spacing -3 gives a wider gap (\(gaps[0])) than -1.5 (\(gaps[1]))")
    }
}

// MARK: Shoulder offset
// The iPad-only slider drops L, R, ZL and ZR together. Every value the slider can send must
// give a layout with no overlaps, keep the four shoulders level and in the same shape as
// each other, never move them up, and never leave them above their home position.

func shoulderRects(_ scheme: ControlScheme) -> [PadButton: CGRect] {
    var out: [PadButton: CGRect] = [:]
    for c in scheme.controls where c.role == .shoulder {
        if let b = c.button { out[b] = c.shape.boundingBox }
    }
    return out
}

for device in TargetDevice.all {
    for id in ["zone", "adaptive"] {
        let base = device.context(.stacked)
        let home = SchemeCatalog.make(id) as! ControlScheme
        home.layout(base)
        let homeRects = shoulderRects(home)
        check(homeRects.count == 4, "\(device.name) \(id): \(homeRects.count) shoulders at home")
        var drops: [CGFloat] = []
        for offset: CGFloat in [-2, 0.5, 1, 1.5, 3] {
            var ctx = base
            ctx.shoulderOffset = offset
            let scheme = SchemeCatalog.make(id) as! ControlScheme
            scheme.layout(ctx)
            let p = LayoutCheck.problems(scheme.controls, in: ctx.safeBounds)
            check(p.isEmpty, "\(device.name) \(id) shoulder offset \(offset): \(p.first ?? "")")
            let rects = shoulderRects(scheme)
            guard rects.count == 4, homeRects.count == 4 else { continue }
            let drop = rects[.zl]!.minY - homeRects[.zl]!.minY
            drops.append(drop)
            for (b, r) in rects {
                check(abs((r.minY - homeRects[b]!.minY) - drop) < 0.5,
                      "\(device.name) \(id) shoulder offset \(offset): \(b) not level with ZL")
                check(abs(r.minX - homeRects[b]!.minX) < 0.5 && abs(r.width - homeRects[b]!.width) < 0.5,
                      "\(device.name) \(id) shoulder offset \(offset): \(b) moved sideways or resized")
            }
            check(drop >= -0.5, "\(device.name) \(id) shoulder offset \(offset): moved up (\(drop))")
            if offset <= 0 { check(abs(drop) < 0.5, "\(device.name) \(id) shoulder offset \(offset): moved (\(drop))") }
        }
        // The mini's pad is already squeezed to fit (its sticks leave under a point of room
        // below the shoulders), so there it correctly stays put.
        if device.name.contains("iPad") && !device.name.contains("mini") {
            check((drops.last ?? 0) > 4, "\(device.name) \(id): the shoulders have no room to move down (\(drops))")
        }
        // More requested never ends up lower than less requested.
        if drops.count == 5 {
            check(drops[1] <= drops[2] + 0.5 && drops[2] <= drops[3] + 0.5 && drops[3] <= drops[4] + 0.5,
                  "\(device.name) \(id): shoulder drop not monotonic \(drops)")
        }
    }
}

// MARK: Behaviour, through the engine, on the A12Z iPad

let ipad = TargetDevice.all.first { $0.name.contains("A12Z") }!

func engine(_ id: String, _ display: TargetDevice.Display = .stacked) -> (PadEngine, Recorder, ControlScheme) {
    let r = Recorder()
    let e = PadEngine(scheme: SchemeCatalog.make(id), output: r, context: ipad.context(display))
    return (e, r, e.scheme as! ControlScheme)
}
func centre(_ s: ControlScheme, _ b: PadButton) -> CGPoint {
    s.controls.first { $0.button == b }!.shape.center
}
func tap(_ e: PadEngine, _ p: CGPoint, id: TouchID = 1, t: Double = 0) {
    e.began(id, at: p, time: t); e.ended(id, at: p, time: t + 0.1)
}

for id in ["zone", "adaptive", "frame", "float"] {
    let (e, r, s) = engine(id)
    for b in [PadButton.a, .b, .x, .y, .l, .r, .zl, .zr, .plus, .minus, .home] {
        r.log = []
        e.began(1, at: centre(s, b), time: 0)
        check(r.held == [b], "\(id): tap \(b) holds exactly \(b), got \(r.held)")
        e.ended(1, at: centre(s, b), time: 0.1)
        check(r.held.isEmpty, "\(id): \(b) released")
        _ = (s as? AdaptivePad)?.resetLearning()
    }

    // Slide A -> B without lifting.
    let a = centre(s, .a), b = centre(s, .b)
    e.began(1, at: a, time: 0)
    e.moved(1, to: b, time: 0.1)
    check(r.held == [.b], "\(id): slide A to B, got \(r.held)")
    e.cancelled(1, time: 0.2)
    check(r.held.isEmpty, "\(id): cancel releases")

    // Chord in the gap between A and B.
    let unit = s.controls.first { $0.button == .a }!.shape.boundingBox.width
    let dir = (b - a) * (1 / b.distance(to: a))
    let gapMid = a + dir * (b.distance(to: a) / 2)
    e.began(2, at: gapMid, time: 1)
    check(r.held == [.a, .b], "\(id): thumb between A and B presses both, got \(r.held) (unit \(unit))")
    e.ended(2, at: gapMid, time: 1.1)
}

do {
    let (e, r, s) = engine("zone")
    let dpad = s.controls.first { if case .dpad = $0.kind { return true }; return false }!
    let c = dpad.shape.center
    let u = s.controls.first { $0.button == .a }!.shape.boundingBox.width
    e.began(1, at: c + CGPoint(x: 1.2 * u, y: -1.2 * u), time: 0)
    check(r.held == [.up, .right], "zone: d-pad up-right diagonal, got \(r.held)")
    e.moved(1, to: c + CGPoint(x: 0, y: 1.1 * u), time: 0.05)
    check(r.held == [.down], "zone: d-pad rolls to down, got \(r.held)")
    e.ended(1, at: c, time: 0.1)
    e.began(1, at: c, time: 1)
    check(r.held == [.stickL], "zone: d-pad centre dot is L3, got \(r.held)")
    e.ended(1, at: c, time: 1.1)

    let stick = s.controls.first { if case .stick(.left, _, _) = $0.kind { return true }; return false }!
    e.began(3, at: stick.shape.center, time: 2)
    e.moved(3, to: stick.shape.center + CGPoint(x: 400, y: 0), time: 2.1)
    check(near(r.sticks[.left]?.x ?? 0, 1), "zone: left stick full right, got \(String(describing: r.sticks[.left]))")
    e.ended(3, at: .zero, time: 2.2)
    check(r.sticks[.left] == .zero, "zone: stick recentres")

    // Touchscreen passthrough.
    let pad = ipad.context(.stacked).touchscreenRect!
    let p = CGPoint(x: pad.minX + pad.width * 0.25, y: pad.minY + pad.height * 0.75)
    if !s.claims(p) {
        e.began(9, at: p, time: 3)
        check(near(Double(r.screen?.x ?? -1), 0.25) && near(Double(r.screen?.y ?? -1), 0.75),
              "zone: GamePad touch normalised, got \(String(describing: r.screen))")
        e.ended(9, at: p, time: 3.1)
        check(r.screen == nil, "zone: touchscreen lifts")
    }
}

do {
    let (e, r, s) = engine("float", .single)
    // Float over a single screen: pick a spot in the left zone that is off the GamePad.
    let zone = s.controls.first { if case .floatingStick(.left, _, _, _, _) = $0.kind { return true }; return false }!
    let ts = ipad.context(.single).touchscreenRect!
    let box = zone.shape.boundingBox
    let p = CGPoint(x: box.minX + 40, y: min(box.maxY - 40, ts.minY - 1 > box.minY ? ts.minY - 20 : box.maxY - 40))
    let landing = ts.contains(p) ? CGPoint(x: box.minX + 20, y: box.maxY - 5) : p
    e.began(1, at: landing, time: 0)
    check(r.sticks[.left] == nil || r.sticks[.left] == .zero, "float: stick is centred under the thumb on landing")
    let drawn = e.render()
    check(!drawn.contains { $0.role == .stickBase }, "float: no stick ring is drawn")
    check(drawn.contains { $0.role == .dot && $0.shape.center == landing }, "float: anchor dot where the thumb landed")
    check(drawn.filter { $0.role == .stickKnob }.count == 1, "float: only the active knob is drawn")
    e.moved(1, to: landing + CGPoint(x: 300, y: 0), time: 0.1)
    check((r.sticks[.left]?.x ?? 0) > 0.9, "float: drag right = full right, got \(String(describing: r.sticks[.left]))")
    let knob = e.render().first { $0.role == .stickKnob }!.shape.center
    let travel = PadParts.stickTravel * s.controls.first { $0.button == .a }!.shape.boundingBox.width / 0.92
    check(knob.distance(to: landing) <= travel + 0.5, "float: knob stops at full push, \(knob.distance(to: landing)) from anchor")
    check(e.render().contains { $0.role == .dot && $0.shape.center == landing }, "float: anchor stays put when dragging past the edge")
    e.moved(1, to: landing + CGPoint(x: -300, y: 0), time: 0.2)
    check((r.sticks[.left]?.x ?? 0) < -0.9, "float: full left from the same anchor, got \(String(describing: r.sticks[.left]))")
    e.ended(1, at: landing, time: 0.3)
    e.began(1, at: landing, time: 0.4)
    check(!r.held.contains(.stickL), "float: re-grabbing after a drag is not a click")
    e.ended(1, at: landing, time: 0.45)
    e.began(1, at: landing + CGPoint(x: 8, y: 4), time: 0.6)
    check(r.held.contains(.stickL), "float: tap then tap-and-hold = L3, got \(r.held)")
    e.ended(1, at: landing, time: 0.9)
    check(r.held.isEmpty, "float: L3 released")
    check(!e.render().contains { $0.role == .stickBase || $0.role == .stickKnob || $0.role == .dot },
          "float: nothing drawn for idle sticks")
}

do {
    let (e, r, s0) = engine("adaptive")
    let s = s0 as! AdaptivePad
    let u = s.controls.first { $0.button == .a }!.shape.boundingBox.width
    let home = centre(s, .a)
    for i in 0..<40 {
        let target = centre(s, .a)
        tap(e, CGPoint(x: home.x - 0.35 * u, y: target.y), t: Double(i))
        _ = r
    }
    let moved = centre(s, .a).x - home.x
    check(moved < -0.15 * u && moved > -0.4 * u, "adaptive: face diamond drifts toward presses left of A, moved \(moved / u)u")
    check(LayoutCheck.problems(s.controls, in: ipad.context(.stacked).safeBounds).isEmpty, "adaptive: drift keeps layout valid")
    let before = s.learned
    e.began(1, at: centre(s, .a), time: 100)
    e.moved(1, to: centre(s, .b), time: 100.1)
    e.ended(1, at: centre(s, .b), time: 100.2)
    check(s.learned == before, "adaptive: a slide teaches nothing")
    s.resetLearning()
    check(centre(s, .a) == home, "adaptive: reset returns home")
    let sample: [Int: CGPoint] = [2: CGPoint(x: -0.25, y: 0.125), 5: CGPoint(x: 0.5, y: 0)]
    check(AdaptivePad.decode(AdaptivePad.encode(sample)) == sample, "adaptive: learned positions round-trip through JSON")
    check(AdaptivePad.decode("garbage").isEmpty, "adaptive: bad saved data loads as nothing learned")
}

do {
    let (_, _, s0) = engine("frame")
    let f = s0 as! FramePad
    check(f.mode == .columns, "frame: stacked screens on the A12Z iPad use side columns, got \(f.mode)")
    let (_, _, s1) = engine("frame", .single)
    check((s1 as! FramePad).mode == .overlay, "frame: single 16:9 on a 4:3 iPad has no usable margin -> overlay")
    let portrait = TargetDevice.all.first { $0.name.contains("portrait") }!
    let fp = FramePad(); fp.layout(portrait.context(.single))
    check(fp.mode == .band, "frame: portrait single screen uses the bottom band, got \(fp.mode)")
}

do {
    let fit = PadScreenGeometry.aspectFit(16.0 / 9.0, in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    check(abs(fit.width - 1000) < 0.01 && abs(fit.height - 562.5) < 0.01 && abs(fit.minY - 218.75) < 0.01,
          "aspectFit letterboxes 16:9 in a square, got \(fit)")
    let tall = PadScreenGeometry.aspectFit(16.0 / 9.0, in: CGRect(x: 10, y: 0, width: 1600, height: 450))
    check(abs(tall.height - 450) < 0.01 && abs(tall.width - 800) < 0.01 && abs(tall.midX - 810) < 0.01,
          "aspectFit pillarboxes in a wide rect, got \(tall)")
}

// MARK: Anchor

do {
    func anchorEngine(_ device: TargetDevice = ipad, _ display: TargetDevice.Display = .stacked) -> (PadEngine, Recorder, AnchorPad) {
        let r = Recorder()
        let e = PadEngine(scheme: AnchorPad(), output: r, context: device.context(display))
        return (e, r, e.scheme as! AnchorPad)
    }
    func at(_ s: AnchorPad, _ deg: Double, _ dist: Double) -> CGPoint {
        let u = Double(s.context.unit * s.diamondScale)
        let a = deg * .pi / 180
        return s.anchor + CGPoint(x: cos(a) * dist * u, y: -sin(a) * dist * u)
    }

    // Eight angles around the anchor. Screen angles: 0 = right (A), 90 = up (X), 180 = Y, 270 = B.
    let expect: [(Double, PadButton)] = [(0, .a), (90, .x), (180, .y), (270, .b),
                                         (40, .a), (50, .x), (130, .x), (140, .y),
                                         (220, .y), (230, .b), (310, .b), (320, .a)]
    for (deg, button) in expect {
        let (e, r, s) = anchorEngine()
        e.began(1, at: at(s, deg, 1.24), time: 0)
        check(r.held == [button], "anchor: \(deg) deg from the anchor presses \(button), got \(r.held)")
        e.ended(1, at: at(s, deg, 1.24), time: 0.1)
    }
    // Exact diagonals sit on a boundary: the neighbour just used wins.
    let cardinal: [PadButton: Double] = [.a: 0, .x: 90, .y: 180, .b: 270]
    for (deg, pair) in [(45.0, [PadButton.a, .x]), (135, [.x, .y]), (225, [.y, .b]), (315, [.b, .a])] {
        for last in pair {
            let (e, _, s) = anchorEngine()
            e.began(1, at: at(s, cardinal[last]!, 1.24), time: 0)
            e.ended(1, at: at(s, cardinal[last]!, 1.24), time: 0.05)
            let p = s.decide(at: at(s, deg, 1.24)).primary
            check(p == last, "anchor: exact \(deg) deg after \(last) lands on \(last), got \(p)")
        }
    }

    // Dead centre repeats the last button.
    do {
        let (e, r, s) = anchorEngine()
        e.began(1, at: at(s, 270, 1.24), time: 0); e.ended(1, at: at(s, 270, 1.24), time: 0.1)
        for i in 0..<4 {
            r.log = []
            let p = s.anchor + CGPoint(x: CGFloat(i) * 2 - 3, y: 2)
            e.began(1, at: p, time: 1 + Double(i)); 
            check(r.held == [.b], "anchor: dead-centre tap \(i) repeats B, got \(r.held)")
            e.ended(1, at: p, time: 1.05 + Double(i))
        }
    }

    // Decided on touch-down: held on the began call itself, no tick or move needed, and a
    // slide afterwards does not change it.
    do {
        let (e, r, s) = anchorEngine()
        e.began(1, at: at(s, 180, 1.24), time: 5)
        check(r.held == [.y], "anchor: press is live on touch-down with zero elapsed time, got \(r.held)")
        e.moved(1, to: at(s, 0, 1.24), time: 5.01)
        check(r.held == [.y], "anchor: a press is not re-decided by a later move")
        e.ended(1, at: at(s, 0, 1.24), time: 5.5)
        check(r.held.isEmpty, "anchor: released on lift")
    }

    // Chords: two fingers, and one flat thumb.
    do {
        let (e, r, s) = anchorEngine()
        e.began(1, at: at(s, 0, 1.24), time: 0); e.began(2, at: at(s, 270, 1.24), time: 0.01)
        check(r.held == [.a, .b], "anchor: two fingers chord A+B, got \(r.held)")
        e.ended(1, at: .zero, time: 0.1); e.ended(2, at: .zero, time: 0.1)
        s.noteContactRadius(3, 30)
        e.began(3, at: at(s, 315, 1.24), time: 1)
        check(r.held == [.a, .b], "anchor: flat thumb on the A/B boundary chords A+B, got \(r.held)")
        e.ended(3, at: .zero, time: 1.1)
        s.noteContactRadius(4, 30)
        e.began(4, at: at(s, 0, 1.24), time: 2)
        check(r.held == [.a], "anchor: flat thumb squarely on A is still just A, got \(r.held)")
        e.ended(4, at: .zero, time: 2.1)
        s.noteContactRadius(5, 8)
        e.began(5, at: at(s, 315, 1.24), time: 3)
        check(r.held.count == 1, "anchor: a normal thumb on the boundary is one button, got \(r.held)")
        e.ended(5, at: .zero, time: 3.1)
    }

    // Following: bounded, right half, never in the GamePad rect - every device, both displays.
    for device in TargetDevice.all {
        for display in TargetDevice.Display.allCases {
            let (e, _, s) = anchorEngine(device, display)
            let ctx = device.context(display)
            let hole = s.avoidsTouchscreen ? ctx.touchscreenRect : nil
            func ok(_ what: String) {
                check(s.anchorBounds.insetBy(dx: -0.01, dy: -0.01).contains(s.anchor), "anchor \(device.name)/\(display): \(what) left its bounds \(s.anchor)")
                check(!(hole?.contains(s.anchor) ?? false), "anchor \(device.name)/\(display): \(what) inside the GamePad rect")
                check(s.anchor.x >= ctx.safeBounds.midX - 0.01 || (ctx.touchscreenRect != nil), "anchor \(device.name)/\(display): \(what) left the right half")
            }
            ok("default")
            var t = 0.0
            for dir in [0.0, 90, 180, 270, 45, 225] {
                for _ in 0..<60 {
                    // Presses that land consistently far from where they "should": a drifting grip.
                    let p = s.anchor + CGPoint(x: cos(dir * .pi / 180) * 120, y: -sin(dir * .pi / 180) * 120)
                    e.began(1, at: p, time: t); e.ended(1, at: p, time: t + 0.05); t += 0.2
                    ok("after drifting \(dir)")
                }
            }
            if let hole {   // and rest-learning
                e.began(2, at: s.anchor + CGPoint(x: hole.midX < s.anchor.x ? -30 : 30, y: 0), time: t)
                e.tick(time: t + 0.3)
                ok("rest-learning")
                e.ended(2, at: .zero, time: t + 0.4)
            }
        }
    }

    // The anchor really does follow a drifting grip, and re-centres the diamond on it.
    do {
        let (e, _, s) = anchorEngine()
        let start = s.anchor
        let drift = CGPoint(x: 25, y: 18)
        var t = 0.0
        for _ in 0..<8 {
            let p = at(s, 0, 1.24) + drift      // thumb now lands consistently low and right of A
            e.began(1, at: p, time: t); e.ended(1, at: p, time: t + 0.05); t += 0.3
        }
        check(s.anchor.distance(to: start) > 10 && s.anchor.x > start.x && s.anchor.y > start.y,
              "anchor: follows a drifting grip, moved \(s.anchor - start)")
        let a = s.controls.first { $0.button == .a }!.shape.center
        check(a.distance(to: at(s, 0, PadParts.crossX)) < 1.0, "anchor: drawn A moves with the anchor")
        // Resting still for 150 ms learns without a lift; the held press stays put.
        let (e2, r2, s2) = anchorEngine()
        let before = s2.anchor
        let p = at(s2, 0, 1.24) + CGPoint(x: 0, y: 20)
        e2.began(1, at: p, time: 0)
        check(s2.anchor == before, "anchor: nothing moves at touch-down")
        e2.tick(time: 0.1)
        check(s2.anchor == before, "anchor: not before 150 ms of rest")
        e2.tick(time: 0.2)
        check(s2.anchor != before && r2.held == [.a], "anchor: rests >150 ms update the anchor, press unchanged \(r2.held)")
        // Saved position round-trips.
        let f = s2.anchorFraction
        check(f != nil, "anchor: has a persistable position after learning")
        let s3 = AnchorPad(); s3.anchorFraction = f; s3.layout(ipad.context(.stacked))
        check(s3.anchor.distance(to: s2.anchor) < 0.5, "anchor: saved fraction restores the anchor")
    }

    // Left hand: floating stick, d-pad flick and hold, shoulders, pills.
    do {
        let (e, r, s) = anchorEngine(ipad, .single)
        let stick = s.controls.first { if case .floatingStick(.left, _, _, _, _) = $0.kind { return true }; return false }!
        let land = stick.shape.center
        e.began(1, at: land, time: 0)
        e.moved(1, to: land + CGPoint(x: 300, y: 0), time: 0.05)
        check((r.sticks[.left]?.x ?? 0) > 0.9, "anchor: left stick floats under the thumb, got \(String(describing: r.sticks[.left]))")
        e.ended(1, at: land, time: 0.1)

        let u = s.context.unit
        let d0 = s.dpadArea.center + CGPoint(x: u, y: 0)
        e.began(2, at: d0, time: 1)
        check(r.held.isEmpty, "anchor: d-pad area does nothing until it is flicked")
        e.moved(2, to: d0 + CGPoint(x: 0.7 * u, y: 0), time: 1.05)
        check(r.held == [.right], "anchor: flick right = d-pad right, got \(r.held)")
        e.ended(2, at: d0, time: 1.1)
        e.began(2, at: d0, time: 2)
        e.moved(2, to: d0 + CGPoint(x: 0.7 * u, y: 0), time: 2.6)
        check(r.held.isEmpty, "anchor: a slow drag in flick mode is not a flick")
        e.ended(2, at: d0, time: 2.7)
        e.began(3, at: s.pillCentre, time: 3); e.ended(3, at: s.pillCentre, time: 3.05)
        check(s.holdDirectionMode, "anchor: the pill switches to hold-direction mode")
        e.began(2, at: d0, time: 4)
        e.moved(2, to: d0 + CGPoint(x: 0, y: -0.8 * u), time: 4.6)
        check(r.held == [.up], "anchor: hold mode follows a slow drag, got \(r.held)")
        e.moved(2, to: d0 + CGPoint(x: 0.8 * u, y: 0.0), time: 4.7)
        check(r.held == [.right], "anchor: hold mode rolls to the new direction, got \(r.held)")
        e.ended(2, at: d0, time: 4.8)
        check(r.held.isEmpty, "anchor: d-pad releases on lift")

        for b in [PadButton.zl, .l, .zr, .r, .plus, .minus, .home] {
            let c = s.controls.first { $0.button == b }!.shape.center
            e.began(5, at: c, time: 6); let h = r.held; e.ended(5, at: c, time: 6.1)
            check(h == [b], "anchor: \(b) band/pill tap, got \(h)")
        }
        let cam = s.controls.first { if case .floatingStick(.right, _, _, _, _) = $0.kind { return true }; return false }!
        e.began(6, at: cam.shape.center, time: 8)
        e.moved(6, to: cam.shape.center + CGPoint(x: 0, y: -300), time: 8.05)
        check((r.sticks[.right]?.y ?? 0) > 0.9, "anchor: right camera stick floats too")
        e.ended(6, at: .zero, time: 8.1)
        // A GamePad touchscreen touch in the video still reaches the screen, not a face button.
        let hole = s.context.touchscreenRect!
        let q = CGPoint(x: hole.midX, y: hole.midY)
        if !s.claims(q) {
            e.began(9, at: q, time: 9)
            check(r.screen != nil && r.held.isEmpty, "anchor: touchscreen passthrough in the video")
            e.ended(9, at: q, time: 9.1)
        }
    }

    // The diamond is faint by default and solid when learning.
    do {
        let (_, _, s) = anchorEngine()
        let faint = s.render(pressed: [], sticks: [:]).filter { $0.role == .face }
        check(faint.count == 4 && faint.allSatisfy { $0.ghost }, "anchor: ghost diamond is faint by default")
        s.learningMode = true
        let solid = s.render(pressed: [], sticks: [:]).filter { $0.role == .face }
        check(solid.count == 4 && solid.allSatisfy { !$0.ghost }, "anchor: learning mode draws the diamond solid")
    }
}

print("\(passes) passed, \(failures) failed")
exit(Int32(min(failures, 125)))
