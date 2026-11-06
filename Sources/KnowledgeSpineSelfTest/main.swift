import Foundation
import KnowledgeSpineCore

enum SelfTestFailure: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SelfTestFailure.failed(message) }
}

let speaker = Speaker(role: .host)
let span = TranscriptSpan(
    sequence: 1,
    startTime: 0,
    endTime: 3,
    speakerID: speaker.id,
    originalText: "真正困难的不是开始，而是一直知道下一步做什么。",
    correctedText: "这是人工修正，但不能替换骨架原话。"
)
let sourceNode = KnowledgeNode(
    sourceSpanIDs: [span.id],
    kind: .main,
    relation: .root,
    position: CanvasPoint(x: 0, y: 0)
)

let expandableDetail = KnowledgeNode(sourceSpanIDs: [span.id], kind: .evidence, parentID: sourceNode.id,
                                    relation: .child, position: CanvasPoint(x: 1, y: 1))
let retainedThought = KnowledgeNode(sourceSpanIDs: [], kind: .thought, parentID: expandableDetail.id,
                                   relation: .userThought, position: CanvasPoint(x: 2, y: 2), userEditedText: "我的原文思考")
let overview = IntegrityValidator.presentationNodes([sourceNode, expandableDetail, retainedThought], transcript: [span], overviewOnly: true)
try require(overview.count == 2, "主线模式没有收起自动细节")
try require(overview.first(where: { $0.id == retainedThought.id })?.parentID == sourceNode.id,
            "收起细节导致用户思考失联")
try require(IntegrityValidator.presentationNodes([sourceNode, expandableDetail, retainedThought], transcript: [span]).count == 3,
            "完整模式丢失了可展开细节")
let compactOverview = CanvasOverviewLayout.arrange(overview)
try require(compactOverview[0].position.y == compactOverview[1].position.y,
            "隐藏细节后父节点仍占用不可见节点的空行")
var positionedThought = retainedThought
positionedThought.manualRevisionAt = Date()
positionedThought.positionEditedAt = Date()
positionedThought.position = CanvasPoint(x: 670, y: 270)
let customOverview = CanvasOverviewLayout.arrange([sourceNode, positionedThought])
try require(customOverview[1].position == positionedThought.position, "主线自动排列覆盖了人工拖动")
try require(sourceNode.position == CanvasPoint(x: 0, y: 0), "显示层排列改写了原始布局")
var legacyPositionObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(positionedThought)) as! [String: Any]
legacyPositionObject.removeValue(forKey: "positionEditedAt")
legacyPositionObject.removeValue(forKey: "positionIsAutomatic")
let legacyThought = try JSONDecoder().decode(KnowledgeNode.self, from: JSONSerialization.data(withJSONObject: legacyPositionObject))
try require(CanvasOverviewLayout.arrange([legacyThought])[0].position == legacyThought.position,
            "旧数据库人工思考的位置被主线排列覆盖")
var freshThought = retainedThought
freshThought.manualRevisionAt = Date()
freshThought.position = CanvasPoint(x: 900, y: 900)
try require(CanvasOverviewLayout.arrange([freshThought])[0].position.y == 150,
            "新思考的创建标记被误当成用户拖动")
var blockingManual = positionedThought
blockingManual.position = .init(x: 550, y: 150)
blockingManual.parentID = sourceNode.id
let avoided = CanvasOverviewLayout.arrange([sourceNode, expandableDetail, blockingManual])
try require(avoided.first { $0.id == blockingManual.id }?.position == blockingManual.position, "避让移动了人工节点")
for first in avoided.indices {
    for second in avoided.indices where second > first {
        let a = avoided[first].position, b = avoided[second].position
        try require(abs(a.x - b.x) >= 320 || abs(a.y - b.y) >= 220, "自动布局覆盖了人工节点")
    }
}
try require(CanvasOverviewLayout.arrange([sourceNode, expandableDetail, blockingManual]).map(\.position) == avoided.map(\.position),
            "同一布局重复计算发生漂移")
