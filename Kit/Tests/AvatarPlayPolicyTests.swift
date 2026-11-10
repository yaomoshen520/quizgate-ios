import XCTest
@testable import QuizGateKit

/// iOS 判定 → 上报档位（`HeartbeatRequest.play_state`）的口径单测。
///
/// 这份映射是跨端视觉契约里写死的那一段：家长后台那只狐狸按 play_state 动，
/// 两端报的不一样，后台同一列里就是两个功能。Android 那一份是
/// `ReportChannel.protoPlayState` + `GateAccessibilityService.playState()`，
/// 这里的次序刻意与它**差一格**（放行窗口并入 playing），理由写在 AvatarState.swift 的注释里，
/// 这个文件钉的是"差完之后每一格落在哪"。
final class AvatarPlayPolicyTests: XCTestCase {

    private func state(playedMs: Int64 = 0,
                       warningSeconds: Int? = nil,
                       monitoring: Bool = true) -> SharedState {
        var s = SharedState()
        s.rule = RuleState(thresholdMinutes: 10, dailyLimitMinutes: 60, graceMinutes: 5,
                           enabled: true, version: 1, warningSeconds: warningSeconds)
        s.ledger = Ledger(playedMs: playedMs)
        s.monitoringStartedAtMs = monitoring ? 1_000 : nil
        return s
    }

    private func decide(_ decision: GateDecision,
                        question: Bool = false,
                        playedMs: Int64 = 0,
                        warningSeconds: Int? = nil,
                        monitoring: Bool = true) -> AvatarPlayState {
        AvatarPlayPolicy.decide(state(playedMs: playedMs,
                                      warningSeconds: warningSeconds,
                                      monitoring: monitoring),
                                decision: decision,
                                questionOnScreen: question,
                                nowMs: 0)
    }

    func testQuestionOnScreenWinsOverEverythingElse() {
        // 题都摆在屏幕上了还报别的，等于告诉家长"孩子没在被拦"。
        XCTAssertEqual(decide(.allow(.underThreshold), question: true), .quiz)
        XCTAssertEqual(decide(.shield(.thresholdReached), question: true), .quiz)
        XCTAssertEqual(decide(.cannotEnforce(.notAuthorized), question: true), .quiz)
    }

    func testShieldMeansQuizEvenWithNoQuestionOnScreen() {
        // iOS 没有 Android 那个"题已发出、浮窗在等"的中间态：掐网与提示是同一秒发生的，
        // 孩子面对的就已经是"去答题"。
        XCTAssertEqual(decide(.shield(.thresholdReached)), .quiz)
        XCTAssertEqual(decide(.shield(.dailyLimitReached)), .quiz)
    }

    func testGateNotOnDutyIsIdleNeverPlaying() {
        // 闸门没在岗时不许报"在玩"：那是我们不知道，不是孩子没玩。
        XCTAssertEqual(decide(.cannotEnforce(.noRule)), .idle)
        XCTAssertEqual(decide(.cannotEnforce(.notAuthorized)), .idle)
        XCTAssertEqual(decide(.allow(.disabledByParent)), .idle)
        // 一轮没开过（monitoringStartedAtMs 是 nil）同理：没有"这一轮"，就谈不上在玩。
        XCTAssertEqual(decide(.allow(.underThreshold), monitoring: false), .idle)
    }

    func testWarningUsesTheServerThresholdNotALocalGuess() {
        // 10 分钟阈值，已玩 9 分半：剩 30 秒。warning_seconds=60 就该亮，=10 就不该。
        XCTAssertEqual(decide(.allow(.underThreshold), playedMs: 570_000, warningSeconds: 60), .warning)
        XCTAssertEqual(decide(.allow(.underThreshold), playedMs: 570_000, warningSeconds: 10), .playing)
        XCTAssertEqual(decide(.allow(.underThreshold), playedMs: 570_000, warningSeconds: nil), .playing)
        XCTAssertEqual(decide(.allow(.underThreshold), playedMs: 570_000, warningSeconds: 0), .playing)
        // 已经用满（remaining <= 0）不是"快到了"，是"到了"：那一档由落盾表达，不由表情表达。
        XCTAssertEqual(decide(.allow(.underThreshold), playedMs: 600_000, warningSeconds: 60), .playing)
    }

    func testPlayingIsTheDefaultWhileARoundIsOpen() {
        XCTAssertEqual(decide(.allow(.underThreshold), playedMs: 60_000), .playing)
        XCTAssertEqual(decide(.allow(.quizPassed), playedMs: 60_000), .playing)
    }

    /// 六档里有两档在 iOS 恒不可达，这是能力边界不是漏做（见 AvatarState.swift 的注释）。
    /// 这里把判定面整格扫一遍钉住它：哪天有人"顺手"让 iOS 也报 paused，这个测试先红。
    func testPendingParentAndPausedAreNeverReported() {
        let decisions: [GateDecision] = [
            .shield(.thresholdReached), .shield(.dailyLimitReached),
            .allow(.underThreshold), .allow(.quizPassed), .allow(.disabledByParent),
            .cannotEnforce(.notAuthorized), .cannotEnforce(.noSelection),
            .cannotEnforce(.noRule), .cannotEnforce(.stateCorrupt),
        ]
        let played: [Int64] = [0, 300_000, 570_000, 600_000, 900_000]
        for decision in decisions {
            for question in [false, true] {
                for ms in played {
                    for warning in [nil as Int?, 10, 60] {
                        let got = decide(decision, question: question, playedMs: ms,
                                         warningSeconds: warning)
                        XCTAssertNotEqual(got, .pendingParent,
                                          "\(decision)/q\(question)/\(ms)/w\(String(describing: warning))")
                        XCTAssertNotEqual(got, .paused,
                                          "\(decision)/q\(question)/\(ms)/w\(String(describing: warning))")
                    }
                }
            }
        }
    }

    /// 反例闸：上面那个"恒不可达"的扫法，如果判定面里真有一格能报出 paused，
    /// 这个测试要能看见——把 isWarning 换成恒真，它就该红在 .warning 上。
    /// （这里直接断言可达的那四档确实都被扫到过，证明循环不是空转。）
    func testTheSweepActuallyReachesEveryReachableState() {
        var seen = Set<AvatarPlayState>()
        for question in [false, true] {
            for ms in [0, 300_000, 570_000, 600_000] as [Int64] {
                seen.insert(decide(.allow(.underThreshold), question: question,
                                   playedMs: ms, warningSeconds: 60))
                seen.insert(decide(.cannotEnforce(.noRule), question: question, playedMs: ms))
                seen.insert(decide(.shield(.thresholdReached), question: question, playedMs: ms))
            }
        }
        XCTAssertEqual(seen, Set([.quiz, .playing, .warning, .idle]))
    }
}
