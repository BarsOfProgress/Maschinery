// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MaschineMachine", platforms: [.macOS(.v14)], products: [.library(name: "MaschineCore", targets: ["MaschineCore"]), .executable(name: "MaschineMachine", targets: ["MaschineMachine"])], targets: [.target(name: "MaschineCore"), .executableTarget(name: "MaschineMachine", dependencies: ["MaschineCore"]), .testTarget(name: "MaschineCoreTests", dependencies: ["MaschineCore"])])
