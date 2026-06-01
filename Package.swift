// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PDFPortalPrep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PDFPortalPrep", targets: ["PDFPortalPrep"])
    ],
    targets: [
        .executableTarget(
            name: "PDFPortalPrep",
            path: ".",
            exclude: [
                "Package.swift",
                ".build",
                "Scripts",
                "dist",
                "Tests",
                "logo.png",
                "client_secret_303761801205-hklf7f79k6jtj68lsigno8tmg9kp6nvi.apps.googleusercontent.com.json"
            ],
            sources: [
                "PDFPortalPrepApp.swift",
                "Views",
                "Models",
                "Services",
                "Utilities"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "PDFPortalPrepTests",
            dependencies: ["PDFPortalPrep"],
            path: "Tests/PDFPortalPrepTests"
        )
    ]
)
