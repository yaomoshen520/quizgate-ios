import XCTest
@testable import QuizGateKit

/// 诊断日志这一本流水的全部可测面：脱敏、轮转、跨进程搬运、按服务端回执删除。
///
/// 每条"洗掉了"的断言都配一条"没 secrets 的原文一个字都不许动"的对照 ——
/// 只断言"看不见秘密了"的话，把 sanitize 改成返回空串也能全绿，那是假绿。
final class DiagLogTests: XCTestCase {

    private var directory: URL!
    private var file: URL { try! DiagLog.fileURL() }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quizgate.diaglog.\(UUID().uuidString)", isDirectory: true)
        // 这里必须真的把目录建出来，而不是只给一个路径。
        // fileURL() 会顺手建目录，所以先碰 file 的用例没事；而 foreign() 是手拼路径直接写，
        // atomic 写在父目录不存在时报的是 NSCocoaError 4「文件夹不存在」——
        // CI 上先红的那四条（两条 pendingBatches + 两条 acknowledge）全是这一型。
        // 扩展进程在真机上写自己那本之前也走 fileURL()，所以这条路径是测试装配缺的前置，
        // 不是产品里的洞。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DiagLog.testDirectory = directory
    }

    override func tearDownWithError() throws {
        DiagLog.testDirectory = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func line(_ ms: Int64, _ text: String, level: DiagLevel = .info, tag: String = "t") -> DiagLog.Line {
        DiagLog.Line(occurredAtMs: ms, level: level, tag: tag, message: text)
    }

    private func written() -> [DiagLog.Line] { (try? DiagLog.readLines(file)) ?? [] }

    /// 另一个"进程"的文件：名字随手写，因为搬运读的是整个目录而不是自己的那一份。
    private func foreign(_ name: String, _ lines: [DiagLog.Line]) throws -> URL {
        let url = directory.appendingPathComponent(name + ".jsonl")
        try DiagLog.write(lines, to: url)
        return url
    }

    // MARK: - 脱敏

    func testSanitizeKeepsPlainTextUntouched() {
        let plain = "阈值回调 event=15m activity=quizgate.cycle-1712 counted=false"
        XCTAssertEqual(DiagLog.sanitize(plain), plain)
    }

    func testSanitizeRedactsCredentialsButKeepsTheRest() {
        let dirty = "心跳 deviceToken=abcdefgh12345 https://host/api?x=1 绑定码：K7Q2X "
            + "Bearer abc.def=1 password=  hunter2 X-Quizgate-Token: zz99"
        let clean = DiagLog.sanitize(dirty)
        for secret in ["abcdefgh12345", "K7Q2X", "abc.def=1", "hunter2", "zz99", "host/api?x=1"] {
            XCTAssertFalse(clean.contains(secret), "泄露了 \(secret)：\(clean)")
        }
        // 洗过之后还得读得出是在说心跳，否则这一本日志等于没有。
        XCTAssertTrue(clean.contains("心跳"))
        XCTAssertTrue(clean.contains("[redacted]"))
    }

    func testSanitizeRemovesNewlinesThatWouldSplitOneRecordIntoTwo() {
        let clean = DiagLog.sanitize("第一行\n第二行\r第三行")
        XCTAssertFalse(clean.contains("\n"))
        XCTAssertFalse(clean.contains("\r"))
        XCTAssertTrue(clean.contains("第一行"))
        XCTAssertTrue(clean.contains("第三行"))
    }

    func testSanitizeTruncatesToOneColumnWidth() {
        XCTAssertEqual(DiagLog.sanitize(String(repeating: "长", count: 9000)).count,
                       DiagLog.maxCleanChars)
    }

    func testProtoLevelMappingIsExplicit() {
        XCTAssertEqual(DiagLevel.info.proto, .info)
        XCTAssertEqual(DiagLevel.warn.proto, .warn)
        XCTAssertEqual(DiagLevel.error.proto, .error)
    }

    // MARK: - 落盘与轮转

    func testRecordWritesOneReadableLine() {
        DiagLog.record("app", "心跳 decision=allow.underThreshold", level: .warn, nowMs: 1234)
        let got = written()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].occurredAtMs, 1234)
        XCTAssertEqual(got[0].level, .warn)
        XCTAssertEqual(got[0].tag, "app")
        XCTAssertEqual(got[0].message, "心跳 decision=allow.underThreshold")
    }

    /// 读不完整的行必须被跳过而不是把整本日志判成废文件：崩在半路的那一次写就是这么来的。
    func testReadSkipsGarbageButKeepsGoodLines() throws {
        try DiagLog.write([line(1, "甲")], to: file)
        let data = try Data(contentsOf: file) + Data("{\"t\":2,\"l\":\"WRONG\"\n".utf8)
            + Data("{\"t\":3,\"l\":\"INFO\",\"g\":\"t\",\"m\":\"丙\"}\n".utf8)
        try data.write(to: file)
        XCTAssertEqual(written().map(\.message), ["甲", "丙"])
    }

    func testRotationDropsOldestAndRecordsHowMany() throws {
        var seed: [DiagLog.Line] = []
        for i in 0..<DiagLog.maxLinesPerFile { seed.append(line(Int64(i), "旧\(i)")) }
        try DiagLog.write(seed, to: file)

        try DiagLog.append(line(99_999, "最新一行"))

        let got = written()
        XCTAssertEqual(got.count, DiagLog.maxLinesPerFile, "轮转后必须正好回到上限")
        // marker 自己占一格，所以真实丢掉的是 2 行 —— 这个 2 就是"日志到顶"这笔账的代价。
        XCTAssertEqual(got.last?.tag, "log")
        XCTAssertEqual(got.last?.level, .warn)
        XCTAssertEqual(got.last?.message, "本地日志到顶，丢掉最旧 2 行")
        XCTAssertEqual(got.dropLast().last?.message, "最新一行", "新写的行永远不能被轮转吃掉")
        XCTAssertEqual(got.first?.message, "旧2", "丢的必须是最旧的两行")
        XCTAssertFalse(got.contains { $0.message == "旧0" || $0.message == "旧1" })
    }

    /// 上限之下不该出现 marker：那是"记了一笔根本没发生过的丢失"。
    func testNoDropMarkerBelowCap() throws {
        try DiagLog.write((0..<(DiagLog.maxLinesPerFile - 1)).map { line(Int64($0), "旧\($0)") }, to: file)
        try DiagLog.append(line(1, "刚好到顶"))
        XCTAssertEqual(written().last?.tag, "t")
        XCTAssertFalse(written().contains { $0.tag == "log" })
    }

    // MARK: - 搬运

    func testPendingBatchesSortsAcrossProcessesByOldestLine() throws {
        _ = try foreign("com_quizgate_ios_monitor", [line(100, "扩展 21:33 的回调")])
        _ = try foreign("com_quizgate_ios", [line(500, "主 App 21:40 的答题"), line(600, "后面一行")])

        let batches = DiagLog.pendingBatches(totalLimit: 10)
        XCTAssertEqual(batches.count, 2)
        // 排查要的是一条能读的时间线：扩展那一行排在主 App 前面，和谁先被扫到无关。
        XCTAssertEqual(batches.map { $0.lines.first?.occurredAtMs }, [100, 500])
    }

    func testPendingBatchesHonoursTotalLimit() throws {
        _ = try foreign("a", (1...300).map { line(Int64($0), "a\($0)") })
        _ = try foreign("b", (1...300).map { line(Int64($0), "b\($0)") })
        let total = DiagLog.pendingBatches(totalLimit: DiagLog.batchLines)
            .reduce(0) { $0 + $1.lines.count }
        XCTAssertLessThanOrEqual(total, DiagLog.batchLines)
        XCTAssertGreaterThan(total, 0)
    }

    func testAcknowledgeRemovesExactlyWhatTheServerAccepted() throws {
        _ = try foreign("c", [line(1, "一"), line(2, "二"), line(3, "三")])
        guard let batch = DiagLog.pendingBatches(totalLimit: 10).first else {
            return XCTFail("没有批次")
        }
        DiagLog.acknowledge(batch, count: 2)
        XCTAssertEqual((try? DiagLog.readLines(batch.url))?.map(\.message), ["三"])
    }

    func testAcknowledgeZeroKeepsEverything() throws {
        // 服务端返回 accepted=0（比如它刚做完裁剪）时，本地一行都不许删。
        _ = try foreign("d", [line(1, "甲"), line(2, "乙")])
        let batch = DiagLog.pendingBatches(totalLimit: 10).first!
        DiagLog.acknowledge(batch, count: 0)
        XCTAssertEqual((try? DiagLog.readLines(batch.url))?.count, 2)
    }
}
