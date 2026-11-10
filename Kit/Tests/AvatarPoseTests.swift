import XCTest
@testable import QuizGateKit

/// Android 那份黄金姿态表的**同一份文本**，内嵌在这里逐格比对。
///
/// 为什么内嵌而不是当测试资源打进包：`QuizGateKit` 是 source-based 静态库，测试 target 要
/// 多挂一份 resources 路径（project.yml 里多一处能被漏掉的地方）；更要紧的是"资源读不到"
/// 在 XCTest 里天然长成"nil 就跳过"的假绿，写死在源码里不会——文本不在，这个文件就编不过。
///
/// 更新口径：改了 Android `AvatarPose.kt` 的姿态数学，那边 `AvatarPoseGoldenTest` 会红并
/// 重新生成 `app/src/test/resources/fox-pose-golden.txt`；把那份新文本整块换到这里即可。
/// 两边文本必须逐字相同，这个文件是 iOS 侧唯一能发现"两端各写一份数、悄悄漂了"的地方。
private let goldenPoseTable = """
LOOP|IDLE|0|idle|layer-body|0.00000000|0.00000000|-0.00000000|1.00000000|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-tail|-9.00000000|0.00000000|0.00000000|1.00000000
LOOP|IDLE|700|idle|layer-body|0.00000000|0.00000000|-0.04082020|1.05224991|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-tail|0.84990788|0.00000000|0.00000000|1.00000000
LOOP|IDLE|1000|idle|layer-body|0.00000000|0.00000000|-0.05524272|1.07071066|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-tail|4.63355446|0.00000000|0.00000000|1.00000000
LOOP|IDLE|2000|idle|layer-body|0.00000000|0.00000000|-0.07812500|1.10000002|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-tail|13.44039154|0.00000000|0.00000000|1.00000000
LOOP|IDLE|3000|idle|layer-body|0.00000000|0.00000000|-0.05524272|1.07071066|layer-ears|-7.23913622|0.00000000|0.00000000|1.00000000|layer-tail|14.30260468|0.00000000|0.00000000|1.00000000
LOOP|IDLE|3999|idle|layer-body|0.00000000|0.00000000|-0.00006135|1.00007856|layer-ears|8.31422901|0.00000000|0.00000000|1.00000000|layer-tail|6.92579460|0.00000000|0.00000000|1.00000000
LOOP|PLAYING|0|happy|layer-arm-left|-18.00000000|0.00000000|0.00000000|1.00000000|layer-arm-right|18.00000000|0.00000000|0.00000000|1.00000000|layer-body|0.00000000|0.00000000|0.00000000|1.00000000|layer-tail|-26.00000000|0.00000000|0.00000000|1.00000000
LOOP|PLAYING|275|happy|layer-arm-left|8.87005806|0.00000000|0.00000000|1.00000000|layer-arm-right|-8.87005806|0.00000000|0.00000000|1.00000000|layer-body|0.00000000|0.00000000|-0.07812500|1.00000000|layer-tail|14.85242081|0.00000000|0.00000000|1.00000000
LOOP|PLAYING|495|happy|layer-arm-left|19.53215790|0.00000000|0.00000000|1.00000000|layer-arm-right|-19.53215790|0.00000000|0.00000000|1.00000000|layer-body|0.00000000|0.00000000|-0.14062500|1.00000000|layer-tail|18.52977371|0.00000000|0.00000000|1.00000000
LOOP|PLAYING|605|happy|layer-arm-left|19.53215408|0.00000000|0.00000000|1.00000000|layer-arm-right|-19.53215408|0.00000000|0.00000000|1.00000000|layer-body|0.00000000|0.00000000|-0.06510416|1.00000000|layer-tail|8.48257828|0.00000000|0.00000000|1.00000000
LOOP|PLAYING|825|happy|layer-arm-left|8.87005806|0.00000000|0.00000000|1.00000000|layer-arm-right|-8.87005806|0.00000000|0.00000000|1.00000000|layer-body|0.00000000|0.00000000|-0.01708984|1.00000000|layer-tail|-25.09972000|0.00000000|0.00000000|1.00000000
LOOP|PLAYING|1099|happy|layer-arm-left|-17.89147568|0.00000000|0.00000000|1.00000000|layer-arm-right|17.89147568|0.00000000|0.00000000|1.00000000|layer-body|0.00000000|0.00000000|-0.00006215|1.00000000|layer-tail|15.20375061|0.00000000|0.00000000|1.00000000
LOOP|QUIZ|0|think|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-head|-14.00000000|0.00000000|0.00000000|1.00000000
LOOP|QUIZ|850|think|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-head|5.79899025|0.00000000|0.00000000|1.00000000
LOOP|QUIZ|1700|think|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-head|14.00000000|0.00000000|0.00000000|1.00000000
LOOP|QUIZ|2550|think|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-head|5.79899025|0.00000000|0.00000000|1.00000000
LOOP|QUIZ|3220|think|layer-ears|-18.00000000|0.00000000|0.00000000|1.00000000|layer-head|-9.36449432|0.00000000|0.00000000|1.00000000
LOOP|QUIZ|3404|think|layer-ears|-1.99998856|0.00000000|0.00000000|1.00000000|layer-head|-13.89651203|0.00000000|0.00000000|1.00000000
LOOP|QUIZ|4599|think|layer-ears|0.01383305|0.00000000|0.00000000|1.00000000|layer-head|11.05303001|0.00000000|0.00000000|1.00000000
LOOP|WARNING|0|think|layer-ears|0.00000000|0.00000000|0.00000000|1.00000000|layer-head|-12.00000000|0.00000000|0.00000000|1.00000000
LOOP|WARNING|105|think|layer-ears|-6.36396074|0.00000000|0.03038349|1.00000000|layer-head|4.97056198|0.00000000|0.00000000|1.00000000
LOOP|WARNING|210|think|layer-ears|-9.00000000|0.00000000|0.04296875|1.00000000|layer-head|12.00000000|0.00000000|0.00000000|1.00000000
LOOP|WARNING|315|think|layer-ears|-6.36396074|0.00000000|0.03038349|1.00000000|layer-head|4.97056198|0.00000000|0.00000000|1.00000000
LOOP|WARNING|419|think|layer-ears|-0.06731988|0.00000000|0.00032141|1.00000000|layer-head|-11.82048035|0.00000000|0.00000000|1.00000000
LOOP|PAUSED|0|idle|NONE
LOOP|PAUSED|1234|idle|NONE
LOOP|PENDING_PARENT|0|idle|NONE
LOOP|PENDING_PARENT|1234|idle|NONE
WALK|0.00000000|happy|0.00000000|0.00000000|layer-arm-left|0.00000000|0.00000000|0.00000000|1.00000000|layer-arm-right|-0.00000000|0.00000000|0.00000000|1.00000000|layer-ears|-0.00000000|0.00000000|0.00000000|1.00000000|layer-hind|0.00000000|0.00000000|0.00000000|1.00000000|layer-tail|0.00000000|0.00000000|0.00000000|1.00000000
WALK|0.12500000|happy|0.29154518|-1.00000000|layer-arm-left|-20.00000000|0.00000000|0.00000000|1.00000000|layer-arm-right|20.00000000|0.00000000|0.00000000|1.00000000|layer-ears|6.00000000|0.00000000|0.00000000|1.00000000|layer-hind|-14.00000000|0.00000000|0.00000000|1.00000000|layer-tail|-22.00000000|0.00000000|0.00000000|1.00000000
WALK|0.34999999|happy|1.00000000|0.58778495|layer-arm-left|11.75569916|0.00000000|0.00000000|1.00000000|layer-arm-right|-11.75569916|0.00000000|0.00000000|1.00000000|layer-ears|-3.52670956|0.00000000|0.00000000|1.00000000|layer-hind|8.22898960|0.00000000|0.00000000|1.00000000|layer-tail|12.93126869|0.00000000|0.00000000|1.00000000
WALK|0.50000000|happy|1.00000000|0.00000005|layer-arm-left|0.00000095|0.00000000|0.00000000|1.00000000|layer-arm-right|-0.00000095|0.00000000|0.00000000|1.00000000|layer-ears|-0.00000029|0.00000000|0.00000000|1.00000000|layer-hind|0.00000067|0.00000000|0.00000000|1.00000000|layer-tail|0.00000105|0.00000000|0.00000000|1.00000000
WALK|0.64999998|happy|1.00000000|-0.58778644|layer-arm-left|-11.75572872|0.00000000|0.00000000|1.00000000|layer-arm-right|11.75572872|0.00000000|0.00000000|1.00000000|layer-ears|3.52671862|0.00000000|0.00000000|1.00000000|layer-hind|-8.22900963|0.00000000|0.00000000|1.00000000|layer-tail|-12.93130112|0.00000000|0.00000000|1.00000000
WALK|0.89999998|happy|0.19825082|0.58778644|layer-arm-left|11.75572872|0.00000000|0.00000000|1.00000000|layer-arm-right|-11.75572872|0.00000000|0.00000000|1.00000000|layer-ears|-3.52671862|0.00000000|0.00000000|1.00000000|layer-hind|8.22900963|0.00000000|0.00000000|1.00000000|layer-tail|12.93130112|0.00000000|0.00000000|1.00000000
WALK|1.00000000|happy|0.00000000|0.00000010|layer-arm-left|0.00000191|0.00000000|0.00000000|1.00000000|layer-arm-right|-0.00000191|0.00000000|0.00000000|1.00000000|layer-ears|-0.00000057|0.00000000|0.00000000|1.00000000|layer-hind|0.00000134|0.00000000|0.00000000|1.00000000|layer-tail|0.00000210|0.00000000|0.00000000|1.00000000
CONST|WALK_WIDTHS|3.20000005|CANVAS|512.00000000
"""

