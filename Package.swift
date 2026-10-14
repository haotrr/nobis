// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Nobis", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NobisUI", targets: ["NobisUI"]), .executable(name: "nobis", targets: ["NobisCLI"])],
    dependencies: [.package(path: "Vendor/MDTextKit")],
    targets: [
        .target(name: "FamilyDomain"),
        .target(name: "FamilyCore", dependencies: ["FamilyDomain"]),
        .target(name: "FamilyPersistence", dependencies: ["FamilyDomain", "FamilyCore"]),
        .target(name: "NobisUI", dependencies: ["FamilyDomain", "FamilyCore", "FamilyPersistence",
            .product(name: "MDTextKitUI", package: "MDTextKit", condition: .when(platforms: [.macOS]))], resources: [.copy("Resources/MDTextKit-LICENSE.txt")]),
        .executableTarget(name: "NobisCLI", dependencies: ["FamilyDomain", "FamilyCore"]),
        .testTarget(name: "FamilyCoreTests", dependencies: ["FamilyCore", "FamilyPersistence", "NobisUI"])
    ])
