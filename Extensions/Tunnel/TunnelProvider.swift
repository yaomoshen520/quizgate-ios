import Foundation
import NetworkExtension
import QuizGateKit

/// 我们自己的 packet tunnel provider —— 也是这台设备上唯一一处「不靠主 App 还活着」的执行点。
///
/// 这一枚扩展做的事只有一件，而且刻意做得「太狠」：把整机 IPv4 默认路由吸进一条
/// **我们从不读包**的隧道。系统把命中的包交给我们，我们一个都不接、也一个都不还，
/// 于是这台设备除了家长后端那一条 /32 之外彻底断网 —— 这就是 VPN 路线下的「拦截」。
///
/// 为什么执法要落在这一格里：主 App 是会被系统划掉的那个进程，而「时间到了」这件事
/// 恰恰发生在孩子玩在别家 App 里、我们的进程早就不在的时候。扩展进程不一样 ——
/// 隧道连着，它就在。所以这一版起隧道不再由判定驱动，改成**常驻**，判定只决定吸不吸包：
/// 「到点起 VPN」这个需求换形成了「VPN 一直开着，到点只换一次路由」。
///
/// 为什么不起隧道就不能拦：iOS 侧 DeviceActivity 的阈值回调实测落不下来（授权那一格
/// 一直回 Not Determined），ManagedSettings 的盾牌也就一直没机会真拦住过一次。
/// 断网不需要系统替我们画 UI，也不需要前台，是这台设备上唯一一条不依赖授权弹窗的执法通道。
///
/// 为什么本轮不按 App 掐（只掐红果、别照常上网）：`NETunnelProviderManager` 确实有
/// appRules / per-app VPN 那一套，但它是 **app-proxy** 扩展点的能力
/// （`com.apple.networkextension.app-proxy`），要另一枚 NEAppProxyProvider 子类。
/// 整机断网 + 放行后端那一条 /32 是当下唯一证过能闭环的形态。
private let tunnelTag = "tunnel"

/// 起隧道之前自己就断掉的那些情况。走 completionHandler 交回系统，
/// 系统会把它当成这次 startTunnel 的失败原因，主 App 那边读 status 就能看见。
private enum CutoffError: Error {
    /// 放行那一格填不出来。绝不能在这种状态下起隧道：那等于把答题接口自己也掐了。
    case noAllowedHost
}

final class TunnelProvider: NEPacketTunnelProvider {

    /// 档位检查的间隔。60 秒不是精度追求：扩展自己数墙钟，间隔只决定「到点之后最多晚多久落地」。
    /// 苹果对 DeviceActivity 的口径是量到的用量能差 5-10 分钟，60 秒不会比它更粗。
    private static let tickSeconds = 60

    /// 无条件心跳行的间隔。刻意比 tick 稀：`DiagLog.append` 是整份文件重写，
    /// 每 60 秒写满 1200 行等于一天重写 288MB，为了一个读数把闪存的写寿命花掉不值。
    /// 5 分钟一格足够回答本轮唯一要问的那件事 —— 这个进程还在不在，以及它不在了的那一刻是几点。
    private static let heartbeatEveryMs: Int64 = 300_000

    /// 所有状态变更走这一条串行队列：tick 与 Darwin 信号来自两个不同线程，
    /// 而 appliedRoute 和上一行的去重账必须只有一处能改它。
    private let work = DispatchQueue(label: "com.quizgate.tunnel.state")

    /// 系统那一边此刻真的吸不吸包。nil = 一次都没落成功过，这一格在日志里长得像"没落过"，
    /// 不会被误读成"落着放行"。
    private var appliedRoute: VpnRoute?

    /// 放行地址。startTunnel 里校验过一次之后缓存下来，之后每一次换档都复用同一枚：
    /// 换档时再去读 Info.plist 会引入「起的时候认得、换的时候读不到」这种中间态。
    private var allowedHost = ""

    /// 排期过期那一行只记一次翻转，不每 5 分钟刷一条。
    private var staleLogged = false

