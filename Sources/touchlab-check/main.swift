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

// MARK: Arc

func arcDevices() -> [TargetDevice] {
    let names = ["iPhone SE", "iPhone 16 Pro Max", "iPad mini", "iPad Pro 13"]
    return TargetDevice.all.filter { names.contains($0.name) } + TargetDevice.portraitVariants
}

// Circle fit: recovers a known pivot and radius from noisy thumb-sweep samples.
do {
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    func gauss() -> Double { (-2 * log(max(rnd(), 1e-12))).squareRoot() * cos(2 * .pi * rnd()) }
    for (cx, cy, r, a0, a1) in [(1180.0, 600.0, 260.0, 1.9, 3.0), (-40.0, 700.0, 190.0, -0.1, 1.2), (400.0, 900.0, 320.0, 1.1, 1.8)] {
        var pts: [CGPoint] = []
        for _ in 0..<80 {
            let a = a0 + (a1 - a0) * rnd()
            let rr = r + 3 * gauss()
            pts.append(CGPoint(x: cx + rr * cos(a), y: cy - rr * sin(a) + 0))
        }
        // (y is flipped on screen; the circle is the same circle.)
        if let fit = ArcMath.fitCircle(pts) {
            let ce = hypot(Double(fit.center.x) - cx, Double(fit.center.y) - cy)
            check(ce < 0.12 * r, "arc: fit pivot off by \(ce) for r=\(r)")
            check(abs(Double(fit.radius) - r) < 0.08 * r, "arc: fit radius \(fit.radius) vs \(r)")
            check(Double(fit.rms) < 6, "arc: residual \(fit.rms) should be near the 3pt noise")
        } else {
            check(false, "arc: no fit for r=\(r)")
        }
    }
    // Noise-free samples are recovered exactly.
    let exact = (0..<20).map { i -> CGPoint in let a = 1.2 + Double(i) * 0.05; return CGPoint(x: 700 + 300 * cos(a), y: 500 - 300 * sin(a)) }
    if let f = ArcMath.fitCircle(exact) {
        check(hypot(Double(f.center.x) - 700, Double(f.center.y) - 500) < 0.01 && abs(Double(f.radius) - 300) < 0.01, "arc: exact fit, got \(f)")
    } else { check(false, "arc: exact samples must fit") }
    let line = (0..<30).map { CGPoint(x: Double($0) * 5, y: 100 + Double($0) * 2) }
    check(ArcMath.fitCircle(line) == nil, "arc: a straight sweep is not a circle")
    check(ArcMath.fitCircle([CGPoint(x: 1, y: 1)]) == nil, "arc: too few points")
}

// Layout on every device and orientation, with and without calibration.
for device in arcDevices() {
    for display in TargetDevice.Display.allCases {
        let ctx = device.context(display)
        let arc = ArcPad()
        arc.layout(ctx)
        let where_ = "Arc / \(device.name) / \(display.rawValue)"
        check(!arc.usingFallback, "\(where_): fell back to the plain arrangement")
        let problems = LayoutCheck.problems(arc.controls, in: ctx.safeBounds)
        check(problems.isEmpty, "\(where_): \(problems.joined(separator: "; "))")
        if arc.avoidance != .none {
            let keep = arc.avoidance == .video ? ctx.videoRects + [ctx.touchscreenRect!] : [ctx.touchscreenRect!]
            for c in arc.controls where !c.isZone {
                for k in keep where k.insetBy(dx: 1, dy: 1).intersects(c.shape.boundingBox) {
                    check(false, "\(where_): \(c.label) covers the video/GamePad rect")
                }
            }
        }
        if display == .stacked && device.name != "iPad Pro 13 portrait" {
            check(arc.avoidance != .none, "\(where_): stacked screens leave margins, Arc must stay off the video (got \(arc.avoidance))")
        }
    }
}

// Angular assignment: radial over/undershoot keeps the button; sliding along the arc moves it.
for device in arcDevices() {
    let ctx = device.context(.stacked)
    for (rad, name) in [(-0.8, "short"), (0.0, "on"), (0.9, "far")] {
        let out = Recorder()
        let arc = ArcPad()
        let eng = PadEngine(scheme: arc, output: out, context: ctx)
        for set in arc.hands {
            let buttons: [PadButton] = set.side == .right ? [.x, .a, .b, .y] : [.up, .right, .down, .left]
            for b in buttons {
                guard let c = arc.controls.first(where: { $0.button == b }) else { check(false, "arc: no \(b)"); continue }
                let (r, phi) = set.polar(c.shape.center)
                let p = set.point(r: r + CGFloat(rad) * arc.layoutUnit, phi: phi)
                eng.began(1, at: p, time: 0)
                check(out.held == [b], "arc \(device.name): \(name) press of \(b) gave \(out.held.map(\.description).sorted())")
                eng.ended(1, at: p, time: 0.1)
                check(out.held.isEmpty, "arc: release after \(b)")
            }
        }
    }
    // Slide A -> B along the arc, with a wobbling radius.
    let out = Recorder()
    let arc = ArcPad()
    let eng = PadEngine(scheme: arc, output: out, context: ctx)
    let hand = arc.hands.first { $0.side == .right }!
    let a = arc.controls.first { $0.button == .a }!.shape.center
    let b = arc.controls.first { $0.button == .b }!.shape.center
    let (r, pa) = hand.polar(a), (_, pb) = hand.polar(b)
    eng.began(1, at: a, time: 0)
    check(out.held == [.a], "arc: touch A")
    for i in 1...10 {
        let t = CGFloat(i) / 10
        let wobble = (i % 2 == 0 ? 0.5 : -0.5) * arc.layoutUnit
        eng.moved(1, to: hand.point(r: r + wobble, phi: pa + (pb - pa) * t), time: Double(i) * 0.01)
    }
    check(out.held == [.b], "arc: slid A to B, holding \(out.held)")
    eng.moved(1, to: CGPoint(x: ctx.size.width / 2, y: ctx.safeBounds.minY + 4), time: 1)
    check(out.held.isEmpty, "arc: far off the arc lets go")
    eng.ended(1, at: .zero, time: 2)
    check(out.held.isEmpty, "arc: nothing stuck")
}

