import Foundation
import QuizGateKit

/// 远程即时控制的 SSE 接收端。和安卓 RemoteCommandStream 同一口径：一台设备一条共享长连接，
/// 事件带类型，按类型分发（应用层多路复用）。收到 command/quiz-now 就取题弹答题页。
///
/// iOS 平台天花板：主 App 被划掉就死，这条连接只在 App 活着时收得到命令。
/// 后台常驻要放进 tunnel 扩展再信号唤醒，但系统不允许扩展随意拉起已划掉的 App——那是后续单独攻坚。
///
/// 做成 @MainActor：读流是 async（逐行 suspend，不阻塞主线程），命令回调直接落在主 actor 上取题。
/// 令牌从 StateStore 读（线程安全的 App Group 快照），不碰主 App 的 @Published 状态。
@MainActor
final class RemoteCommandStream {
    private var task: Task<Void, Never>?
    private let onQuizNow: () async -> Void

    init(onQuizNow: @escaping () async -> Void) {
        self.onQuizNow = onQuizNow
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        var backoff: UInt64 = 1_000_000_000
        while !Task.isCancelled {
            // 没登记/没令牌就连了也是 401，空等别刷服务端。
            guard case .ok(let state) = StateStore.load(),
                  let token = state.deviceToken, !token.isEmpty,
                  let base = AppGroup.apiBase else {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            do {
                try await connect(base: base, token: token)
                backoff = 1_000_000_000
            } catch {
                if !Task.isCancelled {
                    DiagLog.record("remote", "SSE 断开：\(error.localizedDescription)，\(backoff / 1_000_000_000)s 后重连", level: .warn)
                }
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(backoff * 2, 30_000_000_000)
        }
    }

    private func connect(base: String, token: String) async throws {
        guard let url = URL(string: base + "/api/device/events") else { return }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Quizgate-Token")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        DiagLog.record("remote", "SSE 通道已连接")
        var eventType = ""
        var data = ""
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            if line.hasPrefix("event:") {
                eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if line.isEmpty {
                if !data.isEmpty { await dispatch(eventType: eventType, data: data) }
                eventType = ""
                data = ""
            }
            // 以 ":" 开头的是心跳注释，忽略。
        }
    }

    private func dispatch(eventType: String, data: String) async {
        guard eventType == "command",
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let kind = object["kind"] as? String else { return }
        if kind == "quiz-now" {
            DiagLog.record("remote", "收到远程命令：quiz-now")
            await onQuizNow()
        }
    }
}