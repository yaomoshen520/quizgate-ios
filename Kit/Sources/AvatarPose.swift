import Foundation

/// 切层骨骼的编排表：每一档状态里，哪一层、绕哪个支点、扭多少。
///
/// **这一份是 Android `app/src/main/java/com/quizgate/spike/ui/AvatarPose.kt` 的逐条对拷**，
/// 数值、图层名、运算次序都不改。四端（后台 FoxRig.vue 的 @keyframes、Android 这一份、
/// iOS 这一份、母版 SVG）共用同一套数，漂移的口子由素材导出脚本堵：它逐个核对点名的
/// 图层在各端编排表里存在，漏一层就红。那种错的长相是"后台在跳、手机在抽"，
/// 没人会当 bug 报，只当成手机卡。
///
/// 位移一律按画布边长的比例给（0.01 = 1% 画布），所以 44pt 的首页入口和答题页大图
/// 用的是同一个动作，只是幅度按各自尺寸缩放。
///
/// 幅度那批数不是按"这个角度看着舒服"定的，是按**屏幕上挪了几个像素**定的：512 的画布
/// 缩到 40pt 时，位移 40 个单位只剩 3 像素，动画确实挂着，眼睛看不见。后台
/// web/scripts/fox-motion-check.mjs 量的是这个数（最小那一档也要 3 像素以上），
/// 改一边就得改另一边。
public enum AvatarPose {

    /// 整张表都是 Float，π 也单独存一份 Float 的，免得一路转换。
    /// 与 Kotlin 那份写的是同一个十进制字面量（3.14159265f），不是 Float.pi ——
    /// 两者差 1 ULP，会让 sin 的输入先差一档。
    static let piF: Float = 3.14159265

    public static let layerTail = "layer-tail"
    public static let layerBody = "layer-body"
    public static let layerHind = "layer-hind"
    public static let layerClock = "layer-clock"
    public static let layerArmLeft = "layer-arm-left"
    public static let layerArmRight = "layer-arm-right"
    public static let layerEars = "layer-ears"
    public static let layerHead = "layer-head"
    public static let layerFace = "layer-face"
    public static let layerScarf = "layer-scarf"

    public static let exprIdle = "idle"
    public static let exprHappy = "happy"
    public static let exprThink = "think"

    /// 一次呼吸 4 秒、一次甩尾 5.2 秒：各层按自己的周期走，合成起来才不像节拍器。
    static let breathMs: Float = 4_000
    static let tailSlowMs: Float = 5_200
    static let wagMs: Float = 820
    static let hopMs: Float = 1_100
    static let tiltMs: Float = 3_400
    static let twitchMs: Float = 4_600
    static let shakeMs: Float = 420

    /// 一层的变换。字段名和 Android 那份 `Part` 一致，绘制端按同一套读。
    public struct Part: Equatable, Sendable {
        public var rotate: Float = 0
        public var dx: Float = 0
        public var dy: Float = 0
        public var scaleY: Float = 1

        public init(rotate: Float = 0, dx: Float = 0, dy: Float = 0, scaleY: Float = 1) {
            self.rotate = rotate
            self.dx = dx
            self.dy = dy
            self.scaleY = scaleY
        }

        /// 恒等 = 这一层这一刻不用变换，绘制端据此跳过。
        public var isIdentity: Bool { rotate == 0 && dx == 0 && dy == 0 && scaleY == 1 }
    }

    /// 一刻的姿态。**被点名的层即使算出来是恒等也留在表里**（和 Android 的
    /// `pose.part(x)` 语义相同）：绘制端靠"有没有被点名"决定要不要读这一层，
    /// 而单测靠"点了几层"判断整档有没有被做出来。
    public struct Pose: Equatable, Sendable {
        public let expression: String
        public let parts: [String: Part]

        public func part(_ layer: String) -> Part { parts[layer] ?? Part() }
        public var layers: Set<String> { Set(parts.keys) }
    }

    /// 这一档该配哪张表情，和后台 expression 那个 computed、Android expressionOf 是同一张映射。
    public static func expressionOf(_ state: AvatarPlayState) -> String {
        switch state {
        case .playing: return exprHappy
        case .quiz, .warning: return exprThink
        case .idle, .paused, .pendingParent: return exprIdle
        }
    }

    /// 状态循环在某个绝对时刻的画面。
    ///
    /// PAUSED 和 PENDING_PARENT 是**恒等变换**：后台那两档也只做整体压暗、不扭任何一层，
    /// 所以这里也不许多演——两屏不一致时，家长只会怀疑手机报假了。
    /// 这两档返回的表是**空的**（一层都不点名），不是"点了十层全是恒等"。
    public static func loop(_ state: AvatarPlayState, nowMs: Int64) -> Pose {
        var parts: [String: Part] = [:]
        switch state {
        case .paused, .pendingParent:
            break

        case .idle:
            parts[layerBody] = breathed(phaseOf(nowMs, breathMs))
            parts[layerTail] = Part(rotate: swing(phaseOf(nowMs, tailSlowMs), -9, 15))
            // 待机时耳朵偶尔抖一下：这几格都只有 40~76pt，光靠呼吸看不出来。
            parts[layerEars] = Part(rotate: twitch(phaseOf(nowMs, twitchMs)))

        case .playing:
            let hop = phaseOf(nowMs, hopMs)
            parts[layerBody] = hopped(hop)
            parts[layerTail] = Part(rotate: swing(phaseOf(nowMs, wagMs), -26, 21))
            parts[layerArmLeft] = Part(rotate: swing(hop, -18, 20))
            parts[layerArmRight] = Part(rotate: swing(hop, 18, -20))

        case .quiz:
            parts[layerHead] = Part(rotate: swing(phaseOf(nowMs, tiltMs), -14, 14))
            // 耳朵只在 62%~78% 那一小段动，其余时间是直的：抽样只取半周期会看到"没动"。
            parts[layerEars] = Part(rotate: twitch(phaseOf(nowMs, twitchMs)))

        case .warning:
            let p = phaseOf(nowMs, shakeMs)
            parts[layerHead] = Part(rotate: swing(p, -12, 12))
            parts[layerEars] = Part(rotate: swing(p, 0, -9), dy: swing(p, 0, 22 / canvas))
        }
        return Pose(expression: expressionOf(state), parts: parts)
    }