var handPositioned = sourceNode
handPositioned.aiSummary = "保留这个具体方法"
handPositioned.manualRevisionAt = Date()
handPositioned.position = CanvasPoint(x: 800, y: 600)
let newRoot = KnowledgeNode(sourceSpanIDs: [span.id], kind: .main, relation: .root, position: .init(x: 100, y: 100), aiSummary: "整场新的中心主题")
let sameIdea = KnowledgeNode(sourceSpanIDs: [span.id], kind: .branch, parentID: newRoot.id, relation: .child,
                             position: .init(x: 300, y: 100), aiSummary: "保留这个具体方法")
let anotherIdea = KnowledgeNode(sourceSpanIDs: [span.id], kind: .branch, parentID: newRoot.id, relation: .child,
                                position: .init(x: 300, y: 300), aiSummary: "同一原话里的另一个有效观点")
var connectedThought = retainedThought
connectedThought.parentID = handPositioned.id
let mergedVersions = StructureVersionMerge.merge(current: [handPositioned, connectedThought], candidate: [newRoot, sameIdea, anotherIdea])
try require(mergedVersions.count == 4, "人工保护错误删除同一来源的其他观点")
try require(mergedVersions.contains { $0.id == newRoot.id } && mergedVersions.contains { $0.id == anotherIdea.id }, "合并丢失中心或其他观点")
try require(mergedVersions.first { $0.id == handPositioned.id }?.position == handPositioned.position, "合并覆盖手动位置")
try require(mergedVersions.first { $0.id == connectedThought.id }?.parentID == handPositioned.id, "合并导致思考失联")
try require(mergedVersions.first { $0.id == handPositioned.id }?.parentID == newRoot.id, "旧根匹配为新分支后仍留下第二个根")
try require(mergedVersions.first { $0.id == handPositioned.id }?.relation == .child, "迁入分支后仍保留根关系标记")
var sameIDChangedText = handPositioned
sameIDChangedText.aiSummary = "不能覆盖人工内容"
sameIDChangedText.manualRevisionAt = nil
sameIDChangedText.position = .init(x: 0, y: 0)
for proposed in [[sameIDChangedText], [sameIDChangedText, sameIdea]] {
    let merged = StructureVersionMerge.merge(current: [handPositioned], candidate: proposed)
    try require(Set(merged.map(\.id)).count == merged.count, "身份和内容匹配冲突产生重复ID")
    try require(merged.first { $0.id == handPositioned.id }?.aiSummary == handPositioned.aiSummary, "同ID候选覆盖人工内容")
    try require(merged.first { $0.id == handPositioned.id }?.position == handPositioned.position, "同ID候选覆盖人工位置")
}
let firstSameTextThought = KnowledgeNode(sourceSpanIDs: [], kind: .thought, parentID: newRoot.id, relation: .userThought,
    position: .init(x: 500, y: 700), userEditedText: "再次想到同一件事", thoughtID: UUID())
let secondSameTextThought = KnowledgeNode(sourceSpanIDs: [], kind: .thought, parentID: anotherIdea.id, relation: .userThought,
    position: .init(x: 900, y: 900), userEditedText: "再次想到同一件事", thoughtID: UUID())
let repeatedThoughts = StructureVersionMerge.merge(current: [firstSameTextThought, secondSameTextThought], candidate: [newRoot, anotherIdea])
for original in [firstSameTextThought, secondSameTextThought] {
    let saved = repeatedThoughts.first { $0.id == original.id }
    try require(saved?.thoughtID == original.thoughtID && saved?.position == original.position && saved?.parentID == original.parentID,
                "同文不同身份的思考丢失身份、位置或挂接")
}

try require(
    IntegrityValidator.visibleText(for: sourceNode, transcript: [span]) == span.originalText,
    "来源节点没有逐字回读原文"
)
try IntegrityValidator.validateStoredNode(sourceNode, transcript: [span])

let summarizedNode = KnowledgeNode(
    sourceSpanIDs: [span.id],
    kind: .main,
    relation: .root,
    position: CanvasPoint(x: 0, y: 0),
    aiSummary: "持续行动需要始终知道下一步"
)
try require(
    IntegrityValidator.visibleText(for: summarizedNode, transcript: [span]) == "持续行动需要始终知道下一步",
    "AI 概括没有显示在思维导图节点"
)
try require(
    IntegrityValidator.originalSourceText(for: summarizedNode, transcript: [span]) == span.originalText,
    "AI 概括节点丢失了可回查的主播原话"
)
try IntegrityValidator.validateStoredNode(summarizedNode, transcript: [span])

