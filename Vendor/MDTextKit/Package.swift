// swift-tools-version: 6.2
import PackageDescription

//   PolarMark   -> parser + AST + structural operations
//   MDTextStorageCore -> the text storage's Objective-C primitives
//   MDTextKit   -> NSTextStorage / stylers / hider / layout manager
//   MDTextKitUI -> NSTextView subclass + editor view controller
//   SFThemeKit  -> JSON theme loading with $path references
//   TextBundle  -> .textbundle / .textpack packages per textbundle.org
let package = Package(
    name: "MDTextKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MDTextKitUIKit", targets: ["MDTextKitUIKit"]),
        .library(name: "PolarMark", targets: ["PolarMark"]),
        .library(name: "MDTextKit", targets: ["MDTextKit"]),
        .library(name: "MDTextKitUI", targets: ["MDTextKitUI"]),
        .library(name: "SFThemeKit", targets: ["SFThemeKit"]),
        .library(name: "TextBundle", targets: ["TextBundle"]),
        .executable(name: "MDTextKitDemo", targets: ["MDTextKitDemo"]),
    ],
    targets: [
        .target(name: "PolarMark"),
        .target(name: "MDTextKitUIKit", dependencies: ["PolarMark"]),
        .target(name: "SFThemeKit"),
        .target(name: "TextBundle"),
        .target(name: "MDTextStorageCore"),
        .target(name: "MDTextKit", dependencies: ["PolarMark", "SFThemeKit", "MDTextStorageCore"]),
        .target(name: "MDTextKitUI", dependencies: ["MDTextKit", "PolarMark", "SFThemeKit", "TextBundle"]),
        .executableTarget(name: "MDTextKitDemo", dependencies: ["MDTextKitUI", "TextBundle"], resources: [.copy("Themes")]),
        .testTarget(name: "PolarMarkTests", dependencies: ["PolarMark"]),
        .testTarget(name: "MDTextKitTests", dependencies: ["MDTextKit", "MDTextKitUI"]),
        .testTarget(name: "TextBundleTests", dependencies: ["TextBundle"]),
    ],
    swiftLanguageModes: [.v6]
)
