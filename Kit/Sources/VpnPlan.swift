import Foundation

/// VPN 掐网这一格里、**必须由两个进程共用**的判定：隧道扩展的 bundle id，
/// 和「掐完全机网之后仍要留给答题那一条活路」的出口地址（后端那枚 IP，加上域名后端所需的 DNS）。
///
/// 为什么要放在 Kit 而不是各写一份：主 App 负责起停配置，扩展负责真把路由吸进隧道。
/// 这些「必须放行」的地址如果两边各算各的，就会出现「扩展以为放行了、主 App 没配」
/// 这种两边都自洽、孩子却永久断网的状态 —— 而这条链上唯一能被远程读到的证据只有日志，
/// 日志里两处说法不一样时，查的人只会更困惑。
public enum VpnPlan {

    /// 隧道扩展的 bundle id。必须与 project.yml 里那枚 target 的
    /// PRODUCT_BUNDLE_IDENTIFIER 逐字相同：主 App 就是拿这个串在系统偏好里认出「这是我们自己的
    /// 那份 VPN 配置」，认不出就会每 30 秒新建一份，把孩子设置里的 VPN 列表刷成一排。
    public static let providerBundleId = "com.quizgate.ios.tunnel"

    /// 隧道自己的虚拟网卡地址。刻意挑 10/8 里一段后端用不到的：
    /// 家长后端在 101/8，两边不重叠。重叠的话 excludedRoutes 那一条会被自己的网卡地址吃掉，
    /// 表现成「配置全对但答题请求就是出不去」。
    public static let tunnelIPv4 = "10.250.0.1"
    public static let tunnelIPv4Mask = "255.255.255.0"

    /// 一枚永不答应的地址（RFC 5737 TEST-NET-1，标准保留、公网不可能路由）。
    /// 当 DNS 服务器用 = 靠域名找服务器的 App 连「这域名是谁」都问不出来；
    /// 同时当 tunnelRemoteAddress 用 = 那一条只是给系统看的描述，我们并不真要连过去。
    public static let blackholeIPv4 = "192.0.2.1"

    /// 挑出「掐网之后仍要放行」的那一枚 IPv4；挑不出来返回 nil。
    ///
    /// 这一条是 fail-open 的闸，不是配置项：闸门本身要靠 next-question / answer 两个接口判分。
    /// 连它自己都一起掐断了，孩子看到的就不是闸门，而是一台连「答对」都提交不上去的断网手机。
    /// 所以拿不到可放行的 IP 字面量时，两边都必须据此**拒绝起隧道**。
    ///
    /// `override` 是单独配的那枚 IP（`QUIZGATE_TUNNEL_ALLOW_IP`），配了就优先用它：
    /// 后端地址现在是域名，从域名里永远取不出字面量，而放行这一格按设计只能是 IPv4 字面量。
    /// override 存在却不是合法字面量时也回 nil —— 那是配置写错了，此时宁可不起隧道，
    /// 也不去猜「那用 base 里那枚吧」，因为猜错的方向是把孩子的网掐了却没留活路。
    public static func allowedIPv4(fromBase base: String?, override: String? = nil) -> String? {
        if let literal = allowOverride(override) {
            return isIPv4Literal(literal) ? literal : nil
        }
        guard let host = hostOf(base) else { return nil }
        return isIPv4Literal(host) ? host : nil
    }

    /// 给日志用的一句话：放行那一格到底成不成立、成的是哪一路。
    ///
    /// 「放行地址=101.35.194.117」和「放行地址=xxx.com（不是 IPv4 字面量）」在日志里必须长得不一样：
    /// 后者意味着这台设备压根不该开掐网，而前者才意味着真出问题时得去查路由。
    /// 单独配的那枚也必须留痕：查的人要能分清「放行的是 build setting 里那枚 IP」
    /// 和「放行的是从后端地址顺手取的那枚」。
    public static func allowedNote(fromBase base: String?, override: String? = nil) -> String {
        let tag = "（单独配的放行 IP）"
        if let literal = allowOverride(override) {
            if isIPv4Literal(literal) { return "放行地址=" + literal + tag }
            return "放行地址=" + literal + "（单独配的放行 IP 不是 IPv4 字面量）"
        }
        guard let host = hostOf(base) else { return "放行地址=读不到后端主机名" }
        if isIPv4Literal(host) { return "放行地址=" + host }
        return "放行地址=" + host + "（不是 IPv4 字面量，且没配单独放行 IP）"
    }

