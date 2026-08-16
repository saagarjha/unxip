// swift-tools-version:6.0
import PackageDescription

// Platform conditions are modelled with .when rather than #if so they
// are evaluated for the TARGET platform, not the manifest host — this
// keeps cross compilation (e.g. Linux/Android from a macOS host, or
// Android from Linux) selecting the right dependencies. The system
// library shim targets are declared unconditionally: targets that end
// up unreferenced for a platform are not built, so their modulemaps
// cannot clash with platform-provided modules.
let dependencies: [Target.Dependency] = [
	// glibc/Bionic both need the GNUSource and lzma shims; macOS and
	// iOS-family SDKs provide the needed functionality directly.
	.target(name: "GNUSource", condition: .when(platforms: [.linux, .android])),
	.target(name: "lzma", condition: .when(platforms: [.linux, .android])),
	// The Android NDK already ships zlib and getopt modules, so these
	// shims are Linux-only.
	.target(name: "getopt", condition: .when(platforms: [.linux])),
	.target(name: "zlib", condition: .when(platforms: [.linux])),
]

let systemLibraries: [Target] = [
	.systemLibrary(
		name: "GNUSource"
	),
	.systemLibrary(
		name: "getopt"
	),
	.systemLibrary(
		name: "lzma",
		providers: [
			.aptItem(["liblzma-dev"])
		]
	),
	.systemLibrary(
		name: "zlib",
		providers: [
			.apt(["zlib1g-dev"])
		]
	),
]

let package = Package(
	name: "unxip",
	platforms: [
		.macOS(.v10_15), .iOS(.v13), .watchOS(.v6),
	],
	products: [
		.executable(name: "unxip", targets: ["unxip"]),
		.library(name: "libunxip", targets: ["libunxip"]),
	],
	targets: [
		.executableTarget(
			name: "unxip",
			dependencies: dependencies,
			path: "./",
			exclude: [
				"LICENSE",
				"README.md",
				"release.sh",
				"Makefile",
			],
			sources: ["unxip.swift"]
		),
		.target(
			name: "libunxip",
			dependencies: dependencies,
			swiftSettings: [.define("LIBUNXIP")]
		),
	] + systemLibraries
)
