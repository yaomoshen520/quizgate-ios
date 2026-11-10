import Foundation
import NetworkExtension
import QuizGateKit

/// 主 App 这一侧的 VPN 掐网开关。
///
/// 它不碰任何数据包，只做五件事：认出（或第一次建好）我们那枚 tunnel 配置、存进系统偏好、
/// 起它或停它、把系统给的回答一句一行落到诊断日志里、以及每 30 秒对一次账 ——
/// 系统那一边长成的样子和闸门想要的那一档不一致时补发一次（见 reconcile()）。
///
/// 为什么"起"要分三步（存 → 重新读一份 → 起）：Apple 的口径是存完偏好之后手上那份 manager
/// 不能再用于连接，直接 start 得到的是 .invalid。那是我们自己的用法错误，
/// 不是系统对侧载的回答 —— 而本轮唯一要问系统的就是后者，所以必须先把前者排除掉，
/// 否则日志里那一行分不清是谁挡的路。
///
/// 为什么挂在 decision 上而不是挂在盾牌写没写上：走 VPN 这条路之后，真把孩子拦住的是断网，
/// ManagedSettings 那一格只是给系统看的证据。判定说"该拦"就该断网，判定说"放行"就该恢复。
@MainActor
final class VpnCutoff {

    /// 一次动作的结果：applied 才允许更新 lastApplied，失败时必须留在旧值上，
    /// 否则下一次心跳会以为"已经做过了"，于是要么永远起不来、要么永远停不掉。
    private struct Outcome {
        var applied: Bool
        var text: String
    }

    /// 上一次真正落地的指令。心跳每 30 秒调一次 apply()，没有这道闸就成了
    /// 每 30 秒往系统偏好里存一份 VPN 配置 —— 那本身就是可观测的骚扰。
    private var lastApplied: Bool?

    /// 闸门「此刻想要哪一档」，和 lastApplied 分两本账记：后者只记这条指令下没下过，
    /// 这一格记系统那边应该长成什么样。分开的理由是孩子在设置里手动关掉 VPN 那一刻 ——
    /// 指令没失效，失效的是执行结果，而 apply() 那道幂等闸比的是前者，会对不上账一路短路。
    private var desired: Bool?

    /// 为同一个对不上账的状态连续补发的次数。对上就归零。
    private var reconcileTries = 0

    /// 补发上限：到点就停手并明说，不再每 30 秒往系统偏好里存一份。
    /// 5 次 ≈ 两个半分钟的争取，之后留给家长那条日志说话。
    private static let reconcileLimit = 5

    /// 手上还有一件没做完。丢掉的指令不再致命：想要的那一档已经另记在 desired 里，
    /// 下一拍 reconcile() 会照这本账补。
    private var inFlight = false

    /// 状态轮询上一次看到的系统状态文字。同样只为了"变了才记一行"。
    private var lastSeenStatus = ""

    /// 首页那一行和 tag=vpn 日志共用最新那句话。
    private(set) var note = "VPN 通道还没试过"

    var onChange: ((String) -> Void)?

    // MARK: - 入口

    /// wantsCutoff = 闸门这一刻想把这台设备断网。
    func apply(wantsCutoff: Bool, nowMs: Int64) {
        // 先记账再决定动不动手：下面两道闸都可能让这一条指令这一拍不落地，
        // 而"想不想要"和"落没落地"是两回事，前者落了账 reconcile() 才有得补。
        if desired != wantsCutoff { reconcileTries = 0 }
        desired = wantsCutoff
        guard wantsCutoff != lastApplied else { return }
        guard !inFlight else {
            let wanted = describe(wantsCutoff)
            DiagLog.record("vpn", "VPN 指令没下：上一件还在路上（想要=" + wanted + "）",
                           level: .warn, nowMs: nowMs)
            return
        }
        inFlight = true
        Task {
            let outcome = await perform(wantsCutoff: wantsCutoff, nowMs: nowMs)
            inFlight = false
            if outcome.applied { lastApplied = wantsCutoff }
            note = outcome.text
            onChange?(outcome.text)
        }
    }

