import Foundation
import KnowledgeSpineCore

/// Independent acceptance: synthetic records only; no UI, model, audio or formal data.
@main struct SoftwareAcceptanceProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var failures: [String] = []
    @MainActor static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message); print("FAIL: \(message)") }
    }

    static func fixture(_ label: String) -> SessionRecord {
        let host = Speaker(role: .host, displayName: "老师")
        let guest = Speaker(role: .guest, displayName: "老师") // Valid duplicate display names.
        let spans = (0..<3).map { index in
            TranscriptSpan(sequence: index + 1, startTime: Double(index * 30), endTime: Double(index * 30 + 10),
                           speakerID: index == 2 ? guest.id : host.id,
                           originalText: "\(label)课程第\(index + 1)段原文。", isImportant: index < 2)
        }
        let root = KnowledgeNode(sourceSpanIDs: [spans[0].id], kind: .main, relation: .root,
                                 position: CanvasPoint(x: 100, y: 100), coveredSourceSpanIDs: spans.map(\.id))
        let branch = KnowledgeNode(sourceSpanIDs: [spans[2].id], kind: .branch, parentID: root.id,
                                   relation: .child, position: CanvasPoint(x: 500, y: 300))
        let thought = UserThought(text: "我的\(label)思考：  空格保留。\n第二行不应改写。", attachedNodeID: root.id,
                                  isSecondaryEdit: true, anchorTime: 35)
        let mark = ImportantMark(anchorSpanID: spans[1].id, protectedSpanIDs: [spans[0].id, spans[1].id], anchorTime: 32)
        return SessionRecord(title: "相同课程标题", sourceName: label, sourceKind: "合成验收", status: .ready,
                             speakers: [host, guest], transcript: spans, nodes: [root, branch], thoughts: [thought],
                             transcriptComplete: true, structureSaved: true, importantMarks: [mark])
    }

    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    @MainActor static func inspectMerge(_ merged: SessionRecord, originals: [SessionRecord], label: String) {
        let spans = Dictionary(uniqueKeysWithValues: merged.transcript.map { ($0.id, $0) })
        let activeNodes = merged.nodes.filter { !$0.isDeleted }
        let nodeIDs = Set(activeNodes.map(\.id))
        check(spans.count == merged.transcript.count && nodeIDs.count == activeNodes.count, "\(label): unique IDs")
        check(merged.thoughts.count == originals.reduce(0) { $0 + $1.thoughts.count }, "\(label): thoughts preserved")
        check((merged.importantMarks ?? []).count == originals.reduce(0) { $0 + ($1.importantMarks ?? []).count }, "\(label): marks preserved")
        for span in merged.transcript {
            guard let origin = span.origin,
                  let original = originals.first(where: { $0.id == origin.sessionID }),
                  let old = original.transcript.first(where: { $0.id == origin.itemID }) else {
                check(false, "\(label): missing span origin"); continue
            }
            check(origin.startTime == old.startTime && span.originalText == old.originalText && span.correctedText == old.correctedText,
                  "\(label): origin time/raw/correction fidelity")
        }
        for node in activeNodes {
            check(node.parentID == nil || nodeIDs.contains(node.parentID!), "\(label): valid parent")
            check(Set(node.sourceSpanIDs + (node.coveredSourceSpanIDs ?? [])).isSubset(of: Set(spans.keys)), "\(label): valid sources")
            if let origin = node.origin {
                check(originals.contains { $0.id == origin.sessionID && $0.nodes.contains { $0.id == origin.itemID } }, "\(label): valid node origin")
            } else { check(false, "\(label): missing node origin") }
        }
        for original in originals {
            let copies = merged.transcript.filter { $0.origin?.sessionID == original.id }
            guard let first = copies.first, let originTime = first.origin?.startTime else { check(false, "\(label): missing source course"); continue }
            let offset = first.startTime - originTime
            for old in original.thoughts {
                guard let thought = merged.thoughts.first(where: { $0.text == old.text }) else { check(false, "\(label): missing exact thought"); continue }
                check(thought.id != old.id && thought.anchorTime == old.anchorTime.map { $0 + offset }, "\(label): thought identity/time")
                let node = activeNodes.first { $0.thoughtID == thought.id }
                check(node?.userEditedText == old.text && node?.parentID == thought.attachedNodeID, "\(label): thought node identity/raw/attachment")
                check(thought.attachedNodeID.map(nodeIDs.contains) == true, "\(label): attached thought remains connected")
            }
            for old in original.importantMarks ?? [] {
                let mark = (merged.importantMarks ?? []).first { spans[$0.anchorSpanID]?.origin?.itemID == old.anchorSpanID }
                check(mark != nil, "\(label): mark anchored to source")
                if let mark {
                    check(mark.id != old.id && mark.anchorTime == old.anchorTime.map { $0 + offset }, "\(label): mark identity/time")
                    check(Set(mark.protectedSpanIDs.compactMap { spans[$0]?.origin?.itemID }) == Set(old.protectedSpanIDs), "\(label): full protected context")
                    check(activeNodes.contains { $0.importantMarkID == mark.id }, "\(label): mark visible on map")
                }
            }
        }
        // A course may occur in only one continuous display block, regardless of source order.
        var finished: Set<UUID> = []; var last: UUID?
        for span in merged.transcript.sorted(by: { $0.startTime < $1.startTime }) {
            guard let id = span.origin?.sessionID else { continue }
            if id != last {
                check(!finished.contains(id), "\(label): manuscript courses must not interleave")
                if let last { finished.insert(last) }; last = id
            }
        }
    }

    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KnowledgeSpine-SoftwareAcceptance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        print("ISOLATED ROOT: \(root.path)")
        let store = AppStore(storageRoot: root)
        let inputs = [fixture("甲"), fixture("乙")]
        guard store.addLibraryRecords(inputs, collectionID: nil).count == 2 else { throw Failure(description: "Unable to seed isolated records") }
        let originals = store.database.sessions
        let originalIDs = Set(originals.map(\.id))
        let source = originals[0]
        let beforeEmpty = store.database
        check(store.importTranscriptText(" \n\t\r\n", sessionID: source.id) == nil, "empty import returns nil")
        check(store.database == beforeEmpty, "empty import is exact database no-op")
        guard let importedID = store.importTranscriptText("老师：新导入的一段。\n老师：新导入的另一段。", sessionID: source.id) else {
            throw Failure(description: "Nonempty import did not create record")
        }
        check(!originalIDs.contains(importedID), "import existing manuscript creates new record")
        check(originals.allSatisfy { old in store.database.sessions.first { $0.id == old.id } == old }, "import preserves all original content with duplicate speaker names")
        let importedSpans = store.database.sessions.first { $0.id == importedID }!.transcript
        for span in importedSpans {
            store.addSourceNode(spanID: span.id, kind: .main, parentID: nil, sessionID: importedID)
        }
        check(store.database.sessions.first { $0.id == importedID }?.nodes.filter { $0.parentID == nil }.count == importedSpans.count,
              "add as independent node never silently attaches to last node")

        guard let mergedID = store.createMergedRecord(title: "合并验收", sourceSessionIDs: originalIDs),
              let merged = store.database.sessions.first(where: { $0.id == mergedID }) else { throw Failure(description: "Whole-record merge failed") }
        inspectMerge(merged, originals: originals, label: "whole merge")
        let selection = Set(originals.compactMap { $0.nodes.first(where: { $0.kind == .main })?.id })
        guard let selectedID = store.createMergedRecord(title: "选节点验收", sourceNodeIDs: selection),
              let selected = store.database.sessions.first(where: { $0.id == selectedID }) else { throw Failure(description: "Node selection merge failed") }
        inspectMerge(selected, originals: originals, label: "selected merge")
        check(originals.allSatisfy { old in store.database.sessions.first { $0.id == old.id } == old }, "merges do not mutate source records")

        // A legitimate timestamp-only mark has no recognized source yet.
        // Combining must keep it without inventing a transcript reference.
        var timedSource = fixture("时间重点")
        let unresolvedMark = ImportantMark(anchorSpanID: UUID(), protectedSpanIDs: [], anchorTime: 95)
        timedSource.importantMarks = [unresolvedMark]
        let timedBefore = timedSource
        guard let timedMerge = KnowledgeRecordMerger.combine(title: "时间型重点合并", sources: [originals[0], timedSource]) else {
            throw Failure(description: "Timestamp-only mark merge failed")
        }
        let offset = timedMerge.transcript.first { $0.origin?.sessionID == timedSource.id }!.startTime
        let copiedUnresolved = (timedMerge.importantMarks ?? []).filter { $0.protectedSpanIDs.isEmpty }
        check(copiedUnresolved.count == 1, "timestamp-only mark is retained during merge")
        if let copied = copiedUnresolved.first {
            check(copied.anchorTime == 95 + offset && copied.id != unresolvedMark.id && copied.anchorSpanID != unresolvedMark.anchorSpanID,
                  "timestamp-only mark keeps time with fresh identities")
            check(!timedMerge.transcript.contains { $0.id == copied.anchorSpanID }, "timestamp-only mark does not fabricate evidence")
        }
        check(timedSource == timedBefore, "timestamp-only merge does not change original")
        guard let timedID = store.addLibraryRecords([timedMerge], collectionID: nil).first else {
            throw Failure(description: "Timestamp-only merge did not persist")
        }

        // The UI allows selecting separate files in one import operation.
        // References between them must target the new copies, not absent old IDs.
        let sourceFile = try PortableMindMap.exportData(sessions: [source])
        let mergedFile = try PortableMindMap.exportData(sessions: [merged])
        let exchanged = try PortableMindMap.importBatch([sourceFile, mergedFile], existingSessions: store.database.sessions)
        check(exchanged.count == 2, "batch exchange imports both separate files")
        if exchanged.count == 2 {
            let copiedSource = exchanged[0], copiedMap = exchanged[1]
            let internalSpans = copiedMap.transcript.filter { $0.origin?.sessionID == copiedSource.id }
            check(internalSpans.count == source.transcript.count, "cross-file span origins point to new source record")
            for span in internalSpans {
                check(copiedSource.transcript.contains { $0.id == span.origin?.itemID && $0.originalText == span.originalText },
                      "cross-file span origin points to corresponding original text")
            }
            for node in copiedMap.nodes where node.origin?.sessionID == copiedSource.id {
                check(copiedSource.nodes.contains { $0.id == node.origin?.itemID }, "cross-file node origin resolves")
            }
            check(!copiedMap.transcript.contains { $0.origin?.sessionID == source.id }, "no obsolete internal session origin")
            check(copiedMap.transcript.contains { $0.origin?.sessionID == originals[1].id }, "truly external origins stay truthful")
            check(store.addLibraryRecords(exchanged, collectionID: nil).count == 2, "batch exchange commits all new records")
        }
        do {
            _ = try PortableMindMap.importBatch([sourceFile, sourceFile], existingSessions: store.database.sessions)
            check(false, "duplicate source file IDs must not be silently remapped inconsistently")
        } catch { /* Expected atomic rejection. */ }
        do {
            _ = try PortableMindMap.importBatch([sourceFile, Data("broken".utf8)], existingSessions: store.database.sessions)
            check(false, "invalid later file must reject entire import batch")
        } catch { /* Expected atomic rejection. */ }

        let label = "独立人工检索词丙丁"
        let renamedID = merged.nodes.first { $0.kind == .main }!.id
        store.renameNode(renamedID, label: label, sessionID: mergedID)
        store.searchText = label
        check(store.searchHits.contains { $0.sessionID == mergedID && $0.nodeID == renamedID }, "human label is searchable")
        if let ref = merged.transcript.first?.origin {
            store.openOrigin(ref)
            check(store.selectedSessionID == ref.sessionID && store.selectedTranscriptSpanID == ref.itemID, "origin opens exact source span")
        }

        guard let collectionID = store.createCollection(named: "课程主题"),
              let retainedCollection = store.createCollection(named: "长期主题") else { throw Failure(description: "Collection creation failed") }
        for id in [source.id, mergedID] { store.setCollectionMembership(sessionID: id, collectionID: collectionID, included: true) }
        store.setCollectionMembership(sessionID: source.id, collectionID: collectionID, included: true)
        check(store.collections.first { $0.id == collectionID }?.sessionIDs.count == 2, "membership is idempotent")
        store.selectedCollectionID = collectionID
        check(Set(store.librarySessions.map(\.id)) == Set([source.id, mergedID]), "theme lists exact members")
        store.setCollectionMembership(sessionID: mergedID, collectionID: retainedCollection, included: true)
        let beforeRemoval = store.database.sessions
        store.removeCollection(collectionID)
        check(store.database.sessions == beforeRemoval, "deleting theme never deletes or edits records")
        check(!store.collections.contains { $0.id == collectionID }, "theme deleted")

        let exportRoot = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: false)
        let options = ExportOptions(format: .both, includeTranscript: true)
        let firstURLs = try ExportService.export(session: originals[0], to: exportRoot, options: options,
                                                 speakerName: { store.speakerName($0, in: originals[0]) })
        let firstBytes = try firstURLs.map { try Data(contentsOf: $0) }
        let secondURLs = try ExportService.export(session: originals[1], to: exportRoot, options: options,
                                                  speakerName: { store.speakerName($0, in: originals[1]) })
        check(firstURLs.count == 3 && secondURLs.count == 3, "both formats plus transcript exported")
        check(Set(firstURLs).isDisjoint(with: secondURLs), "same-title export has no path collision")
        for (url, bytes) in zip(firstURLs, firstBytes) { check(try Data(contentsOf: url) == bytes, "earlier export unchanged: \(url.lastPathComponent)") }
        let renamed = store.database.sessions.first { $0.id == mergedID }!
        let mapText = ExportService.makeKnowledgeMarkdown(session: renamed, speakerName: { store.speakerName($0, in: renamed) })
        let manuscript = ExportService.makeTranscript(session: renamed, speakerName: { store.speakerName($0, in: renamed) })
        check(mapText.contains(label), "export preserves human node label")
        for thought in originals.flatMap(\.thoughts) {
            check(manuscript.contains(thought.text), "manuscript export preserves exact multiline thought")
            check(mapText.contains(thought.text), "map export preserves exact multiline thought")
        }
        check(manuscript.contains("重点"), "manuscript export marks important context")
        check(store.flush(), "flush succeeds")
        let expected = try canonical(store.database)
        let reopened = AppStore(storageRoot: root)
        check(try canonical(reopened.database) == expected, "restart preserves entire database including provenance/annotations/themes")
        reopened.searchText = label
        check(reopened.searchHits.contains { $0.nodeID == renamedID }, "label search persists after restart")
        check(reopened.collections.first { $0.id == retainedCollection }?.sessionIDs == [mergedID], "retained theme membership survives restart")
        check(reopened.database.sessions.first { $0.id == timedID }?.importantMarks?.contains { $0.anchorTime == 95 + offset && $0.protectedSpanIDs.isEmpty } == true,
              "timestamp-only mark survives restart")
        if !failures.isEmpty { throw Failure(description: "Software acceptance failed: \(failures.count) assertions; isolated evidence retained at \(root.path)") }
        print("PASS: isolated merge provenance/annotations, safe import, duplicate names, search, non-overwriting exports, collections and restart")
    }
}
