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


// MARK: Showcase
// The showcase pad's geometry, transplant and colours ported as pure Swift, and the TouchLab
// scheme built on them.

do {
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
    func centre(_ r: ShowcaseResolved, _ id: String) -> CGPoint { r.controls[id]!.centre }
    func nearPt(_ p: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { abs(p.x - x) < 0.02 && abs(p.y - y) < 0.02 }

    // Expected values are PreviewPadStore.resolve's own, taken by compiling the showcase
    // pad's GamePadGeometry.swift and MuffinPadCustomisation.swift unchanged on the same inputs.
    func resolve(_ preset: ShowcaseLayoutPreset, _ mode: ShowcaseLayout.DisplayMode, size: CGSize, safe: CGRect,
                 ppi: CGFloat, phone: Bool) -> ShowcaseResolved {
        ShowcaseResolver.resolve(preset: preset, displayMode: mode, container: size, safeArea: safe,
                                 pointsPerInch: ppi, isPhone: phone)
    }
    let pro11 = resolve(.native, .fit, size: CGSize(width: 1194, height: 834), safe: rect(0, 24, 1194, 790), ppi: 132, phone: false)
    check(abs(pro11.unit - 55.22) < 0.01, "showcase: iPad Pro 11 life-size D is 10.625 mm at 132 ppi, got \(pro11.unit)")
    check(nearPt(centre(pro11, "A"), 1105.62, 573.81) && nearPt(centre(pro11, "stickL"), 88.37, 429.15)
          && nearPt(centre(pro11, "dpad"), 141.39, 573.81) && nearPt(centre(pro11, "HOME"), 597.00, 765.96),
          "showcase: iPad Pro 11 fit/native positions differ from PreviewPadStore")
    check(abs(pro11.video.height - 671.62) < 0.01, "showcase: iPad Pro 11 fit picture is full-bleed 16:9")

    let se = resolve(.native, .native, size: CGSize(width: 667, height: 375), safe: rect(0, 0, 667, 375), ppi: 163, phone: true)
    check(abs(se.unit - 54.95) < 0.01 && nearPt(centre(se, "plus"), 448.58, 198.38) && nearPt(centre(se, "minus"), 218.42, 198.38),
          "showcase: iPhone SE native: +/- at the elbow, unit 54.95, got \(se.unit)")
    check(abs(se.video.minX - 256.34) < 0.01 && abs(se.video.width - 154.32) < 0.01, "showcase: iPhone SE native picture rect \(se.video)")

    let seT = resolve(.iPadPro2020, .fit, size: CGSize(width: 667, height: 375), safe: rect(0, 0, 667, 375), ppi: 163, phone: true)
    check(abs(seT.unit - 41.40) < 0.01 && nearPt(centre(seT, "A"), 600.74, 194.91) && nearPt(centre(seT, "stickR"), 600.74, 86.45)
          && nearPt(centre(seT, "plus"), 516.28, 295.10), "showcase: iPad Pro preset transplanted to iPhone SE differs from PadPresetFitter, unit \(seT.unit)")
    let miniT = resolve(.iPadPro2020, .native, size: CGSize(width: 1133, height: 744), safe: rect(0, 24, 1133, 700), ppi: 163, phone: false)
    check(abs(miniT.unit - 48.66) < 0.01 && nearPt(centre(miniT, "A"), 1055.11, 251.43) && nearPt(centre(miniT, "HOME"), 558.71, 547.26),
          "showcase: iPad Pro preset on iPad mini native differs from PadPresetFitter, unit \(miniT.unit)")
    let up = resolve(.compact, .fit, size: CGSize(width: 440, height: 956), safe: rect(0, 62, 440, 860), ppi: 460.0 / 3, phone: true)
    check(abs(up.unit - 44.90) < 0.01 && nearPt(centre(up, "A"), 368.14, 311.05) && abs(up.video.minY - 62) < 0.01 && abs(up.video.height - 247.5) < 0.01,
          "showcase: phone upright is forced to Native (picture on top), got \(up.unit) \(up.video)")

    // Colour files: the showcase's JSON, byte for byte readable both ways.
    let json = "{\"version\":1,\"name\":\"Mine\",\"outline\":{\"hex\":\"#101010\"},\"fills\":{\"default\":{\"hex\":\"#336699\",\"alpha\":0.5}},\"glyphs\":{\"default\":{\"hex\":\"#FFFFFF\"}},\"pressedAlphaBoost\":0.12}"
    if let file = try? ShowcaseColourFile.decode(Data(json.utf8)) {
        check(file.fill("A").hex == "#336699" && abs(file.alpha("A", pressed: true) - 0.62) < 1e-9, "showcase: .muffinclr fill/alpha lookup")
        check((try? ShowcaseColourFile.decode(file.encoded())) == file, "showcase: .muffinclr round-trips")
    } else { check(false, "showcase: a .muffinclr written by the showcase pad failed to decode") }
    for p in ShowcaseColourPreset.allCases {
        check((try? ShowcaseColourFile.decode(p.file.encoded())) == p.file, "showcase: \(p.rawValue) round-trips as .muffinclr")
    }
    check(ShowcaseColourPresets.wiiUWhite.fill("A").hex == "#F1F1F1" && ShowcaseColourPresets.wiiUWhite.fill("dpad").hex == "#BDBDC1"
          && ShowcaseColourPresets.superFamicom.fill("Y").hex == "#D14B45", "showcase: preset colours")
    check(abs(ShowcaseDeviceMetrics.measurement(identifier: "iPad8,9", nativePixels: CGSize(width: 1668, height: 2388), scale: 2, isPad: true, calibrated: nil).pointsPerInch - 132) < 0.01
          && abs(ShowcaseDeviceMetrics.measurement(identifier: "iPad16,1", nativePixels: .zero, scale: 2, isPad: true, calibrated: nil).pointsPerInch - 163) < 0.01,
          "showcase: points per inch from model")

    // Every review device, both orientations, both display modes, both host layouts, every preset.
    var overlays = 0, clears = 0
    var smallest: (CGFloat, String) = (1, "")
    for device in TargetDevice.showcaseReview {
        for mode in ShowcaseLayout.DisplayMode.allCases {
            for display in TargetDevice.Display.allCases {
                for preset in ShowcaseLayoutPreset.allCases {
                    let pad = ShowcasePad()
                    pad.pointsPerInch = device.showcasePointsPerInch
                    pad.layoutPreset = preset
                    pad.displayMode = mode
                    let ctx = device.context(display)
                    pad.layout(ctx)
                    let where_ = "Showcase / \(device.name) / \(mode.rawValue) / \(display.rawValue) / \(preset.rawValue)"
                    let problems = LayoutCheck.problems(pad.controls, in: ctx.safeBounds)
                    check(problems.isEmpty, "\(where_): \(problems.joined(separator: "; "))")
                    var reach = Set<PadButton>(), sticks = 0
                    for c in pad.controls {
                        switch c.kind {
                        case .button(let b): reach.insert(b)
                        case .dpad: reach.formUnion([.up, .down, .left, .right, .stickL])
                        case .stick: sticks += 1
                        default: break
                        }
                    }
                    check(reach == Set(PadButton.allCases) && sticks == 2, "\(where_): missing \(Set(PadButton.allCases).subtracting(reach))")
                    let avoid: [CGRect]
                    switch pad.arrangement {
                    case .native:
                        let r = pad.pictureRect
                        check(r != nil && abs(r!.width / r!.height - 16.0 / 9) < 0.01 && ctx.safeBounds.insetBy(dx: -1, dy: -1).contains(r!),
                              "\(where_): native picture rect \(String(describing: r))")
                        avoid = r.map { [$0] } ?? []
                    case .clear:
                        clears += 1
                        avoid = ctx.videoRects
                        check(pad.unitPoints >= pad.minimumUnit - 0.01, "\(where_): clear layout under the minimum size")
                    case .overlay:
                        overlays += 1
                        avoid = []
                        check(mode == .fit, "\(where_): only Fit may float over the picture")
                    }
                    for c in pad.controls where !avoid.isEmpty {
                        check(!avoid.contains { $0.insetBy(dx: 1, dy: 1).intersects(c.shape.boundingBox) },
                              "\(where_): \(c.label) covers the picture")
                    }
                    if pad.lifeSizeFraction < smallest.0 { smallest = (pad.lifeSizeFraction, where_) }
                }
            }
        }
    }
    print("showcase: \(clears) clear, \(overlays) overlay; smallest \(Int(smallest.0 * 100))% of life size (\(smallest.1))")
    // The GamePad stays a real touchscreen wherever Fit found a margin.
    do {
        let d = TargetDevice.all.first { $0.name.contains("A12Z") }!
        let pad = ShowcasePad(); pad.pointsPerInch = 132; pad.layout(d.context(.stacked))
        check(pad.arrangement == .clear && abs(pad.lifeSizeFraction - 1) < 0.01, "showcase: iPad Pro 11 stacked is clear at life size, got \(pad.arrangement) \(pad.lifeSizeFraction)")
        let face = pad.controls.first { $0.button == .a }!.shape.boundingBox.width
        check(abs(face - 10.625 * 132 / 25.4) < 0.05, "showcase: a face button is 10.625 mm across, got \(face) pt")
    }
    // Window sizes of every shape: Fit and Native both stay valid.
    for mode in ShowcaseLayout.DisplayMode.allCases {
        var bad: [String] = []
        var w: CGFloat = 480
        while w <= 1400 {
            var h: CGFloat = 300
            while h <= 1100 {
                let ctx = LayoutContext(size: CGSize(width: w, height: h), safeInsets: Insets(top: 20, left: 0, bottom: 20, right: 0))
                let pad = ShowcasePad(); pad.displayMode = mode; pad.layout(ctx)
                let p = LayoutCheck.problems(pad.controls, in: ctx.safeBounds)
                if !p.isEmpty { bad.append("\(Int(w))x\(Int(h)): \(p.first!)") }
                h += 80
            }
            w += 70
        }
        check(bad.isEmpty, "Showcase \(mode.rawValue): \(bad.count) window sizes fail, e.g. \(bad.prefix(3).joined(separator: " | "))")
    }

    // Behaviour, through the engine, on the A12Z iPad (Fit, clear) and an iPhone (Native).
    for (name, display, mode) in [("iPad Pro 11 (A12Z)", TargetDevice.Display.stacked, ShowcaseLayout.DisplayMode.fit),
                                  ("iPhone 16 Pro Max", .stacked, .native)] {
        let d = TargetDevice.all.first { $0.name == name }!
        let r = Recorder()
        let pad = ShowcasePad(); pad.pointsPerInch = d.showcasePointsPerInch; pad.displayMode = mode
        let e = PadEngine(scheme: pad, output: r, context: d.context(display))
        func at(_ b: PadButton) -> CGPoint { pad.controls.first { $0.button == b }!.shape.center }
        for b in [PadButton.a, .b, .x, .y, .l, .r, .zl, .zr, .plus, .minus, .home, .stickR] {
            e.began(1, at: at(b), time: 0)
            check(r.held == [b], "showcase \(name): tap \(b) holds exactly \(b), got \(r.held)")
            e.ended(1, at: at(b), time: 0.1)
            check(r.held.isEmpty, "showcase \(name): \(b) released")
        }
        let a = at(.a), b = at(.b)
        e.began(1, at: a, time: 1); e.moved(1, to: b, time: 1.1)
        check(r.held == [.b], "showcase \(name): slide A to B, got \(r.held)")
        e.cancelled(1, time: 1.2)
        check(r.held.isEmpty, "showcase \(name): cancel releases")
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        e.began(2, at: mid, time: 2)
        check(r.held == [.a, .b], "showcase \(name): chord in the gap between A and B, got \(r.held)")
        e.ended(2, at: mid, time: 2.1)
        e.began(1, at: at(.zl), time: 3); e.moved(1, to: at(.l), time: 3.1)
        check(r.held == [.l], "showcase \(name): slide ZL to L, got \(r.held)")
        e.ended(1, at: at(.l), time: 3.2)
        // A finger resting in the gap between the faces and the d-pad is claimed by something (gap-free).
        let dpad = pad.controls.first { if case .dpad = $0.kind { return true }; return false }!
        let c = dpad.shape.center, u = pad.unitPoints
        e.began(1, at: c + CGPoint(x: 0.9 * u, y: -0.9 * u), time: 4)
        check(r.held == [.up, .right], "showcase \(name): d-pad up-right diagonal, got \(r.held)")
        e.moved(1, to: c + CGPoint(x: 0, y: 0.9 * u), time: 4.05)
        check(r.held == [.down], "showcase \(name): d-pad rolls to down, got \(r.held)")
        e.ended(1, at: c, time: 4.1)
        e.began(1, at: c, time: 5)
        check(r.held == [.stickL], "showcase \(name): d-pad centre is L3, got \(r.held)")
        e.ended(1, at: c, time: 5.1)
        let stick = pad.controls.first { if case .stick(.left, _, _) = $0.kind { return true }; return false }!
        e.began(3, at: stick.shape.center, time: 6)
        e.moved(3, to: stick.shape.center + CGPoint(x: 400, y: 0), time: 6.1)
        check(near(r.sticks[.left]?.x ?? 0, 1), "showcase \(name): left stick full right, got \(String(describing: r.sticks[.left]))")
        check(pad.scene(pressed: [], sticks: [:]).primitives.count > 40, "showcase \(name): scene has the full pad")
        e.ended(3, at: .zero, time: 6.2)
        check(r.sticks[.left] == .zero, "showcase \(name): stick recentres")
        // Shared stick settings reach it: a bigger deadzone swallows a small push.
        var ctx = d.context(display); ctx.stick = StickTuning(deadzone: 0.5, curve: 1, gate: .round)
        e.setContext(ctx)
        let s2 = pad.controls.first { if case .stick(.left, _, _) = $0.kind { return true }; return false }!
        e.began(4, at: s2.shape.center, time: 7)
        e.moved(4, to: s2.shape.center + CGPoint(x: 0.3 * u, y: 0), time: 7.1)
        check(r.sticks[.left] == .zero, "showcase \(name): stick reads context.stick (deadzone)")
        e.ended(4, at: .zero, time: 7.2)
    }

    // Settings: preset, colour and display mode each change the pad, and colour reaches the scene.
    do {
        let d = TargetDevice.all.first { $0.name.contains("A12Z") }!
        let pad = ShowcasePad(); pad.pointsPerInch = 132; pad.layout(d.context(.stacked))
        let before = pad.controls.first { $0.button == .a }!.shape.center
        pad.layoutPreset = .compact
        check(pad.controls.first { $0.button == .a }!.shape.center != before && pad.lifeSizeFraction < 0.8, "showcase: Compact preset re-lays out at 70%")
        pad.layoutPreset = .native
        pad.displayMode = .native
        check(pad.arrangement == .native && pad.pictureRect != nil, "showcase: display mode switches to Native")
        let white = pad.scene(pressed: [], sticks: [:])
        pad.colourPreset = .wiiUBlack
        check(pad.scene(pressed: [], sticks: [:]) != white, "showcase: colour preset changes the scene")
        let held = pad.scene(pressed: [.a], sticks: [:])
        check(held != pad.scene(pressed: [], sticks: [:]), "showcase: a held button looks different")
    }
}

print("\(passes) passed, \(failures) failed")
exit(Int32(min(failures, 125)))