    /// 忽略幂等账，把同一条指令再下一次（调试按钮用）。
    ///
    /// 为什么要绕：孩子机上一次起隧道失败之后 lastApplied 会留在旧值上，
    /// 于是「再点一次试试」这颗按钮什么都不做，而调试最需要的正是重按。
    /// 真闸门路径不走这里。
    func forceApply(wantsCutoff: Bool, nowMs: Int64) {
        lastApplied = nil
        apply(wantsCutoff: wantsCutoff, nowMs: nowMs)
    }

    /// 读一次系统那边的现状；心跳每 30 秒调一次，只在状态变了的那一次落一行。
    ///
    /// 起隧道是异步的：startTunnel 返回时多半还是 .connecting，"扩展到底载没载起来"
    /// 落在后面那一格 .connected 或弹回的 .disconnected 上。所以这一格必须由心跳续上，
    /// 不能由 apply() 那一跳的即时状态代替。
    func refresh(nowMs: Int64) {
        Task { await poll(nowMs: nowMs) }
    }

    // MARK: - 干活的四步

    private func perform(wantsCutoff: Bool, nowMs: Int64) async -> Outcome {
        let base = AppGroup.apiBase
        let allowed = VpnPlan.allowedIPv4(fromBase: base)
        let hostNote = VpnPlan.allowedNote(fromBase: base)
        if wantsCutoff, allowed == nil {
            // 这条路在这里就断掉，是设计而不是兜底：放行那一格填不出来还起隧道，
            // 等于把取题/判分两跳一起掐了，孩子面对的是"答对也提交不了"的死局。
            let text = "掐网没开：" + hostNote + "，放行那一格填不出来"
            DiagLog.record("vpn", text + "，宁可不断网", level: .error, nowMs: nowMs)
            return Outcome(applied: false, text: "VPN 没开：认不出可放行的后端 IP")
        }

        let managers = await Self.loadAll()
        let found = managers.first(where: Self.isOurs)
        let count = String(managers.count)
        let foundText = found == nil ? "没有" : "已有"
        let head = "系统里已有 " + count + " 份 tunnel 配置，我们那枚" + foundText + "（" + hostNote + "）"
        DiagLog.record("vpn", head, nowMs: nowMs)

        // 要停而根本没有那枚配置：这就是"没掐着"，不用报错，直接认账。
        if !wantsCutoff, found == nil {
            return Outcome(applied: true, text: "VPN 没在跑（本机还没建过那枚配置）")
        }

        let manager = found ?? NETunnelProviderManager()
        if found == nil { Self.configure(manager, allowed: allowed ?? "") }
        if let saveError = await Self.save(manager) {
            let domain = saveError.domain
            let code = String(saveError.code)
            let desc = saveError.localizedDescription
            let text = "存 VPN 配置失败 domain=" + domain + " code=" + code + " " + desc
            DiagLog.record("vpn", text, level: .error, nowMs: nowMs)
            return Outcome(applied: false, text: "VPN 配置没存进去（code=" + code + "）")
        }

        // 存完必须换一份从偏好里读出来的对象再用它的 connection（见类注释）。
        let reread = await Self.loadAll()
        guard let ready = reread.first(where: Self.isOurs),
              let session = ready.connection as? NETunnelProviderSession else {
            let text = "存成功但回读找不到那枚配置，或 connection 不是 tunnel session"
            DiagLog.record("vpn", text, level: .error, nowMs: nowMs)
            return Outcome(applied: false, text: "VPN 配置存了但拿不到连接对象")
        }

        if wantsCutoff {
            let startError = Self.start(session)
            if let startError {
                let domain = startError.domain
                let code = String(startError.code)
                let desc = startError.localizedDescription
                let text = "startTunnel 当场被拒 domain=" + domain + " code=" + code + " " + desc
                DiagLog.record("vpn", text, level: .error, nowMs: nowMs)
                return Outcome(applied: false, text: "VPN 起不来（code=" + code + "）")
            }
            let status = Self.statusText(session.status)
            let text = "startTunnel 已受理，当下状态=" + status
            DiagLog.record("vpn", text, nowMs: nowMs)
            // 受理 ≠ 起来。applied 记成 true 是"指令已发出且没被当场拒绝"，
            // 后面那格 connected 由 refresh() 续上；两者分开，日志才说得出是谁挡的路。
            return Outcome(applied: true, text: "VPN 正在起（" + status + "）")
        }

        Self.stop(session)
        let status = Self.statusText(session.status)
        let text = "stopTunnel 已发出，当下状态=" + status
        DiagLog.record("vpn", text, nowMs: nowMs)
        return Outcome(applied: true, text: "VPN 已下令停（" + status + "）")
    }