let traditionalSpan = TranscriptSpan(
    sequence: 2,
    startTime: 3,
    endTime: 6,
    speakerID: speaker.id,
    originalText: "我還挺好奇的，這個具體怎麼才能做得到。",
    isBackgroundAudio: true
)
try require(
    traditionalSpan.simplifiedOriginalText == "我还挺好奇的，这个具体怎么才能做得到。",
    "繁体识别文字没有转换为简体显示"
)
try require(traditionalSpan.isFilteredBackground, "背景声音标记没有生效")
var punctuatedSpan = TranscriptSpan(sequence: 3, startTime: 6, endTime: 9, speakerID: speaker.id,
                                   originalText: "原話數字123", punctuatedText: "原話數字123。")
try require(punctuatedSpan.displayedText == "原话数字123。", "停顿标点没有显示")
try require(punctuatedSpan.originalText == "原話數字123", "停顿标点改动原始识别")
punctuatedSpan.punctuatedText = "改写数字456。"
try require(punctuatedSpan.displayedText == "原话数字123", "展示标点通道允许改写原话")
punctuatedSpan.punctuatedText = "原話數字123补写。"
try require(punctuatedSpan.displayedText == "原话数字123", "展示标点通道允许增加文字")
punctuatedSpan.correctedText = "用户明确修正"
try require(punctuatedSpan.displayedText == "用户明确修正", "标点覆盖了人工修正")
var oldSpanObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(punctuatedSpan)) as! [String: Any]
oldSpanObject.removeValue(forKey: "punctuatedText")
let oldPunctuationSpan = try JSONDecoder().decode(TranscriptSpan.self, from: JSONSerialization.data(withJSONObject: oldSpanObject))
try require(oldPunctuationSpan.punctuatedText == nil, "旧片段无法兼容新增标点字段")
let allExportFields = "標題｜人工修正｜二次編輯｜我的思考｜說話人｜來源"
try require(
    allExportFields.simplifiedChineseForDisplay == "标题｜人工修正｜二次编辑｜我的思考｜说话人｜来源",
    "标题、人工修正、二次编辑、思考或说话人没有统一转换为简体显示"
)

let thought = UserThought(text: "这句必须原封不动。", isSecondaryEdit: false, anchorTime: 42)
let thoughtNode = KnowledgeNode(
    sourceSpanIDs: [],
    kind: .thought,
    relation: .userThought,
    position: CanvasPoint(x: 0, y: 0),
    userEditedText: thought.text,
    thoughtID: thought.id
)
try require(
    IntegrityValidator.visibleText(for: thoughtNode, transcript: [span]) == thought.text,
    "我的思考没有原封不动地显示在导图节点"
)
try IntegrityValidator.validateStoredNode(thoughtNode, transcript: [span])
try require(thought.anchorTime == 42, "我的思考没有保留当时的逐字稿位置")
var backgroundSpan = span
backgroundSpan.isBackgroundAudio = true
backgroundSpan.correctedText = nil // unedited automatic background, not a user correction
var backgroundNode = sourceNode
backgroundNode.parentID = nil
let filteredPresentation = IntegrityValidator.presentationNodes([backgroundNode, thoughtNode], transcript: [backgroundSpan])
try require(filteredPresentation.map(\.id) == [thoughtNode.id], "旧导图背景节点仍显示或用户思考被误隐藏")
backgroundNode.importantMarkID = UUID()
try require(IntegrityValidator.presentationNodes([backgroundNode], transcript: [backgroundSpan]).count == 1, "用户重点被背景过滤隐藏")

let formalSupportRoot = URL(fileURLWithPath: "/formal/Application Support", isDirectory: true)
let disposableRoot = URL(fileURLWithPath: "/tmp/knowledge-spine-tests", isDirectory: true)
let demoStorage = AppDataStoragePlan(
    requestedInMemory: false,
    seedDemo: true,
    applicationSupportRoot: formalSupportRoot,
    temporaryRoot: disposableRoot,
    processIdentifier: 42
)
try require(demoStorage.inMemory, "演示模式没有强制启用内存存储")
try require(
    !demoStorage.dataRoot.path.hasPrefix(formalSupportRoot.path),
    "演示模式仍可能写入正式数据库目录"
)
let formalStorage = AppDataStoragePlan(
    requestedInMemory: false,
    seedDemo: false,
    applicationSupportRoot: formalSupportRoot,
    temporaryRoot: disposableRoot,
    processIdentifier: 42
)
try require(!formalStorage.inMemory, "正式模式不应被改成内存存储")
try require(
    formalStorage.dataRoot == formalSupportRoot.appendingPathComponent("直播与课程知识骨架", isDirectory: true),
    "正式模式数据库目录发生变化"
)

