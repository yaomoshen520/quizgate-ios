import Foundation

/// App 与 extension 之间关于「监控活动叫什么名字」的契约。
///
/// 刻意用裸字符串而不是 DeviceActivityName：Kit 不 import DeviceActivity，
/// 这样 GatePolicy 和这份契约都能在模拟机上跑单测。两个使用方各自包一层。
///
/// 名字为什么要带本轮起点毫秒（这整个文件存在的原因）：
/// DeviceActivity 的阈值事件是**单调跨过**语义——同一个活动里，`step-0` 一天只会来一次，
/// 而且系统盯的是「这个区间开始之后累计了多少分钟」。答对题目时我们只把自己的账本清零了，
/// 区间没换、事件名没换，于是系统那边再也没有任何东西会被「跨过」——
/// 实测表现就是当天第一次答对之后永不落盾。所以一轮 = 一个新活动名 + 一个从现在开始的一次性区间，
/// 让系统的计数器和我们的去重集合同时归零。
public enum MonitoringNames {

    /// 当日总时长活动。这一条**故意不轮次化**：家长要的是「今天一共玩了多久」，
    /// 答对题目不应该把它清零，所以它必须是横跨一整天的那一个活动，名字固定。
    public static let dayActivity = "quizgate.day"

    /// 当日总时长只用这一个事件，阈值就是 dailyLimitMinutes。
    public static let dayLimitEvent = "limit"

    /// 一轮一个名字。startedAtMs 用服务器基准时刻（SharedState.nowMs()），
    /// 只当唯一键用，不参与任何判定，所以孩子改系统时钟也不会撞名。
    public static func cycleActivity(startedAtMs: Int64) -> String {
        "quizgate.c\(startedAtMs)"
    }

    /// 轮内的阶梯事件，第 index 档。阈值 = step * (index + 1) 分钟。
    public static func cycleEvent(index: Int) -> String {
        "step-\(index)"
    }
}
