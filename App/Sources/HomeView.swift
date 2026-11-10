import SwiftUI
import QuizGateKit

/// 孩子平时看到的那一屏。
///
/// 和 Android 首页最大的不同：倒计时只能显示「约」。
/// Android 是无障碍一秒一秒累出来的，iOS 拿不到前台 App，
/// 时长只能由聚合阈值事件推算，精度上限就是阈值粒度。显示到秒是在骗孩子。
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSize

    /// 宽屏 = iPad（以及 iPad 上的全屏分栏）。判据只有这一处：
    /// 首页、答题页共用同一个 `wide`，两屏的排版才不会一个两列一个单列。
    private var wide: Bool { horizontalSize == .regular }

    var body: some View {
        ZStack {
            Theme.pageGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s5) {
                    statusHero
                    if model.state.shieldApplied { answerCard }
                    // 宽屏上这三块并两列；诊断卡和故障卡刻意留在整列宽，
                    // 它们的内容是长句子和日志行，两列会把每行都劈成两段。
                    LazyVGrid(columns: cardGridColumns(wide: wide), alignment: .leading,
                              spacing: Theme.Space.s5) {
                        countdownCard
                        permissionCard
                        if !model.state.faults.isEmpty { faultCard }
                    }
                    shieldDebugCard
                    if let note = model.monitoringNote {
                        BannerView(text: note, tone: .warn)
                    }
                    if let banner = model.banner {
                        BannerView(text: banner, tone: .danger)
                    }
                }
                .padding(Theme.Space.s5)
                .readableColumn()
            }
        }
    }

    private var statusHero: some View {
        let decision = model.decision
        let title: String
        let subtitle: String
        let tone: BannerView.Tone

        switch decision {
        case .shield:
            title = "该答题啦"
            subtitle = "玩满这一轮了，答对一道就能继续"
            tone = .warn
        case .allow:
            title = "闸门在岗"
            subtitle = "到时间会提醒你答题"
            tone = .ok
        case .cannotEnforce(let why):
            title = "闸门现在拦不住"
            switch why {
            case .notAuthorized: subtitle = "请家长来授权屏幕使用时间"
            case .noSelection: subtitle = "请家长来选要管的 App"
            case .noRule: subtitle = "还没连上服务器拿到规则"
            case .stateCorrupt: subtitle = "本地状态坏了，请连一次服务器"
            }
            tone = .danger
        }

        return VStack(alignment: .leading, spacing: Theme.Space.s3) {
            HStack(spacing: Theme.Space.s3) {
                Circle()
                    .fill(tone == .ok ? Theme.Palette.ok : (tone == .warn ? Theme.Palette.warn : Theme.Palette.danger))
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(.system(size: Theme.Text.title, weight: .bold))
                    .foregroundStyle(Theme.Palette.ink)
            }
            Text(subtitle)
                .font(.system(size: Theme.Text.body))
                .foregroundStyle(Theme.Palette.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text("被挡住了？答一道题就放行")
                .font(.system(size: Theme.Text.control, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Button {
                Task { await model.loadQuestion() }
            } label: {
                Text(model.busy ? "正在取题…" : "开始答题")
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeightLarge)
            }
            .buttonStyle(PrimaryButtonStyle(disabled: model.busy))
            .disabled(model.busy)
        }
        .card()
    }

    private var countdownCard: some View {
        let threshold = model.state.rule?.thresholdMinutes ?? 0
        let playedMinutes = Int(model.state.ledger.playedMs / 60_000)
        let remaining = max(threshold - playedMinutes, 0)
        let fraction = threshold > 0 ? min(Double(playedMinutes) / Double(threshold), 1) : 0

        return VStack(alignment: .leading, spacing: Theme.Space.s3) {
            HStack {
                Text("这一轮还能玩")
                    .font(.system(size: Theme.Text.label))
                    .foregroundStyle(Theme.Palette.inkSoft)
                Spacer()
                // 「约」字是必须的：iOS 的时长来自阈值阶梯，不是秒级计时。
                Text(threshold > 0 ? "约 \(remaining) 分钟" : "家长还没设时长")
                    .font(.system(size: Theme.Text.title, weight: .bold))
                    .foregroundStyle(Theme.Palette.brand600)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.surfaceSunken)
                    Capsule()
                        .fill(Theme.Palette.brand500)
                        .frame(width: max(geo.size.width * fraction, 0))
                }
            }
            .frame(height: Theme.Metric.progressHeight)
            Text("本轮已玩约 \(playedMinutes) 分钟 · 答对 \(model.state.ledger.correctCount) 道")
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(Theme.Palette.inkFaint)
        }
        .card()
    }

    /// 只读清单。和 Android 一样：孩子看得到闸门靠什么工作，但改不了。
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text("闸门靠什么工作")
                .font(.system(size: Theme.Text.control, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            PermissionRow(name: "屏幕使用时间授权",
                          ok: model.state.authorization?.isApproved == true)
            PermissionRow(name: "已选要管的 App",
                          ok: model.state.selectionData != nil)
            PermissionRow(name: "连上家长服务器",
                          ok: model.state.lastSyncAtMs != nil)
            PermissionRow(name: "已绑定到家长账号",
                          ok: model.state.deviceBound)
            // 「到点提示」这一行不是一格勾，是一句话：排没排进系统、排在几分钟后、
            // 没排是为啥，家长拿这一行才能把「提示不准时」和「压根没排上」分开。
            Text(model.promptNote)
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(Theme.Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    /// 落盾诊断卡（调试，查完整段删）。侧载装上后强制写盾+回读，
    /// 再冷启动红果看系统到底执不执行。
    private var shieldDebugCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text("落盾诊断（调试）")
                .font(.system(size: Theme.Text.control, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("点“强制落盾”，再把红果彻底关掉重开，看是否被蓝色盾牌挡住。")
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(Theme.Palette.inkSoft)
            HStack(spacing: Theme.Space.s3) {
                Button { model.debugForceShield() } label: {
                    Text("强制落盾")
                        .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button { model.debugClearShield() } label: {
                    Text("清盾")
                        .frame(minHeight: Theme.Metric.controlHeight)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Button { model.debugVpnCutoff(true) } label: {
                Text("试一次掐网")
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button { model.debugVpnCutoff(false) } label: {
                Text("试一次放行")
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            // 这一行是本轮的读数落点：起隧道是异步的，"受理"和"扩展真起来了"隔着一格 status，
            // 而家长手里只有这一行能把两者分开看。
            Text(model.vpnNote)
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(Theme.Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var faultCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("最近发生的事")
                .font(.system(size: Theme.Text.label, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkSoft)
            ForEach(model.state.faults.suffix(5).reversed(), id: \.self) { fault in
                Text("· \(fault)")
                    .font(.system(size: Theme.Text.caption))
                    .foregroundStyle(Theme.Palette.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct PermissionRow: View {
    let name: String
    let ok: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Theme.Palette.ok : Theme.Palette.warn)
            Text(name)
                .font(.system(size: Theme.Text.body))
                .foregroundStyle(Theme.Palette.ink)
            Spacer()
            Text(ok ? "正常" : "缺")
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(ok ? Theme.Palette.ok : Theme.Palette.warn)
        }
        .frame(minHeight: Theme.Metric.chipHeight)
    }
}