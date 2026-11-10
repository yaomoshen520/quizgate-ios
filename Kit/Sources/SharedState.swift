import Foundation

/// 从后端 RuleSnapshot 映射过来的纯值。
///
/// 刻意**不含** watched_packages / game_packages：那两项装的是 Android 包名，
/// iOS 侧管的是 FamilyActivitySelection 里的不透明 token，两者不可互转。
/// 把包名带进来只会让人误以为 iOS 也能按包名拦，所以这一层直接不收。
public struct RuleState: Codable, Equatable, Sendable {
    public var thresholdMinutes: Int
    public var dailyLimitMinutes: Int
    public var graceMinutes: Int
    public var enabled: Bool
    public var version: Int64
    /// 「快到了」的门槛秒数，来自 GameModeRule.warning_seconds。
    /// 用服务端这个数而不是本地另编一个：家长在后台调了这一格，两端要一起变，
    /// 否则同一份规则在两台机上提醒的时机不同。nil/0 = 这一档不提醒。
    /// 可选是为了让老 payload 缺键也能解出来（见 SharedState 那条 schemaVersion 注释）。
    public var warningSeconds: Int?

    public init(thresholdMinutes: Int, dailyLimitMinutes: Int, graceMinutes: Int,
                enabled: Bool, version: Int64, warningSeconds: Int? = nil) {
        self.thresholdMinutes = thresholdMinutes
        self.dailyLimitMinutes = dailyLimitMinutes
        self.graceMinutes = graceMinutes
        self.enabled = enabled
        self.version = version
        self.warningSeconds = warningSeconds
    }
}

/// 本地账本。注意 playedMs 的来源和 Android 完全不同：
/// Android 是无障碍看着前台 App 一秒一秒累出来的；iOS 拿不到前台包名，
/// 这个数只能由 DeviceActivity 的聚合阈值事件推算，**精度上限就是阈值粒度**。
public struct Ledger: Codable, Equatable, Sendable {
    public var playedMs: Int64
    public var correctCount: Int
    public var wrongCount: Int
    /// 答对之后放行的截止时刻（已换算到服务器时间基准）。nil 表示没有通行权。
    public var unlockUntilMs: Int64?
    public var lastQuestionId: String?
    public var lastKnowledgePoint: String?

    public init(playedMs: Int64 = 0, correctCount: Int = 0, wrongCount: Int = 0,
                unlockUntilMs: Int64? = nil, lastQuestionId: String? = nil,
                lastKnowledgePoint: String? = nil) {
        self.playedMs = playedMs
        self.correctCount = correctCount
        self.wrongCount = wrongCount
        self.unlockUntilMs = unlockUntilMs
        self.lastQuestionId = lastQuestionId
        self.lastKnowledgePoint = lastKnowledgePoint
    }
}

/// 授权状态。存字符串而不是枚举原始值，是为了让「系统给了个我们不认识的新状态」
/// 这件事能原样落盘并上报，而不是解码失败把整份状态搞坏。
public struct AuthorizationState: Codable, Equatable, Sendable {
    public var raw: String
    public var checkedAtMs: Int64

    public init(raw: String, checkedAtMs: Int64) {
        self.raw = raw
        self.checkedAtMs = checkedAtMs
    }

    public var isApproved: Bool { raw == "approved" }
}

