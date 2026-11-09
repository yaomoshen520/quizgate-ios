import XCTest
@testable import QuizGateKit

final class GatePolicyTests: XCTestCase {

    private let now: Int64 = 1_700_000_000_000

    private func approvedState(threshold: Int = 30, daily: Int = 0,
                               enabled: Bool = true, playedMs: Int64 = 0) -> SharedState {
        var state = SharedState(installId: "test-install")
        state.authorization = AuthorizationState(raw: "approved", checkedAtMs: now)
        state.selectionData = Data([0x01, 0x02])
        state.rule = RuleState(thresholdMinutes: threshold, dailyLimitMinutes: daily,
                               graceMinutes: 2, enabled: enabled, version: 1)
        state.ledger.playedMs = playedMs
        return state
    }

    // MARK: - 不能执行的那一档（这一档最容易被写成 allow，那就是 fail-open）

    func testMissingAuthorizationIsCannotEnforceNotAllow() {
        var state = approvedState()
        state.authorization = nil
        let decision = GatePolicy.decide(state, nowMs: now)
        XCTAssertEqual(decision, .cannotEnforce(.notAuthorized))
        // 反例断言：如果哪天有人把它改成 .allow，这两条会红。
        XCTAssertNotEqual(decision, .allow(.underThreshold))
        XCTAssertFalse(decision.wantsShield)
    }

