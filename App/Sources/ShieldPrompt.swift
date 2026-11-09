import Foundation
import QuizGateKit
import UserNotifications

/// 盾牌落下之后，孩子屏幕上的那一声提示。
///
/// 为什么必须有这一个文件：iOS 拿不到「现在哪个 App 在前台」，盾牌页又是系统按固定模板画的，
/// 上面那颗按钮在 iOS 26.5 以下跳不回我们（理由写在 ShieldActionExtension 里）。
/// 三件事叠起来的结果就是今天日志里那个样子：盾确实落了，但孩子只知道「打不开」，
/// 不知道「答一道题就能继续」，而 `quizgate://quiz` 那个入口在 QuizGateApp 里一直空等。
/// 本地通知是不依赖系统跳转、又能把孩子送到答题页的唯一一条通道。
///
/// 为什么不在扩展里直接发：`UNUserNotificationCenter` 不对 app extension 开放，只有主 App 能发。
/// 所以提示的及时性 = 主 App 最近一次跑起来的及时性。落盾那一刻如果 App 已经被彻底划掉，
/// 这一声要等下一次心跳或被 BGTask 唤醒才补得上 —— 这是通道给的天花板，不是漏写。
@MainActor
enum ShieldPrompt {

    /// 固定 identifier：同一时刻只留一条。阈值之后每 30 秒都会重算一次判定，
    /// 用随机 id 会在通知中心堆出一排，孩子划掉一条还剩五条。
    private static let identifier = "quizgate.shield"

    /// 通知被点开之后要走的那一步，由 AppModel 在前台挂上。
    /// 走闭包而不是让 AppDelegate 直接摸 AppModel：`@StateObject` 在 adaptor 里拿不到。
    ///
    /// 冷启动时闭包还没挂上，通知就已经点开了，所以那一跳先记账、等挂上时补跑一次。
    /// 少了这笔账，孩子从锁屏点通知只会把 App 打开在首页，看上去和「提示没用」一模一样。
    static var onOpenQuiz: (() -> Void)? {
        didSet {
            guard onOpenQuiz != nil, pendingOpen else { return }
            pendingOpen = false
            onOpenQuiz?()
        }
    }

    private static var pendingOpen = false

    /// AppDelegate 收到点击之后走这里。
    static func tappedOpen() {
        guard let open = onOpenQuiz else {
            pendingOpen = true
            return
        }
        open()
    }

    /// 家长在 setup 里点一次。系统弹窗只在「从没问过」时出现，重复调用只会拿回当前状态。
    static func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            DiagLog.record("prompt", granted ? "通知权限已通过" : "通知权限被点了拒绝",
                           level: granted ? .info : .warn)
        } catch {
            // 侧载包如果 entitlement 没被系统认下来，异常就是唯一的读数。
            DiagLog.record("prompt", "通知权限请求异常：" + error.localizedDescription, level: .error)
        }
    }

    /// 当前授权状态。给 setup 那一屏看的一格：「没提示」到底是没授权还是没落盾，
    /// 没有这一格在机器上根本分不清。
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 发一声。权限没开时只记日志不弹窗：落盾判定每 30 秒重来一次，
    /// 在这里反复调 requestAuthorization 会变成拿系统弹窗轰炸家长。
    static func fire(nowMs: Int64) {
        let center = UNUserNotificationCenter.current()
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status.promptGranted else {
                // 这一行必须有：静默 return 和「压根没落到这一步」在服务端长成同一个样子，
                // 而这一条通道存在的意义就是把这两种情况分开。
                DiagLog.record("prompt", "盾牌落了但提示发不出去：通知权限 status="
                                   + String(status.rawValue) + "（" + status.promptLabel + "）",
                               level: .warn, nowMs: nowMs)
                return
            }
            let content = UNMutableNotificationContent()
            // 文案和盾牌页上那句对齐（ShieldConfigurationExtension）：孩子在哪看到的
            // 都是同一句话，才不会当成两条互不相干的通知。
            content.title = "先答一道题"
            content.body = "这个 App 已经被挡住了。打开 QuizGate，答对就能继续玩。"
            // 刻意不发声：这一声要在孩子正盯着盾牌页的时候弹，加一段提示音只是吵。
            content.sound = nil
            content.threadIdentifier = "quizgate"
            content.userInfo = ["route": "quiz"]
            // 1 秒而不是 0：系统把 0 当成非法触发器，add 会直接抛错。
            let request = UNNotificationRequest(identifier: identifier,
                                                content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1,
                                                                                          repeats: false))
            do {
                try await center.add(request)
                DiagLog.record("prompt", "已发出答题提示 nowMs=" + String(nowMs), nowMs: nowMs)
            } catch {
                DiagLog.record("prompt", "提示没发出去：" + error.localizedDescription,
                               level: .error, nowMs: nowMs)
            }
        }
    }

    /// 解盾之后把还没点的那条撤掉，免得孩子答完题还被催。
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

extension UNAuthorizationStatus {
    /// setup 那一屏上的一句话。notDetermined 和 denied 要分开写：
    /// 前者还能再弹一次系统窗，后者在本 App 里永远点不出来，只能去设置。
    var promptLabel: String {
        switch self {
        case .authorized, .provisional: return "已经开启"
        case .denied: return "被拒了，只能去系统设置里打开"
        case .notDetermined: return "还没问过"
        @unknown default: return "系统返回了没见过的状态"
        }
    }

    var promptGranted: Bool {
        self == .authorized || self == .provisional
    }
}
