import SwiftUI
import QuizGateKit

/// iOS 端的那只狐狸：切层骨骼实时合成，不是把一张图挪来挪去。
///
/// 图层、叠放顺序、支点全部来自素材导出脚本写进包里的 `fox_rig.json`，而那张表是从矢量
/// 母版现读的——手机里不存在第二个"尾巴该绕哪儿扭"。动作数值在 Kit 的 `AvatarPose`，
/// 与 Android `AvatarPose.kt` 逐条对拷，两端各有一份单测钉着同一张黄金值表。
///
/// 为什么用一层 Canvas 而不是摆十个 Image：十个视图各自一次布局、各自一次上屏，
/// 而这一切发生在孩子答题时的屏幕上。这里只有一次绘制。
///
/// **节拍是"自己给自己排下一次"**（[FoxClock]），不是 TimelineView 逐帧：
/// Android 那边实测过，无限重复的动画器就算把回调节流到 200ms 一格，主线程仍吃到 36%
/// 单核——贵的是每帧都要叫醒这条线程，不是那一下重绘。iOS 这一份沿用同一个形状：
/// 待机 300ms 问一次姿态，互动那两秒多才按帧问。
/// （iOS 侧的 CPU 占用我没测过，本机没有 Xcode；"300ms 够用"是从 Android 那次实测搬来的判断。）
struct AvatarRigView: View {

    /// 家长挑的那一档（proto `AvatarId` 的编号）。0 和认不出来的编号一律整块不画，
    /// 也不给布局留空位——和"这台设备还没有形象"时的首页长得一样。
    let avatarId: Int
    let playState: AvatarPlayState
    var size: CGFloat
    /// 点一下演一次"走出去再回来"。首页那格是 44pt，点了没反应比不响应更让人怀疑坏了。
    var playsOnTap: Bool = false
    /// 这一屏一出现就先演一次，不用孩子先点。
    ///
    /// 只有 iOS 有这一格：iOS 拿不到前台 App，也就没有 Android 那句「正在玩「XXX」」当引子，
    /// 首页第一段少了会说话的那一格；用一次开场互动补上"它是活的"这个印象。
    /// 回到前台也算一次打开——`onAppear` 那时不会再触发（视图一直挂着），所以两个入口都要接。
    /// 撞车不要紧：`playInteraction()` 在上一场没演完时直接返回 false，不会把动作截断重来。
    var greetsOnAppear: Bool = false
    /// 答对/答错时由宿主置 true，触发庆祝/挠头（变成 true 的那一刻演一次）。
    var celebrate: Bool = false
    var scratch: Bool = false
    /// 答题养成：等级 >=3 头顶戴皇冠，胸前挂最新解锁的勋章（编号）。
    var achievementLevel: Int = 0
    var achievementBadge: String? = nil
    /// 宿主置 true 的那一刻演一次佩戴动画（勋章飞入、皇冠落下）。
    var equip: Bool = false