/// 比对容差。取 1e-5 而不是 0：JVM 的 `Math.sin` 与 Apple libm 的 `sin` 不保证最后一位相同，
/// 差 1 ULP（这里量级最大 26，1 ULP ≈ 2e-6）在屏幕上等于不存在——512 的画布缩到 40pt 时，
/// 一度角对应 0.08pt，1e-5 度是它的百万分之一。但**写错的数学**通常差到 1e-3 以上，
/// 所以这条线足以把"舍入不同"和"公式不同"分开。
private let tolerance: Float = 1e-5

final class AvatarPoseTests: XCTestCase {

    // MARK: - 跨端锚：和 Android 跑出来的那份表逐格相同

    func testPoseTableMatchesTheAndroidGoldenValues() {
        let rows = goldenPoseTable.split(separator: "\n", omittingEmptySubsequences: true)
        // 反例闸：内嵌文本被误删成空/半截时，这个断言先红，而不是让下面 0 行的循环假绿。
        XCTAssertEqual(rows.count, 36, "内嵌的黄金值应当是 36 行（28 条 LOOP + 7 条 WALK + 1 条 CONST），"
            + "实得 \(rows.count)：多半是拷贝时截断了")

        var loopRows = 0
        var walkRows = 0
        var constRows = 0
        for (index, row) in rows.enumerated() {
            let cells = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            switch cells[0] {
            case "LOOP":
                loopRows += 1
                checkLoop(cells, line: index + 1)
            case "WALK":
                walkRows += 1
                checkWalk(cells, line: index + 1)
            case "CONST":
                constRows += 1
                checkConst(cells, line: index + 1)
            default:
                XCTFail("第 \(index + 1) 行的行首不是 LOOP/WALK/CONST：\(cells[0])")
            }
        }
        // 分档计数也要对：少了整档（比如 WARNING 全丢）不会被上面的逐行比对发现。
        XCTAssertEqual(loopRows, 28, "LOOP 行数不对，某一档状态可能整档丢了")
        XCTAssertEqual(walkRows, 7, "WALK 行数不对")
        XCTAssertEqual(constRows, 1, "CONST 行数不对")
    }