    /// 答题页那一下互动：整只走出去 → 停一下回头看看孩子 → 再走回来。
    ///
    /// **这里只管四肢怎么倒腾，不管位移。** 位移以前写在图层上，谁没被点名就留在原地——
    /// 手臂和尾巴只转不移、后腿只跟三成，结果就是"身子跑了手脚还在原地"。
    /// 整只一起走改由绘制端平移整个视图，十个图层天然同步，少写一层也不会漏。
    public static func interaction(_ progress: Float) -> Pose {
        let stride = strideOf(progress)
        let parts: [String: Part] = [
            layerArmLeft: Part(rotate: 20 * stride),
            layerArmRight: Part(rotate: -20 * stride),
            layerHind: Part(rotate: 14 * stride),
            layerTail: Part(rotate: 22 * stride),
            layerEars: Part(rotate: -6 * stride),
        ]
        return Pose(expression: exprHappy, parts: parts)
    }

    /// 走出去多远：按**这个视图自己宽度**的倍数算，3.2 倍 = 真的离开那格，不是原地挪一挪。
    public static let walkWidths: Float = 3.2

    /// 一趟走的进度表（0 起步 → 1 走到最远 → 回 0）。视图按它平移自己。
    public static func walk(_ progress: Float) -> Float {
        let p = clamped01(progress)
        // 回来那一段用 (1-p) 而不是 1-(p-0.65)/0.35：后者在 float 里到 p=1 时差出 1e-7，
        // 于是"结束时回到原位"变成"结束时停在 1e-13 的位置"——看着无所谓，断言却永远绿不了。
        let raw: Float
        if p < 0.35 {
            raw = ease(p / 0.35)
        } else if p < 0.65 {
            raw = 1
        } else {
            raw = ease((1 - p) / 0.35)
        }
        return clamped01(raw)
    }

    /// 六步一路的抬腿相位，四肢的摆动和视图的上下颠一下都用它，免得两处各数一遍步子。
    public static func strideOf(_ progress: Float) -> Float {
        sinF(2 * piF * clamped01(progress) * 6)
    }

    /// 画布边长：母版的 viewBox 是 512，素材导出脚本把它一起写进了几何表。
    public static let canvas: Float = 512

    /// 互动一趟多久：走出去、回头看一眼、再走回来。再长就要挡住孩子读题了。
    public static let interactionMs: Int64 = 2_400

    static func phaseOf(_ nowMs: Int64, _ periodMs: Float) -> Float {
        let p = Float(nowMs % Int64(periodMs)) / periodMs
        return p < 0 ? p + 1 : p
    }

    /// 首尾回到 A、中间到 B 的平滑一趟，对应 CSS 那条 0%/50%/100% 的 ease-in-out。
    static func swing(_ phase: Float, _ from: Float, _ to: Float) -> Float {
        from + (to - from) * sinF(piF * phase)
    }

    static func breathed(_ phase: Float) -> Part {
        let t = sinF(piF * phase)
        return Part(dy: (-40 / canvas) * t, scaleY: 1 + 0.1 * t)
    }

    /// 耳朵一整圈只在 62%~78% 那一小段抖两下，其余时间是直的——和后台那条 keyframes 同形状。
    static func twitch(_ phase: Float) -> Float {
        keys(phase, (0, 0), (0.62, 0), (0.70, -18), (0.78, 14), (1, 0))
    }

    /// 落地那一下只抬半格：0%→45% 起跳、60% 已接近落地、100% 归零。dy 为负是往上。
    static func hopped(_ phase: Float) -> Part {
        Part(dy: keys(phase, (0, 0), (0.45, -72 / canvas), (0.60, -14 / canvas), (1, 0)))
    }

    static func keys(_ phase: Float, _ stops: (Float, Float)...) -> Float {
        keys(phase, stops)
    }

    static func keys(_ phase: Float, _ stops: [(Float, Float)]) -> Float {
        guard stops.count > 1 else { return stops.last?.1 ?? 0 }
        for i in 1..<stops.count {
            let at = stops[i].0
            let before = stops[i - 1].0
            let was = stops[i - 1].1
            if phase <= at {
                let span = at - before
                let t = span <= 0 ? 1 : (phase - before) / span
                return was + (stops[i].1 - was) * t
            }
        }
        return stops[stops.count - 1].1
    }

    /// 平滑起步/停步，走出去那几步不至于匀速平移。
    static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    static func clamped01(_ v: Float) -> Float { min(max(v, 0), 1) }

    /// **刻意在 Double 里算完再收窄成 Float**：Kotlin/JVM 的 `kotlin.math.sin(Float)` 就是
    /// 先转 double 调 `Math.sin` 再 `.toFloat()`，直接用 Swift 的 `sin(Float)`（sinf）
    /// 会与它差到 1 ULP。差 1 ULP 在屏幕上看不见，但两端各写一份数就再没有"同一套"可言了。
    static func sinF(_ x: Float) -> Float { Float(sin(Double(x))) }
}
