import Foundation
import ManagedSettings
import ManagedSettingsUI
import QuizGateKit

/// 孩子点了盾牌上的按钮之后走到这里。
///
/// 这里**不做解盾**。解盾的唯一条件是「在主 App 里答对题」，
/// 如果点一下按钮就放行，整个闸门等于没有。
final class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken) -> ShieldActionResponse {
        handle()
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken) -> ShieldActionResponse {
        handle()
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken) -> ShieldActionResponse {
        handle()
    }

    private func handle() -> ShieldActionResponse {
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

        // iOS 26.5 起有官方的「打开家长管控 App」响应。
        // 26.5 以下社区流传 URL scheme 的写法，但实测报告说不通（issue #81/#60），
        // 所以这里不搬那个未验证的 hack：直接关闭盾牌，靠文案让孩子自己去开 QuizGate。
        if #available(iOS 26.5, *) {
            return .openParentalControlsApp
        }
        return .close
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