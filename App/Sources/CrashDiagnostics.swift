import CryptoKit
import Foundation
import MetricKit
import QuizGateKit

final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnostics()
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                guard let root = try? JSONSerialization.jsonObject(with: crash.callStackTree.jsonRepresentation()) as? [String: Any] else { continue }
                let tree = root["callStackTree"] as? [String: Any] ?? root
                guard let threads = tree["callStacks"] as? [[String: Any]],
                      let fault = threads.first(where: { $0["threadAttributed"] as? Bool == true }),
                      let frames = fault["callStackRootFrames"] as? [[String: Any]],
                      let frame = frames.first, let binary = frame["binaryUUID"] as? String,
                      let offset = frame["offsetIntoBinaryTextSegment"] as? NSNumber else { continue }
                let key = "\(crash.exceptionType?.intValue ?? -1)/\(crash.signal?.intValue ?? -1)/\(binary)/\(offset)"
                let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
                DiagLog.record("crash", "系统报告了应用崩溃", level: .error, fingerprint: digest)
            }
        }
    }
}
