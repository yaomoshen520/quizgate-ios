import Foundation
import ManagedSettings
import ManagedSettingsUI
import QuizGateKit

/// 孩子点了盾牌上的按钮之后走到这里。
///
/// 这里**不做解盾**。解盾的唯一条件是「在主 App 里答对题」，
/// 如果点一下按钮就放行，整个闸门等于没有。
///
/// 签名是照着 iOS 26.5 的 ManagedSettings.swiftinterface 写的：
/// handle(action:for:completionHandler:) 返回 Void，答案靠回调交回系统；
/// 之前按「同步 return ShieldActionResponse」写，系统里根本没有这个要求，
/// 于是三个 override 全部报 does not override any method from its superclass。
final class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction,
                         for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        complete(completionHandler)
    }

    override func handle(action: ShieldAction,
                         for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        complete(completionHandler)
    }

    override func handle(action: ShieldAction,
                         for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        complete(completionHandler)
    }

    /// 每条路径都必须且只能回调一次：不回调盾牌卡住，回调两次系统侧行为未定义。
    private func complete(_ completionHandler: (ShieldActionResponse) -> Void) {
        // 只记一笔「孩子撞到了盾牌」，让主 App 下次前台时补报给家长。
        // extension 里发网络只能 fire-and-forget，所以这里优先落盘。
        StateStore.mutate { state in
            state.recordFault("孩子点开了被挡的 App，等待答题")
            OutboxStore.enqueue(
                PendingReport(
                    path: "gate-event",
                    payload: (try? shieldTappedRequest(state: state).serializedData()) ?? Data(),
                    createdAtMs: state.nowMs()
                ),
                to: AppGroup.defaults ?? UserDefaults.standard
            )
        }
        DarwinSignal.post()

        // SDK 里确实有 ShieldActionResponse.openParentalControlsApp（26.5 起），
        // 用它把孩子直接送到答题界面本来更顺。但这里刻意不用，两个原因：
        // 1) 它是 26.5 SDK 才有的符号，CI 那台 macos-15 的 SDK 更旧，
        //    即使写 if #available(iOS 26.5) 也编不过 —— 缺的是声明不是运行时；
        // 2) 「跳到家长管控 App」会不会顺手把盾牌放行，我没有实测过；
        //    在没验证之前，闸门不能依赖一个行为未知的响应。
        // 26.5 以下社区流传 URL scheme 的写法，实测报告说不通（issue #81/#60），
        // 所以也不搬那个 hack：关盾牌，靠文案让孩子自己去开 QuizGate。
        completionHandler(.close)
    }

    private func shieldTappedRequest(state: SharedState) -> Quizgate_GateEventReportRequest {
        var event = Quizgate_GateEvent()
        event.eventID = UUID().uuidString
        event.kind = .gateInterrupted
        event.occurredAtMs = state.nowMs()
        event.detail = "孩子撞到了盾牌，还没答题"
        var request = Quizgate_GateEventReportRequest()
        request.events = [event]
        return request
    }
}