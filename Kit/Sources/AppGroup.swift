import Foundation

/// 主 App 与三个 extension 跑在不同进程里，彼此唯一的共享地面就是这个 App Group。
/// suite 名从各 target 自己的 Info.plist 取（project.yml 里统一定义一次）。
public enum AppGroup {

    public static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "QUIZGATE_APP_GROUP") as? String
    }

    /// 拿不到 suite 名说明 build setting 没灌进 Info.plist，是工程配置错误。
    /// 这里刻意不 fatalError：extension 里崩一次，系统会在每次触发时再崩一次，
    /// 表现成「盾牌永远不来」而且没有任何现场。返回 nil 让调用方记 fault。
    public static var defaults: UserDefaults? {
        guard let identifier else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    public static var containerURL: URL? {
        guard let identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 后端地址。和 App Group 一样只在 project.yml 里定义一次。
    public static var apiBase: String? {
        Bundle.main.object(forInfoDictionaryKey: "QUIZGATE_API_BASE") as? String
    }

    /// 「掐网之后仍要放行」那一条的 IPv4 字面量，同样只在 project.yml 里定义一次。
    /// 为什么不从 apiBase 里取：一条 IPv4 路由只能写地址，而 apiBase 现在是域名，
    /// 域名要先解析才变成 IP —— 解析那一跳也得留出口，见下面的 tunnelAllowDNS 和 VpnPlan.egress。
    public static var tunnelAllowIP: String? {
        Bundle.main.object(forInfoDictionaryKey: "QUIZGATE_TUNNEL_ALLOW_IP") as? String
    }

    /// 掐网档额外放行的那一枚 DNS 服务器 IP，只在后端是域名时才有意义：
    /// 隧道一起来系统 DNS 就被我们自己黑洞掉了，不把这格留给真实接口，域名后端就解析不出来，
    /// 于是取题和判分一起死 —— 那是闸门最不该长成的样子。详见 VpnPlan.egress。
    public static var tunnelAllowDNS: String? {
        Bundle.main.object(forInfoDictionaryKey: "QUIZGATE_TUNNEL_ALLOW_DNS") as? String
    }
}