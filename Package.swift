// swift-tools-version:5.5
import PackageDescription

let package = Package(
	name: "unxip",
	platforms: [
		.macOS(.v11)
	],
	products: [
		.executable(name: "unxip", targets: ["unxip"])
	],
	targets: [
		.executableTarget(
			name: "unxip",
			path: "./",
			exclude: [
				"LICENSE",
				"README.md",
			],
			sources: ["unxip.swift"]
		)
	]
)
