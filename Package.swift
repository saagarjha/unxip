// swift-tools-version: 5.5

import PackageDescription

let package = Package(
	name: "unxip",
	platforms: [.macOS(.v12)],
	products: [
		.executable(name: "unxip", targets: ["unxip"]),
		.library(name: "UnxipFramework", targets: ["UnxipFramework"]),
	],
	targets: [
		.executableTarget(name: "unxip", dependencies: ["UnxipFramework"]),
		.target(name: "UnxipFramework"),
	]
)
