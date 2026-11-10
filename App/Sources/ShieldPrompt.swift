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

    // MARK: - 到点提示（提前排进系统的那一声）

    /// 和盾牌提示分开两枚 identifier：两样东西的生死时间不一样 ——
    /// 那一条跟着盾牌状态走，这一条跟着本轮排期走，混用一枚 id 会让后写的把先写的顶掉。
    private static let dueIdentifier = "quizgate.cycle.due"

    /// 把「这一轮玩满了」那一声明明地排给系统，不等时刻到了再发。
    ///
    /// 为什么必须提前排：`fire()` 只有主 App 活着才发得出去，而阈值到的那一刻孩子正玩在
    /// 别家 App 里，我们的进程多半已经被划掉了 —— 这正是上一版「提示不准时」的真因。
    /// 本地通知请求由系统自己持有，排进去之后杀掉 App 照样投递，这是侧载包能拿到的
    /// 唯一一种不依赖自身存活的全局提示。所以它不该是「落盾之后的补救」，而是「配好一轮时就该做的事」。
    ///
    /// - Parameter dueMs: 本轮阈值到点的时刻（服务器时间基准）。
    ///   传的是**时间差**，不是绝对时刻：触发器量的是设备墙钟，而我们那套时钟换算只存在于
    ///   `state.nowMs()` 里。两边各自换算会引入孩子改系统时钟的口子，用差值就没这件事。
    static func scheduleDue(dueMs: Int64, nowMs: Int64) {
        let seconds = Double(dueMs - nowMs) / 1000
        guard seconds >= 1 else {
            // 排在一个过去的时间点上，系统是直接丢还是立刻发没有原文可依，所以不赌：
            // 已经过点的这一轮交给落盾那条提示，下一次重配会排到未来。
            DiagLog.record("prompt", "到点提示没排：算出来已过 " + String(Int(-seconds)) + " 秒",
                           level: .warn, nowMs: nowMs)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "这一轮到时间了"
        content.body = "打开 QuizGate 答对一道题，就能接着玩。"
        // 这一声刻意带声音，和盾牌那条相反：孩子此刻在别的 App 里，横幅可能直接被划走，
        // 声音是唯一还能追上他的那一下。
        content.sound = .default
        content.threadIdentifier = "quizgate"
        content.userInfo = ["route": "quiz"]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: dueIdentifier, content: content, trigger: trigger)
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status.promptGranted else {
                DiagLog.record("prompt", "到点提示没排：通知权限 status="
                                   + String(status.rawValue) + "（" + status.promptLabel + "）",
                               level: .warn, nowMs: nowMs)
                return
            }
            do {
                // 同一个 identifier 重复 add 是替换语义，所以心跳里反复重配只会把下一次往后推，
                // 不会在通知中心堆出一排 —— 这一点和 fire() 用固定 id 是同一个理由。
                try await center.add(request)
                let minutes = Int(seconds / 60)
                DiagLog.record("prompt", "已排定到点提示 " + String(minutes) + " 分钟后",
                               nowMs: nowMs)
            } catch {
                DiagLog.record("prompt", "到点提示没排上：" + error.localizedDescription,
                               level: .error, nowMs: nowMs)
            }
        }
    }

    /// 家长关掉闸门、阈值改成 0、或者还没选 App 时必须撤掉这一条。
    /// 留着它就会出现「闸门已经关了，孩子还是每隔一会儿被催去答题」。
    static func cancelDue() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [dueIdentifier])
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
