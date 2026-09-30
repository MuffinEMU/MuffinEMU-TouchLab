import SwiftUI
import TouchLabCore
import TouchLabUI

/// A test bench for the four schemes: fake TV / GamePad screens, the pad over them, and a
/// live readout of exactly what the pad would send to the emulator. Nothing here talks to
/// an emulator core.
@main
struct TouchLabApp: App {
    var body: some Scene {
        WindowGroup {
            LabView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                // Edge swipes on a game pad are almost always thumbs, not requests for
                // Control Centre.
                .defersSystemGestures(on: .all)
        }
    }
}

/// Records what the pad sends. Same four calls MuffinEMU's bridge adapter implements.
final class LabOutput: PadOutput, ObservableObject {
    @Published var pressed: Set<PadButton> = []
    @Published var sticks: [PadStick: StickValue] = [:]
    @Published var touchscreen: CGPoint?
    @Published var log: [String] = []

    func setButton(_ button: PadButton, pressed down: Bool) {
        if down { pressed.insert(button) } else { pressed.remove(button) }
        record("\(button) \(down ? "down" : "up")")
    }

    func setStick(_ stick: PadStick, _ value: StickValue) {
        sticks[stick] = value
    }

    func setTouchscreen(_ point: CGPoint?) {
        if (point == nil) != (touchscreen == nil) {
            record(point.map { String(format: "touch %.2f, %.2f", $0.x, $0.y) } ?? "touch up")
        }
        touchscreen = point
    }

    func releaseAll() {
        pressed = []
        sticks = [:]
        record("release all")
    }

    private func record(_ line: String) {
        log.append(line)
        if log.count > 8 { log.removeFirst(log.count - 8) }
    }
}

struct LabView: View {
    @StateObject private var output = LabOutput()
    @AppStorage("touchlab.scheme") private var schemeID = ZonePad.schemeInfo.id
    @AppStorage("touchlab.display") private var displayRaw = TargetDevice.Display.stacked.rawValue
    @AppStorage("touchlab.scale") private var scale = 1.0
    @AppStorage("touchlab.opacity") private var opacity = 0.85
    @AppStorage("touchlab.haptics") private var haptics = true
    @AppStorage("touchlab.float.camera") private var cameraRaw = FloatPad.Camera.stick.rawValue
    @AppStorage("touchlab.adaptive.learned") private var learnedJSON = "{}"
    @State private var resets = 0
    @State private var showSettings = false

    private var display: TargetDevice.Display { TargetDevice.Display(rawValue: displayRaw) ?? .stacked }

    var body: some View {
        GeometryReader { geo in
            let screens = videoRects(in: geo)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(screens.rects.enumerated()), id: \.offset) { i, r in
                    FakeScreen(title: screens.rects.count == 2 && i == 0 ? "TV" : "GamePad",
                               touch: i == screens.rects.count - 1 ? output.touchscreen : nil)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                Readout(output: output, schemeName: SchemeCatalog.all.first { $0.id == schemeID }?.name ?? "")
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                TouchPad(schemeID: schemeID, output: output,
                         touchscreenRect: screens.gamepad, videoRects: screens.rects,
                         scale: scale, opacity: opacity, haptics: haptics,
                         revision: cameraRaw.hashValue &+ resets, makeScheme: makeScheme)
                    .ignoresSafeArea()

                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showSettings) {
            LabSettings(schemeID: $schemeID, displayRaw: $displayRaw, scale: $scale,
                        opacity: $opacity, haptics: $haptics, cameraRaw: $cameraRaw,
                        learnedJSON: learnedJSON,
                        resetLearning: { learnedJSON = "{}"; resets += 1 })
        }
    }

    private func makeScheme(_ id: String) -> TouchScheme {
        switch id {
        case FloatPad.schemeInfo.id:
            return FloatPad(camera: FloatPad.Camera(rawValue: cameraRaw) ?? .stick)
        case AdaptivePad.schemeInfo.id:
            let pad = AdaptivePad(learned: AdaptivePad.decode(learnedJSON))
            pad.onLearned = { learned in learnedJSON = AdaptivePad.encode(learned) }
            return pad
        default:
            return SchemeCatalog.make(id)
        }
    }