// Calibration end to end: two thumbs sweep known arcs, the scheme fits and re-lays out.
do {
    let device = TargetDevice.all.first { $0.name == "iPad mini" }!
    let ctx = device.context(.stacked)
    let out = Recorder()
    let arc = ArcPad()
    var saved: [String: ArcProfile] = [:]
    arc.onProfiles = { saved = $0 }
    let eng = PadEngine(scheme: arc, output: out, context: ctx)
    let u = ctx.unit
    // Right thumb pivots below-right of the screen; left mirrored. Sweeps of ~55 degrees.
    let rp = CGPoint(x: ctx.size.width - 10, y: ctx.size.height + 40), lp = CGPoint(x: 10, y: ctx.size.height + 40)
    let rad: CGFloat = 6.2 * u
    var seed: UInt64 = 42
    func jitter() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(seed >> 11) / Double(1 << 53) - 0.5) * 6
    }
    arc.startCalibration()
    check(arc.isCalibrating && eng.claims(CGPoint(x: 5, y: 5)), "arc: calibration claims the whole screen")
    var t = 0.0
    eng.began(1, at: CGPoint(x: rp.x - rad * sin(0.35), y: rp.y - rad * cos(0.35)), time: t)
    eng.began(2, at: CGPoint(x: lp.x + rad * sin(0.35), y: lp.y - rad * cos(0.35)), time: t)
    for i in 0...120 {
        t = Double(i) * 0.04
        let phi = 0.35 + 0.9 * CGFloat(i) / 120
        eng.moved(1, to: CGPoint(x: rp.x - rad * sin(phi) + jitter(), y: rp.y - rad * cos(phi) + jitter()), time: t)
        eng.moved(2, to: CGPoint(x: lp.x + rad * sin(phi) + jitter(), y: lp.y - rad * cos(phi) + jitter()), time: t)
        eng.tick(time: t)
    }
    check(out.held.isEmpty && out.log.isEmpty, "arc: a calibration sweep presses nothing")
    eng.tick(time: 5.2)
    check(!arc.isCalibrating, "arc: calibration ends after five seconds")
    eng.ended(1, at: .zero, time: 5.3); eng.ended(2, at: .zero, time: 5.3)
    let prof = saved["landscape"]
    check(prof?.left != nil && prof?.right != nil, "arc: both hands calibrated, got \(String(describing: prof))")
    if let r = prof?.right {
        let short = Double(min(ctx.size.width, ctx.size.height))
        check(abs(r.radius * short - Double(rad)) < 0.08 * Double(rad), "arc: fitted radius \(r.radius * short) vs \(rad)")
        check(abs(r.pivotX * Double(ctx.size.width) - Double(rp.x)) < 0.1 * Double(rad), "arc: fitted pivot x")
        check(abs(r.pivotY * Double(ctx.size.height) - Double(rp.y)) < 0.1 * Double(rad), "arc: fitted pivot y")
    }
    check(arc.hands.allSatisfy { $0.calibrated }, "arc: layout uses the calibration")
    check(LayoutCheck.problems(arc.controls, in: ctx.safeBounds).isEmpty, "arc: calibrated layout has no overlaps")
    check(arc.avoidance != .none, "arc: calibrated layout still avoids the video")
    let json = ArcPad.encode(saved)
    check(ArcPad.decode(json) == saved, "arc: calibration round-trips through JSON")
    check(ArcPad.decode("garbage").isEmpty && ArcPad.decode("{\"landscape\":{\"right\":{\"pivotX\":1e999}}}").isEmpty, "arc: bad saved data loads as nothing")
    // A fresh scheme with the saved JSON lays out the same way; portrait has its own (empty) profile.
    let again = ArcPad(profiles: ArcPad.decode(json))
    again.layout(ctx)
    check(again.hands == arc.hands, "arc: saved calibration reproduces the layout")
    again.layout(TargetDevice.portraitVariants.first { $0.name == "iPad mini portrait" }!.context(.stacked))
    check(again.hands.allSatisfy { !$0.calibrated }, "arc: calibration is per orientation")
    // Skipping leaves everything as it was; reset returns the default arc.
    arc.startCalibration(); arc.skipCalibration()
    check(arc.hands.allSatisfy { $0.calibrated }, "arc: skipping keeps the calibration")
    arc.resetCalibration()
    check(arc.hands.allSatisfy { !$0.calibrated }, "arc: reset returns the default arc")
    // A garbage sweep (a tap) is rejected and the default stays.
    arc.startCalibration()
    let e2 = PadEngine(scheme: arc, output: out, context: ctx)
    e2.began(9, at: CGPoint(x: 700, y: 600), time: 0)
    e2.moved(9, to: CGPoint(x: 701, y: 600), time: 0.1)
    e2.tick(time: 5.5)
    check(arc.hands.allSatisfy { !$0.calibrated }, "arc: a tap is not a sweep")
}

print("\(passes) passed, \(failures) failed")
exit(Int32(min(failures, 125)))