    private func poll(nowMs: Int64) async {
        let managers = await Self.loadAll()
        guard let manager = managers.first(where: Self.isOurs) else {
            // 无配置也是一档"稳定错着"：孩子能在设置里把那枚配置整条删掉，
            // 而 perform() 见到 found == nil 会重新建好，所以这一格照样要过一遍账。
            await reconcile(status: "无配置", nowMs: nowMs)
            if lastSeenStatus != "无配置" {
                lastSeenStatus = "无配置"
                let text = "VPN：系统里还没有那枚配置"
                note = text
                onChange?(text)
            }
            return
        }
        let status = Self.statusText(manager.connection.status)
        // 补账排在"变了才记行"之前：状态一直稳定地错着，恰恰是最不需要变化通知的那种错。
        await reconcile(status: status, nowMs: nowMs)
        guard status != lastSeenStatus else { return }
        let previous = lastSeenStatus
        lastSeenStatus = status
        let level: DiagLevel = status == "已连接" ? .info : .warn
        DiagLog.record("vpn", "状态变化 " + previous + " → " + status, level: level, nowMs: nowMs)
        var text = "VPN 状态：" + status
        if status != "已连接" {
            // 这一句才是本轮真正要的读数：弹回断开时系统留了的那条错。
            // "扩展加载失败"与"权限层拒绝"在它出现之前一直是同一副长相。
            if let err = await Self.lastDisconnectError(manager.connection) {
                let domain = err.domain
                let code = String(err.code)
                let desc = err.localizedDescription
                DiagLog.record("vpn", "上次断开原因 domain=" + domain + " code=" + code,
                               level: .error, nowMs: nowMs)
                DiagLog.record("vpn", "上次断开原文 " + desc, level: .error, nowMs: nowMs)
                text += "，原因 code=" + code
            }
        }
        note = text
        onChange?(text)
    }

    /// 系统那一边和想要的这一档对不上账时补发一次。心跳每 30 秒经 poll() 走一遍。
    ///
    /// 为什么必须由这里补而不能靠 apply()：那道幂等闸比的是"我上次下过什么指令"，
    /// 而孩子手动关掉 VPN 之后指令并没有失效，失效的是执行结果。这时 desired 与
    /// lastApplied 相等 ⇒ apply() 安静短路，于是"该断网"能一路保持到设备重启。
    /// 上一版真机日志里的 `状态变化 已连接 → 断开` 就是这么一条只记录、不处理的行。
    private func reconcile(status: String, nowMs: Int64) async {
        guard let want = desired else { return }
        // 正在起 / 正在停 / 重手中 / 无效都算"上一条还在落地"，不是对不上账。
        let stable = status == "已连接" || status == "断开" || status == "无配置"
        guard stable else { return }
        let got = status == "已连接"
        guard got != want else {
            reconcileTries = 0
            return
        }
        guard !inFlight, reconcileTries < Self.reconcileLimit else { return }
        reconcileTries += 1
        let tried = String(reconcileTries)
        let head = "系统那边 ≠ 想要（想要=" + describe(want) + "，读到=" + status + "）"
        let text = head + "，补发第 " + tried + " 次"
        DiagLog.record("vpn", text, level: .warn, nowMs: nowMs)
        note = text
        onChange?(text)
        if reconcileTries == Self.reconcileLimit {
            let last = head + "，补发满 " + String(Self.reconcileLimit) + " 次仍不对，停手等家长处理"
            DiagLog.record("vpn", last, level: .error, nowMs: nowMs)
            note = last
            onChange?(last)
        }
        inFlight = true
        let outcome = await perform(wantsCutoff: want, nowMs: nowMs)
        inFlight = false
        if outcome.applied { lastApplied = want }
    }

