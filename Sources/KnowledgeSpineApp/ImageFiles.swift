import AppKit
import CryptoKit
import Foundation
import ImageIO
import KnowledgeSpineCore
import UniformTypeIdentifiers

enum ImageFileFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Originals are immutable; disposable, bounded JPEGs are the only model inputs.
enum ImageFiles {
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumCount = 50

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func metadata(_ data: Data, title: String) throws -> ImageAttachment {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              let mime = ["public.png": "image/png", "public.jpeg": "image/jpeg", "org.webmproject.webp": "image/webp"][type as String],
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              width * height <= 50_000_000 else {
            throw ImageFileFailure.invalid("请选择有效的 PNG、JPEG 或 WebP 静态图片；单张不超过 20 MB、5000 万像素。")
        }
        let id = UUID()
        let ext = mime == "image/png" ? "png" : (mime == "image/jpeg" ? "jpg" : "webp")
        return ImageAttachment(id: id, title: String(title.prefix(160)), relativePath: "Images/\(id.uuidString).\(ext)",
                               sha256: digest(data), mimeType: mime, width: width, height: height)
    }

    static func resolve(_ image: ImageAttachment, directory: URL) -> URL? {
        let parts = image.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Images", !parts[1].isEmpty,
              !parts[1].contains("\\"), parts[1] != ".", parts[1] != ".." else { return nil }
        let root = directory.appendingPathComponent("Images", isDirectory: true).resolvingSymlinksInPath()
        let url = directory.appendingPathComponent(image.relativePath).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == root,
              root.deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { return nil }
        return url
    }

    static func verifiedData(_ image: ImageAttachment, directory: URL) throws -> Data {
        guard let url = resolve(image, directory: directory),
              let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]).fileSize,
              size <= maximumBytes else { throw ImageFileFailure.invalid("图片文件不存在或路径无效：\(image.title)") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard digest(data) == image.sha256 else { throw ImageFileFailure.invalid("图片内容校验不一致，已停止读取：\(image.title)") }
        return data
    }

    static func pastedPNG() throws -> Data? {
        guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff)
                ?? NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) else { return nil }
        guard data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 50_000_000,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= maximumBytes else {
            throw ImageFileFailure.invalid("剪贴板截图过大或无法解码，请缩小截图范围后重试。")
        }
        return png
    }

    private static func jpeg(_ image: CGImage, to url: URL) throws {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageFileFailure.invalid("无法创建图片分析预览。")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageFileFailure.invalid("图片预览保存失败。") }
        try (bytes as Data).write(to: url, options: .atomic)
    }

    private static func readable(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetStatus(source) == .statusComplete else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 8] as CFDictionary) != nil
    }

    static func modelInputs(_ image: ImageAttachment, directory: URL) throws -> [URL] {
        let data = try verifiedData(image, directory: directory)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let overview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: false,
              ] as CFDictionary) else { throw ImageFileFailure.invalid("无法解码图片：\(image.title)") }
        let work = directory.appendingPathComponent("Processing/ImageInputs", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let base = image.id.uuidString + "-" + image.sha256.prefix(12)
        let main = work.appendingPathComponent(base + ".jpg")
        if !readable(main) { try jpeg(overview, to: main) }
        var result = [main]
        // Dense high-resolution slides get readable regions as well
        // as an overview. Bound the decode and the number of transmitted images.
        if max(image.width, image.height) > 2400,
           let original = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
           ] as CFDictionary) {
            var index = 0
            for y in stride(from: 0, to: original.height, by: 2048) {
                for x in stride(from: 0, to: original.width, by: 2048) {
                    let rect = CGRect(x: x, y: y, width: min(2048, original.width - x), height: min(2048, original.height - y))
                    guard let tile = original.cropping(to: rect) else { continue }
                    let url = work.appendingPathComponent(base + "-\(index).jpg")
                    if !readable(url) { try jpeg(tile, to: url) }
                    result.append(url); index += 1
                }
            }
        }
        return result
    }

    /// The cache key binds source bytes, user context, provider/model and prompt.
    static func request(_ image: ImageAttachment, session: SessionRecord, configuration: APIConfiguration, directory: URL) throws -> [String: Any] {
        let inputs = try modelInputs(image, directory: directory)
        let context = session.transcript.filter { span in
            if let id = image.anchorSpanID, id == span.id { return true }
            if let nodeID = image.attachedNodeID, let node = session.nodes.first(where: { $0.id == nodeID }) {
                return (node.sourceSpanIDs + (node.coveredSourceSpanIDs ?? [])).contains(span.id)
            }
            if let time = image.anchorTime { return span.endTime >= time - 45 && span.startTime <= time + 45 }
            return false
        }.filter { !$0.isFilteredBackground }
        let bytes = try inputs.map { try Data(contentsOf: $0) }
        let hashes = bytes.map(digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var config = configuration
        config.baseURL = (try? APIConfiguration.normalizedEndpoint(configuration.baseURL)) ?? configuration.baseURL
        let configObject = try JSONSerialization.jsonObject(with: encoder.encode(config))
        let contextRecords: [[String: Any]] = context.map { ["id": $0.id.uuidString, "text": $0.displayedText,
                                                          "original": $0.originalText, "corrected": $0.correctedText ?? ""] }
        let basis: [String: Any] = ["version": "image-v1", "originalSHA256": image.sha256, "inputs": hashes,
                                  "note": image.note, "context": contextRecords, "configuration": configObject]
        let fingerprint = digest(try JSONSerialization.data(withJSONObject: basis, options: [.sortedKeys]))
        var request: [String: Any] = ["id": image.id.uuidString, "path": inputs[0].path,
            "sha256": hashes[0], "title": image.title, "note": image.note,
            "sourceSpanIDs": context.map { $0.id.uuidString }, "context": contextRecords, "fingerprint": fingerprint,
            "detailPaths": inputs.dropFirst().map(\.path), "detailSHA256": Array(hashes.dropFirst())]
        if let time = image.anchorTime { request["anchorTime"] = time }
        if let analysis = image.analysis { request["analysis"] = try JSONSerialization.jsonObject(with: encoder.encode(analysis)) }
        return request
    }
}
