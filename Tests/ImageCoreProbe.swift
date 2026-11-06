import Foundation

@main
@MainActor
struct ImageCoreProbe {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw MindMapExchangeError.invalid("Image probe failed: \(message)") }; checks += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw MindMapExchangeError.invalid("Image probe accepted invalid input: \(message)")
    }
    static func image() -> ImageAttachment {
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1cAAAAASUVORK5CYII=")!
        return ImageAttachment(title: "合成课件", relativePath: "Session/Images/source.png", sha256: ImageAttachmentValidation.digest(bytes),
                               mimeType: "image/png", width: 1, height: 1, note: "用户原样批注", portableData: bytes)
    }
    static func payload(_ data: Data, mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        mutate(&object); return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func main() throws {
        let speaker = Speaker(role: .host)
        let span = TranscriptSpan(sequence: 1, startTime: 3, endTime: 7, speakerID: speaker.id, originalText: "请看图片里的三个步骤。")
        var picture = image()
        let node = KnowledgeNode(sourceSpanIDs: [], kind: .main, relation: .root, position: CanvasPoint(x: 1, y: 2),
                                 aiSummary: "来自课件的方法", sourceImageIDs: [picture.id])
        picture.anchorSpanID = span.id; picture.anchorTime = 5; picture.attachedNodeID = node.id
        picture.analysis = ImageAnalysis(fingerprint: "test-fingerprint", model: "synthetic-vision", extractedText: "观察、比较、检验", explanation: "合成方法图", uncertainties: ["小字不清"])
        try ImageAttachmentValidation.validate(picture, requireData: true)
        checks += 1
        let candidate = StructureCandidate(nodeID: node.id, sourceSpanIDs: [], kind: .main, relation: .root, confidence: 0.9,
                                           summary: node.aiSummary, sourceImageIDs: [picture.id])
        try IntegrityValidator.validate(candidates: [candidate], transcript: [], images: [picture]); checks += 1
        try IntegrityValidator.validateStoredNode(node, transcript: [], images: [picture]); checks += 1
        try rejects("image source absent") { try IntegrityValidator.validate(candidates: [candidate], transcript: []) }
        var mixed = candidate; mixed.sourceSpanIDs = [UUID()]
        try rejects("real image cannot launder fake transcript") { try IntegrityValidator.validate(candidates: [mixed], transcript: [], images: [picture]) }
        var background = span; background.isBackgroundAudio = true
        var mixedNode = node; mixedNode.sourceSpanIDs = [span.id]
        try check(IntegrityValidator.presentationNodes([mixedNode], transcript: [background]).count == 1, "visual evidence remains visible with filtered audio")
        try check(IntegrityValidator.presentationNodes([node], transcript: [], images: [picture], overviewOnly: true).count == 1, "pure image model node stays visible in overview")
        var edited = node; edited.isSecondaryEdit = true; edited.manualRevisionAt = Date(); edited.userEditedText = "人工原话"
        var other = edited; other.id = UUID(); other.sourceImageIDs = [UUID()]
        try check(StructureVersionMerge.signature(other) != StructureVersionMerge.signature(edited), "different images have different node signatures")
        var session = SessionRecord(title: "合成图片课程", sourceName: "合成输入", sourceKind: "测试", status: .ready,
                                    speakers: [speaker], transcript: [span], nodes: [node], transcriptComplete: true,
                                    structureSaved: true, images: [picture])
        session.versions = [StructureSnapshot(reason: "图片来源快照", nodes: [node], thoughts: [], transcript: [span], speakers: [speaker], images: [picture])]
        session.focusedStudyReports = [FocusedStudyReport(question: "图中的方法？", sections: [FocusedStudySection(heading: "步骤", explanation: "合成图示说明", sourceSpanIDs: [], sourceImageIDs: [picture.id])])]
        let encoded = try PortableMindMap.exportData(sessions: [session])
        let encodedText = String(decoding: encoded, as: UTF8.self)
        try check(!encodedText.contains("Session/Images/source.png"), "local image paths replaced")
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        try check((json["imageData"] as? [String: Any])?.count == 1, "bytes deduplicated across current and historical versions")
        let imported = try PortableMindMap.importData(encoded, existingSessions: [session])[0]
        let importedImage = imported.images![0]
        try check(importedImage.id != picture.id && importedImage.portableData == picture.portableData, "original image retained with new identity")
        try check(importedImage.anchorSpanID == imported.transcript[0].id && importedImage.attachedNodeID == imported.nodes[0].id, "picture context remapped")
        try check(imported.nodes[0].sourceImageIDs == [importedImage.id], "pure visual node points to imported original")
        try check(imported.versions[0].images![0].id == importedImage.id && imported.versions[0].nodes[0].sourceImageIDs == [importedImage.id], "snapshot image identity preserved")
        try check(importedImage.note == picture.note && importedImage.analysis == picture.analysis, "notes and analysis preserved exactly")
        try check(imported.focusedStudyReports![0].sections[0].sourceImageIDs == [importedImage.id], "focused study visual citations remapped")
        try check(importedImage.relativePath == ImageAttachmentValidation.portablePath(id: importedImage.id, mimeType: importedImage.mimeType), "safe destination relative path regenerated")
        var missingBytes = session; missingBytes.images![0].portableData = nil
        missingBytes.versions = []
        try rejects("missing portable original") { _ = try PortableMindMap.exportData(sessions: [missingBytes]) }
        var broken = picture; broken.sha256 = String(repeating: "0", count: 64)
        try rejects("checksum tampering") { try ImageAttachmentValidation.validate(broken, requireData: true) }
        broken = picture; broken.width = 100
        try rejects("dimension mismatch") { try ImageAttachmentValidation.validate(broken, requireData: true) }
        broken = picture; broken.mimeType = "image/jpeg"
        try rejects("mime mismatch") { try ImageAttachmentValidation.validate(broken, requireData: true) }
        broken = picture; broken.relativePath = "../../outside.png"
        try rejects("path traversal") { try ImageAttachmentValidation.validate(broken, requireData: true) }
        broken = picture; broken.portableData = Data(repeating: 0, count: ImageAttachmentValidation.maximumImageBytes + 1)
        broken.sha256 = ImageAttachmentValidation.digest(broken.portableData!)
        try rejects("oversized original") { try ImageAttachmentValidation.validate(broken, requireData: true) }
        let pathTamper = try payload(encoded) { object in
            var sessions = object["sessions"] as! [[String: Any]]; var pictures = sessions[0]["images"] as! [[String: Any]]
            pictures[0]["relativePath"] = "../../escape.png"; sessions[0]["images"] = pictures; object["sessions"] = sessions
        }
        try rejects("import path traversal") { _ = try PortableMindMap.importData(pathTamper) }
        let unknownImage = try payload(encoded) { object in
            var sessions = object["sessions"] as! [[String: Any]]; var nodes = sessions[0]["nodes"] as! [[String: Any]]
            nodes[0]["sourceImageIDs"] = [UUID().uuidString]; sessions[0]["nodes"] = nodes; object["sessions"] = sessions
        }
        try rejects("unknown portable visual source") { _ = try PortableMindMap.importData(unknownImage) }
        let orphanData = try payload(encoded) { object in
            var bytes = object["imageData"] as! [String: Any]; bytes["unreferenced"] = Data([1, 2]).base64EncodedString(); object["imageData"] = bytes
        }
        try rejects("unreferenced blob") { _ = try PortableMindMap.importData(orphanData) }
        var crowded = session
        crowded.images = (0...ImageAttachmentValidation.maximumImagesPerSession).map { _ in var value = image(); value.id = UUID(); return value }
        crowded.nodes = []; crowded.versions = []; crowded.focusedStudyReports = nil
        try rejects("too many original images") { _ = try PortableMindMap.exportData(sessions: [crowded]) }
        let emptySession = SessionRecord(title: "旧文字记录", sourceName: "测试", sourceKind: "测试")
        let old = try payload(PortableMindMap.exportData(sessions: [emptySession])) { $0["version"] = 1; $0.removeValue(forKey: "imageData") }
        let legacyImported = try PortableMindMap.importData(old)
        try check(legacyImported[0].images == nil, "version-one text package still readable")
        let legacy = Data("{\"baseURL\":\"\",\"model\":\"\",\"contextWindow\":32768,\"maxOutputTokens\":4096,\"tokenLimitField\":\"max_tokens\",\"jsonMode\":true}".utf8)
        let config = try JSONDecoder().decode(APIConfiguration.self, from: legacy)
        try check(config.approvedImageEndpoint == nil && !config.isImageApproved, "legacy API config does not silently authorize images")
        let merged = KnowledgeRecordMerger.combine(title: "图片综合", sources: [session], selectedNodeIDs: [node.id])!
        try check(merged.images?.count == 1 && merged.transcript.count == 1, "node selection carries original image and contextual passage")
        try check(merged.images![0].anchorSpanID == merged.transcript[0].id && merged.images![0].attachedNodeID == merged.nodes[0].id, "combined image relations remapped")
        try check(merged.nodes[0].sourceImageIDs == [merged.images![0].id] && merged.images![0].origin?.itemID == picture.id, "combined node and image provenance retained")
        let batch = try PortableMindMap.importData(PortableMindMap.exportData(sessions: [session, merged]))
        try check(batch[1].images![0].origin?.sessionID == batch[0].id && batch[1].images![0].origin?.itemID == batch[0].images![0].id, "cross-record image origin remapped together")
        try check(session.images![0] == picture && node.sourceSpanIDs.isEmpty, "existing data and ASR remain unchanged")
        print("PASS image core: \(checks) checks")
    }
}