    @StateObject private var clock = FoxClock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let rig = FoxRig.load(), let scarf = rig.scarf(for: avatarId) {
            canvas(rig: rig, scarf: scarf, frame: currentFrame(), equipProgress: clock.equipProgress ?? 1)
        }
    }

    private func currentFrame() -> Frame {
        // 先把 @Published 读进本地值再往下传：渲染闭包里读不一定被登记成依赖，
        // 那一格不刷新时长相就是"这只狐狸从头到尾一动不动"。Android 那边踩过同一个坑
        // （可见性回调比布局早，那一刻宽还是 0，之后没有任何人再叫过一次）。
        let progress = clock.interactionProgress
        guard let progress else {
            return Frame(pose: AvatarPose.loop(playState, nowMs: clock.uptimeMs), walk: 0, bob: 0, type: .walk)
        }
        let type = clock.interactionType
        let walk: Float
        let bob: Float
        switch type {
        case .walk:
            walk = AvatarPose.walk(progress)
            // 上下颠一下跟着步子走，不是跟着位移走：位移在中段是平的（站着看孩子），
            // 那时该停下来，而不是继续飘。
            bob = abs(AvatarPose.strideOf(progress))
        case .celebrate:
            walk = 0
            bob = AvatarPose.jump(progress)
        case .scratch:
            walk = 0
            bob = 0
        }
        return Frame(pose: AvatarPose.interaction(type, progress), walk: walk, bob: bob, type: type)
    }

    private struct Frame {
        let pose: AvatarPose.Pose
        let walk: Float
        let bob: Float
        let type: AvatarPose.Interaction
    }

    private func canvas(rig: FoxRig, scarf: String, frame: Frame, equipProgress: Float) -> some View {
        let pose = frame.pose
        return Canvas { context, canvasSize in
            let box = min(canvasSize.width, canvasSize.height)
            guard box > 0 else { return }
            // 支点是按母版 viewBox 512 给的，绘制时折算到这个方框。
            let fit = box / FoxRig.canvas
            for layer in rig.layers {
                guard let image = layer.image(rig: rig, scarf: scarf, expression: pose.expression, avatar: avatarId) else {
                    // 表里没有的图层就整块不画：半只狐狸比没有狐狸更容易被当成显示故障报上来。
                    continue
                }
                let part = pose.part(layer.name)
                var ctx = context
                ctx.translateBy(x: box * CGFloat(part.dx), y: box * CGFloat(part.dy))
                let pivotX = layer.pivotX * fit
                let pivotY = layer.pivotY * fit
                if part.rotate != 0 {
                    ctx.translateBy(x: pivotX, y: pivotY)
                    ctx.rotate(by: .degrees(Double(part.rotate)))
                    ctx.translateBy(x: -pivotX, y: -pivotY)
                }
                if part.scaleY != 1 {
                    ctx.translateBy(x: pivotX, y: pivotY)
                    ctx.scaleBy(x: 1, y: CGFloat(part.scaleY))
                    ctx.translateBy(x: -pivotX, y: -pivotY)
                }
                // 位图解出来多大不重要，一律铺满这个方框；支点已经折算过了。
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: box, height: box))
            }
            // 成就佩戴：皇冠戴头顶、勋章挂胸前，叠在骨骼层之上。坐标与安卓/web 一致（512 画布）。
            let alpha = Double(min(1, equipProgress / 0.3))
            if achievementLevel >= 3, let crown = FoxRig.achievementImage("achievement_crown") {
                let dy = equipLerp(equipProgress, -140, 10, 0)
                let sc = equipLerp(equipProgress, 0.6, 1.1, 1)
                // 皇冠缩小上移坐头顶，避免压住眼睛（与 web/安卓同一坐标）。
                drawAccessory(context, image: crown, x: 181, y: 20, w: 150, fit: fit, dy: dy, scale: sc, rot: 0, alpha: alpha)
            }
            if let badge = achievementBadge, let medal = FoxRig.achievementImage("achievement_\(badge)") {
                let dy = equipLerp(equipProgress, 140, -12, 0)
                let sc = equipLerp(equipProgress, 0.2, 1.18, 1)
                let rot = equipLerp(equipProgress, -180, 8, 0)
                drawAccessory(context, image: medal, x: 196, y: 298, w: 120, fit: fit, dy: dy, scale: sc, rot: rot, alpha: alpha)
            }
        }
        .frame(width: size, height: size)
        // 压暗挂在整体上、只压一次：逐层各压一次会在头身交界留出一条深浅接缝。
        .opacity(opacity)
        // 整只狐狸的移动写在**视图自己**身上，不写在图层上。写在图层上就得逐层点名，
        // 漏一层那一层留在原地——Android 上一版正是手臂和尾巴没被点名，于是"身子跑了手脚还在原地"。
        .offset(x: CGFloat(frame.walk) * size * CGFloat(AvatarPose.walkWidths),
                y: -CGFloat(frame.bob) * size * (frame.type == .celebrate ? 0.18 : 0.07))
        // 走出去要压在题目卡上面：它是这一屏第一个孩子，不抬 zIndex 会被后面的卡盖住半只。
        .zIndex(frame.walk > 0 ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard playsOnTap else { return }
            clock.playInteraction()
        }
        .onAppear { clock.start(); greet() }
        .onDisappear { clock.stop() }
        // 别只靠 onDisappear：App 退到后台时视图仍然挂着，那一趟 ticker 会一直空转。
        .onChange(of: scenePhase) { phase in
            if phase == .active { clock.start(); greet() } else { clock.stop() }
        }
        // 答对庆祝、答错挠头：宿主把对应标志置 true 的那一刻演一次。
        .onChange(of: celebrate) { on in if on { clock.playInteraction(.celebrate) } }
        .onChange(of: scratch) { on in if on { clock.playInteraction(.scratch) } }
        .onChange(of: equip) { on in if on { clock.playEquip() } }
    }

    /// 画一枚勋章/皇冠：中心定位 + 佩戴动画的位移/缩放/旋转/透明度。
    private func drawAccessory(_ context: GraphicsContext, image: Image, x: CGFloat, y: CGFloat, w: CGFloat, fit: CGFloat, dy: CGFloat, scale: CGFloat, rot: Double, alpha: Double) {
        let size = w * fit
        let cx = (x + w / 2) * fit
        let cy = (y + w / 2) * fit + dy * fit
        var ctx = context
        ctx.translateBy(x: cx, y: cy)
        if rot != 0 { ctx.rotate(by: .degrees(rot)) }
        ctx.scaleBy(x: scale, y: scale)
        ctx.opacity = alpha
        ctx.draw(image, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
    }

    /// 佩戴动画三段插值：起点 → 过冲 → 落稳。
    private func equipLerp(_ p: Float, _ start: CGFloat, _ over: CGFloat, _ end: CGFloat) -> CGFloat {
        let pp = CGFloat(p)
        return pp < 0.55 ? start + (over - start) * (pp / 0.55) : over + (end - over) * ((pp - 0.55) / 0.45)
    }

    /// 开场那一次互动。必须在 `clock.start()` 之后叫：节拍器没跑起来时
    /// `playInteraction()` 会当成"这一刻不该演"直接返回 false，狐狸就永远不动。
    private func greet() {
        guard greetsOnAppear else { return }
        clock.playInteraction()
    }

    private var opacity: Double {
        switch playState {
        case .paused: return 0.72
        case .pendingParent: return 0.82
        default: return 1
        }
    }
}