/// 进程间共享的全部状态。这是 App 与 extension 之间唯一的契约，
/// 改字段必须同时想到四个读取方。
public struct SharedState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    static let storageKey = "quizgate.sharedState.v1"

    public var schemaVersion: Int
    public var installId: String
    /// 设备令牌。放 App Group 是因为 extension 也要用它发上报；
    /// App Group 只对我们这四个 target 可见，不落 UserDefaults.standard。
    public var deviceToken: String?
    public var bindCode: String?
    public var deviceBound: Bool
    public var childGrade: Int
    public var rule: RuleState?
    public var authorization: AuthorizationState?
    /// FamilyActivitySelection 的归档数据。不透明，只能原样存、原样还原。
    public var selectionData: Data?
    public var ledger: Ledger
    /// 当前盾牌是否已落下。由写入方维护，读取方拿它做幂等判断。
    public var shieldApplied: Bool
    /// 服务器时间 − 本地时间。所有判定都走换算后的时间，避免孩子改系统时钟绕过。
    public var clockOffsetMs: Int64
    public var lastSyncAtMs: Int64?
    /// 已处理过的阈值事件 id。回调会重复来，去重靠它。
    public var processedEventIds: [String]
    /// 人话故障记录，给首页和家长告警看。有上限，不会无限长。
    public var faults: [String]
    /// 当前挂在系统上的那一轮监控活动名（MonitoringNames.cycleActivity）。
    /// nil = 还没配过。重配时必须先把它 stop 掉，否则每答对一次就永久占掉
    /// 「同时最多 20 个活动」额度里的一格，二十轮之后系统开始拒新活动。
    ///
    /// 这三个新字段刻意全是**可选**的：JSONDecoder 对可选键走 decodeIfPresent，
    /// 老版本落盘的 payload 缺键也能解出来，于是不用升 schemaVersion。
    /// 一旦写成非可选，升级后第一次 load 就是 .corrupt，而 corrupt 分支
    /// 永远不会重写状态——那台设备会卡在旧状态上直到重装，等于把闸门自己砖了。
    public var monitoringActivity: String?
    /// 当日总时长用完的那一天（UTC 日序号，和事件去重键同一个粒度）。
    /// 由 quizgate.day 的阈值事件写入，**答对不清它**——否则日限额就变成
    /// 「每答一题送一轮」而不是「今天到此为止」。
    public var dailyLimitReachedOnDay: Int64?
    /// 本轮监控的开始时刻（服务器基准）。和 monitoringActivity 成对写。
    /// 它的存在只为一件事：前台时判断「这一轮大概还在不在区间里」，
    /// 而且判断依据是时间而不是系统的活动列表——列表读不准时，
    /// 拿它当重配依据会把「重开 App」变成「重新计时」，那是给孩子开的门。
    public var monitoringStartedAtMs: Int64?
    /// 家长给孩子挑的形象（proto AvatarId 的编号）。**nil 和 0 都不画狐狸**：
    /// 0 是 AVATAR_UNSPECIFIED，proto 那段注释写的是「0 不是"没有形象"而是"没选过"」，
    /// 各端在这种情况下必须退回昵称首字头像，不能默认弹一只。
    /// 走心跳而不是 RuleSnapshot：规则那一份带 version，换条围巾就抬版本号的话，
    /// 「改形象不影响规则」这条在代码里就不成立了。
    public var avatarId: Int?

    public init(installId: String = UUID().uuidString) {
        self.schemaVersion = Self.currentSchemaVersion
        self.installId = installId
        self.deviceToken = nil
        self.bindCode = nil
        self.deviceBound = false
        self.childGrade = 3
        self.rule = nil
        self.authorization = nil
        self.selectionData = nil
        self.ledger = Ledger()
        self.shieldApplied = false
        self.clockOffsetMs = 0
        self.lastSyncAtMs = nil
        self.processedEventIds = []
        self.faults = []
        self.monitoringActivity = nil
        self.dailyLimitReachedOnDay = nil
        self.monitoringStartedAtMs = nil
        self.avatarId = nil
    }

    public func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) + clockOffsetMs
    }

    public mutating func recordFault(_ message: String) {
        faults.append(message)
        if faults.count > 20 { faults.removeFirst(faults.count - 20) }
    }

    public mutating func markEventProcessed(_ id: String) {
        processedEventIds.append(id)
        if processedEventIds.count > 200 {
            processedEventIds.removeFirst(processedEventIds.count - 200)
        }
    }

    public func hasProcessed(_ id: String) -> Bool {
        processedEventIds.contains(id)
    }
}

/// 读盘结果。三态而不是「可选值」，因为「没存过」和「存坏了」要区别对待：
/// 没存过 = 首次安装，正常走 setup；存坏了 = 有东西被写坏，必须记 fault 且**不动盾牌**。
public enum StateLoad: Equatable, Sendable {
    case ok(SharedState)
    case absent
    case corrupt(String)
}

public enum StateStore {

    /// 绝不强解包、绝不 try!。一次半截写入或备份还原如果能让这里崩，
    /// 主 App 和三个 extension 会在每次启动/每次触发时一起崩，现场没有任何线索。
    public static func load(from defaults: UserDefaults) -> StateLoad {
        guard let data = defaults.data(forKey: SharedState.storageKey) else { return .absent }
        do {
            let state = try JSONDecoder().decode(SharedState.self, from: data)
            guard state.schemaVersion == SharedState.currentSchemaVersion else {
                return .corrupt("状态版本 \(state.schemaVersion) 与本版本 \(SharedState.currentSchemaVersion) 不符")
            }
            return .ok(state)
        } catch {
            return .corrupt("状态解码失败：\(error.localizedDescription)")
        }
    }

    public static func load() -> StateLoad {
        guard let defaults = AppGroup.defaults else {
            return .corrupt("读不到 App Group，检查 QUIZGATE_APP_GROUP 是否灌进了 Info.plist")
        }
        // extension 与主 App 不同进程，UserDefaults 的内存缓存可能是旧的。
        // 不先 synchronize 就会拿上一轮的规则做判定。
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        return load(from: defaults)
    }

    @discardableResult
    public static func save(_ state: SharedState, to defaults: UserDefaults) -> Bool {
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: SharedState.storageKey)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public static func save(_ state: SharedState) -> Bool {
        guard let defaults = AppGroup.defaults else { return false }
        let ok = save(state, to: defaults)
        if ok { CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication) }
        return ok
    }

    /// 读—改—写。extension 侧的回调都要走这个，避免各自拿旧快照覆盖别人刚写的字段。
    /// 注意这不是原子操作：App Group 没有跨进程锁，两个 extension 同时写仍可能丢更新。
    /// 缓解办法是「每个回调都从快照重算全量策略」而不是增量改字段，丢一次也能被下一次纠正。
    public static func mutate(_ body: (inout SharedState) -> Void) -> StateLoad {
        guard let defaults = AppGroup.defaults else {
            return .corrupt("读不到 App Group，检查 QUIZGATE_APP_GROUP 是否灌进了 Info.plist")
        }
        return mutate(in: defaults, body)
    }

    /// 可注入版本，单测走这条。生产代码不要用。
    public static func mutate(in defaults: UserDefaults, _ body: (inout SharedState) -> Void) -> StateLoad {
        var state: SharedState
        switch load(from: defaults) {
        case .ok(let loaded):
            state = loaded
        case .absent:
            state = SharedState()
        case .corrupt(let reason):
            // 存坏了就保持现状，绝不在这里重置：重置会把盾牌状态抹掉，等于替孩子开了门。
            return .corrupt(reason)
        }
        body(&state)
        if !save(state, to: defaults) {
            return .corrupt("状态写入失败")
        }
        return .ok(state)
    }
}