    /// 上一跳「意图文件读不读得到」。同样是翻转才记一行：
    /// 这一格一直是 false 的话，孩子机上一次被系统清掉容器就永远只响一次。
    private var lastIntentReadable: Bool?

    private var timer: DispatchSourceTimer?

    /// 观察者必须被强引用活着（见 DarwinSignal 类注释）：这一格丢了，
    /// 主 App 那边"我明明吼了一声"和这边"我压根没收到"就永远分不清。
    private var signal: DarwinSignal?

    private var lastHeartbeatMs: Int64 = 0

    // MARK: - 系统入口

    /// 签名照 Apple 文档逐字抄：`options` 那一份字典是 `[String: NSObject]?`，不是 `[String: Any]?`
    /// ——写成一字之差的 Any，编译器给的是一句「method does not override any method from its
    /// superclass」（上一轮 CI 就红在这一行），而这句话长得像我们类名写错了，指不到真正的原因。
    /// 这里刻意不覆写 NEProvider 的 `sleepWithCompletionHandler` / `wake`：
    /// 上一版 CI 红过两次都红在扩展签名的一个字符上（`options` 是 `[String: NSObject]?` 不是 Any），
    /// 而这两格对本轮的判据没有增量 —— 睡眠前后都有那个 60 秒的表会自己跳，值得等一次实测再决定要不要接。
    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        let base = AppGroup.apiBase
        let note = VpnPlan.allowedNote(fromBase: base)
        DiagLog.record(tunnelTag, "startTunnel 被调，" + note, nowMs: nowMs())

        guard let allowed = VpnPlan.allowedIPv4(fromBase: base) else {
            // 断在这里是设计，不是兜底：没有放行地址还起隧道 = 孩子答对也提交不上去。
            DiagLog.record(tunnelTag, "startTunnel 拒绝起隧道：放行那一格填不出来", level: .error, nowMs: nowMs())
            completionHandler(CutoffError.noAllowedHost)
            return
        }
        allowedHost = allowed

