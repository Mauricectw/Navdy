// swift-tools-version:5.9
import PackageDescription

// Foundation-only layers for the Navdy app. Builds and tests on macOS and Linux, so the byte-level
// HUD protocol and the Google Maps parsing can be verified without an iPhone.
let package = Package(
    name: "NavdyWire",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "NavdyWire", targets: ["NavdyWire"]),
        .library(name: "NavdyPlaces", targets: ["NavdyPlaces"]),
    ],
    targets: [
        .target(name: "NavdyWire"),
        .target(name: "NavdyPlaces"),
        .testTarget(name: "NavdyWireTests", dependencies: ["NavdyWire"]),
        .testTarget(name: "NavdyPlacesTests", dependencies: ["NavdyPlaces"]),
    ]
)
