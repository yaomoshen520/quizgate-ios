import Foundation

/// 隧道这一侧只有两档可切，而且**两档都把隧道留着连着**：
/// - `.pass` = 一个包都不吸（includedRoutes 为空），整机照常上网；
/// - `.cutoff` = 默认路由吸进这条我们从不去读的隧道，只把家长后端那一条 /32 留在外面。
///
/// 为什么只有这两档：以前「放行」的做法是把隧道停掉，于是「到点拦人」这件事必须由主 App
/// 亲手按下起隧道那一下。而主 App 正是会被系统划掉的那个进程 —— 通道给了，人不在。
/// 换成常连之后，到点要做的只是改一次路由，改路由的活儿扩展进程自己就能干。
public enum VpnRoute: String, Codable, Equatable, Sendable {

    case pass
    case cutoff

    /// 首页与日志共用的中文短语。两边同源，避免同一件事在两个进程里两种说法。
    public var label: String {
        switch self {
        case .pass: return "放行"
        case .cutoff: return "掐网"
        }
    }
}

/// 主 App 交给隧道扩展的那份意图：现在想要哪一档、到什么时候该换哪一档。
///
/// 为什么单独写一枚文件而不是往 `SharedState` 里加字段：那份状态是四个进程共用的整包 JSON，
/// 靠「每次全量重算」来消解读—改—写竞态。这一格形状相反 —— 写的人只有主 App，读的人只有扩展，
/// 而读的那一侧活在一个没人能叫醒的进程里，只能自己隔一段时间回来翻一眼。
/// 单独一枚原子写的文件把这件事的账划清了：**扩展永远不改它**，读出来的东西只可能是主 App 写的。
///
/// 为什么必须带绝对时刻而不是只带「现在想要哪一档」：到点那一刻主 App 多半已经被划掉了，
/// 只交当前档位的话，扩展手里那份意图会一直停在「放行」。交出截止时刻，
/// 扩展拿自己的钟做比较就能推进 —— 它不需要新增任何判断，只需要比大小。
///
/// 为什么这一份里的时刻一律是**本地墙钟**基准而不是服务器基准：服务器基准只存在于
/// `SharedState.clockOffsetMs` 那一格里，而换算要读整包状态；扩展只该做最少的事。
/// 换算发生在写入侧、由唯一那个写入方做。已知代价：孩子改系统时钟能挪动这些时刻，
/// 这是整条 VPN 路线的天花板（DeviceActivity 那条精确计时在侧载上落不下来，见类注释），
/// 所以扩展的心跳行会把它的本地时刻一起写出去，家长那边对得上对不上是看得见的。
public struct VpnIntent: Codable, Equatable, Sendable {

    public static let currentSchema = 1

    /// 「意图变了」的信号名。扩展收到之后立刻重算一次档位，
    /// 不等自己那个 60 秒的表 —— 没有它，主 App 活着时落下的指令也要最多一分钟才生效。
    public static let signalName = "com.quizgate.ios.vpnIntent"

    public var schema: Int
    /// 闸门是否要求这条隧道常驻。false = 家长关了闸门、或还在「连该不该拦都还不知道」的诊断期，
    /// 那时连隧道都不该占着，扩展也就无从换档。
    public var armed: Bool
    /// 从这一刻起该掐网。落在过去 = 「现在就该掐」。
    public var cutoffAtLocalMs: Int64
    /// 答对换来的放行截止。nil = 手里没有通行权。
    public var unlockUntilLocalMs: Int64?
    /// 这份排期的寿命上界。过了它一律回放行并记一行，等主 App 回来重排。
    /// 没有这一格，「主 App 一整天没跑起来」就会变成永久断网 —— 那是砖，不是闸门。
    public var notAfterLocalMs: Int64
    /// 写入方那一刻的判定原文（`GateDecision.diagToken`），让两边日志能用同一个词归类。
    public var reason: String
    /// 单调递增。扩展靠它分清「意图真的变了」和「只是钟走到了」，两者要记的行不一样。
    public var seq: Int
    public var writtenAtLocalMs: Int64

    public init(schema: Int = VpnIntent.currentSchema, armed: Bool, cutoffAtLocalMs: Int64,
                unlockUntilLocalMs: Int64?, notAfterLocalMs: Int64, reason: String,
                seq: Int, writtenAtLocalMs: Int64) {
        self.schema = schema
        self.armed = armed
        self.cutoffAtLocalMs = cutoffAtLocalMs
        self.unlockUntilLocalMs = unlockUntilLocalMs
        self.notAfterLocalMs = notAfterLocalMs
        self.reason = reason
        self.seq = seq
        self.writtenAtLocalMs = writtenAtLocalMs
    }

