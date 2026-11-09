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
}