let illegalNode = KnowledgeNode(
    sourceSpanIDs: [span.id],
    kind: .main,
    relation: .root,
    position: CanvasPoint(x: 0, y: 0),
    userEditedText: "AI 总结",
    isSecondaryEdit: false
)
do {
    try IntegrityValidator.validateStoredNode(illegalNode, transcript: [span])
    throw SelfTestFailure.failed("含自由文字的模型节点没有被拒绝")
} catch IntegrityViolation.generatedSemanticText {
    // Expected.
}

let incomplete = SessionRecord(
    title: "测试",
    sourceName: "微信",
    sourceKind: "应用",
    transcriptComplete: true,
    structureSaved: false,
    filesComplete: true
)
try require(
    !IntegrityValidator.canPermanentlyDeleteAudio(from: incomplete),
    "处理不完整时不应允许永久删除音频"
)

let candidate = StructureCandidate(
    sourceSpanIDs: [span.id],
    kind: .main,
    relation: .root,
    confidence: 0.91,
    summary: "持续行动需要始终知道下一步"
)
try IntegrityValidator.validate(candidates: [candidate], transcript: [span])

let configured = AppDatabase(
    sessions: [incomplete],
    settings: AppSettings(
        pythonPath: "/local/python",
        whisperModelPath: "/local/whisper.pt",
        structureModelPath: "/local/deepseek.gguf",
        ffmpegPath: "/local/ffmpeg"
    )
)
let encoded = try JSONEncoder().encode(configured)
let decoded = try JSONDecoder().decode(AppDatabase.self, from: encoded)
try require(decoded.settings?.whisperModelPath == "/local/whisper.pt", "模型设置没有持久化")

var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
legacyObject.removeValue(forKey: "settings")
let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
let legacyDecoded = try JSONDecoder().decode(AppDatabase.self, from: legacyData)
try require(legacyDecoded.sessions.count == 1, "旧数据库不能向后兼容读取")

// Isolated on disk: stale writers must fail, and the previous committed bytes
// must remain recoverable after replacement.
let storageTestDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-spine-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: storageTestDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: storageTestDirectory) }
let storageTestURL = storageTestDirectory.appendingPathComponent("database.json")
let firstWriter = try ProtectedDatabaseFile(url: storageTestURL)
try firstWriter.save(encoded)
let staleWriter = try ProtectedDatabaseFile(url: storageTestURL)
let nextData = try JSONEncoder().encode(AppDatabase(sessions: []))
try firstWriter.save(nextData)
do {
    try staleWriter.save(encoded)
    fatalError("旧实例覆盖了新数据库")
} catch ProtectedDatabaseFile.Failure.conflict { }
let afterConflict = try Data(contentsOf: storageTestURL)
try require(afterConflict == nextData, "冲突写入损坏数据库")
let backupURLs = try FileManager.default.contentsOfDirectory(at: storageTestDirectory.appendingPathComponent("DatabaseBackups"), includingPropertiesForKeys: nil)
try require(backupURLs.count == 1, "缺少自动备份")
let restored = try JSONDecoder().decode(AppDatabase.self, from: Data(contentsOf: backupURLs[0]))
try require(restored.sessions.count == configured.sessions.count, "备份不可恢复")
print("PASS: 独立目录数据库自动备份、恢复读取和旧实例冲突保护")
let damagedBytes = Data("{broken".utf8)
try damagedBytes.write(to: storageTestURL, options: .atomic)
let recoveringWriter = try ProtectedDatabaseFile(url: storageTestURL)
let recoveredBytes = try recoveringWriter.recoverIfNeeded {
    (try? JSONDecoder().decode(AppDatabase.self, from: $0)) != nil
}
try require(recoveredBytes == encoded, "没有自动恢复最近有效备份")
let afterRecovery = try Data(contentsOf: storageTestURL)
try require(afterRecovery == encoded, "自动恢复未落盘")
let quarantined = try FileManager.default.contentsOfDirectory(at: storageTestDirectory, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent.hasPrefix("database-unreadable-") }
try require(quarantined.count == 1, "没有保留损坏原文件")
let damagedOriginal = try Data(contentsOf: quarantined[0])
try require(damagedOriginal == damagedBytes, "损坏原文件被改动")
print("PASS: 损坏数据库自动恢复且原文件单独保留")
for zoom in [0.1, 0.5, 0.82, 1.0, 1.5] {
    let origin = CanvasPoint(x: 1000, y: 1000)
    var point = origin
    for _ in 0..<1000 {
        point = CanvasDragGeometry.position(origin: point, dx: 70, dy: 30, zoom: zoom)
        point = CanvasDragGeometry.position(origin: point, dx: -70, dy: -30, zoom: zoom)
    }
    try require(abs(point.x - origin.x) < 0.000001 && abs(point.y - origin.y) < 0.000001, "缩放拖动累积漂移")
}
print("PASS: 五种缩放各1000次往返坐标计算无漂移")

