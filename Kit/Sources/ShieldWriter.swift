import Foundation
import FamilyControls
import ManagedSettings

/// 唯一的盾牌写入点。主 App 和 Monitor extension 都走这里，避免两边各写一套写出分歧。
///
/// ManagedSettingsStore 没有进程亲和性：主 App 落的盾，extension 里 new 一个同名
/// 默认 store 就能解。所以不需要跨进程传屏蔽状态，只需要跨进程传「该不该屏蔽」的决策。
public enum ShieldWriter {

    /// 默认 store。刻意不用具名 store：具名 store 的作用域语义没有实证，
    /// 默认 store 被社区两个独立项目验证过跨进程一致。
    private static let store = ManagedSettingsStore()

    public enum ApplyResult: Equatable {
        case applied
        /// 选择解不出来或是空的。**这种情况绝不写 store** ——
        /// 写一个空集合等于把盾清了，是 fail-open。
        case noTokens
    }

    @discardableResult
    public static func apply(selectionData: Data?) -> ApplyResult {
        guard let selection = SelectionArchive.decode(selectionData),
              !SelectionArchive.isEmpty(selection) else {
            return .noTokens
        }
        store.shield.applications = selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens
        return .applied
    }

    public static func clear() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
    }

    /// 幂等写入：只有决策和现状不一致才动 store。
    /// 每个回调都重算全量再走这里，所以丢一次更新也能被下一次纠正。
    /// - Returns: 是否真的写了。调用方据此决定要不要更新 state.shieldApplied。
    @discardableResult
    public static func reconcile(decision: GateDecision, state: inout SharedState) -> Bool {
        guard GatePolicy.needsShieldWrite(decision: decision, currentlyApplied: state.shieldApplied) else {
            return false
        }
        if decision.wantsShield {
            guard apply(selectionData: state.selectionData) == .applied else {
                state.recordFault("要落盾但选不出 App，盾牌保持原样")
                return false
            }
            state.shieldApplied = true
        } else {
            clear()
            state.shieldApplied = false
        }
        return true
    }
}