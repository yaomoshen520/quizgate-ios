import Foundation

/// 跨进程「状态变了，去重读 App Group」的信号。
///
/// 为什么不用 NotificationCenter.default：它不跨进程。主 App post 一条，
/// extension 永远收不到 —— 看起来像「回调没触发」，实际是信号压根没出门。
/// Darwin 通知能跨进程，但**不带任何 payload**，所以收到之后必须自己回去读快照。
public final class DarwinSignal {

    public static let stateChangedName = "com.quizgate.ios.stateChanged"

    /// 观察者必须被强引用活着。回调里拿到的是裸指针，
    /// 对象先被释放再触发回调就是 use-after-free，表现为随机 EXC_BAD_ACCESS。
    /// 用注册表持有，stop() 时先摘观察者再放引用，顺序不能反。
    private static var registry: [ObjectIdentifier: DarwinSignal] = [:]

    private let name: CFString
    private var observing = false
    public var onSignal: (() -> Void)?

    public init(name: String = DarwinSignal.stateChangedName) {
        self.name = name as CFString
    }

    deinit {
        stop()
    }

    public func start() {
        guard !observing else { return }
        observing = true
        Self.registry[ObjectIdentifier(self)] = self
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            opaque,
            Self.callback,
            name,
            nil,
            .deliverImmediately
        )
    }

    public func stop() {
        guard observing else { return }
        observing = false
        // AddObserver 收 CFString，RemoveObserver 收 CFNotificationName —— 同一个字符串，
        // 两个 API 的原型不一致，少包一层就是编译期报错，别在运行时才发现观察者没摘掉。
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name),
            nil
        )
        Self.registry.removeValue(forKey: ObjectIdentifier(self))
    }

    public static func post(name: String = stateChangedName) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    private static let callback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let signal = Unmanaged<DarwinSignal>.fromOpaque(observer).takeUnretainedValue()
        signal.onSignal?()
    }
}