import DeviceActivity
import FamilyControls
import Foundation
import QuizGateKit

/// 配置系统级用量监控。
///
/// 两条硬约束（来自 SDK 签名，不是猜的）：
/// - 监控进行中**不能改阈值**，必须 stop → 重配 → start。所以每次答对开新一轮都要走全流程。
/// - 最小监控区间 15 分钟。家长配的阈值如果小于 15，系统这一层做不到，
///   只能抬到 15 —— 这件事必须在 UI 上说清楚，不能默默抬。
final class MonitoringController {

    static let activityName = DeviceActivityName("quizgate.daily")
    /// 系统最小粒度。
    static let minimumStepMinutes = 15
    /// 事件数量自限。同时监控的活动总数上限是 20，这里只占 1 个活动，
    /// 但事件也不该无限铺，16 个阶梯足够覆盖 4 小时。
    static let maxEvents = 16

    private let center = DeviceActivityCenter()

    enum ConfigureResult: Equatable {
        case started(stepMinutes: Int, eventCount: Int)
        case noSelection
        case ruleDisabled
    }

    @discardableResult
    func reconfigure(rule: RuleState?, selectionData: Data?) throws -> ConfigureResult {
        // 先停。不停就改阈值会被系统拒，而且拒的方式不总是抛错。
        center.stopMonitoring([Self.activityName])

        guard let rule, rule.enabled, rule.thresholdMinutes > 0 else { return .ruleDisabled }
        guard let selection = SelectionArchive.decode(selectionData),
              !SelectionArchive.isEmpty(selection) else { return .noSelection }

        let step = max(rule.thresholdMinutes, Self.minimumStepMinutes)
        let cap = rule.dailyLimitMinutes > 0 ? rule.dailyLimitMinutes : step * 4

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )

        // 阶梯式事件：每 step 分钟一个。Monitor 侧每收到一个就累加 step，
        // 这样累计时长才对得上。事件名带序号，去重靠「活动名|事件名|天」。
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        var minutes = step
        var index = 0
        while minutes <= cap && index < Self.maxEvents {
            events[DeviceActivityEvent.Name("step-\(index)")] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(minute: minutes)
            )
            minutes += step
            index += 1
        }

        try center.startMonitoring(Self.activityName, during: schedule, events: events)
        return .started(stepMinutes: step, eventCount: events.count)
    }

    func stop() {
        center.stopMonitoring([Self.activityName])
    }
}