    func testDeniedAuthorizationIsCannotEnforce() {
        var state = approvedState()
        state.authorization = AuthorizationState(raw: "denied", checkedAtMs: now)
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .cannotEnforce(.notAuthorized))
    }

    func testUnknownAuthorizationRawValueIsNotTreatedAsApproved() {
        var state = approvedState()
        state.authorization = AuthorizationState(raw: "someFutureSystemState", checkedAtMs: now)
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .cannotEnforce(.notAuthorized))
    }

    func testEmptySelectionIsCannotEnforce() {
        var state = approvedState()
        state.selectionData = Data()
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .cannotEnforce(.noSelection))
    }

    func testMissingRuleIsCannotEnforce() {
        var state = approvedState()
        state.rule = nil
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .cannotEnforce(.noRule))
    }

    // MARK: - 家长关掉了

    func testDisabledRuleAllows() {
        let state = approvedState(enabled: false, playedMs: 999 * 60_000)
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .allow(.disabledByParent))
    }

    /// 对齐 Android SpikeSettings.cycleRule()：thresholdMinutes <= 0 不跟随服务端规则。
    func testNonPositiveThresholdAllows() {
        for threshold in [0, -1] {
            let state = approvedState(threshold: threshold, playedMs: 999 * 60_000)
            XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .allow(.disabledByParent),
                           "threshold=\(threshold) 应当视为不启用")
        }
    }

    // MARK: - 阈值边界

    func testExactlyAtThresholdShields() {
        let state = approvedState(threshold: 30, playedMs: 30 * 60_000)
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .shield(.thresholdReached))
    }

    func testOneMillisecondUnderThresholdAllows() {
        let state = approvedState(threshold: 30, playedMs: 30 * 60_000 - 1)
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .allow(.underThreshold))
    }

    /// 日限额不再由 ledger.playedMs 推：playedMs 每轮清零，用它当「今天一共玩了多久」
    /// 等于答对一次就把当天的账抹平，日限额永远到不了。它只能来自横跨全天的那条活动。
    func testDailyLimitComesFromTheDayFlagNotTheCycleLedger() {
        var state = approvedState(threshold: 30, daily: 60, playedMs: 0)
        state.dailyLimitReachedOnDay = GatePolicy.dayIndex(now)
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .shield(.dailyLimitReached))
    }

    func testDailyLimitTakesPrecedenceOverThreshold() {
        var state = approvedState(threshold: 30, daily: 60, playedMs: 60 * 60_000)
        state.dailyLimitReachedOnDay = GatePolicy.dayIndex(now)
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .shield(.dailyLimitReached))
    }

    func testZeroDailyLimitMeansNoDailyCap() {
        var state = approvedState(threshold: 30, daily: 0, playedMs: 29 * 60_000)
        state.dailyLimitReachedOnDay = GatePolicy.dayIndex(now)
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .allow(.underThreshold),
                       "dailyLimitMinutes=0 表示不限，那这条标记就不该有拦人的效力")
    }

    /// 隔天的旧标记必须失效：否则一次「今天用完了」会把这台机器永久锁死，
    /// 家长第二天看到的是一个再也答不开的门。
    func testStaleDailyLimitFlagFromYesterdayDoesNotShield() {
        var state = approvedState(threshold: 30, daily: 60, playedMs: 0)
        state.dailyLimitReachedOnDay = GatePolicy.dayIndex(now) - 1
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .allow(.underThreshold))
    }

    /// 放行窗仍然排在日限额前面（沿用改动前的顺序，不是这次新定的语义）：
    /// 日限额已到的那一刻答对一道题，买回的是一个阈值长度的窗口，不是立刻再拦。
    func testDailyLimitYieldsToAFreshUnlockWindow() {
        var state = approvedState(threshold: 30, daily: 60, playedMs: 0)
        state.dailyLimitReachedOnDay = GatePolicy.dayIndex(now)
        state.ledger.unlockUntilMs = now + 60_000
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .allow(.quizPassed))
    }

    // MARK: - 答对放行窗口

    func testInsideUnlockWindowAllowsEvenOverThreshold() {
        var state = approvedState(threshold: 30, playedMs: 90 * 60_000)
        state.ledger.unlockUntilMs = now + 60_000
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .allow(.quizPassed))
    }

    func testUnlockWindowEndIsExclusive() {
        var state = approvedState(threshold: 30, playedMs: 90 * 60_000)
        state.ledger.unlockUntilMs = now
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .shield(.thresholdReached),
                       "到期那一刻就应当重新落盾，不能多放一毫秒")
    }

    /// 放行判定必须走传入的服务器基准时间。孩子把系统时钟往后拨，
    /// 只要 clockOffsetMs 是从服务器校出来的，窗口就不会被凭空延长。
    func testDecisionUsesInjectedClockNotWallClock() {
        var state = approvedState(threshold: 30, playedMs: 90 * 60_000)
        state.ledger.unlockUntilMs = now + 60_000
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now + 120_000), .shield(.thresholdReached))
    }

    func testNewCycleClearsCountsAndOpensWindow() {
        let rule = RuleState(thresholdMinutes: 30, dailyLimitMinutes: 120,
                             graceMinutes: 2, enabled: true, version: 3)
        let ledger = GatePolicy.startNewCycle(afterCorrectAt: now, rule: rule)
        XCTAssertEqual(ledger.playedMs, 0)
        XCTAssertEqual(ledger.correctCount, 0)
        XCTAssertEqual(ledger.wrongCount, 0)
        XCTAssertEqual(ledger.unlockUntilMs, now + 30 * 60_000)
    }

    // MARK: - 回调去重与幂等

    /// 2026-11-09「答对之后当天再也不落盾」那条 bug 的回归。
    ///
    /// processedEventIds 挂在 SharedState 上，而 startNewCycle 只换 ledger，
    /// 所以账本清零之后**同一批事件名重放是不算数的**。重新落盾的唯一出路是
    /// 新一轮换一套事件 id —— 现在由 MonitoringController 按本轮起点毫秒生成活动名。
    /// 下面两组断言是一对的：旧名重放必须加不回时长，新名必须能重新跨过阈值。
    /// 只有其中一半的话，这个测试自己就是假绿的。
    func testNewRoundNeedsFreshEventIdsBecauseProcessedSetSurvivesTheReset() {
        let rule = RuleState(thresholdMinutes: 1, dailyLimitMinutes: 120,
                             graceMinutes: 2, enabled: true, version: 1)
        var state = approvedState(threshold: 1, daily: 120)
        state = GatePolicy.accumulate(state, thresholdMinutes: 1, eventId: "quizgate.c1|step-0|5")
        XCTAssertEqual(GatePolicy.decide(state, nowMs: now), .shield(.thresholdReached))

        state.ledger = GatePolicy.startNewCycle(afterCorrectAt: now, rule: rule)
        let afterCorrectAt = now + 61_000   // 放行窗（1 分钟）已过
        XCTAssertEqual(GatePolicy.decide(state, nowMs: afterCorrectAt), .allow(.underThreshold))

        let replay = GatePolicy.accumulate(state, thresholdMinutes: 1, eventId: "quizgate.c1|step-0|5")
        XCTAssertEqual(replay.ledger.playedMs, 0, "上一轮的事件名重放不能再算一次时长")
        XCTAssertEqual(GatePolicy.decide(replay, nowMs: afterCorrectAt), .allow(.underThreshold))

        let nextRound = GatePolicy.accumulate(state, thresholdMinutes: 1, eventId: "quizgate.c2|step-0|5")
        XCTAssertEqual(nextRound.ledger.playedMs, 60_000)
        XCTAssertEqual(GatePolicy.decide(nextRound, nowMs: afterCorrectAt), .shield(.thresholdReached))
    }

    func testSameEventIdDoesNotDoubleCount() {
        let state = approvedState()
        let once = GatePolicy.accumulate(state, thresholdMinutes: 15, eventId: "evt-1")
        let twice = GatePolicy.accumulate(once, thresholdMinutes: 15, eventId: "evt-1")
        XCTAssertEqual(once.ledger.playedMs, 15 * 60_000)
        XCTAssertEqual(twice.ledger.playedMs, 15 * 60_000, "重复回调不能再加一次时长")
    }

    func testDifferentEventIdsAccumulate() {
        let state = approvedState()
        let once = GatePolicy.accumulate(state, thresholdMinutes: 15, eventId: "evt-1")
        let twice = GatePolicy.accumulate(once, thresholdMinutes: 15, eventId: "evt-2")
        XCTAssertEqual(twice.ledger.playedMs, 30 * 60_000)
    }

    func testEmptyEventIdIsIgnored() {
        let state = approvedState()
        let next = GatePolicy.accumulate(state, thresholdMinutes: 15, eventId: "")
        XCTAssertEqual(next.ledger.playedMs, 0)
    }

    func testShieldWriteIsIdempotent() {
        XCTAssertTrue(GatePolicy.needsShieldWrite(decision: .shield(.thresholdReached), currentlyApplied: false))
        XCTAssertFalse(GatePolicy.needsShieldWrite(decision: .shield(.thresholdReached), currentlyApplied: true))
        XCTAssertTrue(GatePolicy.needsShieldWrite(decision: .allow(.quizPassed), currentlyApplied: true))
        XCTAssertFalse(GatePolicy.needsShieldWrite(decision: .allow(.quizPassed), currentlyApplied: false))
    }

    /// cannotEnforce 不该被当成「要落盾」——落不了，写了也是白写还会把状态记成已落。
    func testCannotEnforceNeverRequestsShieldWrite() {
        for reason in CannotEnforceReason.allCases {
            XCTAssertFalse(GatePolicy.needsShieldWrite(decision: .cannotEnforce(reason), currentlyApplied: false))
        }
    }
}