        let opening = Self.openingRoute()
        DiagLog.record(tunnelTag, "起隧道这一档=" + opening.label + "（" + note + "）", nowMs: nowMs())
        set(route: opening) { err in
            completionHandler(err)
        }
        armTicker()
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let code = String(reason.rawValue)
        DiagLog.record(tunnelTag, "stopTunnel reason=" + code, level: .warn, nowMs: nowMs())
        disarmTicker()
        completionHandler()
    }

    // MARK: - 每一跳干的活

    /// 读意图 → 算档 → 和系统那边对账 → 不一致才换。心跳和信号两条路都汇到这里。
    ///
    /// 为什么两条路共用一个函数：换档的判据只能有一处。分开写就会出现「心跳算出来该掐、
    /// 信号那一路算出来该放」，而这两句会同时出现在同一本日志里，查的人只会更困惑。
    private func evaluate(because source: String) {
        let now = nowMs()
        guard let intent = VpnIntentStore.read() else {
            // 读不到一律按放行，而不是「保持上一次」：一份坏文件保持到有人来看，
            // 在远程日志里和「闸门一直生效」长得一模一样。
            if lastIntentReadable != false {
                let text = "意图文件读不到（没写过、写坏了、或版本不符），这一档按放行"
                DiagLog.record(tunnelTag, text, level: .warn, nowMs: now)
            }
            lastIntentReadable = false
            if appliedRoute != .pass {
                let text = "换档 →放行，因为 " + source
                logSwitch(text, intentNote: "无意图", from: appliedRoute, nowMs: now)
                set(route: .pass)
            }
            heartbeat(now: now, route: .pass, seq: -1, armed: false)
            return
        }
        // 从「读不到」翻回「读得到」也要一行：那台设备到底有没有被系统清过容器，
        // 只看后面那几行是分不清「本来就没有」和「有过又被抹了」的。
        if lastIntentReadable != true {
            let text = "意图文件又能读了 seq=" + String(intent.seq)
            DiagLog.record(tunnelTag, text, nowMs: now)
        }
        lastIntentReadable = true

        let route = intent.route(atLocal: now)
        if !intent.armed || now <= intent.notAfterLocalMs {
            staleLogged = false
        } else if !staleLogged {
            staleLogged = true
            // 这一行是本轮唯一的账面 fail-open 读数点：主 App 一整天没回来重排，
            // 设备回到能上网状态。孩子多玩一会儿是可接受的，永久断网不是。
            let head = "排期已过期 本地=" + String(now) + " 上界=" + String(intent.notAfterLocalMs)
            DiagLog.record(tunnelTag, head + "，回到放行，等主 App 重排", level: .warn, nowMs: now)
        }

        if route != appliedRoute {
            let text = "换档 →" + route.label + "，因为 " + source
            logSwitch(text, intentNote: intent.diagNote, from: appliedRoute, nowMs: now)
            set(route: route)
        }
        heartbeat(now: now, route: route, seq: intent.seq, armed: intent.armed)
    }

    /// 换档那一行分两段写：先记「我们决定要换」，再由系统那边回答认不认。
    ///
    /// 顺序是有讲究的：setTunnelNetworkSettings 是异步的，把两句合成一句就得等回调，
    /// 而回调里那句失败原文已经单独占一行了 —— 两句话混在一起，日志就说不清是判据错还是系统拒。
    private func logSwitch(_ text: String, intentNote: String,
                           from previous: VpnRoute?, nowMs: Int64) {
        let head = text + " " + intentNote
        let tail = " 原档=" + (previous?.label ?? "没落过")
        DiagLog.record(tunnelTag, head + tail, nowMs: nowMs)
    }

    /// 无条件心跳行：本轮要问系统的那一格的读数点。
    ///
    /// 「扩展进程到底能连续值班多久」在这条线之前只能靠推断 —— 我们只证过它起得来
    /// （`setTunnelNetworkSettings 成功`），没证过它能活过一段空闲。这一行按 5 分钟一格
    /// 把它的存活摊在日志上：断在哪一行，就是断在几点。
    private func heartbeat(now: Int64, route: VpnRoute, seq: Int, armed: Bool) {
        guard now - lastHeartbeatMs >= Self.heartbeatEveryMs else { return }
        lastHeartbeatMs = now
        let local = String(now)
        let want = " 想要=" + route.label
        let got = " 已落=" + (appliedRoute?.label ?? "没落过")
        let number = " seq=" + String(seq)
        let gate = " armed=" + String(armed)
        DiagLog.record(tunnelTag, "心跳 本地=" + local + want + got + number + gate, nowMs: now)
    }

    /// 落一份路由到系统。那两句读数（`setTunnelNetworkSettings 成功 domain=… code=…`
    /// 和失败原文）刻意保持上一版逐字不变：家长后台和这一轮的判据都按它们 grep，
    /// 换了措辞就等于把上一轮的证据抹掉。
    private func set(route: VpnRoute, completion: ((Error?) -> Void)? = nil) {
        let settings = Self.buildSettings(allowed: allowedHost, route: route)
        setTunnelNetworkSettings(settings) { [weak self] err in
            let ns = err as NSError?
            let verdict = ns == nil ? "成功" : "失败"
            let level: DiagLevel = ns == nil ? .info : .error
            let domain = ns?.domain ?? "-"
            let code = String(ns?.code ?? 0)
            let text = "setTunnelNetworkSettings " + verdict + " domain=" + domain + " code=" + code
            DiagLog.record(tunnelTag, text, level: level, nowMs: nowMs())
            // 失败原文单独一行：domain/code 只能归类，"到底哪一项被系统拒了"在这句里。
            if let ns {
                let desc = ns.localizedDescription
                DiagLog.record(tunnelTag, "被拒原文 " + desc, level: .error, nowMs: nowMs())
            }
            self?.work.async {
                // 只有系统认下来才更新对账本。落失败时保持旧值，下一跳会再试一次 ——
                // 反过来写就会出现「本档说已经掐着了、系统那边其实还通着」那种两边都自洽的状态。
                if ns == nil { self?.appliedRoute = route }
            }
            completion?(err)
        }
    }

    /// 起隧道时先落哪一档。这一刻手上很可能还没有意图文件（首次安装、或主 App 还没跑过判定），
    /// 那就从放行起步：隧道先把通道占住，等心跳或信号带来真正的档位。
    /// 反过来从掐网起步是会出事故的 —— 一次「还没选要管的 App」的启动就把整机断了网。
    private static func openingRoute() -> VpnRoute {
        guard let intent = VpnIntentStore.read() else { return .pass }
        return intent.route(atLocal: nowMs())
    }

    // MARK: - 表

    /// 全套网络设置：两档只差在吸不吸包，其余形状完全一致。
    ///
    /// 每一行的作用与对应证据：
    /// - includedRoutes = 默认路由 ⟹ 所有 IPv4 出网都交给这枚扩展；我们从不读 packetFlow，
    ///   于是这些包有去无回。这就是「断网」的全部机制。
    /// - excludedRoutes = 后端 /32 ⟹ 答题那两跳（取题、判分）仍走真实接口。
    ///   没有它，这道闸门会把孩子锁死在「答对也解不开」上。真机上一轮已证过它有效。
    /// - dnsSettings = 黑洞地址 ⟹ 只在掐网档挂：放行档如果还挂着它，靠域名的 App
    ///   连解析这一步都过不去，那就不叫放行，叫半断网。
    ///
    /// 放行档刻意用空数组而不是 nil：`includedRoutes` 留 nil 在部分系统版本上被当成
    /// 「全部吸进来」，那一档就成了永远断网，而且和「设置没落成功」长得一模一样。
    /// 空数组的语义是唯一那一条「一个包都别给我」。
    private static func buildSettings(allowed: String, route: VpnRoute) -> NEPacketTunnelNetworkSettings {
        let v4 = NEIPv4Settings(addresses: [VpnPlan.tunnelIPv4], subnetMasks: [VpnPlan.tunnelIPv4Mask])
        if route == .cutoff {
            v4.includedRoutes = [NEIPv4Route.default()]
            let keepAlive = NEIPv4Route(destinationAddress: allowed, subnetMask: "255.255.255.255")
            v4.excludedRoutes = [keepAlive]
        } else {
            v4.includedRoutes = []
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: VpnPlan.blackholeIPv4)
        settings.ipv4Settings = v4
        if route == .cutoff {
            settings.dnsSettings = NEDNSSettings(servers: [VpnPlan.blackholeIPv4])
        }
        // 只吸 IPv4。双栈网络下 IPv6 仍然通，是已知缺口而不是漏做：它要另一份
        // NEIPv6Settings，而这一轮要问系统的是「扩展能不能自己值班」，多塞一个变量就答不回来了。
        return settings
    }

    // MARK: - 心跳与信号

    private func armTicker() {
        work.async {
            guard self.timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.work)
            source.schedule(deadline: .now() + .seconds(Self.tickSeconds),
                            repeating: .seconds(Self.tickSeconds),
                            leeway: .seconds(5))
            source.setEventHandler { [weak self] in
                self?.evaluate(because: "心跳")
            }
            self.timer = source
            source.resume()

            let listener = DarwinSignal(name: VpnIntent.signalName)
            listener.onSignal = { [weak self] in
                self?.work.async { self?.evaluate(because: "信号") }
            }
            listener.start()
            self.signal = listener

            let head = "定时器已装 每 " + String(Self.tickSeconds) + " 秒查一次档"
            let tail = "，信号已听 " + VpnIntent.signalName
            DiagLog.record(tunnelTag, head + tail, nowMs: nowMs())
        }
    }

    private func disarmTicker() {
        work.async {
            // 顺序不能反：先摘观察者再放引用，反过来就是 use-after-free，
            // 表现成随机 EXC_BAD_ACCESS 而不是「停止之后不再响」。
            self.signal?.stop()
            self.signal = nil
            self.timer?.cancel()
            self.timer = nil
        }
    }
}

private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
