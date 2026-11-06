// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KnowledgeSpine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KnowledgeSpineCore", targets: ["KnowledgeSpineCore"]),
        .executable(name: "KnowledgeSpineApp", targets: ["KnowledgeSpineApp"]),
        .executable(name: "KnowledgeSpineSelfTest", targets: ["KnowledgeSpineSelfTest"]),
        .executable(name: "KnowledgeSpineAppleSpeech", targets: ["KnowledgeSpineAppleSpeech"]),
    ],
    targets: [
        .target(name: "KnowledgeSpineCore"),
        .executableTarget(name: "KnowledgeSpineAppleSpeech"),
        .executableTarget(
            name: "KnowledgeSpineApp",
            dependencies: ["KnowledgeSpineCore"]
        ),
        .executableTarget(
            name: "KnowledgeSpineSelfTest",
            dependencies: ["KnowledgeSpineCore"]
        ),
    ]
)
