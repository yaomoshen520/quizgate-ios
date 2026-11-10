import XCTest
@testable import QuizGateKit

/// 「主 App 说的该掐」和「扩展算的该掐」必须是同一件事 —— 这两边算歪时的长相恰好是
/// 两边都自洽、孩子却永久断网，而那条链上唯一能被远程读到的证据只有日志。
/// 所以这本文档不写「看起来对」，逐条写反例：故意把某个时刻挪错，断言必须翻。
final class VpnIntentTests: XCTestCase {

    private let server: Int64 = 1_700_000_000_000

    /// 设备墙钟比服务器基准慢 60 秒 —— 故意不是整数倍，这样「忘了换算」一定会被读出来。
    private var local: Int64 { server - 60_000 }

    /// 一个测试实例一个临时目录。刻意存下来而不是每次现算：
    /// 上一版这里写成计算属性，于是「setUp 交给 store 的那一格」和「用例自己手写坏文件的那一格」
    /// 是两个不同 UUID 的目录 —— 写失败的 `try?` 把错吞了，`read()` 读到 nil 反而让断言变绿。
    /// 那两条红就是这道坑自己报的账。
    private let dir: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quizgate-intent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    override func setUp() {
        super.setUp()
        VpnIntentStore.testDirectory = dir
    }

