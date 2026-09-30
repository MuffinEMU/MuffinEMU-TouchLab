// swift-tools-version: 5.9
// Compiles integration/MuffinEMU/TouchLabPads.swift for iOS against stubs that mirror
// MuffinEMU's real declarations (bridge header, ControllerLayoutSettings, PadDiagnostics,
// effectiveRenderScale), so the drop-in file is known to build before anyone copies it.
// CI copies TouchLabPads.swift in next to the stubs; nothing here ships.
import PackageDescription

let package = Package(
    name: "IntegrationCheck",
    platforms: [.iOS(.v15)],
    products: [.library(name: "Check", targets: ["Check"])],
    dependencies: [.package(path: "../../..")],
    targets: [
        .target(name: "Check", dependencies: [
            .product(name: "TouchLabCore", package: "MuffinEMU-TouchLab"),
            .product(name: "TouchLabUI", package: "MuffinEMU-TouchLab"),
        ]),
    ]
)
