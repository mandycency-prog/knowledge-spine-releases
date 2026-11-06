import Foundation

/// Bundle-relative defaults; saved user settings remain authoritative.
public struct PortableRuntime: Equatable, Sendable {
    public let pythonPath: String
    public let whisperModelPath: String
    public let structureModelPath: String
    public let ffmpegPath: String

    public static var dataDirectoryName: String {
        Bundle.main.object(forInfoDictionaryKey: "KnowledgeSpineDistributionPreview") as? Bool == true
            ? "直播与课程知识骨架测试版" : "直播与课程知识骨架"
    }

    public static var defaults: Self {
        resolve(resources: Bundle.main.resourceURL,
                home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func resolve(resources: URL?, home: URL) -> Self {
        let runtime = resources?.appendingPathComponent("Runtime", isDirectory: true)
        let bundledPython = runtime?.appendingPathComponent("bin/runtime-python")
        let present = bundledPython.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        let support = home.appendingPathComponent("Library/Application Support")
            .appendingPathComponent(dataDirectoryName)
        return Self(
            pythonPath: present ? bundledPython!.path : home.appendingPathComponent(".local/bin/python3").path,
            whisperModelPath: present ? resources!.appendingPathComponent("Models/base.pt").path
                : home.appendingPathComponent(".cache/whisper/base.pt").path,
            structureModelPath: support.appendingPathComponent("Models/structure.gguf").path,
            ffmpegPath: present ? resources!.appendingPathComponent("Tools/ffmpeg").path
                : home.appendingPathComponent(".local/bin/ffmpeg").path)
    }
}
