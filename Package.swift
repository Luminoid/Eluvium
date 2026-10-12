// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Eluvium",
    // Required once a target ships localized resources (EluviumUI's
    // en.lproj); the base language every lookup falls back to.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "EluviumCore", targets: ["EluviumCore"]),
        .library(name: "EluviumCatalog", targets: ["EluviumCatalog"]),
        .library(name: "EluviumNet", targets: ["EluviumNet"]),
        .library(name: "EluviumDOM", targets: ["EluviumDOM"]),
        .library(name: "EluviumPlaces", targets: ["EluviumPlaces"]),
        .library(name: "EluviumUI", targets: ["EluviumUI"]),
        .executable(name: "eluvium", targets: ["EluviumCLI"]),
    ],
    dependencies: [
        // LumiKit follows semantic versioning from 1.0, so `from:` takes any
        // 1.x release and stops before the next breaking (major) one.
        .package(url: "https://github.com/Luminoid/LumiKit.git", from: "1.0.0"),
        .package(url: "https://github.com/SnapKit/SnapKit.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "EluviumCore",
            dependencies: [],
            path: "Sources/EluviumCore"
        ),
        // The source catalog (starter pack + opt-in packs), split out of the
        // engine so an adopting app can compile in only a curated subset (via
        // `eluvium curate`) instead of force-linking all sources. Apps that
        // want everything depend on this product; the engine (EluviumCore)
        // carries no sources.
        .target(
            name: "EluviumCatalog",
            dependencies: [
                "EluviumCore",
            ],
            path: "Sources/EluviumCatalog",
            resources: [
                // The opt-in packs (Amazon/Chewy), kept out of the compiled
                // starter and loaded only through ELVOptInPacks. A real JSON
                // asset, so the generated resource bundle is not the empty
                // placeholder codesign rejects (see the EluviumUI note).
                .copy("OptIn/CommerceOptInPack.json"),
            ]
        ),
        .target(
            name: "EluviumNet",
            dependencies: [
                "EluviumCore",
            ],
            path: "Sources/EluviumNet"
        ),
        .target(
            name: "EluviumDOM",
            dependencies: [
                "EluviumCore",
            ],
            path: "Sources/EluviumDOM",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .target(
            name: "EluviumPlaces",
            dependencies: [
                "EluviumCore",
            ],
            path: "Sources/EluviumPlaces"
        ),
        .target(
            name: "EluviumUI",
            dependencies: [
                "EluviumCore",
                .product(name: "LumiKitUI", package: "LumiKit"),
                // Declared, not inherited: EluviumUI lays out with SnapKit
                // directly, so it must not ride LumiKit's transitive graph.
                "SnapKit",
            ],
            path: "Sources/EluviumUI",
            // The card's own copy: compiled `.lproj` strings plus a
            // `.stringsdict` plural, never a String Catalog (command-line
            // SwiftPM copies an `.xcstrings` uncompiled, so every lookup
            // would return its key). Real assets only: a placeholder-only
            // bundle (the former Resources/.gitkeep) was rejected by Xcode
            // 26.4's codesign as "format unrecognized" in signed consumer
            // builds.
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Author tooling: `eluvium curate` (subset the catalog into an app's
        // compiled-in pack), `eluvium keygen` / `eluvium sign` (remote-pack
        // signing). Not linked by adopting apps.
        .executableTarget(
            name: "EluviumCLI",
            dependencies: [
                "EluviumCatalog",
                "EluviumCore",
                // `curate` checks a subset against the capabilities an app
                // linking Core + Net would have, so EluviumNet's
                // `shortlink.expand` registers before the check.
                "EluviumNet",
            ],
            path: "Sources/EluviumCLI"
        ),
        // Engine tests link no sources: anything that loads the starter or
        // opt-in packs lives in EluviumCatalogTests.
        .testTarget(
            name: "EluviumCoreTests",
            dependencies: ["EluviumCore"],
            path: "Tests/EluviumCoreTests"
        ),
        // The catalog's own suite: starter/opt-in pack content, the frozen
        // compatibility matrix, and the fixture-backed parity runs.
        .testTarget(
            name: "EluviumCatalogTests",
            dependencies: ["EluviumCatalog", "EluviumCore"],
            path: "Tests/EluviumCatalogTests",
            resources: [
                // .copy, not .process: the Petfolio parity fixtures must stay
                // byte-identical to PetfolioTests/Fixtures/.
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "EluviumNetTests",
            dependencies: ["EluviumNet", "EluviumCatalog"],
            path: "Tests/EluviumNetTests"
        ),
        .testTarget(
            name: "EluviumDOMTests",
            dependencies: ["EluviumDOM"],
            path: "Tests/EluviumDOMTests"
        ),
        .testTarget(
            name: "EluviumPlacesTests",
            dependencies: ["EluviumPlaces", "EluviumCatalog"],
            path: "Tests/EluviumPlacesTests"
        ),
        .testTarget(
            name: "EluviumUITests",
            dependencies: ["EluviumUI"],
            path: "Tests/EluviumUITests"
        ),
    ]
)
