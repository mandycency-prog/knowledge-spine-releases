import AppKit
import CoreText
import Foundation
import ImageIO
import KnowledgeSpineCore

/// Creates only synthetic UI materials in an explicitly validated test directory.
@main @MainActor struct ImageUIFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected isolated root") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasPrefix("KnowledgeSpine-Acceptance-"),
              !FileManager.default.fileExists(atPath: root.path) else { fatalError("Unsafe fixture root") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = AppStore(storageRoot: root)
        store.asrCommandPath = "/usr/bin/false"
        store.whisperModelPath = "/synthetic/no-model.pt"
        let id = store.createSession(title: "图片功能验收（合成材料）", sourceName: "合成课程", sourceKind: "测试")
        _ = store.importTranscriptText("先观察现象，再提出假设，最后通过实验进行验证。课件上补充了每一步的具体操作。", sessionID: id)
        guard store.flush() else { fatalError("Fixture storage failed") }
        let width = 960, height = 420
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat) {
            context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: y)
            let attributed = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.black])
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        text("合成课件：从观察到验证", x: 60, y: 345, size: 32)
        for (index, label) in ["观察现象", "提出假设", "实验验证"].enumerated() {
            let x = CGFloat(60 + index * 300)
            context.setFillColor(CGColor(red: 0.83, green: 0.94, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: x, y: 180, width: 240, height: 100))
            text(label, x: x + 45, y: 218, size: 25)
            if index < 2 { text("→", x: x + 260, y: 217, size: 26) }
        }
        text("示例数据：对照组 10，实验组 15；这是测试图片。", x: 60, y: 90, size: 22)
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Fixture image failed") }
        let imageURL = root.appendingPathComponent("合成课件.png")
        try (bytes as Data).write(to: imageURL, options: .atomic)
        print("Synthetic fixture ready:", root.path)
        print("Record:", id.uuidString)
        print("Image:", imageURL.path)
    }
}
