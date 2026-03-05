import Foundation

/// AI 会话状态请求限流器：按 key 记录最近一次请求时间，避免短时间重复请求。
struct AISessionStatusRequestLimiter {
    private var lastRequestedAtByKey: [String: Date] = [:]

    /// 判断是否应发起请求。
    ///
    /// - Parameters:
    ///   - key: 请求维度键（建议包含 project/workspace/tool/session）
    ///   - now: 当前时间（便于测试注入）
    ///   - minInterval: 最小请求间隔（秒）
    ///   - force: 是否强制放行（用于会话切换、手动刷新等场景）
    /// - Returns: `true` 表示应发起请求；`false` 表示命中限流
    mutating func shouldRequest(
        key: String,
        now: Date = Date(),
        minInterval: TimeInterval,
        force: Bool = false
    ) -> Bool {
        guard !key.isEmpty else { return force || minInterval <= 0 }
        if force || minInterval <= 0 {
            lastRequestedAtByKey[key] = now
            return true
        }
        if let last = lastRequestedAtByKey[key],
           now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastRequestedAtByKey[key] = now
        return true
    }

    mutating func clear(key: String) {
        guard !key.isEmpty else { return }
        lastRequestedAtByKey.removeValue(forKey: key)
    }

    mutating func clearAll() {
        lastRequestedAtByKey.removeAll()
    }
}
