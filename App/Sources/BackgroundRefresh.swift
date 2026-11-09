import BackgroundTasks
import Foundation
import QuizGateKit

/// 后台重挂监控。补的是一个明确的洞：本轮区间最长寿到当天 23:59，
/// 而 `ensureMonitoringArmed` 原来只在 `onAppear` 跑 —— 孩子一整天不打开 App，
/// 过 23:59 之后就没有任何一段代码在重配，第二天等于没闸门。
///
/// 为什么只有 BGAppRefreshTask 这一条路：
/// - DeviceActivityMonitor 扩展不是常驻进程，它只在系统回调的那一瞬间活着；
/// - 主 App 被孩子杀掉就没有心跳，兜底的那条「前台定时重算」根本不会发生；
/// - BGProcessingTask 在低电量或不活跃时可能几小时不来，而闸门拖不起几个小时。
///
/// **系统不保证来。** 这条通道把「一定不来」变成「多半会来」，不是承诺。
/// 每次跑完都把结果写进诊断日志并顺手搬去服务端 —— 远程能看到的那一行，
/// 才是这一版到底有没有在后台真跑过的唯一证据。
enum BackgroundRefresh {

    /// 必须和 Info.plist 里 `BGTaskSchedulerPermittedIdentifiers` 那一串逐字相同。
    /// 不一致的话 `submit` 直接抛错，而错只会在真机的后台里发生，本机永远看不到。
    static let identifier = "com.quizgate.ios.rearm"

    /// 注册回调。必须在启动流程里调（`willFinishLaunching`），晚了系统这一轮就不接了。
    static func register(launchHandler: @escaping (BGAppRefreshTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            launchHandler(refresh)
        }
    }

    /// 排下一次。无论这一次成没成都要排 —— 失败之后再没有下一次，就再也没机会查为什么。
    static func scheduleNext(after seconds: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // 这只是「最早」，系统想给更晚就给更晚。写 15 分钟是照着社区实测的下限写的，
        // 不是承诺 —— 真机上常见的间隔远大于它。
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        // 这里原本想写 requiresNetworkConnectivity = true，编不过：那两个属性只在
        // BGProcessingTaskRequest 上，BGAppRefreshTaskRequest 只有 earliestBeginDate。
        // 所以「没网白跑一趟」只能在运行时判：run 里第一步就是搬日志和拉规则，
        // 连不上各自立即返回，代价是一次唤醒而不是一次卡死。
        try? BGTaskScheduler.shared.submit(request)
    }

    /// 跑一次后台体检。由注册时那个 closure 调用。
    static func run(_ task: BGAppRefreshTask) {
        // 系统的 launch handler 不承诺在主线程上调，而下面每一步都按主线程写
        // （AppModel 是 @MainActor，UserDefaults 和 ManagedSettings 同理），所以先跳回去。
        //
        // expired 用盒子而不是局部 var：@Sendable 的闭包捕获可变局部量编不过。
        // 两处读写都落在主队列上（`using: nil` 让系统把 expirationHandler 派回主队列，
        // 续体本身是 @MainActor），所以这个盒子不需要锁。
        let expired = ExpiredFlag()
        task.expirationHandler = { expired.value = true }

        Task { @MainActor in
            scheduleNext()
            DiagLog.record("bg", "后台唤醒开始 id=" + identifier)
            let model = AppModel()
            await model.backgroundCheck()
            DiagLog.record("bg",
                           "后台唤醒结束 activity=" + (model.state.monitoringActivity ?? "nil")
                               + " decision=" + model.decision.diagToken,
                           level: expired.value ? .warn : .info,
                           nowMs: model.state.nowMs())
            // 被系统中途收回时间片就不算成功：报成功等于骗调度器，
            // 它会按「上一次很顺利」把下一次排得更远。
            task.setTaskCompleted(success: !expired.value)
        }
    }
}

private final class ExpiredFlag {
    var value = false
}
