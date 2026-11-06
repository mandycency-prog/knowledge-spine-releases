import Foundation
import CryptoKit
import ImageIO

/// A visual source is preserved independently of ASR and model commentary.
public struct ImageAnalysis: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var model: String
    public var extractedText: String
    public var explanation: String
    public var uncertainties: [String]

    public init(fingerprint: String, model: String, extractedText: String, explanation: String, uncertainties: [String] = []) {
        self.fingerprint = fingerprint; self.model = model; self.extractedText = extractedText
        self.explanation = explanation; self.uncertainties = uncertainties
    }
}

public struct ImageAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var relativePath: String
    public var sha256: String
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var createdAt: Date
    public var anchorTime: Double?
    public var anchorSpanID: UUID?
    public var attachedNodeID: UUID?
    public var note: String
    public var analysis: ImageAnalysis?
    public var analysisError: String?
    public var deletedAt: Date?
    /// Present only during portable exchange; normal databases store the image on disk.
    public var portableData: Data? = nil
    public var origin: SourceReference? = nil

    public init(id: UUID = UUID(), title: String, relativePath: String, sha256: String, mimeType: String,
                width: Int, height: Int, createdAt: Date = Date(), anchorTime: Double? = nil,
                anchorSpanID: UUID? = nil, attachedNodeID: UUID? = nil, note: String = "",
                analysis: ImageAnalysis? = nil, analysisError: String? = nil, deletedAt: Date? = nil, portableData: Data? = nil,
                origin: SourceReference? = nil) {
        self.id = id; self.title = title; self.relativePath = relativePath; self.sha256 = sha256
        self.mimeType = mimeType; self.width = width; self.height = height; self.createdAt = createdAt
        self.anchorTime = anchorTime; self.anchorSpanID = anchorSpanID; self.attachedNodeID = attachedNodeID
        self.note = note; self.analysis = analysis; self.analysisError = analysisError
        self.deletedAt = deletedAt; self.portableData = portableData
        self.origin = origin
    }
}

public enum ImageAttachmentValidation {
    public static let maximumImageBytes = 20 * 1024 * 1024
    public static let maximumImagesPerSession = 50
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func fileExtension(for mimeType: String) -> String? {
        switch mimeType { case "image/png": "png"; case "image/jpeg": "jpg"; case "image/webp": "webp"; default: nil }
    }
    public static func portablePath(id: UUID, mimeType: String) -> String? {
        fileExtension(for: mimeType).map { "Images/\(id.uuidString.lowercased()).\($0)" }
    }
    public static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.contains("\\") && !path.contains(":") && !path.contains("\0")
            && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("%") })
            && !path.hasPrefix("~")
    }
    public static func validate(_ image: ImageAttachment, requireData: Bool = false) throws {
        func invalid(_ reason: String) -> MindMapExchangeError { .invalid("图片资料无效：\(reason)") }
        guard isSafeRelativePath(image.relativePath), fileExtension(for: image.mimeType) != nil,
              image.sha256.count == 64, image.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              image.width > 0, image.height > 0, image.width <= 20_000, image.height <= 20_000,
              Int64(image.width) * Int64(image.height) <= 50_000_000,
              image.createdAt.timeIntervalSince1970.isFinite,
              image.deletedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              image.anchorTime.map({ $0.isFinite && $0 >= 0 && $0 <= 315_576_000 }) ?? true else {
            throw invalid("路径、格式、尺寸、校验值或时间不正确")
        }
        guard let data = image.portableData else {
            if requireData { throw invalid("导出缺少原图") }
            return
        }
        guard !data.isEmpty, data.count <= maximumImageBytes,
              digest(data) == image.sha256.lowercased(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              ["image/png": "public.png", "image/jpeg": "public.jpeg", "image/webp": "org.webmproject.webp"][image.mimeType] == type,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == image.width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == image.height else {
            throw invalid("原图已损坏，或与校验值、格式及尺寸不一致")
        }
        // Validate actual decoding at bounded preview size, not metadata alone.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 8,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil else {
            throw invalid("原图内容无法解码")
        }
    }
}
