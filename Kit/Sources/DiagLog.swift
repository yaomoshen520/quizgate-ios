import Foundation

/// 诊断日志的等级。和协议里的 `LogLevel` 一一对应，字符串就是库里那一列的值。
public enum DiagLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

extension DiagLevel {
    /// 协议里对应的那一档。逐条显式映射，不靠声明顺序对齐：
    /// 哪天协议中间插一个级别，靠 rawValue 会把 WARN 报成 INFO，而这一本日志的用途就是查错。
    public var proto: Quizgate_LogLevel {
        switch self {
        case .info: return .info
        case .warn: return .warn
        case .error: return .error
        }
    }
}

/// 设备自己写的排查流水。
///
/// 为什么这个文件存在：iOS 上没有前台可读、没有 overlay、盾牌是系统画的，
/// 所以「阈值到了却没拦住」这一类问题在本机连一个目击者都没有，而家长后台远程看的时候
/// 我们又不在孩子身边。这一本流水是唯一能被远程读到的现场。
///
/// 三条硬约束，都是这个项目里已经付过学费的地方：
///
/// 1. **脱敏发生在出门之前，不发生在服务端。** 日志在离开设备前就可能已经带上令牌、绑定码
///    （最自然的写法就是把整条请求上下文打出来）。所以服务端拿到的一律是洗过的，
///    它不需要也不应该再洗一遍——否则下一版客户端就敢直接写原文。
/// 2. **写日志不能把闸门带崩。** 落盘一律 best-effort，任何失败都吞掉：
///    一条日志写不进去的代价是少一行现场，一个异常冒到调用方的代价是这次拦截整个没了。
/// 3. **每个进程写自己的文件。** App Group 没有跨进程锁（SharedState 为此走的是全量重算），
///    四个进程往同一个文件尾部追加会互相啃掉半行 JSON。各写各的，主 App 前台时统一搬运。
public enum DiagLog {

    /// 单个进程的文件最多留多少行。到顶就丢最旧的：宁可现场不完整，
    /// 也不能让一台从没连上过后台的设备把 App Group 容器写满。
    static let maxLinesPerFile = 1200

    /// 一次上报最多多少行，和服务端 `DeviceLogStore.MAX_LINES_PER_REPORT` 对齐。
    /// 两边各写一份不是重复：服务端那道是门（不可信输入），这一道是形状（我们主动分批）；
    /// 只靠服务端那道的话每一批都被拒，队列永远排不空。
    public static let batchLines = 400

    /// 进 sanitizer 之前的上限，和 Android LogSanitizer 的 8192 对齐。
    static let maxRawChars = 8192
    /// 出 sanitizer 之后的上限。协议里那一列是 512，服务端还会再截一次。
    static let maxCleanChars = 512

    private static let queue = DispatchQueue(label: "com.quizgate.ios.diaglog")

    /// 单测用的落点覆盖。生产路径永远为 nil，走真实的 App Group 容器。
    /// 没有这枚口子，队列、轮转和 acknowledge 三件事在 CI 里一行都测不到。
    static var testDirectory: URL?

    public struct Line {
        public var occurredAtMs: Int64
        public var level: DiagLevel
        public var tag: String
        public var message: String

        var json: [String: Any] {
            ["t": occurredAtMs, "l": level.rawValue, "g": tag, "m": message]
        }

        static func decode(_ object: [String: Any]) -> Line? {
            guard let stamp = object["t"] as? NSNumber,
                  let levelText = object["l"] as? String, let level = DiagLevel(rawValue: levelText),
                  let tag = object["g"] as? String, let message = object["m"] as? String else { return nil }
            return Line(occurredAtMs: stamp.int64Value, level: level, tag: tag, message: message)
        }
    }

    // MARK: - 落盘

    /// 记一行。调用点只写「发生了什么 + 关键数字」，不要贴整段上下文：
    /// 上下文里的令牌要靠 sanitize 兜，那是第二道而不是第一道。
    public static func record(_ tag: String, _ message: String, level: DiagLevel = .info, nowMs: Int64? = nil) {
        let line = Line(occurredAtMs: nowMs ?? Int64(Date().timeIntervalSince1970 * 1000),
                        level: level, tag: tag, message: sanitize(message))
        // best-effort：这里任何失败都不能冒到调用方。
        try? queue.sync { try append(line) }
    }

    /// 在当前进程的文件尾部加一行。超上限先丢最旧的，并把丢了多少**记成一条 WARN**——
    /// 协议里刻意没有 `dropped_lines` 那个字段，丢掉多少的去处就是这一行，走同一个通道。
    static func append(_ line: Line) throws {
        let url = try fileURL()
        var lines = try readLines(url)
        lines.append(line)
        if lines.count > maxLinesPerFile {
            // 那条 WARN 自己也要占一格，所以多丢一行来付它。
            // 不这么算是死代码：写完 marker 行数正好回到上限，下一次 append 又溢出，
            // 而「只在 lines.count < 上限时才补记」的写法会让 marker 永远写不进去。
            let dropped = lines.count - maxLinesPerFile + 1
            lines.removeFirst(dropped)
            lines.append(Line(occurredAtMs: line.occurredAtMs, level: .warn, tag: "log",
                              message: "本地日志到顶，丢掉最旧 \(dropped) 行"))
        }
        try write(lines, to: url)
    }

    // MARK: - 搬运

    /// 一批待上报的行，连着它来自哪个文件。
    ///
    /// 为什么要带上文件：四个进程各写各的文件（见上面的硬约束 3），而搬运只发生在主 App
    /// 前台这一个地方。扩展进程写的行如果孩子从不打开 App 就永远留在盘上——
    /// 那也正是「时间到了没拦住」最需要被看到的那几行，所以搬运必须能读别人的文件。
    public struct Batch {
        public let url: URL
        public let lines: [Line]
    }