    private func checkLoop(_ cells: [String], line: Int) {
        let stateName = cells[1]
        guard let now = Int64(cells[2]) else {
            return XCTFail("第 \(line) 行的时刻读不出来：\(cells[2])")
        }
        let pose = AvatarPose.loop(state(stateName, line: line), nowMs: now)
        XCTAssertEqual(pose.expression, cells[3], "第 \(line) 行 \(stateName)@\(now) 的表情不对")
        let expected = namedParts(cells[4...], line: line)
        assertSameLayers(expected: expected, actual: pose.parts, where: "第 \(line) 行 \(stateName)@\(now)")
    }

    private func checkWalk(_ cells: [String], line: Int) {
        guard let progress = Float(cells[1]) else {
            return XCTFail("第 \(line) 行的进度读不出来：\(cells[1])")
        }
        let pose = AvatarPose.interaction(progress)
        XCTAssertEqual(pose.expression, cells[2], "第 \(line) 行 progress=\(progress) 的表情不对")
        assertClose(AvatarPose.walk(progress), Float(cells[3]) ?? .nan,
                    "第 \(line) 行 walk(\(progress)) 对不上")
        assertClose(AvatarPose.strideOf(progress), Float(cells[4]) ?? .nan,
                    "第 \(line) 行 strideOf(\(progress)) 对不上")
        let expected = namedParts(cells[5...], line: line)
        assertSameLayers(expected: expected, actual: pose.parts, where: "第 \(line) 行 walk \(progress)")
    }