if CommandLine.arguments.count > 1 {
    let databaseData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let databaseDecoder = JSONDecoder()
    databaseDecoder.dateDecodingStrategy = .iso8601
    let inspected = try databaseDecoder.decode(AppDatabase.self, from: databaseData)
    for session in inspected.sessions {
        for node in session.nodes where !node.isDeleted {
            try IntegrityValidator.validateStoredNode(node, transcript: session.transcript)
        }
    }
    print("PASS: 指定数据库可读取且所有来源节点有效")
}

var annotationSession = SessionRecord(title: "旁侧原文验收", sourceName: "fixture", sourceKind: "test")
let exactThought = "我想：**先验证**，再行动。\n第二行要原封不动。"
let thoughtOne = UserThought(text: exactThought, isSecondaryEdit: false)
let thoughtTwo = UserThought(text: exactThought, isSecondaryEdit: false)
let thoughtOneNode = KnowledgeNode(sourceSpanIDs: [], kind: .thought, parentID: sourceNode.id, relation: .userThought,
    position: CanvasPoint(x: 0, y: 0), userEditedText: exactThought, thoughtID: thoughtOne.id, aiSummary: "先验证，再行动")
let thoughtTwoNode = KnowledgeNode(sourceSpanIDs: [], kind: .thought, parentID: sourceNode.id, relation: .userThought,
    position: CanvasPoint(x: 0, y: 0), userEditedText: exactThought, thoughtID: thoughtTwo.id)
annotationSession.nodes = [sourceNode, thoughtOneNode, thoughtTwoNode]
annotationSession.thoughts = [thoughtOne, thoughtTwo]
try require(AnnotationPresentation.thoughts(for: sourceNode, in: annotationSession).map(\.id) == [thoughtOne.id, thoughtTwo.id], "自动挂接或同文不同ID思考丢失")
try require(AnnotationPresentation.thoughts(for: thoughtOneNode, in: annotationSession).first?.text == exactThought, "思考自身弹窗必须显示精确原文")
let roundTrip = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(annotationSession))
try require(roundTrip.thoughts[0].text == exactThought && roundTrip.nodes[1].aiSummary == "先验证，再行动", "概括不能覆盖用户原文")
print("PASS: 自动挂接与同文不同ID思考、思考自身旁侧原文、概括/原文独立持久化")
var continuation = span
continuation.id = UUID(); continuation.sequence = 2; continuation.startTime = 3; continuation.endTime = 5
continuation.originalText = "所以先验证，再应用。"
var separated = continuation
separated.id = UUID(); separated.sequence = 4; separated.startTime = 8
let excerpts = AnnotationPresentation.excerpts([separated, continuation, span])
try require(excerpts.count == 2 && excerpts[0].spans.map(\.id) == [span.id, continuation.id], "相邻原话没有合并成连续短稿，或遗漏原文被伪装为连续")
print("PASS: 旁侧原文合并相邻识别单元，保留非连续引用边界")
print("PASS: AI 概括与原话回查、思考原文与时间位置、全字段简体导出、背景过滤、演示数据隔离、非法自由文字拒绝、来源 ID 校验、音频删除门禁、设置持久化、旧库兼容")
