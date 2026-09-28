// swift-tools-version:6.0
import PackageDescription

let dependencies: [Target.Dependency] = [
	.target(name: "GNUSource", condition: .when(platforms: [.linux, .android])),
	.target(name: "getopt", condition: .when(platforms: [.linux])),
	.target(name: "lzma", condition: .when(platforms: [.linux, .android])),
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
		pkgConfig: "liblzma",
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