    /// 这一刻该走哪一档。纯函数、只读自己的字段，所以能在 CI 上逐条断言。
    ///
    /// 顺序是抄 `GatePolicy.decide` 的，不是随便排的：
    /// 1. 闸门关着 ⇒ 放行。这条没有例外，家长那一头的开关必须压过一切排期。
    /// 2. 排期过期 ⇒ 放行。宁可让孩子多玩一会儿，也不能把一台没人重排的设备永久断网。
    ///    这一档是刻意的 fail-open，且必须被扩展记成一行 WARN —— 账面要有人看见。
    /// 3. 答对换来的窗口还没到 ⇒ 放行。日限额已在它之后，所以「今天用完了」仍然允许
    ///    刚答对的那一道题买回一个阈值长度的窗口（沿用 GatePolicy 的既有语义，不是新定的）。
    /// 4. 到点 ⇒ 掐网。
    public func route(atLocal nowMs: Int64) -> VpnRoute {
        guard armed else { return .pass }
        guard nowMs <= notAfterLocalMs else { return .pass }
        if let unlock = unlockUntilLocalMs, nowMs < unlock { return .pass }
        return nowMs >= cutoffAtLocalMs ? .cutoff : .pass
    }

    /// 排期本体一不一样。刻意不比 seq / reason / writtenAt：那三格每 30 秒的心跳都会变一次，
    /// 把它们算进"变没变"就等于每次都重写文件 —— 一份 400 字节的原子写一天就是 35MB 的闪存账，
    /// 而心跳真正要问的是「到点时刻有没有挪」，不是「我又活了一拍」。
    public func samePlan(as other: VpnIntent) -> Bool {
        armed == other.armed
            && cutoffAtLocalMs == other.cutoffAtLocalMs
            && unlockUntilLocalMs == other.unlockUntilLocalMs
            && notAfterLocalMs == other.notAfterLocalMs
    }

    /// 给日志用的一行读数。逐字段独立成串，不写成一条 `+` 链：
    /// 上一版 CI 报过 "the compiler is unable to type-check this expression in reasonable time"。
    public var diagNote: String {
        let head = "armed=" + String(armed)
        let cut = " 到点=" + String(cutoffAtLocalMs)
        let unlock = " 通行到=" + String(unlockUntilLocalMs ?? -1)
        let end = " 过期=" + String(notAfterLocalMs)
        let why = " 判定=" + reason
        let number = " seq=" + String(seq)
        return head + cut + unlock + end + why + number
    }
}

/// 把「状态 + 判定」翻成意图。放在 Kit 而不是主 App 里，唯一的原因是它必须能被单测跑到：
/// 这台设备上没有任何别的观察者能证明「主 App 说的该掐」和「扩展算的该掐」是同一件事，
/// 而这两边算歪时的长相恰好是两边都自洽、孩子却永久断网。
public enum VpnIntentPlan {

    /// UTC 日界，和 `GatePolicy.dayIndex` 同一粒度。日限额按这一界复位，
    /// 排期的上界也必须按同一界，否则凌晨那几小时会出现「日限额已复位但还在掐着」。
    public static func dayEnd(_ serverMs: Int64) -> Int64 {
        let next = (serverMs / 86_400_000 + 1) * 86_400_000
        return next - 1
    }

    /// - Parameters:
    ///   - nowMs: 由调用方给的服务器基准时刻。**刻意不调 `state.nowMs()`**：单测要能钉住时刻，
    ///     而 `state.nowMs()` 里的偏移是状态里的字段，测试里改它就等于改被测对象自己。
    ///   - localNowMs: 同一瞬间的设备墙钟。两者之差就是这一次写入的换算量。
    public static func build(state: SharedState, decision: GateDecision,
                             seq: Int, nowMs: Int64, localNowMs: Int64) -> VpnIntent {
        // 闸门关着 / 还在诊断期 ⇒ armed=false，隧道不必常驻，扩展也无从换档。
        // 判据刻意挂在判定上而不是 rule.enabled 上：cannotEnforce 那一档的含义是
        // 「我们连该不该拦都还不知道」，在这种设备上先把一条 VPN 挂起来，
        // 是把诊断期过成事故 —— 和上一版「不在 cannotEnforce 时掐网」是同一条口径。
        var armed = true
        if case .cannotEnforce = decision { armed = false }
        if case .allow(.disabledByParent) = decision { armed = false }

        // 该不该现在就掐：判定说该拦，到点时刻就落在当下。
        // 判定说还早，就交本轮阈值到点的那个时刻；本轮起始时刻读不到（还没配过监控）时，
        // 交一个绝不可能自己到点的时刻（上界本身），等主 App 下一次回来重排。
        let cutoffAtMs: Int64
        if decision.wantsShield {
            cutoffAtMs = nowMs
        } else if let started = state.monitoringStartedAtMs, let rule = state.rule {
            cutoffAtMs = started + Int64(max(rule.thresholdMinutes, 0)) * 60_000
        } else {
            cutoffAtMs = dayEnd(nowMs)
        }

        // 服务器基准 → 本地墙钟：两个基准在这一瞬间的差值就是换算量，写入侧一次算清。
        let shift = localNowMs - nowMs
        let unlock = state.ledger.unlockUntilMs.map { $0 + shift }

        return VpnIntent(armed: armed,
                         cutoffAtLocalMs: cutoffAtMs + shift,
                         unlockUntilLocalMs: unlock,
                         notAfterLocalMs: dayEnd(nowMs) + shift,
                         reason: decision.diagToken,
                         seq: seq,
                         writtenAtLocalMs: localNowMs)
    }

