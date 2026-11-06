import KnowledgeSpineCore
import SwiftUI

@MainActor
enum FocusedStudyAvailability {
    static func canSubmit(question: String, session: SessionRecord, store: AppStore, processor: LocalProcessingService) -> Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && question.trimmingCharacters(in: .whitespacesAndNewlines).count <= 600
            && (!session.transcript.isEmpty || (session.images ?? []).contains { $0.deletedAt == nil })
            && !processor.isProcessing(session.id)
            && !processor.isFocusing(session.id)
            && !store.database.sessions.contains { [.recording, .paused].contains($0.status) }
    }
}

/// A question-led reading of the saved manuscript, separate from the map.
struct FocusedStudyView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @Binding var question: String
    @State private var selectedReportID: UUID?

    private var session: SessionRecord? { store.database.sessions.first { $0.id == sessionID } }
    private var reports: [FocusedStudyReport] { session?.focusedStudyReports ?? [] }
    private var report: FocusedStudyReport? {
        reports.first { $0.id == selectedReportID } ?? reports.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("围绕我的问题整理").font(.title2.bold())
                    Text(session?.title ?? "课程记录").font(.caption).foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            VStack(alignment: .leading, spacing: 10) {
                TextField("你想重点弄清什么？例如：第二课堂和志愿服务的学分怎么获得、认定", text: $question, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Text("重新阅读本条已保存的逐字稿和图片，不局限于导图里已有的内容。")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                    Spacer()
                    Button("围绕这个问题整理") {
                        processor.processFocus(question: question, sessionID: sessionID, store: store)
                    }
                    .buttonStyle(.borderedProminent).tint(AppTheme.teal)
                    .disabled(session.map { !FocusedStudyAvailability.canSubmit(question: question, session: $0, store: store, processor: processor) } ?? true)
                }
                if question.trimmingCharacters(in: .whitespacesAndNewlines).count > 600 {
                    Text("问题请控制在 600 字以内。")
                        .font(.caption).foregroundStyle(AppTheme.coral)
                }
                if processor.isFocusing(sessionID) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(processor.focusProgress[sessionID] ?? "正在从逐字稿中整理与你的问题有关的内容…")
                            .font(.callout).foregroundStyle(AppTheme.teal)
                    }
                    Text("可以关闭此窗口，整理会继续；已有结果不会被覆盖。")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                } else if let error = session?.focusedStudyError, !error.isEmpty {
                    Text(error)
                        .font(.callout).foregroundStyle(AppTheme.coral).textSelection(.enabled)
                }
            }.padding(.horizontal, 22).padding(.bottom, 18)
            Divider()
            if !reports.isEmpty {
                HStack {
                    Text("已保存的专题").font(.caption).foregroundStyle(AppTheme.muted)
                    Picker("已保存的专题", selection: Binding(get: { report?.id }, set: { selectedReportID = $0 })) {
                        ForEach(reports.reversed()) { item in
                            Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(item.question)")
                                .tag(Optional(item.id))
                        }
                    }.labelsHidden()
                    Spacer()
                }.padding(.horizontal, 22).padding(.vertical, 12)
            }
            ScrollView {
                if let report, let session {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(report.question).font(.title3.bold()).textSelection(.enabled)
                            Text("依据本条逐字稿与图片整理；原导图保留")
                                .font(.caption).foregroundStyle(AppTheme.muted)
                        }
                        ForEach(report.sections) { section in
                            FocusedStudySectionCard(section: section, transcript: session.transcript, sessionID: session.id)
                        }
                        if !report.gaps.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("原稿未讲清楚的部分", systemImage: "questionmark.circle").font(.headline)
                                ForEach(Array(report.gaps.enumerated()), id: \.offset) { _, gap in
                                    Text("• \(gap.simplifiedChineseForDisplay)")
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if report.sections.isEmpty {
                            Text("本条逐字稿中没有找到足以回答这个问题的内容。可参考上面的缺失说明，调整问题后重新整理。")
                                .foregroundStyle(AppTheme.muted).textSelection(.enabled)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(processor.isFocusing(sessionID) ? "正在围绕你的问题阅读原稿" : "把你关心的问题写在上面").font(.headline)
                        Text("例如：第二课堂和志愿服务分别需要多少学分？怎么获得、如何认定、有没有期限？\n整理结果会单独保存在这里，不会改变原导图或逐字稿。")
                            .foregroundStyle(AppTheme.muted).lineSpacing(6)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 620, idealHeight: 720)
        .background(AppTheme.paper)
        .onChange(of: reports.last?.id) { _, id in selectedReportID = id }
    }
}

private struct FocusedStudySectionCard: View {
    let section: FocusedStudySection
    let transcript: [TranscriptSpan]
    let sessionID: UUID
    @State private var showingSources = false

    private var sources: [TranscriptSpan] {
        let ids = Set(section.sourceSpanIDs)
        return transcript.filter { ids.contains($0.id) }.sorted { $0.sequence < $1.sequence }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(section.heading.simplifiedChineseForDisplay).font(.headline).textSelection(.enabled)
                Spacer()
                Button("查看原文", systemImage: "arrow.up.forward.square") { showingSources = true }
                    .buttonStyle(.link)
                    .disabled(sources.isEmpty && section.sourceImageIDs?.isEmpty != false)
                    .popover(isPresented: $showingSources, arrowEdge: .trailing) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("对应原文").font(.headline)
                                Text("以下是保留的原始识别文字，可能含识别错误。")
                                    .font(.caption).foregroundStyle(AppTheme.muted)
                                ForEach(sources) { span in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("\(time(span.startTime)) – \(time(span.endTime))")
                                            .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.muted)
                                        Text(span.originalText.simplifiedChineseForDisplay)
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                ImageEvidenceStrip(sessionID: sessionID, imageIDs: section.sourceImageIDs ?? [])
                            }.padding(20)
                        }.frame(width: 450, height: 420)
                    }
            }
            Text(section.explanation.simplifiedChineseForDisplay)
                .lineSpacing(6).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
    }

    private func time(_ value: TimeInterval) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
