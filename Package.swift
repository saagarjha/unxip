// swift-tools-version:6.0
import PackageDescription

#if os(macOS)
	let dependencies = [Target.Dependency]()
	let systemLibraries = [Target]()
#elseif os(Android)
	// The Android NDK modulemap already provides the zlib and getopt
	// modules, so defining our own would clash. GNUSource and lzma
	// still need shims.
	let dependencies: [Target.Dependency] = [
		.target(name: "GNUSource"),
		.target(name: "lzma"),
	]
	let systemLibraries: [Target] = [
		.systemLibrary(
			name: "GNUSource"
		),
		.systemLibrary(
			name: "lzma",
			providers: [
				.aptItem(["liblzma-dev"])
			]
		),
	]
#else
	let dependencies: [Target.Dependency] = [
		.target(name: "GNUSource"),
		.target(name: "getopt"),
		.target(name: "zlib"),
		.target(name: "lzma"),
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
#endif

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