/// 姿态的节拍器。
///
/// 用 `ProcessInfo.systemUptime` 而不是墙上时钟：它不含深度休眠的时间，和 Android
/// `SystemClock.uptimeMillis()` 是同一个量。动作相位拿墙上时钟算的话，孩子把手机锁一夜，
/// 回来那一秒的相位会跳到一个谁也说不清的位置。
@MainActor
final class FoxClock: ObservableObject {

    /// 待机那几档多久算一次姿态。一圈 3~5 秒的动作，5fps 和 60fps 在屏幕上是同一个东西。
    static let tickMs: Int64 = 300
    /// 互动期间多久算一次：孩子点一下才演的那两秒多，手臂 1.1 秒一圈，按帧才不跳格。
    static let frameMs: Int64 = 16
    /// 佩戴动画时长：勋章飞入挂稳、皇冠落下戴稳。
    static let equipMs: Int64 = 1300

    @Published private(set) var uptimeMs: Int64 = FoxClock.now()
    @Published private(set) var interactionEndsAtMs: Int64 = 0
    @Published private(set) var interactionType: AvatarPose.Interaction = .walk
    @Published private(set) var equipEndsAtMs: Int64 = 0

    private var task: Task<Void, Never>?

    var interactionRunning: Bool { uptimeMs < interactionEndsAtMs }
    var equipRunning: Bool { uptimeMs < equipEndsAtMs }

    /// 互动那一趟走到哪了；不在演的时候是 nil，调用方据此回到状态循环。
    var interactionProgress: Float? {
        guard interactionRunning else { return nil }
        return Float(AvatarPose.interactionMs - (interactionEndsAtMs - uptimeMs)) / Float(AvatarPose.interactionMs)
    }

    /// 佩戴动画进度；不在演的时候是 nil（调用方按落稳态画）。
    var equipProgress: Float? {
        guard equipRunning else { return nil }
        return Float(Self.equipMs - (equipEndsAtMs - uptimeMs)) / Float(Self.equipMs)
    }

    func start() {
        guard task == nil else { return }
        uptimeMs = Self.now()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.uptimeMs = Self.now()
                let interval = (self.interactionRunning || self.equipRunning) ? Self.frameMs : Self.tickMs
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // 界面不可见时不许停在"走到一半"的位置：回来时它该坐在原来的格子里。
        interactionEndsAtMs = 0
        interactionType = .walk
        equipEndsAtMs = 0
    }

    /// 演一次互动：走路（被点）、庆祝（答对）、挠头（答错）。返回 false 表示这一刻不该演。
    @discardableResult
    func playInteraction(_ type: AvatarPose.Interaction = .walk) -> Bool {
        guard task != nil, !interactionRunning else { return false }
        interactionType = type
        interactionEndsAtMs = Self.now() + AvatarPose.interactionMs
        uptimeMs = Self.now()
        return true
    }

    /// 演一次佩戴动画：孩子刚解锁徽章时调。
    func playEquip() {
        guard task != nil else { return }
        equipEndsAtMs = Self.now() + Self.equipMs
        uptimeMs = Self.now()
    }

    private static func now() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }
}