    /// 首页那两颗调试按钮用的排期：只动「到没到点」，其余形状和真意图逐字一致。
    ///
    /// 为什么不调 cutoffAt 到 10 年后：`route` 的第 2 步先看过期上界，把上界留在今日界内
    /// 才能让这两档和真路径走同一条判据；推到十年后会让"放行"这一档读起来像"排期已过期"，
    /// 而那两种状态在日志里必须长得不一样 —— 一个是照旧，一个是账面 fail-open。
    public static func debug(cutoff: Bool, seq: Int, nowMs: Int64, localNowMs: Int64) -> VpnIntent {
        let shift = localNowMs - nowMs
        let end = dayEnd(nowMs)
        let when = cutoff ? nowMs : end
        let why = cutoff ? "debug.cutoff" : "debug.pass"
        return VpnIntent(armed: true, cutoffAtLocalMs: when + shift, unlockUntilLocalMs: nil,
                         notAfterLocalMs: end + shift, reason: why, seq: seq,
                         writtenAtLocalMs: localNowMs)
    }
}

/// 意图的落盘与读取。
///
/// 两边都必须容忍读不到：主 App 写失败只记一行不动判定，扩展读不到一律按放行处理并记一行。
/// 「读不到就当拦着」是这条链上最不能犯的错 —— 那份状态在远程日志里和「闸门生效」长得一模一样。
public enum VpnIntentStore {

    /// 单测用的落点覆盖，和 `DiagLog.testDirectory` 同一手法。生产路径永远为 nil。
    static var testDirectory: URL?

    /// 意图落在 App Group 容器里的哪一格。
    ///
    /// 刻意不用 UserDefaults：那一格会被 `CFPreferencesAppSynchronize` 整份重写，
    /// 两个进程各写各的键也可能互相啃掉；而这一份要的是「一次写完整、一次读完整」。
    /// 拿不到容器时回 nil：工程配置错误的代价应当是「这条通道没有读数」，
    /// 不是闸门进程崩一次、每次触发再崩一次。
    static var directoryURL: URL? {
        if let testDirectory { return testDirectory }
        guard let base = AppGroup.containerURL else { return nil }
        return base.appendingPathComponent("vpn", isDirectory: true)
    }

    static var fileURL: URL? {
        directoryURL?.appendingPathComponent("intent.json")
    }

    /// 成功返回 nil，失败返回一句原因。调用方负责按自己的 tag 记日志。
    public static func write(_ intent: VpnIntent) -> String? {
        guard let dir = directoryURL, let url = fileURL else { return "读不到 App Group 容器" }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(intent)
            // 原子写：扩展那边是「随时可能被系统拉起来翻一眼」的读法，
            // 半截 JSON 会被静默读成「没意图」，于是到点不掐 —— 那是最难查的一种掉线。
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 读不到、解不动、schema 不符一律回 nil。调用方把它当成「没有排期」而不是「保持上一次」：
    /// 保持上一次意味着一份坏文件能一直生效到有人来看，而我们没有那种人。
    public static func read() -> VpnIntent? {
        guard let url = fileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let intent = try? JSONDecoder().decode(VpnIntent.self, from: data) else { return nil }
        guard intent.schema == VpnIntent.currentSchema else { return nil }
        return intent
    }

    /// 下一次写入用的序号。读不到旧意图时从 0 重新开始 —— 序号只用来让扩展分清
    /// 「意图变了」和「钟走到了」，它不是账，跳号不丢任何东西。
    public static func nextSeq() -> Int { (read()?.seq ?? -1) + 1 }
}
