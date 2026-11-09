import XCTest
@testable import QuizGateKit

final class OutboxTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "quizgate.outbox.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func report(_ id: String) -> PendingReport {
        PendingReport(id: id, path: "usage", payload: Data([0x01]), createdAtMs: 1)
    }

    func testEmptyQueue() {
        XCTAssertEqual(OutboxStore.load(from: defaults), [])
    }

    func testEnqueueThenRemove() {
        XCTAssertTrue(OutboxStore.enqueue(report("a"), to: defaults))
        XCTAssertTrue(OutboxStore.enqueue(report("b"), to: defaults))
        XCTAssertEqual(OutboxStore.load(from: defaults).map(\.id), ["a", "b"])

        OutboxStore.remove(ids: ["a"], from: defaults)
        XCTAssertEqual(OutboxStore.load(from: defaults).map(\.id), ["b"])
    }

    func testSameIdIsNotEnqueuedTwice() {
        OutboxStore.enqueue(report("a"), to: defaults)
        OutboxStore.enqueue(report("a"), to: defaults)
        XCTAssertEqual(OutboxStore.load(from: defaults).count, 1)
    }

    /// 无上限攒下去会撑爆 App Group，而一个坏值能让四个进程一起崩。
    func testQueueIsCappedAndDropsOldest() {
        for i in 0..<(OutboxStore.maxItems + 10) {
            OutboxStore.enqueue(report("id-\(i)"), to: defaults)
        }
        let items = OutboxStore.load(from: defaults)
        XCTAssertEqual(items.count, OutboxStore.maxItems)
        XCTAssertEqual(items.first?.id, "id-10", "丢的应当是最老的")
        XCTAssertEqual(items.last?.id, "id-\(OutboxStore.maxItems + 9)")
    }

    func testCorruptQueueFallsBackToEmptyNotCrash() {
        defaults.set(Data([0x00, 0xFF]), forKey: OutboxStore.storageKey)
        XCTAssertEqual(OutboxStore.load(from: defaults), [])
        // 坏了之后还能继续入队，不能卡死。
        XCTAssertTrue(OutboxStore.enqueue(report("a"), to: defaults))
        XCTAssertEqual(OutboxStore.load(from: defaults).map(\.id), ["a"])
    }

    func testBumpAttemptsOnlyTouchesGivenIds() {
        OutboxStore.enqueue(report("a"), to: defaults)
        OutboxStore.enqueue(report("b"), to: defaults)
        OutboxStore.bumpAttempts(ids: ["a"], in: defaults)
        let items = OutboxStore.load(from: defaults)
        XCTAssertEqual(items.first { $0.id == "a" }?.attempts, 1)
        XCTAssertEqual(items.first { $0.id == "b" }?.attempts, 0)
    }

    /// payload 必须逐字节不变：重传时不再经过生成代码，改一个字节服务端就解不开了。
    func testPayloadIsByteExact() {
        let blob = Data((0..<300).map { UInt8($0 % 256) })
        var item = report("a")
        item.payload = blob
        OutboxStore.enqueue(item, to: defaults)
        XCTAssertEqual(OutboxStore.load(from: defaults).first?.payload, blob)
    }

    /// GateEventReportReply 的线格式手写死在这里：字段 1 = accepted，字段 2 = duplicated，都是 varint。
    /// 故意不用生成的消息类去序列化 —— 那样字段号是从同一份 .proto 里绕出来的自证，
    /// 手写这份字节才能真的钉住「服务端回的那几个字段号我们读对了」。
    private func reply(accepted: Int, duplicated: Int) -> Data {
        var bytes: [UInt8] = []
        if accepted != 0 { bytes += [0x08, UInt8(accepted)] }
        if duplicated != 0 { bytes += [0x10, UInt8(duplicated)] }
        return Data(bytes)
    }

    func testAcknowledgedCountsWithAcceptedOrDuplicated() {
        XCTAssertTrue(OutboxStore.acknowledged(events: 1, replyData: reply(accepted: 1, duplicated: 0)))
        // 重传按 event_id 去重回 duplicated：这条已经落过账，可以出队。
        XCTAssertTrue(OutboxStore.acknowledged(events: 1, replyData: reply(accepted: 0, duplicated: 1)))
        XCTAssertTrue(OutboxStore.acknowledged(events: 2, replyData: reply(accepted: 1, duplicated: 1)))
    }

    /// 服务端一条都没记 = 绝不能出队。这一条是「http 200 就删」那个错误的反面。
    func testNotAcknowledgedWhenNothingWasRecorded() {
        XCTAssertFalse(OutboxStore.acknowledged(events: 1, replyData: reply(accepted: 0, duplicated: 0)))
        XCTAssertFalse(OutboxStore.acknowledged(events: 2, replyData: reply(accepted: 1, duplicated: 0)))
        XCTAssertFalse(OutboxStore.acknowledged(events: 0, replyData: reply(accepted: 9, duplicated: 9)))
    }

    /// 解不出回包就当没送达：宁可留着重传，也不能凭一份不认识的回包清队列。
    func testGarbageReplyIsNotAcknowledged() {
        XCTAssertFalse(OutboxStore.acknowledged(events: 1, replyData: Data([0x00, 0xFF, 0x7F])))
        XCTAssertFalse(OutboxStore.acknowledged(events: 1, replyData: Data()))
    }
}