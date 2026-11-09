import XCTest
@testable import QuizGateKit

/// 这一组测的不是业务，是**存坏了会不会把四个进程一起带崩**。
/// App Group 里一个半截写入的值如果能让解码崩，主 App 和三个 extension
/// 会在每次启动/每次触发时一起崩，现场只表现为「盾牌永远不来」。
final class SharedStateTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "quizgate.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAbsentIsDistinctFromCorrupt() {
        XCTAssertEqual(StateStore.load(from: defaults), .absent)
    }

    func testRoundTrip() {
        var state = SharedState(installId: "install-1")
        state.deviceToken = "token-abc"
        state.bindCode = "ABC123"
        state.deviceBound = true
        state.childGrade = 4
        state.clockOffsetMs = -1234
        state.ledger.playedMs = 55_000
        state.selectionData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertTrue(StateStore.save(state, to: defaults))

        guard case .ok(let loaded) = StateStore.load(from: defaults) else {
            return XCTFail("刚写进去的状态读不回来")
        }
        XCTAssertEqual(loaded, state)
    }

    /// 老 payload 没有这两个键也必须解得出来（monitoringActivity / dailyLimitReachedOnDay
    /// 是后加的，所以它们必须是可选的）。
    ///
    /// 为什么单独测这一条：schemaVersion 停在 1，而版本不符走的是 .corrupt，
    /// corrupt 分支永远不会重写状态。如果这两个字段写成非可选，升级后第一次
    /// load 就判 corrupt，那台设备的闸门会卡在旧状态上直到重装——
    /// 现场表现正好就是本次要修的那个「盾牌永远不来」。
    func testPayloadWithoutTheNewOptionalKeysStillDecodes() throws {
        var state = SharedState(installId: "install-old")
        state.deviceToken = "token-old"
        state.ledger.playedMs = 120_000
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
            as! [String: Any]
        var stripped = encoded
        stripped.removeValue(forKey: "monitoringActivity")
        stripped.removeValue(forKey: "dailyLimitReachedOnDay")
        XCTAssertNil(stripped["monitoringActivity"])
        XCTAssertNil(stripped["dailyLimitReachedOnDay"])
        XCTAssertNotNil(stripped["schemaVersion"], "反例前提：这仍是当前版本的 payload，不是靠版本不符混过去的")
        XCTAssertNotNil(stripped["installId"], "反例前提：除了那两个键，payload 本身是完整的")
        defaults.set(try JSONSerialization.data(withJSONObject: stripped),
                     forKey: SharedState.storageKey)

        guard case .ok(let loaded) = StateStore.load(from: defaults) else {
            return XCTFail("缺新键的老 payload 必须照常解出来，不能判 corrupt")
        }
        XCTAssertNil(loaded.monitoringActivity)
        XCTAssertNil(loaded.dailyLimitReachedOnDay)
        XCTAssertEqual(loaded.deviceToken, "token-old")
        XCTAssertEqual(loaded.ledger.playedMs, 120_000)

        // 另一半反例：如果哪天有人把它写成「缺键就当 corrupt」，这一条会红。
        XCTAssertTrue(StateStore.save(loaded, to: defaults))
        XCTAssertEqual(StateStore.load(from: defaults), .ok(loaded))
    }

    func testGarbageBytesAreCorruptNotCrash() {
        defaults.set(Data([0x00, 0xFF, 0x13, 0x37]), forKey: SharedState.storageKey)
        guard case .corrupt = StateStore.load(from: defaults) else {
            return XCTFail("乱码必须判成 corrupt")
        }
    }

    /// 模拟半截写入：合法 JSON 的前半段。这是备份还原/进程被杀最常见的产物。
    func testTruncatedJSONIsCorruptNotCrash() {
        var state = SharedState()
        state.bindCode = "ABC123"
        let data = try! JSONEncoder().encode(state)
        defaults.set(data.prefix(data.count / 2), forKey: SharedState.storageKey)
        guard case .corrupt = StateStore.load(from: defaults) else {
            return XCTFail("半截 JSON 必须判成 corrupt")
        }
    }

    func testWrongSchemaVersionIsCorrupt() {
        var state = SharedState()
        state.schemaVersion = SharedState.currentSchemaVersion + 1
        XCTAssertTrue(StateStore.save(state, to: defaults))
        guard case .corrupt(let reason) = StateStore.load(from: defaults) else {
            return XCTFail("版本不符必须判成 corrupt，不能按旧字段硬读")
        }
        XCTAssertTrue(reason.contains("版本"))
    }

    /// 最关键的一条：状态存坏了，mutate **不许**把它重置成初始值。
    /// 重置会连带抹掉 shieldApplied，等于替孩子把门开了。
    func testMutateOnCorruptKeepsBytesUntouched() {
        let garbage = Data([0x00, 0xFF, 0x13, 0x37])
        defaults.set(garbage, forKey: SharedState.storageKey)

        let result = StateStore.mutate(in: defaults) { $0.ledger.playedMs = 999 }

        guard case .corrupt = result else {
            return XCTFail("corrupt 状态下 mutate 必须回 corrupt")
        }
        XCTAssertEqual(defaults.data(forKey: SharedState.storageKey), garbage,
                       "存坏的字节必须原样留着，绝不能被初始状态覆盖")
    }

    func testMutateOnAbsentCreatesState() {
        let result = StateStore.mutate(in: defaults) { $0.childGrade = 5 }
        guard case .ok(let state) = result else {
            return XCTFail("首次安装应当建出初始状态")
        }
        XCTAssertEqual(state.childGrade, 5)
        XCTAssertEqual(state.schemaVersion, SharedState.currentSchemaVersion)
    }

    func testFaultListIsCapped() {
        var state = SharedState()
        for i in 0..<50 { state.recordFault("fault-\(i)") }
        XCTAssertEqual(state.faults.count, 20)
        XCTAssertEqual(state.faults.last, "fault-49")
        XCTAssertEqual(state.faults.first, "fault-30")
    }

    func testProcessedEventIdsAreCappedAndStillDedupRecent() {
        var state = SharedState()
        for i in 0..<250 { state.markEventProcessed("evt-\(i)") }
        XCTAssertEqual(state.processedEventIds.count, 200)
        XCTAssertTrue(state.hasProcessed("evt-249"))
        XCTAssertFalse(state.hasProcessed("evt-0"), "最老的应当被挤出去")
    }

    func testNowMsAppliesServerClockOffset() {
        var state = SharedState()
        state.clockOffsetMs = 0
        let base = state.nowMs()
        state.clockOffsetMs = 60_000
        let shifted = state.nowMs()
        // 两次调用之间墙钟也在走，所以只断言偏移量级而不是精确相等。
        XCTAssertGreaterThanOrEqual(shifted - base, 59_000)
        XCTAssertLessThan(shifted - base, 65_000)
    }

    /// selectionData 是不透明归档，存取必须逐字节不变。
    /// 任何「顺手解析一下」的改动都会在这里红。
    func testSelectionDataIsOpaqueAndByteExact() {
        var state = SharedState()
        let blob = Data((0..<512).map { UInt8($0 % 256) })
        state.selectionData = blob
        XCTAssertTrue(StateStore.save(state, to: defaults))
        guard case .ok(let loaded) = StateStore.load(from: defaults) else {
            return XCTFail("读回失败")
        }
        XCTAssertEqual(loaded.selectionData, blob)
    }
}