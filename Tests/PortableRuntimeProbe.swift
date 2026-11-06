import Foundation
import KnowledgeSpineCore

@main struct Probe {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Portable-\(UUID()) 空格")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("new-user")
        let resources = root.appendingPathComponent("Moved App.app/Contents/Resources")
        let executable = resources.appendingPathComponent("Runtime/bin/runtime-python")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let first = PortableRuntime.resolve(resources: resources, home: home)
        precondition(first.pythonPath == executable.path)
        precondition(first.whisperModelPath == resources.appendingPathComponent("Models/base.pt").path)
        precondition(first.ffmpegPath == resources.appendingPathComponent("Tools/ffmpeg").path)
        precondition(first.structureModelPath.hasPrefix(home.path))
        let next = root.appendingPathComponent("Relocated.app/Contents/Resources")
        try fm.createDirectory(at: next.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: resources, to: next)
        precondition(PortableRuntime.resolve(resources: next, home: home).pythonPath.hasPrefix(next.path))
        let saved = AppSettings(pythonPath: "/synthetic/custom/python", whisperModelPath: "/synthetic/custom/asr", structureModelPath: "/synthetic/custom/model", ffmpegPath: "/synthetic/custom/ffmpeg")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved))
        precondition(decoded == saved)
        precondition(PortableRuntime.resolve(resources: nil, home: home).pythonPath == home.appendingPathComponent(".local/bin/python3").path)
        print("PASS: relocated bundle, spaces, fresh-user defaults and saved settings preserved")
    }
}
