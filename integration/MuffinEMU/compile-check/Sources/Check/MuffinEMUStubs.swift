// Stubs with the SAME shapes as MuffinEMU's real declarations (main @ 8de67090). If
// MuffinEMU changes one of these, update the stub to match - it is the contract the
// drop-in file is compiled against.
import SwiftUI
import UIKit

// src/ios/Bridge/CemuBridge.h - C enums import as RawRepresentable structs over UInt32,
// and their cases as global constants.
struct CemuBridgeButton: Equatable, RawRepresentable {
    var rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
let CEMU_BRIDGE_BUTTON_A = CemuBridgeButton(1)
let CEMU_BRIDGE_BUTTON_B = CemuBridgeButton(2)
let CEMU_BRIDGE_BUTTON_X = CemuBridgeButton(3)
let CEMU_BRIDGE_BUTTON_Y = CemuBridgeButton(4)
let CEMU_BRIDGE_BUTTON_L = CemuBridgeButton(5)
let CEMU_BRIDGE_BUTTON_R = CemuBridgeButton(6)
let CEMU_BRIDGE_BUTTON_ZL = CemuBridgeButton(7)
let CEMU_BRIDGE_BUTTON_ZR = CemuBridgeButton(8)
let CEMU_BRIDGE_BUTTON_PLUS = CemuBridgeButton(9)
let CEMU_BRIDGE_BUTTON_MINUS = CemuBridgeButton(10)
let CEMU_BRIDGE_BUTTON_UP = CemuBridgeButton(11)
let CEMU_BRIDGE_BUTTON_DOWN = CemuBridgeButton(12)
let CEMU_BRIDGE_BUTTON_LEFT = CemuBridgeButton(13)
let CEMU_BRIDGE_BUTTON_RIGHT = CemuBridgeButton(14)
let CEMU_BRIDGE_BUTTON_STICK_L = CemuBridgeButton(15)
let CEMU_BRIDGE_BUTTON_STICK_R = CemuBridgeButton(16)
let CEMU_BRIDGE_BUTTON_HOME = CemuBridgeButton(17)

struct CemuBridgeStick: Equatable, RawRepresentable {
    var rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
let CEMU_BRIDGE_STICK_LEFT = CemuBridgeStick(0)
let CEMU_BRIDGE_STICK_RIGHT = CemuBridgeStick(1)

func cemu_bridge_set_button_state(_ button: CemuBridgeButton, _ pressed: Bool) {}
func cemu_bridge_set_stick_axis(_ stick: CemuBridgeStick, _ x: Float, _ y: Float) {}
func cemu_bridge_set_pad_touch(_ x: Double, _ y: Double, _ down: Bool) {}
func cemu_bridge_release_all_buttons() {}

// src/ios/App/ControllerLayout.swift
enum ControllerLayoutSettings {
    static let scaleKey = "muffin.controls.scale"
    static let opacityKey = "muffin.controls.opacity"
    static let deadzoneKey = "muffin.controls.stick.deadzone"
    static let stickCurveKey = "muffin.controls.stick.curve"
    static let stickGateKey = "muffin.controls.stick.gate"
    static let hapticsKey = "muffin.pad.haptics"
    static let defaultHaptics = true
    static let defaultDeadzone: Double = 0.06
    static let defaultStickCurve: Double = 1.0
    static let defaultStickGateRaw = "octagon"
    static let defaultScale: Double = 1.0
    static let defaultOpacity: Double = 0.85
}

// src/ios/App/PadDiagnostics.swift
@MainActor
final class PadDiagnostics: ObservableObject {
    static let shared = PadDiagnostics()
    func recordInput(_ label: String, _ pressed: Bool) {}
    func recordStick(_ stick: Int, _ position: CGPoint) {}
}

// src/ios/App/RenderScale.swift
extension UIScreen {
    // Real code: `max(0.5, Double(scale) * RenderScale.current.factor)`. UIScreen is
    // main-actor isolated in current SDKs, and so is this extension.
    var effectiveRenderScale: Double { Double(scale) }
}