    /// 把所有文件里的待发行按「最旧那行的时刻」排序，凑够 totalLimit 为止。
    ///
    /// 排序而不是固定顺序：排查要的是一条能读的时间线。扩展在 21:33 触发的阈值事件，
    /// 应当排在主 App 21:40 的答题记录前面，不管哪个文件先被扫到。
    public static func pendingBatches(totalLimit: Int) -> [Batch] {
        guard totalLimit > 0 else { return [] }
        let urls = (try? queue.sync(execute: { allFiles() })) ?? []
        var batches: [Batch] = []
        var remaining = totalLimit
        for url in urls {
            guard remaining > 0 else { break }
            let lines = (try? queue.sync(execute: { readLines(url) })) ?? []
            guard !lines.isEmpty else { continue }
            let take = Array(lines.prefix(remaining))
            batches.append(Batch(url: url, lines: take))
            remaining -= take.count
        }
        return batches.sorted { ($0.lines.first?.occurredAtMs ?? 0) < ($1.lines.first?.occurredAtMs ?? 0) }
    }

    /// 服务端确认收了某个文件的前 `count` 行，把它们从那个文件里去掉。
    ///
    /// 已知代价：读-改-写这一小段窗口里同文件被别的进程追加过，那几行会一起消失。
    /// 文件名按 bundle id 分，四个进程四个 id，所以这条路径只在同一进程被并发调用时才走到。
    public static func acknowledge(_ batch: Batch, count: Int) {
        guard count > 0 else { return }
        try? queue.sync {
            var lines = try readLines(batch.url)
            lines.removeFirst(min(count, lines.count))
            try write(lines, to: batch.url)
        }
    }

    static func allFiles() throws -> [URL] {
        let dir = try fileURL().deletingLastPathComponent()
        let found = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return found.filter { $0.pathExtension == "jsonl" }
    }

    // MARK: - 位置

    /// 每个进程一个文件，文件名就是它的 bundle id。
    /// 拿不到 App Group 容器时整条通道静默关闭：没有容器就没地方写，而工程配置错误的后果
    /// 应当是「少一本日志」，不是「闸门不再落盾」。
    static func fileURL() throws -> URL {
        if let testDirectory {
            try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
            return testDirectory.appendingPathComponent(name + ".jsonl")
        }
        guard let base = AppGroup.containerURL else { throw ConfigError.noContainer }
        let dir = base.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name + ".jsonl")
    }

    public enum ConfigError: Error { case noContainer }

    /// bundle id 里的非法字符一律换成下划线：这个名字会直接进文件路径。
    static var name: String {
        String((Bundle.main.bundleIdentifier ?? "unknown").map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    // MARK: - 读写

    static func readLines(_ url: URL) throws -> [Line] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }
        var result: [Line] = []
        for chunk in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(String(chunk).utf8)),
                  let dict = object as? [String: Any], let line = Line.decode(dict) else { continue }
            result.append(line)
        }
        return result
    }

    static func write(_ lines: [Line], to url: URL) throws {
        var text = ""
        for line in lines {
            guard let json = try? JSONSerialization.data(withJSONObject: line.json) else { continue }
            text += String(decoding: json, as: UTF8.self) + "\n"
        }
        // 整文件原子重写：半行 JSON 会在下一次读时被跳过，宁可少一行也别留一行垃圾。
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - 脱敏

    private static let urlPattern = try? NSRegularExpression(pattern: "https?://[^\\s<>]+", options: .caseInsensitive)
    private static let bearerPattern = try? NSRegularExpression(pattern: "(?i)Bearer\\s+[A-Za-z0-9._~+/=-]+")
    /// 键名清单和 Android 的 LogSanitizer 是同一批词。加词要两边一起加，
    /// 否则同一句话在两个客户端上一条洗过一条没洗过，那种差异最难查。
    /// 长的排前面：择一匹配先命中先赢，`token` 排在 `device_token` 前面会把它只洗掉半截。
    private static let secretKeys = [
        "X-Quizgate-Token", "device_token", "deviceToken", "access_token", "accessToken",
        "refresh_token", "refreshToken", "token", "password", "passwd", "secret",
        "bind_code", "bindCode", "绑定码", "密码",
    ]
    private static let secretPattern: NSRegularExpression? = {
        let keys = secretKeys.sorted { $0.count > $1.count }
              .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "(?i)((?:\(keys))[\"']?\\s*[:=：]?\\s*[\"']?)([^\\s,;，；\"'}]+)")
    }()

    /// 顺序是有讲究的：先按字符数截，再跑正则，避免有人塞一段超长文本把回溯时间吃满。
    public static func sanitize(_ message: String) -> String {
        var safe = String(message.prefix(maxRawChars))
        safe = replace(urlPattern, in: safe, with: "[url]")
        safe = replace(bearerPattern, in: safe, with: "Bearer [redacted]")
        safe = secretPattern?.stringByReplacingMatches(
            in: safe, range: NSRange(location: 0, length: safe.utf16.count),
            withTemplate: "$1[redacted]") ?? safe
        // 换行必须清掉：jsonl 一行一条记录，原文里的 \n 会把一行劈成两行残缺 JSON。
        safe = safe.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return String(safe.prefix(maxCleanChars))
    }

    private static func replace(_ pattern: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let pattern else { return text }
        return pattern.stringByReplacingMatches(in: text,
                                                range: NSRange(location: 0, length: text.utf16.count),
                                                withTemplate: template)
    }
}