    private func checkConst(_ cells: [String], line: Int) {
        XCTAssertEqual(cells[1], "WALK_WIDTHS")
        XCTAssertEqual(cells[3], "CANVAS")
        assertClose(AvatarPose.walkWidths, Float(cells[2]) ?? .nan, "第 \(line) 行 WALK_WIDTHS 对不上")
        assertClose(AvatarPose.canvas, Float(cells[4]) ?? .nan, "第 \(line) 行 CANVAS 对不上")
    }

    /// 把 `name|rotate|dx|dy|scaleY` 的重复段解析成表。`NONE` 表示这一档一层都没点名。
    private func namedParts(_ cells: ArraySlice<String>, line: Int) -> [String: AvatarPose.Part] {
        let list = Array(cells)
        if list == ["NONE"] { return [:] }
        XCTAssertEqual(list.count % 5, 0, "第 \(line) 行的图层段不是 5 个一组：\(list.count) 格")
        var out: [String: AvatarPose.Part] = [:]
        var i = 0
        while i + 4 < list.count {
            out[list[i]] = AvatarPose.Part(rotate: num(list[i + 1], line: line),
                                           dx: num(list[i + 2], line: line),
                                           dy: num(list[i + 3], line: line),
                                           scaleY: num(list[i + 4], line: line))
            i += 5
        }
        return out
    }

    /// 先比**点了哪几层**，再比每层的四个数。顺序不能反：少点名一层时，
    /// 逐层比数会安静通过（缺的那层没人问），而绘制端读到的是恒等 —— 那一层就永远不动。
    private func assertSameLayers(expected: [String: AvatarPose.Part],
                                  actual: [String: AvatarPose.Part], where label: String) {
        XCTAssertEqual(expected.keys.sorted(), actual.keys.sorted(),
                       "\(label) 点名的图层和 Android 不一致（绘制端靠这份名单决定读哪几层）")
        for name in expected.keys.sorted() {
            guard let want = expected[name] else { continue }
            let got = actual[name] ?? AvatarPose.Part()
            assertClose(got.rotate, want.rotate, "\(label) \(name).rotate")
            assertClose(got.dx, want.dx, "\(label) \(name).dx")
            assertClose(got.dy, want.dy, "\(label) \(name).dy")
            assertClose(got.scaleY, want.scaleY, "\(label) \(name).scaleY")
        }
    }

    private func num(_ text: String, line: Int) -> Float {
        guard let v = Float(text) else {
            XCTFail("第 \(line) 行有个数读不出来：\(text)")
            return 0
        }
        return v
    }

    private func assertClose(_ got: Float, _ want: Float, _ label: String) {
        if abs(got - want) > tolerance {
            XCTFail("\(label)：Android 是 \(want)，iOS 算出 \(got)，差 \(abs(got - want))"
                + "（容差 \(tolerance)，超出这个量就不是舍入而是公式不同）")
        }
    }

    private func state(_ name: String, line: Int) -> AvatarPlayState {
        switch name {
        case "IDLE": return .idle
        case "PLAYING": return .playing
        case "QUIZ": return .quiz
        case "WARNING": return .warning
        case "PAUSED": return .paused
        case "PENDING_PARENT": return .pendingParent
        default:
            XCTFail("第 \(line) 行出现了不认的状态名 \(name)")
            return .idle
        }
    }

    // MARK: - 行为断言：整份对拷 Android `AvatarPoseTest.kt`
    //
    // 上面那条锚只管"两端算出同一批数"，管不了"这批数本身还有没有意义"。
    // 下面六条挑的都是**看不见就会长期存在**的错：某一档整档不动、两档之间串了相位、
    // 互动结束没回到原位（那会让孩子看到狐狸歪着停住）。

    /// 一圈里采 24 个点：够密，不会因为刚好踩在恒等相位上而漏掉一整档动作。
    private func everyPhase(_ periodMs: Int64, _ sample: (Int64) -> Void) {
        for i in 0..<24 { sample(i * periodMs / 24) }
    }

    private func moved(_ pose: AvatarPose.Pose) -> Bool {
        pose.layers.contains { !pose.part($0).isIdentity }
    }

