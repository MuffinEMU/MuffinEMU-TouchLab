// swift-tools-version: 5.9
// MuffinEMU TouchLab — code by the MuffinEMU Development Team.
// Copyright (c) 2026 MuffinEMU Development Team.
// SPDX-License-Identifier: GPL-3.0-only
// This notice must be kept in any copy or modified version (GPL-3.0 §4 and §5).

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