    override func tearDown() {
        VpnIntentStore.testDirectory = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// 手搓一份意图，让每一档都能单独挪动。`end` 默认 `Int64.max` = 这份排期永不过期，
    /// 于是大多数用例只能在「到没到点」这一格上做断言，不会被过期那一档混掉。
    private func intent(armed: Bool = true, cutoffAt: Int64, unlock: Int64? = nil,
                        end: Int64 = Int64.max, seq: Int = 0) -> VpnIntent {
        VpnIntent(armed: armed, cutoffAtLocalMs: cutoffAt, unlockUntilLocalMs: unlock,
                  notAfterLocalMs: end, reason: "test", seq: seq, writtenAtLocalMs: local)
    }

    // MARK: - 判据本身

    func testPastDeadlineCutsOff() {
        XCTAssertEqual(intent(cutoffAt: local - 1).route(atLocal: local), .cutoff)
    }

    func testFutureDeadlinePasses() {
        // 反例校验：把上面那条的到点时刻挪到未来就必须换成放行，否则这条判据是假绿的。
        XCTAssertEqual(intent(cutoffAt: local + 1).route(atLocal: local), .pass)
    }

    func testUnlockWindowOutranksDeadline() {
        // 答对买回来的窗口压过到点：这是 GatePolicy 的既有顺序（quizPassed 判在阈值之前），
        // 挪到这个顺序之前，孩子答对之后会被立刻再掐一次。
        let cut = intent(cutoffAt: local - 1, unlock: local + 60_000)
        XCTAssertEqual(cut.route(atLocal: local), .pass)
        XCTAssertEqual(cut.route(atLocal: local + 120_000), .cutoff)
    }

    func testDisabledGateNeverCutsOff() {
        let off = intent(armed: false, cutoffAt: local - 10_000)
        XCTAssertEqual(off.route(atLocal: local), .pass)
        XCTAssertNotEqual(off.route(atLocal: local), .cutoff)
    }

    func testExpiredScheduleFallsBackToPass() {
        // 排期过期的那一档必须回放行：主 App 一整天没回来重排时，
        // 继续掐着就成了「没人能解开的断网」，那是砖不是闸门。
        let stale = intent(cutoffAt: local - 10_000, end: local - 1)
        XCTAssertEqual(stale.route(atLocal: local), .pass)
        XCTAssertNotEqual(stale.route(atLocal: local), .cutoff)
        // 而同一份排期在上界之内仍然该掐 —— 证明上面那条不是因为 armed 或 deadline 通过。
        let fresh = intent(cutoffAt: local - 10_000, end: local + 1)
        XCTAssertEqual(fresh.route(atLocal: local), .cutoff)
    }

    // MARK: - 与 GatePolicy 对齐

    private func approvedState(threshold: Int = 30, daily: Int = 0, enabled: Bool = true,
                               playedMs: Int64 = 0, unlockUntil: Int64? = nil) -> SharedState {
        var state = SharedState(installId: "test-install")
        state.authorization = AuthorizationState(raw: "approved", checkedAtMs: server)
        state.selectionData = Data([0x01, 0x02])
        state.rule = RuleState(thresholdMinutes: threshold, dailyLimitMinutes: daily,
                               graceMinutes: 2, enabled: enabled, version: 1)
        state.ledger.playedMs = playedMs
        state.ledger.unlockUntilMs = unlockUntil
        return state
    }

    func testShieldDecisionBuildsArmedCutoffIntent() {
        var state = approvedState(playedMs: 30 * 60_000)
        state.monitoringStartedAtMs = server - 30 * 60_000
        let decision = GatePolicy.decide(state, nowMs: server)
        XCTAssertEqual(decision, .shield(.thresholdReached))
        let built = VpnIntentPlan.build(state: state, decision: decision, seq: 1,
                                        nowMs: server, localNowMs: local)
        XCTAssertTrue(built.armed)
        XCTAssertEqual(built.route(atLocal: local), .cutoff)
    }

    func testUnderThresholdBuildsPassingIntent() {
        var state = approvedState(playedMs: 5 * 60_000)
        state.monitoringStartedAtMs = server - 5 * 60_000
        let decision = GatePolicy.decide(state, nowMs: server)
        XCTAssertEqual(decision, .allow(.underThreshold))
        let built = VpnIntentPlan.build(state: state, decision: decision, seq: 1,
                                        nowMs: server, localNowMs: local)
        XCTAssertTrue(built.armed)
        XCTAssertEqual(built.route(atLocal: local), .pass)
        // 到点之后（阈值 30 分钟，本轮起点在 5 分钟前）必须由同一条判据自己推进到掐网，
        // 而不是等主 App 回来改写 —— 这一条就是本轮换形的全部内容。
        let due = local + 25 * 60_000
        XCTAssertEqual(built.route(atLocal: due), .cutoff)
        XCTAssertNotEqual(built.route(atLocal: due), .pass)
    }

    func testDailyLimitKeepsCuttingOffAfterTheQuizWindow() {
        var state = approvedState(threshold: 10, daily: 60, playedMs: 60 * 60_000)
        state.dailyLimitReachedOnDay = GatePolicy.dayIndex(server)
        state.monitoringStartedAtMs = server - 60 * 60_000
        let decided = GatePolicy.decide(state, nowMs: server)
        XCTAssertEqual(decided, .shield(.dailyLimitReached))
        let built = VpnIntentPlan.build(state: state, decision: decided, seq: 1,
                                        nowMs: server, localNowMs: local)
        XCTAssertEqual(built.route(atLocal: local), .cutoff)

        // 答对：拿到 10 分钟窗口 ⇒ 放行；窗口一过 ⇒ 扩展自己再掐回去，全程不需要主 App。
        var passed = state
        passed.ledger = GatePolicy.startNewCycle(afterCorrectAt: server, rule: passed.rule!)
        let afterCorrect = GatePolicy.decide(passed, nowMs: server)
        let rearmed = VpnIntentPlan.build(state: passed, decision: afterCorrect, seq: 2,
                                         nowMs: server, localNowMs: local)
        XCTAssertEqual(rearmed.route(atLocal: local), .pass)
        XCTAssertNotEqual(rearmed.route(atLocal: local), .cutoff)
        XCTAssertEqual(rearmed.route(atLocal: local + 11 * 60_000), .cutoff)
    }

    func testParentDisabledBuildsUnarmedIntent() {
        let state = approvedState(enabled: false)
        let decision = GatePolicy.decide(state, nowMs: server)
        XCTAssertEqual(decision, .allow(.disabledByParent))
        let built = VpnIntentPlan.build(state: state, decision: decision, seq: 1,
                                        nowMs: server, localNowMs: local)
        XCTAssertFalse(built.armed)
        XCTAssertEqual(built.route(atLocal: local - 10_000), .pass)
    }

    func testCannotEnforceBuildsUnarmedIntent() {
        var state = approvedState()
        state.authorization = nil
        let decision = GatePolicy.decide(state, nowMs: server)
        XCTAssertEqual(decision, .cannotEnforce(.notAuthorized))
        let built = VpnIntentPlan.build(state: state, decision: decision, seq: 1,
                                        nowMs: server, localNowMs: local)
        XCTAssertFalse(built.armed)
    }

    // MARK: - 两个时钟之间的那一跳

    func testDeadlinesAreCarriedOntoTheDeviceClock() {
        // 设备墙钟比服务器基准慢 60 秒。扩展手上只有它自己的墙钟（它读不到那份 clockOffset，
        // 也不该为了换算去读整包状态），所以交出去的时刻必须整体挪到本地基准上。
        var state = approvedState(playedMs: 0)
        state.monitoringStartedAtMs = server - 10 * 60_000      // 阈值 30 分钟 ⇒ 到点 = server + 20 分钟
        let built = VpnIntentPlan.build(state: state, decision: .allow(.underThreshold), seq: 1,
                                        nowMs: server, localNowMs: local)
        XCTAssertEqual(built.cutoffAtLocalMs, server + 20 * 60_000 - 60_000)

        // 反对照：换算量给成 0（也就是忘了换算）时，落点会停在服务器基准上。
        let forgot = VpnIntentPlan.build(state: state, decision: .allow(.underThreshold), seq: 1,
                                         nowMs: server, localNowMs: server)
        XCTAssertEqual(forgot.cutoffAtLocalMs, server + 20 * 60_000)
        XCTAssertNotEqual(built.cutoffAtLocalMs, forgot.cutoffAtLocalMs)

        // 通行窗口走的是同一把换算量：少挪这一次，孩子答对之后会被立刻再掐一次。
        state.ledger.unlockUntilMs = server + 5 * 60_000
        let moved = VpnIntentPlan.build(state: state, decision: .allow(.quizPassed), seq: 2,
                                        nowMs: server, localNowMs: local)
        XCTAssertEqual(moved.unlockUntilLocalMs, server + 5 * 60_000 - 60_000)
        XCTAssertEqual(moved.route(atLocal: local), .pass)
    }

    func testNoMonitoringRoundMeansNoSelfAdvancingDeadline() {
        // 还没配过监控（首次安装、或重配失败）：不能交一个"马上就到点"的时刻出去，
        // 否则一台刚装好、用量还是 0 的设备会被扩展自己掐了。
        let state = approvedState(playedMs: 0)
        let built = VpnIntentPlan.build(state: state, decision: .allow(.underThreshold), seq: 1,
                                        nowMs: server, localNowMs: local)
        XCTAssertEqual(built.route(atLocal: local), .pass)
        XCTAssertEqual(built.cutoffAtLocalMs, built.notAfterLocalMs)
    }

    func testDebugIntentsMatchTheRealShapes() {
        let on = VpnIntentPlan.debug(cutoff: true, seq: 1, nowMs: server, localNowMs: local)
        XCTAssertTrue(on.armed)
        XCTAssertEqual(on.route(atLocal: local), .cutoff)
        let off = VpnIntentPlan.debug(cutoff: false, seq: 2, nowMs: server, localNowMs: local)
        XCTAssertTrue(off.armed)
        XCTAssertEqual(off.route(atLocal: local), .pass)
        // 调试那两档都不能长得像"排期已过期"：一个是照旧、一个是账面 fail-open，
        // 日志里必须分得出。判据就是当下这一刻还没越过上界（越过了扩展会记那行 WARN）。
        XCTAssertLessThanOrEqual(local, off.notAfterLocalMs)
        XCTAssertLessThanOrEqual(local, on.notAfterLocalMs)
    }

    // MARK: - 「排期变没变」这道写盘闸

    func testSamePlanIgnoresSeqReasonAndWrittenAt() {
        // 心跳每 30 秒都会重新算一份意图，只有 seq / 判定原文 / 写入时刻在变的那一种
        // 必须跳过写盘，否则每天三万次同样的原子写。
        let a = intent(cutoffAt: server + 60_000, seq: 1)
        let b = intent(cutoffAt: server + 60_000, seq: 99)
        XCTAssertTrue(a.samePlan(as: b))
    }

    func testShiftedDeadlineIsNotTheSamePlan() {
        // 反例：上面那条如果比对写反了（比如只比 armed），这一条会一起绿，
        // 而"到点时刻挪了却没写盘"恰好是孩子重新答对一轮之后还能被旧时刻掐着的形状。
        let before = intent(cutoffAt: server + 60_000)
        let after = intent(cutoffAt: server + 120_000)
        XCTAssertFalse(before.samePlan(as: after))
        let unlocked = intent(cutoffAt: server + 60_000, unlock: server + 30_000)
        XCTAssertFalse(before.samePlan(as: unlocked))
        let disarmed = intent(armed: false, cutoffAt: server + 60_000)
        XCTAssertFalse(before.samePlan(as: disarmed))
    }

    // MARK: - 落盘

    /// store 自己认为的那一格文件路径。手写坏文件时必须拿这一格，
    /// 在测试里重拼一遍 "intent.json" 就是再赌一次「两边拼得一样」——
    /// 上一版的假绿正是赌输了却没人数（写到另一个 UUID 目录里，`read()` 本来就返回 nil）。
    private var intentFile: URL? { VpnIntentStore.fileURL }

    /// 手写这一格不许静默失败：写不进去就是测试自己坏了，必须红，不能悄悄变成一条通过的断言。
    private func writeRaw(_ text: String, to file: URL) {
        do {
            try Data(text.utf8).write(to: file)
        } catch {
            XCTFail("坏文件没落下去：" + error.localizedDescription)
        }
    }

    func testRoundTripKeepsEveryField() {
        let original = intent(cutoffAt: server, unlock: server + 60_000, end: server + 600_000)
        XCTAssertNil(VpnIntentStore.write(original))
        let back = VpnIntentStore.read()
        XCTAssertEqual(back, original)
    }

    func testUnreadableFileIsTreatedAsNoIntent() {
        guard let file = intentFile else {
            XCTFail("测试落点没生效，fileURL 为空")
            return
        }
        writeRaw("这不是 JSON", to: file)
        XCTAssertNil(VpnIntentStore.read())
        // 正对照：同一格随后能被 store 正常写读。没有这一条，上面那句 nil
        // 就分不清是「坏文件被拒」还是「这一格压根写不进去」。
        XCTAssertNil(VpnIntentStore.write(intent(cutoffAt: server)))
        XCTAssertNotNil(VpnIntentStore.read())
    }

    func testFutureSchemaVersionIsRefusedInsteadOfHalfRead() {
        // 一份形状完全正确、只有版本号不同的载荷。不带这一份对照，
        // "拒收"可能只是因为键名写错，那就根本没证到版本这道闸。
        let body = "{\"schema\":SCHEMA,\"armed\":true,\"cutoffAtLocalMs\":1,"
            + "\"unlockUntilLocalMs\":null,\"notAfterLocalMs\":99999999999999,"
            + "\"reason\":\"test\",\"seq\":3,\"writtenAtLocalMs\":1}"
        guard let file = intentFile else {
            XCTFail("测试落点没生效，fileURL 为空")
            return
        }
        writeRaw(body.replacingOccurrences(of: "SCHEMA", with: "99"), to: file)
        XCTAssertNil(VpnIntentStore.read())

        writeRaw(body.replacingOccurrences(of: "SCHEMA", with: "1"), to: file)
        XCTAssertEqual(VpnIntentStore.read()?.seq, 3)
    }

    /// seq 是「下一次写入该用第几号」，所以它必须来自盘上那一号 + 1，
    /// 而不是调用方自己数 —— 主 App 被系统杀掉重来时手上什么都没有，只有盘上那份。
    func testSeqAdvancesFromWhatIsOnDisk() {
        XCTAssertEqual(VpnIntentStore.nextSeq(), 0)
        XCTAssertNil(VpnIntentStore.write(intent(cutoffAt: server, seq: VpnIntentStore.nextSeq())))
        XCTAssertEqual(VpnIntentStore.nextSeq(), 1)
        XCTAssertNil(VpnIntentStore.write(intent(cutoffAt: server, seq: VpnIntentStore.nextSeq())))
        XCTAssertEqual(VpnIntentStore.nextSeq(), 2)
    }

    func testMissingFileReadsAsNilAndWritesAnyway() {
        XCTAssertNil(VpnIntentStore.read())
        XCTAssertNil(VpnIntentStore.write(intent(cutoffAt: server)))
        XCTAssertNotNil(VpnIntentStore.read())
    }
}
