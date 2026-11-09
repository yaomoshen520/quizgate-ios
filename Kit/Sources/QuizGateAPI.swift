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
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200...299:
            do {
                return try Reply(serializedData: data)
            } catch {
                throw ReportUnavailable(message: "\(path) 应答不是合法 protobuf：\(error.localizedDescription)")
            }
        case 401, 403:
            throw ReportUnavailable(message: "\(path) 认定令牌无效（http=\(status)）", needsReenroll: true)
        default:
            throw ReportUnavailable(message: "\(path) 被拒（http=\(status)）")
        }
    }
}