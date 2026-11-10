import Foundation

/// VPN 掐网这一格里、**必须由两个进程共用**的两份判定：
/// 隧道扩展的 bundle id，和「掐完全机网之后留给答题接口那一条活路」的地址。
///
/// 为什么要放在 Kit 而不是各写一份：主 App 负责起停配置，扩展负责真把路由吸进隧道。
/// 那枚「必须放行」的地址如果两边各算各的，就会出现「扩展以为放行了、主 App 没配」
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

    /// 从后端地址里挑出「掐网之后仍要放行」的那一枚 IPv4；挑不出来返回 nil。
    ///
    /// 这一条是 fail-open 的闸，不是配置项：闸门本身要靠 next-question / answer 两个接口判分。
    /// 连它自己都一起掐断了，孩子看到的就不是闸门，而是一台连「答对」都提交不上去的断网手机。
    /// 所以拿不到可放行的 IP 字面量时，两边都必须据此**拒绝起隧道**。
    public static func allowedIPv4(fromBase base: String?) -> String? {
        guard let host = hostOf(base) else { return nil }
        return isIPv4Literal(host) ? host : nil
    }

    /// 给日志用的一句话：后端主机是什么、放行那一格到底成不成立。
    ///
    /// 「放行地址=101.35.194.117」和「放行地址=xxx.com（不是 IPv4 字面量）」在日志里必须长得不一样：
    /// 后者意味着这台设备压根不该开掐网，而前者才意味着真出问题时得去查路由。
    public static func allowedNote(fromBase base: String?) -> String {
        guard let host = hostOf(base) else { return "放行地址=读不到后端主机名" }
        if isIPv4Literal(host) { return "放行地址=" + host }
        return "放行地址=" + host + "（不是 IPv4 字面量）"
    }

    /// 后端地址里没有端口/路径时也一样只要主机那一段。
    private static func hostOf(_ base: String?) -> String? {
        guard let base, let host = URL(string: base)?.host, !host.isEmpty else { return nil }
        return host
    }

    /// 只认点分十进制。域名一律回 false —— 域名要解析才变成 IP，而隧道一起来之后
    /// 连 DNS 都被我们掐了，那时再去解析必然失败，所以放行这一格只能是字面量。
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