    /// Same placement rule as TargetDevice.video: 16:9 screens, centred, stacked or single.
    private func videoRects(in geo: GeometryProxy) -> (rects: [CGRect], gamepad: CGRect) {
        let i = geo.safeAreaInsets
        let device = TargetDevice(name: "live", size: geo.size,
                                  insets: Insets(top: i.top, left: i.leading, bottom: i.bottom, right: i.trailing))
        return device.video(display)
    }
}

struct FakeScreen: View {
    let title: String
    let touch: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.14, green: 0.20, blue: 0.29), Color(red: 0.08, green: 0.11, blue: 0.17)],
                               startPoint: .top, endPoint: .bottom)
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.25))
                if let touch {
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 18, height: 18)
                        .position(x: touch.x * geo.size.width, y: touch.y * geo.size.height)
                }
            }
        }
    }
}

struct Readout: View {
    @ObservedObject var output: LabOutput
    let schemeName: String

    var body: some View {
        VStack(spacing: 6) {
            Text(schemeName).font(.headline)
            Text(output.pressed.isEmpty ? "-" : output.pressed.sorted { $0.rawValue < $1.rawValue }
                    .map(\.description).joined(separator: " "))
                .font(.system(.title3, design: .monospaced).weight(.bold))
            HStack(spacing: 18) {
                StickDial(label: "L", value: output.sticks[.left] ?? .zero)
                StickDial(label: "R", value: output.sticks[.right] ?? .zero)
            }
            ForEach(Array(output.log.suffix(4).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 70)
    }
}

struct StickDial: View {
    let label: String
    let value: StickValue

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.white.opacity(0.4), lineWidth: 1.5)
                Circle().fill(.yellow).frame(width: 8, height: 8)
                    .offset(x: value.x * 22, y: -value.y * 22)
            }
            .frame(width: 52, height: 52)
            Text(String(format: "%@ %+.2f %+.2f", label, value.x, value.y)).font(.caption2.monospaced())
        }
    }
}

struct LabSettings: View {
    @Binding var schemeID: String
    @Binding var displayRaw: String
    @Binding var scale: Double
    @Binding var opacity: Double
    @Binding var haptics: Bool
    @Binding var cameraRaw: String
    let learnedJSON: String
    let resetLearning: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Scheme") {
                    Picker("Scheme", selection: $schemeID) {
                        ForEach(SchemeCatalog.all, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    if let info = SchemeCatalog.all.first(where: { $0.id == schemeID }) {
                        Text(info.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if schemeID == FloatPad.schemeInfo.id {
                    Section("Camera (right side)") {
                        Picker("Camera", selection: $cameraRaw) {
                            Text("Floating stick").tag(FloatPad.Camera.stick.rawValue)
                            Text("Swipe").tag(FloatPad.Camera.swipe.rawValue)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                if schemeID == AdaptivePad.schemeInfo.id {
                    Section("Adaptive") {
                        Text("Learned: \(AdaptivePad.decode(learnedJSON).count) of 7 groups moved")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Reset to home positions", role: .destructive, action: resetLearning)
                    }
                }
                Section("Screens") {
                    Picker("Layout", selection: $displayRaw) {
                        Text("TV + GamePad").tag(TargetDevice.Display.stacked.rawValue)
                        Text("GamePad only").tag(TargetDevice.Display.single.rawValue)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Pad") {
                    LabeledContent("Size") {
                        Slider(value: $scale, in: 0.7...1.4)
                    }
                    LabeledContent("Opacity") {
                        Slider(value: $opacity, in: 0.2...1)
                    }
                    Toggle("Haptics", isOn: $haptics)
                }
            }
            .navigationTitle("TouchLab")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
