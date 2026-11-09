import Foundation
import FamilyControls

/// FamilyActivitySelection 的归档。
///
/// 里面的 ApplicationToken / CategoryToken 是**不透明**的：不能转成 bundle id，
/// 不能传到后端再传回来，也不能指望换台设备还能解。所以家长选 App 这一步
/// 必须在孩子这台机器上跑一次，之后只在本机原样存、原样还原。
///
/// 用 Codable 而不是 NSKeyedArchiver：社区两种写法都有，Codable 更短且失败可捕获。
public enum SelectionArchive {

    public static func encode(_ selection: FamilyActivitySelection) -> Data? {
        try? JSONEncoder().encode(selection)
    }

    /// 解不出来回 nil，绝不抛、绝不强解包。
    /// 调用方拿到 nil 的正确反应是「保持盾牌现状 + 记 fault」，不是清盾。
    public static func decode(_ data: Data?) -> FamilyActivitySelection? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    public static func isEmpty(_ selection: FamilyActivitySelection) -> Bool {
        selection.applicationTokens.isEmpty
            && selection.categoryTokens.isEmpty
            && selection.webDomainTokens.isEmpty
    }
}