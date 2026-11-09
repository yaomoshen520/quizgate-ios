import Foundation
import SwiftProtobuf

/// 设备令牌被服务端认定无效。重试一万次也不会好，只能重新 enroll。
/// 单独标出来而不是混在网络错误里：401 一直重试的现场表现是「看起来像网络很差」，
/// 这是最难查的一种失败。
public struct ReportUnavailable: Error, Equatable {
    public let message: String
    public let needsReenroll: Bool

    public init(message: String, needsReenroll: Bool = false) {
        self.message = message
        self.needsReenroll = needsReenroll
    }
}

/// 设备端网络出口。只走 protobuf —— 后端没有 JSON 层，发 JSON 只会拿到 415。
/// 契约与 Android ApiClient.kt 逐条对齐：路径前缀、两个头、超时、401/403 语义。
public final class QuizGateAPI {

    public static let contentType = "application/x-protobuf"
    public static let tokenHeader = "X-Quizgate-Token"

    /// 单条应答的字节上界。服务端最重的应答是题库回显，也远不到这个量级；
    /// 超过它只可能是连错了对象（网页、代理页、别人家的接口），别把整坨喂给 protobuf 解析器。
    public static let maxResponseBytes = 2_097_152

    private let base: String
    private let session: URLSession

    public init(base: String) {
        self.base = base.hasSuffix("/") ? String(base.dropLast()) : base
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 13
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// 主 App 用这条：正常等响应。
    public func post<Request: Message, Reply: Message>(
        _ path: String,
        token: String?,
        request: Request,
        reply: Reply.Type
    ) async throws -> Reply {
        let urlRequest = try makeRequest(path, token: token, body: try request.serializedData())
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            // 带上地址：ATS 拦下来时也是走这里，不写地址就没人想到是安全配置。
            throw ReportUnavailable(message: "连不上 \(base)：\(error.localizedDescription)")
        }
        return try decode(data: data, response: response, path: path, reply: reply)
    }

    /// 补发队列用这条：payload 是入队时就已经序列化好的字节，重传时不再依赖生成代码的版本。
    /// 返回原始应答字节，由调用方按那条路径的回包自己判「这笔账落了没有」。
    public func postRaw(_ path: String, token: String?, body: Data) async throws -> Data {
        let urlRequest = try makeRequest(path, token: token, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ReportUnavailable(message: "连不上 \(base)：\(error.localizedDescription)")
        }
        return try checked(data: data, response: response, path: path)
    }

    /// extension 用这条：发出去，最多硬等 waitMs，不等响应体、不重试。
    ///
    /// 为什么这么憋屈：extension 的回调一返回，进程随时可能被结束，
    /// 异步请求还没发出去就没了。社区库的做法是发完 sleep 1 秒，这里照做。
    /// **所以凡是「必须确认服务端收到了」的上报，都不能走这条**，要进 Outbox 由主 App 补发。
    public func fireAndForget<Request: Message>(
        _ path: String,
        token: String?,
        request: Request,
        waitMs: Int = 1000
    ) {
        guard let urlRequest = try? makeRequest(path, token: token, body: try request.serializedData()) else {
            return
        }
        let group = DispatchGroup()
        group.enter()
        // 持有 task：不持有的话请求可能被 URLSession 生命周期提前收掉。
        let task = session.dataTask(with: urlRequest) { _, _, _ in group.leave() }
        task.resume()
        _ = group.wait(timeout: .now() + .milliseconds(waitMs))
    }

    // MARK: - 内部

    private func makeRequest(_ path: String, token: String?, body: Data) throws -> URLRequest {
        guard let url = URL(string: "\(base)/api/device/\(path)") else {
            throw ReportUnavailable(message: "后端地址非法：\(base)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.contentType, forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: Self.tokenHeader)
        }
        return request
    }

    private func decode<Reply: Message>(data: Data, response: URLResponse,
                                        path: String, reply: Reply.Type) throws -> Reply {
        let bytes = try checked(data: data, response: response, path: path)
        do {
            return try reply.init(serializedData: bytes)
        } catch {
            throw ReportUnavailable(message: "\(path) 应答不是合法 protobuf：\(error.localizedDescription)")
        }
    }

    /// 状态码 → Content-Type → 大小上界，三关都过了才把字节交出去。
    /// post 和 postRaw 共用这一条：补发链路单独写一份校验，迟早会和主链路对不上。
    private func checked(data: Data, response: URLResponse, path: String) throws -> Data {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        switch status {
        case 200...299:
            // 服务端每个应答都由 ProtobufHttp.reply 发出，一定带这个头。
            // 没带就说明我们连的根本不是它，内容再像 protobuf 也不能信。
            let mime = http?
                .value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces)
            guard mime == Self.contentType else {
                throw ReportUnavailable(message: "\(path) 回的不是 protobuf（content-type=\(mime ?? "无")）")
            }
            guard data.count <= Self.maxResponseBytes else {
                throw ReportUnavailable(message: "\(path) 应答 \(data.count) 字节，超过 \(Self.maxResponseBytes) 上界")
            }
            return data
        case 401, 403:
            throw ReportUnavailable(message: "\(path) 认定令牌无效（http=\(status)）", needsReenroll: true)
        default:
            throw ReportUnavailable(message: "\(path) 被拒（http=\(status)）")
        }
    }
}