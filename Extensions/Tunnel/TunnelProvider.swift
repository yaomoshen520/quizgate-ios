import Foundation
import NetworkExtension
import QuizGateKit

/// 我们自己的 packet tunnel provider。
///
/// 这一枚扩展做的事只有一件，而且刻意做得「太狠」：把整机 IPv4 默认路由吸进一条
/// **我们从不读包**的隧道。系统把命中的包交给我们，我们一个都不接、也一个都不还，
/// 于是这台设备除了家长后端那一条 /32 之外彻底断网 —— 这就是 VPN 路线下的「拦截」。
///
/// 为什么不起隧道就不能拦：iOS 侧 DeviceActivity 的阈值回调实测落不下来（授权那一格
/// 一直回 Not Determined），ManagedSettings 的盾牌也就一直没机会真拦住过一次。
/// 断网不需要系统替我们画UI，也不需要前台，是这台设备上唯一一条不依赖授权弹窗的执法通道。
///
/// 为什么本轮不按 App 掐（只掐红果、别照常上网）：`NETunnelProviderManager` 确实有
/// appRules / forPerAppVPN 那一套 per-app VPN，但它是 **app-proxy** 扩展点的能力
/// （`com.apple.networkextension.app-proxy`，见 NETunnelProvider 文档页），要另一枚
/// NEAppProxyProvider 子类。本轮要问系统的问题只有一个 ——
/// 「侧载包里我们自己的这枚 tunnel provider 扩展，系统载不载得起来」，所以一次只动这一个变量。
private let tunnelTag = "tunnel"

/// 起隧道之前自己就断掉的那些情况。走 completionHandler 交回系统，
/// 系统会把它当成这次 startTunnel 的失败原因，主 App 那边读 status 就能看见。
private enum CutoffError: Error {
    /// 放行那一格填不出来。绝不能在这种状态下起隧道：那等于把答题接口自己也掐了。
    case noAllowedHost
}

final class TunnelProvider: NEPacketTunnelProvider {

    /// 签名照 Apple 文档逐字抄：`options` 那一份字典是 `[String: NSObject]?`，不是 `[String: Any]?`
    /// ——写成一字之差的 Any，编译器给的是一句「method does not override any method from its
    /// superclass」（上一轮 CI 就红在这一行），而这句话长得像我们类名写错了，指不到真正的原因。
    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        let stamp = nowMs()
        let base = AppGroup.apiBase
        let note = VpnPlan.allowedNote(fromBase: base)
        DiagLog.record(tunnelTag, "startTunnel 被调，" + note, nowMs: stamp)

        guard let allowed = VpnPlan.allowedIPv4(fromBase: base) else {
            // 断在这里是设计，不是兜底：没有放行地址还起隧道 = 孩子答对也提交不上去。
            DiagLog.record(tunnelTag, "startTunnel 拒绝起隧道：放行那一格填不出来", level: .error, nowMs: nowMs())
            completionHandler(CutoffError.noAllowedHost)
            return
        }

        let settings = Self.buildSettings(allowed: allowed)
        setTunnelNetworkSettings(settings) { err in
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
            completionHandler(err)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let code = String(reason.rawValue)
        DiagLog.record(tunnelTag, "stopTunnel reason=" + code, level: .warn, nowMs: nowMs())
        completionHandler()
    }

    /// 全套网络设置：默认路由吸进隧道，只把家长后端那一条留在外面。
    ///
    /// 每一行的作用与对应证据：
    /// - includedRoutes = 默认路由 ⟹ 所有 IPv4 出网都交给这枚扩展；我们从不读 packetFlow，
    ///   于是这些包有去无回。这就是「断网」的全部机制。
    /// - excludedRoutes = 后端 /32 ⟹ 答题那两跳（取题、判分）仍走真实接口。
    ///   没有它，这道闸门会把孩子锁死在「答对也解不开」上。
    /// - dnsSettings = 黑洞地址 ⟹ 让靠域名干活的 App 连解析这一步都过不去。
    ///   后端是 IP 字面量，不受这一刀影响，所以两条互不打架。
    private static func buildSettings(allowed: String) -> NEPacketTunnelNetworkSettings {
        let v4 = NEIPv4Settings(addresses: [VpnPlan.tunnelIPv4], subnetMasks: [VpnPlan.tunnelIPv4Mask])
        v4.includedRoutes = [NEIPv4Route.default()]
        let keepAlive = NEIPv4Route(destinationAddress: allowed, subnetMask: "255.255.255.255")
        v4.excludedRoutes = [keepAlive]

        let dns = NEDNSSettings(servers: [VpnPlan.blackholeIPv4])

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: VpnPlan.blackholeIPv4)
        settings.ipv4Settings = v4
        settings.dnsSettings = dns
        // 本轮只吸 IPv4。双栈网络下 IPv6 仍然通，是已知缺口而不是漏做：它要另一份
        // NEIPv6Settings，而这一轮要问系统的是「这枚扩展载不载得起来」，多塞一个变量就答不回来了。
        return settings
    }
}

private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