    func testPlayingWagsTailSwingsArmsInAntiPhaseAndOnlyLiftsOnTheHop() {
        var wagged = 0
        var grounded = 0
        var peak: Float = 0
        everyPhase(1_100) { now in
            let pose = AvatarPose.loop(.playing, nowMs: now)
            if pose.part(AvatarPose.layerTail).rotate != 0 { wagged += 1 }
            let dy = pose.part(AvatarPose.layerBody).dy
            if dy == 0 { grounded += 1 }
            peak = max(peak, -dy)
            let l = pose.part(AvatarPose.layerArmLeft).rotate
            let r = pose.part(AvatarPose.layerArmRight).rotate
            XCTAssertTrue(l * r <= 0, "两只手要一前一后，同相就不是跑是抖（l=\(l) r=\(r)）")
        }
        XCTAssertGreaterThanOrEqual(wagged, 18, "24 个采样点里一次都没甩尾，这一档等于没做")
        XCTAssertEqual(grounded, 1, "一整圈里只该有一格稳稳贴着地，实得 \(grounded)")
        // 24 个采样点踩不到 45% 那一格，所以"最高抬到多少"单独按母版的起跳点直接问一次。
        let hop = -AvatarPose.loop(.playing, nowMs: 495).part(AvatarPose.layerBody).dy
        XCTAssertEqual(hop, 72 / 512, accuracy: 1e-4, "起跳幅度对不上编排表的 72/512")
        XCTAssertGreaterThan(peak, 0.07, "采样一圈都没见过离地，实得峰值 \(peak)")
    }

