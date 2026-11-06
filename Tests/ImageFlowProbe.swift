import AppKit
import CoreGraphics
import Foundation
import ImageIO
import KnowledgeSpineCore
import UniformTypeIdentifiers

/// Full application services, isolated storage, generated pixels and fake model.
/// No production bundle, permission prompts, Keychain, audio or remote requests.
@main
@MainActor
struct ImageFlowProbe {
    static var checks = 0

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ImageFileFailure.invalid("Image flow probe failed: \(message)") }
        checks += 1
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { checks += 1; return }
        throw ImageFileFailure.invalid("Image flow probe accepted invalid input: \(message)")
    }

    static func record(_ id: UUID, store: AppStore) throws -> SessionRecord {
        guard let value = store.database.sessions.first(where: { $0.id == id }) else {
            throw ImageFileFailure.invalid("Missing synthetic record")
        }
        return value
    }

    static func original(_ id: UUID, store: AppStore) throws -> ImageAttachment {
        guard let image = try record(id, store: store).images?.first else {
            throw ImageFileFailure.invalid("Missing synthetic image")
        }
        return image
    }

    static func generatedPNG(width: Int = 96, height: Int = 64) throws -> Data {
        let bytes = [UInt8](repeating: 180, count: width * height * 4)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ImageFileFailure.invalid("Cannot create synthetic pixels")
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageFileFailure.invalid("Cannot create synthetic PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageFileFailure.invalid("Synthetic PNG failed") }
        return buffer as Data
    }

    static func imageFiles(_ directory: URL) throws -> [String] {
        let path = directory.appendingPathComponent("Images", isDirectory: true)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: path.path).sorted()
    }

    static func waitUntilIdle(_ service: LocalProcessingService, id: UUID) async throws {
        for _ in 0..<1000 {
            if !service.isProcessing(id) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ImageFileFailure.invalid("Synthetic processing timed out")
    }

    static func main() async {
        do { try await run() }
        catch {
            print("FAIL image application flow:", error)
            exit(1)
        }
    }

    static func run() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("KnowledgeSpine-ImageFlow-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("Store", isDirectory: true)
        try manager.createDirectory(at: dataRoot, withIntermediateDirectories: false)
        var store = AppStore(storageRoot: dataRoot)
        try check(store.dataRoot == dataRoot && !store.isEphemeral, "explicit isolated durable store")
        let id = store.createSession(title: "合成图片流程", sourceName: "生成像素", sourceKind: "test")
        let png = try generatedPNG()
        let source = root.appendingPathComponent("source.png")
        try png.write(to: source)
        try store.importImages(urls: [source], sessionID: id)
        print("Image flow: original imported")
        let first = try original(id, store: store)
        try check(first.portableData == nil, "database keeps metadata rather than inline bytes")
        let localURL = store.imageURL(first, sessionID: id)!
        try check(localURL != source && Data(contentsOf: localURL) == png, "import copies original into record")
        try manager.removeItem(at: source)
        try check(Data(contentsOf: localURL) == png, "removing source screenshot preserves copied original")
        try check(store.flush(), "persist copied image")
        store = AppStore(storageRoot: dataRoot)
        let reopened = try original(id, store: store)
        try check(reopened.id == first.id && reopened.sha256 == first.sha256 && reopened.relativePath == first.relativePath
                  && reopened.mimeType == first.mimeType && reopened.width == first.width && reopened.height == first.height
                  && reopened.note == first.note && abs(reopened.createdAt.timeIntervalSince(first.createdAt)) < 1,
                  "restart preserves image metadata with existing ISO8601 second precision")
        try check(try ImageFiles.verifiedData(first, directory: store.sessionDirectory(id)) == png, "restart reads original")

        let good = root.appendingPathComponent("batch-good.png")
        let bad = root.appendingPathComponent("batch-bad.png")
        try png.write(to: good); try Data("not an image".utf8).write(to: bad)
        let beforeBatch = store.database
        let beforeFiles = try imageFiles(store.sessionDirectory(id))
        try rejects("invalid image") { try store.importImages(urls: [bad], sessionID: id) }
        try check(store.database == beforeBatch, "invalid image leaves database untouched")
        try rejects("mixed batch must be atomic") { try store.importImages(urls: [good, bad], sessionID: id) }
        try check(store.database == beforeBatch, "batch validation leaves no half database")
        try check(try imageFiles(store.sessionDirectory(id)) == beforeFiles, "batch validation leaves no half files")
        print("Image flow: persistence and invalid batch checked")

        store.removeImage(id: first.id, sessionID: id)
        try check(try original(id, store: store).deletedAt != nil, "soft delete records deletion")
        try check(manager.fileExists(atPath: localURL.path), "soft delete retains recoverable original")
        store.restoreImage(id: first.id, sessionID: id)
        try check(try original(id, store: store).deletedAt == nil, "restore makes original active")
        let synthetic = ImageAnalysisResult(id: first.id, fingerprint: "synthetic-flow-v1", model: "synthetic-vision",
            extractedText: "观察比较独有检索词", explanation: "图片展示观察、比较和检验三个步骤。", uncertainties: ["合成测试，不是课程资料。"])
        try check(store.applyImageAnalyses([synthetic], inputs: [try original(id, store: store)], sessionID: id), "apply visual result")
        let analyzed = try original(id, store: store)
        let unchanged = store.database
        store.updateImage(id: analyzed.id, sessionID: id, note: analyzed.note, anchorSpanID: analyzed.anchorSpanID, attachedNodeID: analyzed.attachedNodeID)
        try check(store.database == unchanged && original(id, store: store).analysis == synthetic.analysis, "same note is no-op and preserves analysis")
        store.updateImage(id: analyzed.id, sessionID: id, note: "  我的图片思考原样保留\n第二行  ", anchorSpanID: nil, attachedNodeID: nil)
        try check(try original(id, store: store).analysis == nil, "changed note invalidates analysis")
        try check(try original(id, store: store).note == "  我的图片思考原样保留\n第二行  ", "note content is verbatim")
        _ = store.applyImageAnalyses([synthetic], inputs: [analyzed], sessionID: id)
        try check(try original(id, store: store).analysis == nil, "result from stale note cannot restore obsolete analysis")

        var configuration = APIConfiguration(baseURL: "https://synthetic.invalid/v1", model: "synthetic-vision")
        store.imageAPIConfiguration = configuration
        configuration.approvedImageEndpoint = configuration.baseURL
        store.imageAPIConfiguration = configuration
        let processor = LocalProcessingService(runner: { _, _, _, _, _, label, checkpoint, _ in
            guard let saved = checkpoint, let image = saved.imageInputs?.first else {
                throw ImageFileFailure.invalid("Fake runner did not receive image input")
            }
            var result = LocalProcessingResult(speakers: saved.speakers, spans: saved.spans, candidates: [], warnings: [])
            result.imageAnalyses = [ImageAnalysisResult(id: image.id, fingerprint: "synthetic-flow-runner", model: "synthetic-vision",
                extractedText: "观察比较独有检索词", explanation: "图示要求观察、比较并检验结果。", uncertainties: [])]
            if !label.hasPrefix("images-") {
                result.candidates = [StructureCandidate(sourceSpanIDs: saved.spans.map(\.id), kind: .main, relation: .root,
                    confidence: 1, summary: "结合观察与比较检验结果", sourceImageIDs: [image.id])]
            }
            return result
        }, notifier: { _, _ in })
        processor.processImages(sessionID: id, store: store)
        try await waitUntilIdle(processor, id: id)
        try check(try original(id, store: store).analysis?.fingerprint == "synthetic-flow-runner", "fake runner visual result saved")
        try check(try record(id, store: store).transcript.isEmpty, "image analysis never creates ASR spans")
        processor.process(sessionID: id, audioPaths: [], store: store)
        try await waitUntilIdle(processor, id: id)
        let pure = try record(id, store: store)
        print("Image flow: fake model picture structure checked")
        try check(pure.structureSaved && !pure.nodes.isEmpty, "pure picture record completes structure")
        try check(pure.transcript.isEmpty && pure.nodes.contains { $0.sourceImageIDs == [first.id] && $0.sourceSpanIDs.isEmpty }, "pure image candidate keeps only visual source IDs")
        try check(pure.images?.first?.note == "  我的图片思考原样保留\n第二行  ", "processing preserves authored note")

        try check(store.prepareFocusedStudy("图片中的方法", sessionID: id), "prepare pure image focused question")
        let report = FocusedStudyReport(question: "图片中的方法", sections: [FocusedStudySection(heading: "图示步骤", explanation: "根据图示观察、比较和检验。", sourceSpanIDs: [], sourceImageIDs: [first.id])])
        try check(store.saveFocusedStudy(report, sessionID: id, baseline: [], imageBaseline: pure.images), "focused report accepts valid picture evidence")
        let invalid = FocusedStudyReport(question: "图片中的方法", sections: [FocusedStudySection(heading: "无效来源", explanation: "不应保存", sourceSpanIDs: [], sourceImageIDs: [UUID()])])
        try check(!store.saveFocusedStudy(invalid, sessionID: id, baseline: [], imageBaseline: pure.images), "focused report rejects foreign picture evidence")
        try check(try record(id, store: store).focusedStudyReports?.count == 1, "bad focus result preserves previous report")
        store.searchText = "独有检索词"
        let hit = store.searchHits.first { $0.kind == .image && $0.imageID == first.id }
        try check(hit != nil, "search finds extracted picture text")
        store.selectSearchHit(hit!)
        try check(store.selectedSessionID == id && store.selectedImageID == first.id, "search opens exact image source")

        let bundle = try PortableMindMap.exportData(sessions: store.preparePortableSessions([try record(id, store: store)]))
        let destination = root.appendingPathComponent("ImportStore", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        let importedStore = AppStore(storageRoot: destination)
        let decoded = try PortableMindMap.importData(bundle)
        let inserted = importedStore.addLibraryRecords(decoded, collectionID: nil)
        print("Image flow: portable original materialized")
        try check(inserted.count == 1, "portable picture bundle imported")
        let portableImage = try original(inserted[0], store: importedStore)
        try check(portableImage.portableData == nil && ImageFiles.verifiedData(portableImage, directory: importedStore.sessionDirectory(inserted[0])) == png, "portable bytes materialized into immutable local file")
        try check(try record(inserted[0], store: importedStore).focusedStudyReports?.first?.sections.first?.sourceImageIDs == [portableImage.id], "portable report image citation remapped")

        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try manager.createDirectory(at: exports, withIntermediateDirectories: false)
        let exportRecord = try record(id, store: store)
        let outputs = try ExportService.export(session: exportRecord, to: exports, options: ExportOptions(format: .both, includeTranscript: true), speakerName: { _ in "合成讲者" }, imageURL: { store.imageURL($0, sessionID: id) })
        let markdownURL = outputs.first { $0.pathExtension == "md" && $0.lastPathComponent.contains("知识骨架") }!
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let exportedImage = markdownURL.deletingLastPathComponent().appendingPathComponent("Images/\(first.id.uuidString).png")
        try check(markdown.contains("![图片原图](Images/") && markdown.contains("图片依据：") && Data(contentsOf: exportedImage) == png, "markdown includes copied image and source link")
        let pdfURL = outputs.first { $0.pathExtension == "pdf" }!
        print("Image flow: Markdown and PDF exported")
        guard let pdf = CGPDFDocument(pdfURL as CFURL) else { throw ImageFileFailure.invalid("Unreadable exported PDF") }
        try check(pdf.numberOfPages >= 2 && String(decoding: Data(contentsOf: pdfURL), as: UTF8.self).contains("/Subtype /Image"), "PDF includes actual image page")

        let mergedID = store.createMergedRecord(title: "合成图片合并", sourceSessionIDs: [id])!
        let mergedImage = try original(mergedID, store: store)
        let mergedURL = store.imageURL(mergedImage, sessionID: mergedID)!
        try check(mergedURL != localURL && Data(contentsOf: mergedURL) == png, "merge copies image into independent record")
        store.moveSessionToTrash(id)
        store.runRetentionAudit(now: Date().addingTimeInterval(31 * 86400))
        try check(store.flush(), "persist source deletion after retention")
        try check(!manager.fileExists(atPath: localURL.path) && Data(contentsOf: mergedURL) == png, "merge survives original course file deletion")

        let mixedID = store.createSession(title: "合成图文", sourceName: "合成", sourceKind: "test")
        _ = store.importTranscriptText("这里是真实合成原话。", sessionID: mixedID)
        let real = try record(mixedID, store: store).transcript
        print("Image flow: source deletion checked; preparing mixed material")
        try store.importImageData(png, title: "图文素材", sessionID: mixedID, anchorSpanID: real[0].id)
        processor.process(sessionID: mixedID, audioPaths: [], store: store, reuseTranscriptClassification: true)
        try await waitUntilIdle(processor, id: mixedID)
        let mixed = try record(mixedID, store: store)
        try check(mixed.transcript == real, "mixed processing leaves actual transcript unchanged")
        try check(mixed.nodes.contains { $0.sourceSpanIDs == real.map(\.id) && $0.sourceImageIDs?.count == 1 }, "mixed candidate has independent real and image source IDs")
        let picture = mixed.images!.first!
        let sources: [TranscriptSpan] = (0..<45).map { index in
            TranscriptSpan(sequence: index, startTime: Double(index), endTime: Double(index + 1), speakerID: real[0].speakerID, originalText: "合成上下文第\(index)条。")
        }
        var requestSession = mixed
        requestSession.transcript = sources
        requestSession.nodes = [KnowledgeNode(sourceSpanIDs: sources.map(\.id), kind: .main, relation: .root, position: CanvasPoint(x: 0, y: 0))]
        var requestImage = picture
        requestImage.anchorSpanID = nil; requestImage.anchorTime = nil; requestImage.attachedNodeID = requestSession.nodes[0].id
        let beforeRequest = try ImageFiles.request(requestImage, session: requestSession, configuration: configuration, directory: store.sessionDirectory(mixedID))
        requestSession.transcript[44].originalText = "超过四十条的末尾已经改变。"
        let afterRequest = try ImageFiles.request(requestImage, session: requestSession, configuration: configuration, directory: store.sessionDirectory(mixedID))
        try check((beforeRequest["sourceSpanIDs"] as? [String])?.count == 45, "request includes complete associated context")
        try check(beforeRequest["fingerprint"] as? String != afterRequest["fingerprint"] as? String, "cache fingerprint includes context after forty spans")
        let previews = try ImageFiles.modelInputs(picture, directory: store.sessionDirectory(mixedID))
        try Data("truncated preview".utf8).write(to: previews[0])
        let repaired = try ImageFiles.modelInputs(picture, directory: store.sessionDirectory(mixedID))
        let repairedSource = CGImageSourceCreateWithURL(repaired[0] as CFURL, nil)
        try check(repairedSource != nil && CGImageSourceGetStatus(repairedSource!) == .statusComplete, "corrupt disposable preview automatically rebuilt")
        try check(store.flush(), "final isolated state persisted")
        print("PASS image application flow: \(checks) checks (isolated storage, fake model, no Keychain/network)")
    }
}
