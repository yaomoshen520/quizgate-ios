import Foundation
import SwiftProtobuf

/// 一条还没确认送达的上报。payload 是已序列化好的 protobuf 字节，
/// 存字节而不是存消息对象：重传时不需要再依赖生成代码的版本。
public struct PendingReport: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var payload: Data
    public var createdAtMs: Int64
    public var attempts: Int

    public init(id: String = UUID().uuidString, path: String, payload: Data,
                createdAtMs: Int64, attempts: Int = 0) {
        self.id = id
        self.path = path
        self.payload = payload
        self.createdAtMs = createdAtMs
        self.attempts = attempts
    }
}

/// 断网兜底队列。和 Android ReportChannel 同一个思路：
/// 发不出去就先留着，下次再试；服务端按 event_id 去重，所以重传是安全的。
///
/// 有上限。孩子的设备可能几天连不上服务器，无上限攒下去会把 App Group 撑爆，
/// 而 App Group 里一个坏值能让四个进程一起崩。超限丢最老的 —— 用量数据丢一条
/// 远好过把整个闸门搞崩。
public enum OutboxStore {

    static let storageKey = "quizgate.outbox.v1"
    public static let maxItems = 500

    public static func load(from defaults: UserDefaults) -> [PendingReport] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        // 解码失败回空队列而不是崩：队列丢了可以重攒，进程崩了闸门就没了。
        guard let items = try? JSONDecoder().decode([PendingReport].self, from: data) else { return [] }
        return items
    }

    public static func load() -> [PendingReport] {
        guard let defaults = AppGroup.defaults else { return [] }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        return load(from: defaults)
    }

    @discardableResult
    public static func save(_ items: [PendingReport], to defaults: UserDefaults) -> Bool {
        var capped = items
        if capped.count > maxItems { capped.removeFirst(capped.count - maxItems) }
        guard let data = try? JSONEncoder().encode(capped) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    @discardableResult
    public static func enqueue(_ report: PendingReport, to defaults: UserDefaults) -> Bool {
        var items = load(from: defaults)
        // 同一个 id 不重复入队：重传靠服务端去重，队列里没必要留两份。
        guard !items.contains(where: { $0.id == report.id }) else { return true }
        items.append(report)
        return save(items, to: defaults)
    }

    public static func remove(ids: Set<String>, from defaults: UserDefaults) {
        let items = load(from: defaults).filter { !ids.contains($0.id) }
        save(items, to: defaults)
    }

    public static func bumpAttempts(ids: Set<String>, in defaults: UserDefaults) {
        var items = load(from: defaults)
        for index in items.indices where ids.contains(items[index].id) {
            items[index].attempts += 1
        }
        save(items, to: defaults)
    }

    /// http 200 不等于这一条已经记账。只有 accepted + duplicated 覆盖到本批条数才算送达。
    /// duplicated 也算数：重传本来就指望服务端按 event_id 去重，去重成功就是已经落库。
    ///
    /// 方向选错的代价不对称：按 200 就删，服务端可能一条都没归属，本地队列已经清空，
    /// 等设备绑定之后这笔账追不回来；判严只会多留一会儿，不会丢数据。
    public static func acknowledged(events: Int, replyData: Data) -> Bool {
        guard events > 0 else { return false }
        guard let reply = try? Quizgate_GateEventReportReply(serializedData: replyData) else { return false }
        return Int(reply.accepted) + Int(reply.duplicated) >= events
    }
}