    /// 单独配的那枚放行 IP：没配、空串、只有空白都当成「没配」，好让 base 那一路继续生效。
    private static func allowOverride(_ override: String?) -> String? {
        guard let override else { return nil }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 掐网档要放行的出口：答题接口那一枚 IP，加上（后端是域名时）DNS 那几枚。
    public struct Egress: Equatable {
        public let apiIPv4: String
        /// 空数组 = 这一档不往外放 DNS，系统 DNS 继续指向黑洞地址。
        /// 之所以允许配两枚：公共 DNS 会被个别运营商拦，只留一枚时那一拦的失败方向是
        /// 「孩子答对也提交不上去」，而不是「多问了一次 DNS」。
        public let dnsIPv4s: [String]

        public init(apiIPv4: String, dnsIPv4s: [String]) {
            self.apiIPv4 = apiIPv4
            self.dnsIPv4s = dnsIPv4s
        }
    }

    /// 一次算清「这台设备能不能开掐网」。两个进程都只读这一条判据，
    /// 因为这两格任何一格填不出来都会走成同一个样子：掐了网、孩子答对也提交不上去。
    ///
    /// - 后端是 IP 字面量：不需要 DNS 出口（我们自己的请求根本不查域名），那一格留空。
    /// - 后端是域名：**必须**有单独配好的 DNS 出口。隧道一起来系统 DNS 就被我们自己黑洞掉了，
    ///   那时连「服务器是谁」都问不出来，放行那枚 IP 也就永远用不上。
    ///
    /// 回 nil 一律据此拒绝起隧道，不做「先起了再说」的猜测。
    public static func egress(fromBase base: String?,
                              allowIP: String? = nil,
                              allowDNS: String? = nil) -> Egress? {
        guard let host = hostOf(base) else { return nil }
        guard let api = allowedIPv4(fromBase: base, override: allowIP) else { return nil }
        if isIPv4Literal(host) {
            return Egress(apiIPv4: api, dnsIPv4s: [])
        }
        guard let dns = dnsExit(allowDNS) else { return nil }
        return Egress(apiIPv4: api, dnsIPv4s: dns)
    }

    /// 逗号分隔的 DNS 出口。空白项丢掉；任何一项不是 IPv4 字面量就整条判负（回 nil）。
    ///
    /// 判负而不是「只跳过写坏的那一项」：配错一项还照样起隧道，等于把「到底放行了几枚」
    /// 变成只有系统知道的事 —— 这条链上能远程读到的证据只有我们自己的日志，那种分裂查不出来。
    static func dnsExit(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        var out: [String] = []
        for piece in raw.split(separator: ",") {
            let host = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty { continue }
            guard isIPv4Literal(host) else { return nil }
            out.append(host)
        }
        return out.isEmpty ? nil : out
    }

    /// egress 的日志版：两格各自的成立与否都要写出来，缺哪一格写哪一格。
    ///
    /// 「没配 DNS 出口」和「放行 IP 那格填不出来」在远程日志里必须是两句话：
    /// 前者去改 build setting，后者去查路由。
    public static func egressNote(fromBase base: String?,
                                  allowIP: String? = nil,
                                  allowDNS: String? = nil) -> String {
        let api = allowedNote(fromBase: base, override: allowIP)
        guard let host = hostOf(base) else { return api + "，后端地址读不到，掐网这一档不能开" }
        if isIPv4Literal(host) { return api + "，后端是 IP 字面量，不需要放行 DNS" }
        let head = api + "，后端是域名，放行 DNS="
        if let dns = dnsExit(allowDNS) { return head + dns.joined(separator: "、") }
        let configured = allowOverride(allowDNS)
        if let configured { return head + configured + "（里面有不是 IPv4 字面量的项）" }
        return head + "没配"
    }

    /// 后端地址里没有端口/路径时也一样只要主机那一段。
    private static func hostOf(_ base: String?) -> String? {
        guard let base, let host = URL(string: base)?.host, !host.isEmpty else { return nil }
        return host
    }

    /// 只认点分十进制。域名一律回 false —— 一条 IPv4 路由只能写地址，写域名的那一格
    /// 系统不会报错，只会让那条放行路由悄悄不生效，而它不生效的形状正是「孩子被锁死」。
    static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard part.count <= 3, part.allSatisfy({ $0.isNumber }),
                  let value = Int(part), value <= 255 else { return false }
        }
        return true
    }
}