    /// 这一条是踩过坑之后加的：抽耳只占一圈里的后段（62% 之后才起步，一路摆到圈末才归零），
    /// 只采半周期会得出"这一层没动"的假阴性（在浏览器里就假绿过一次）。
    func testQuizKeepsEarsStraightUntilSixtyTwoPercentThenTwitches() {
        var peakTilt: Float = 0
        everyPhase(3_400) { now in
            let head = AvatarPose.loop(.quiz, nowMs: now).part(AvatarPose.layerHead)
            XCTAssertLessThanOrEqual(abs(head.rotate), 14.1, "歪头要来回摆，不能一直歪在同一边")
            peakTilt = max(peakTilt, abs(head.rotate))
        }
        // 只有上限的断言是空的：幅度掉到 0 照样一路通过。这一格补的是"歪头到底歪没歪到位"。
        XCTAssertGreaterThanOrEqual(peakTilt, 13, "歪头峰值只有 \(peakTilt)°，编排表写的是 14°，那等于没歪")

        let twitch = Int(AvatarPose.twitchMs)
        let samples = (0...99).map { i -> (Int, Float) in
            (i, AvatarPose.loop(.quiz, nowMs: Int64(i * twitch / 100)).part(AvatarPose.layerEars).rotate)
        }
        let movedSlots = samples.filter { $0.1 != 0 }
        XCTAssertFalse(movedSlots.isEmpty, "一圈里一次都没抽耳")
        // 同上：只问"动没动"不够，0.5° 也算动了，但屏幕上看不出。
        let peakTwitch = movedSlots.map { abs($0.1) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(peakTwitch, 13, "抽耳最大才 \(peakTwitch)°，看不出来")
        let slots = movedSlots.map { $0.0 }
        XCTAssertGreaterThanOrEqual(slots.min() ?? -1, 62,
                                    "抽耳提前到了第 \(slots.min() ?? -1) 格，母版是 62 之后才起步")
        XCTAssertLessThanOrEqual(slots.count, 45, "抽耳占了 \(slots.count) 格，那不是抽一下是全程抖")
    }

    /// 后台那两档只做整体压暗、不扭任何一层；手机要是自己多演，两屏就对不上了。
    func testPausedAndPendingParentAreTotallyStill() {
        for playState in [AvatarPlayState.paused, .pendingParent] {
            everyPhase(4_000) { now in
                let pose = AvatarPose.loop(playState, nowMs: now)
                XCTAssertTrue(pose.layers.isEmpty || !moved(pose), "\(playState) 不该有任何图层在动")
            }
        }
    }

    func testIdleBreathIsSmallEnoughToNotLookLikeFrameSkippingButLargeEnoughToSee() {
        var peakScale: Float = 1
        var peakLift: Float = 0
        everyPhase(4_000) { now in
            let body = AvatarPose.loop(.idle, nowMs: now).part(AvatarPose.layerBody)
            // 这几格都只有 40~76pt：呼吸再小一档就等于没动，家长那句"web 没动过"就是这么来的。
            // 上限防的是"呼吸变成抽"，下限防的是"挂着动画但一屏只挪一两像素"。
            // 判据来自后台那条量尺（web/scripts/fox-motion-check.mjs）：最小那一档也要 3 像素以上。
            XCTAssertTrue((1.0...1.101).contains(body.scaleY), "呼吸顶到 \(body.scaleY)")
            XCTAssertEqual(body.dx, 0, "身子不该横向飘 \(body.dx)")
            peakScale = max(peakScale, body.scaleY)
            peakLift = max(peakLift, -body.dy)
        }
        XCTAssertGreaterThan(peakScale, 1.09, "呼吸只有 \(peakScale)，屏幕上看不出来")
        XCTAssertGreaterThan(peakLift, 36 / AvatarPose.canvas, "身子只抬 \(peakLift) 个画布，屏幕上看不出来")
        // 后台 is-idle 也点名了耳朵，手机不跟着动就是两屏不一致。
        let twitch = Int(AvatarPose.twitchMs)
        let twitched = (0...99).filter { i in
            AvatarPose.loop(.idle, nowMs: Int64(i * twitch / 100)).part(AvatarPose.layerEars).rotate != 0
        }.count
        XCTAssertGreaterThan(twitched, 0, "待机一圈里耳朵一次都没抖")
    }

    /// 互动结束必须回到原位：停在半路就是孩子看到一只卡在画面外的狐狸。
    func testInteractionWalksTheWholeViewOutAndPutsNoOffsetOnAnyLayer() {
        XCTAssertEqual(AvatarPose.walk(0), 0, accuracy: 0, "起步就该在原位")
        XCTAssertEqual(AvatarPose.walk(1), 0, accuracy: 0, "走完必须精确归零，停在半路就是卡在画面外")
        XCTAssertGreaterThan(AvatarPose.walk(0.5), 0.99, "中段要走到最远，实得 \(AvatarPose.walk(0.5))")
        XCTAssertGreaterThanOrEqual(AvatarPose.walkWidths, 3,
                                    "只走 \(AvatarPose.walkWidths) 个格宽，看不出它挪窝了")
        // 图层上不许出现位移：谁把位移写回图层，没被点名的那一层就会留在原地——
        // 上一版正是手臂和尾巴没被点名，孩子看到的就是"身子跑了手脚还在原地"。
        for p in [Float(0), 0.125, 0.5, 0.9, 1] {
            let pose = AvatarPose.interaction(p)
            for name in pose.layers {
                let part = pose.part(name)
                XCTAssertEqual(part.dx, 0, "\(name) 在 \(p) 处带位移 dx=\(part.dx)：整只走要交给视图平移")
                XCTAssertEqual(part.dy, 0, "\(name) 在 \(p) 处带位移 dy=\(part.dy)：整只走要交给视图平移")
            }
        }
        let mid = AvatarPose.interaction(0.125)
        let l = mid.part(AvatarPose.layerArmLeft).rotate
        let r = mid.part(AvatarPose.layerArmRight).rotate
        XCTAssertLessThanOrEqual(l * r, 0, "两只手要一前一后，同相就不是走是抖")
        XCTAssertGreaterThan(abs(l), 12, "手臂几乎不摆，实得 \(l)")
        XCTAssertGreaterThan(abs(mid.part(AvatarPose.layerHind).rotate), 8, "后腿要跟着倒腾")
        XCTAssertGreaterThan(abs(mid.part(AvatarPose.layerTail).rotate), 12, "尾巴要摆")
        XCTAssertEqual(mid.expression, AvatarPose.exprHappy, "互动时是开心表情")
    }

    func testEveryStateMapsToExactlyOneExpression() {
        XCTAssertEqual(AvatarPose.expressionOf(.playing), AvatarPose.exprHappy)
        XCTAssertEqual(AvatarPose.expressionOf(.quiz), AvatarPose.exprThink)
        XCTAssertEqual(AvatarPose.expressionOf(.warning), AvatarPose.exprThink)
        for playState in [AvatarPlayState.idle, .paused, .pendingParent] {
            XCTAssertEqual(AvatarPose.expressionOf(playState), AvatarPose.exprIdle, "\(playState) 该配待机脸")
        }
    }
}