    // MARK: - 系统调用

    /// 认出「这是我们自己的那枚配置」。判据只用 providerBundleIdentifier：
    /// 一台机器上可能装着别的 VPN，而 localizedDescription 是家长能改的字符串，不能当身份。
    private static func isOurs(_ manager: NETunnelProviderManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerBundleIdentifier == VpnPlan.providerBundleId
    }

    private static func configure(_ manager: NETunnelProviderManager, allowed: String) {
        let proto = NETunnelProviderProtocol()
        // 这一行是整枚扩展能否被加载的入口：系统按这个 bundle id 去宿主包的 PlugIns 里找
        // 那枚 packet-tunnel 扩展。写错或扩展没嵌进去，表现就是 VPN 起不来。
        proto.providerBundleIdentifier = VpnPlan.providerBundleId
        // serverAddress 在 packet tunnel 里并不真连过去（我们自己就是隧道那头），
        // 但它是 NEVPNProtocol 上必填形状的那一格，留空会让配置校验先拒一道，
        // 于是"权限层答不答话"这个问题又被配置层挡在前面。填放行那个 IP 最省事。
        proto.serverAddress = allowed
        // 显式标成 [String: Any]：这一格的类型是 Any 字典，字面量给成 [String:String]
        // 能不能隐式升上去取决于版本，不拿一轮 CI 去试这个。
        let marker: [String: Any] = ["quizgate": "cutoff"]
        proto.providerConfiguration = marker
        manager.protocolConfiguration = proto
        manager.localizedDescription = "QuizGate 答题闸门"
        manager.isEnabled = true
    }

    /// NETunnelProviderSession 上的 startTunnel 是同步 throws：
    /// 返回只代表"受理/当场拒绝"，不代表隧道起来了。
    private static func start(_ session: NETunnelProviderSession) -> NSError? {
        do {
            try session.startTunnel(options: nil)
            return nil
        } catch {
            return error as NSError
        }
    }

    private static func stop(_ session: NETunnelProviderSession) {
        session.stopTunnel()
    }

    private static func loadAll() async -> [NETunnelProviderManager] {
        await withCheckedContinuation { cont in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                let list = managers ?? []
                if let ns = error as NSError? {
                    let domain = ns.domain
                    let code = String(ns.code)
                    let text = "loadAllFromPreferences 失败 domain=" + domain + " code=" + code
                    DiagLog.record("vpn", text, level: .error)
                }
                cont.resume(returning: list)
            }
        }
    }

    private static func save(_ manager: NETunnelProviderManager) async -> NSError? {
        await withCheckedContinuation { cont in
            manager.saveToPreferences { error in
                cont.resume(returning: error as NSError?)
            }
        }
    }

    private static func lastDisconnectError(_ connection: NEVPNConnection) async -> NSError? {
        await withCheckedContinuation { cont in
            connection.fetchLastDisconnectError { error in
                cont.resume(returning: error as NSError?)
            }
        }
    }

    // MARK: - 措辞

    /// NEVPNStatus 的六档翻成首页与日志共用的中文短语。
    ///
    /// 刻意写成 if 链而不是 switch：这枚枚举是系统给的，哪天多一档也不能让 switch 编不过；
    /// 而且它到底是 enum 还是带静态成员的包装类型，我不打算凭记忆下注（`==` 两种写法都认）。
    /// 认不出来时回 "无效"，这一格在日志里就长得像"没读到"，不会被误读成"没断"。
    private static func statusText(_ status: NEVPNStatus) -> String {
        if status == .connected { return "已连接" }
        if status == .connecting { return "正在起" }
        if status == .reasserting { return "重手中" }
        if status == .disconnecting { return "正在停" }
        if status == .disconnected { return "断开" }
        return "无效"
    }

    private func describe(_ wantsCutoff: Bool) -> String {
        wantsCutoff ? "掐网" : "放行"
    }
}
