import Foundation

public enum CaptureSignalHealth {
    public static func warning(now: Date, startedAt: Date, lastSampleAt: Date?, lastAudibleAt: Date?) -> String? {
        if now.timeIntervalSince(lastSampleAt ?? startedAt) >= 10 {
            return "已连续 10 秒没有收到系统声音数据；已录内容仍保留，请检查来源或权限。"
        }
        if now.timeIntervalSince(lastAudibleAt ?? startedAt) >= 30 {
            return "已连续 30 秒只有静音或极低音量；请确认课程正在播放、来源没有选错。已录内容仍保留。"
        }
        return nil
    }
}
