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
    @State private var showDebug = false

    /// 宽屏 = iPad（以及 iPad 上的全屏分栏）。判据只有这一处：
    /// 首页、答题页共用同一个 `wide`，两屏的排版才不会一个两列一个单列。
    private var wide: Bool { horizontalSize == .regular }

    /// 五段，次序与 Android `activity_main.xml` 逐段相同（跨端视觉契约钉着）：
    /// 状态 hero → 倒计时 → 权限 → 最近发生的事 → 绑定码（仅未绑定时）。
    /// 宽屏上第三、四段并两列，但**次序不变**：响应式只改排布，不改段落。
    var body: some View {
        ZStack {
            Theme.pageGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    if let note = model.monitoringNote {
                        BannerView(text: note, tone: .warn)
                    }
                    if let banner = model.banner {
                        BannerView(text: banner, tone: .danger)
                    }
                    statusHero
                    // iOS 没有无障碍服务替孩子把答题页顶到最前，落盾之后这一屏就是唯一的出口，
                    // 所以这颗按钮是 iOS 独有的第六块——它占的正是 Android 自动抢屏那一格。
                    if model.state.shieldApplied { answerCard }
                    countdownCard
                    LazyVGrid(columns: cardGridColumns(wide: wide), alignment: .leading,
                              spacing: Theme.Space.s4) {
                        permissionCard
                        faultCard
                    }
                    if !model.state.deviceBound { bindCard }
                    footer
                    #if DEBUG
                    if showDebug { shieldDebugCard }
                    #endif
                }
                .padding(Theme.Space.s4)
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

        // 段内次序与 Android hero 卡逐格相同：形象 + 引子 → 大标题 → 一句正文。
        // 引子那一格 Android 放的是「正在玩「XXX」」这枚 chip，iOS 拿不到前台包名，
        // 写不出这句事实，于是这一格只放状态色圆点——位置留着，内容不编。
        return VStack(alignment: .leading, spacing: Theme.Space.s2) {
            HStack(spacing: Theme.Space.s3) {
                // 家长在后台挑的那只：编号走心跳，动作走本机判定。
                // 编号认不出来时它自己整块不画、不留空位，和"还没有形象"时长得一样。
                AvatarRigView(avatarId: model.state.avatarId ?? 0,
                              playState: model.currentPlayState(),
                              size: Theme.Metric.avatarHero)
                Circle()
                    .fill(tone == .ok ? Theme.Palette.ok : (tone == .warn ? Theme.Palette.warn : Theme.Palette.danger))
                    .frame(width: Theme.Metric.toneDot, height: Theme.Metric.toneDot)
                Spacer(minLength: 0)
            }
            Text(title)
                .font(.system(size: Theme.Text.hero, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
                // 8 的段间距 + 这 4 = Android 那个 `layout_marginTop=space_3`（12）。
                .padding(.top, Theme.Space.s1)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: Theme.Text.body))
                .foregroundStyle(Theme.Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard()
        // 会改变闸门行为的开关一律收进长按才出现的调试卡，界面上不留一颗就能放行的洞。
        // 和 Android 长按页头是同一个手势、同一个意图。
        .onLongPressGesture(minimumDuration: 0.8) {
            #if DEBUG
            showDebug.toggle()
            #endif
        }
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text("被挡住了？答一道题就放行")
                .font(.system(size: Theme.Text.control, weight: .bold))
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

        // 段内次序同 Android：标题行（左标题 + 右大数字）→ 进度条 → 一行小字。
        // 大数字用 hero 那一档（34），它是这一屏孩子唯一需要一眼读到的数。
        return VStack(alignment: .leading, spacing: Theme.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text("这一轮还能玩")
                    .font(.system(size: Theme.Text.control, weight: .bold))
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: Theme.Space.s3)
                // 「约」字是必须的：iOS 的时长来自阈值阶梯，不是秒级计时。
                Text(threshold > 0 ? "约 \(remaining) 分钟" : "家长还没设时长")
                    .font(.system(size: Theme.Text.hero, weight: .bold))
                    .foregroundStyle(Theme.Palette.brand600)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.surfaceSunken)
                    Capsule()
                        // brand_400 → brand_600 的横向渐变，取自 Android `bg_progress_fill.xml`。
                        .fill(LinearGradient(colors: [Theme.Palette.brand400, Theme.Palette.brand600],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * fraction, 0))
                }
            }
            .frame(height: Theme.Metric.progressHeight)
            // 8 的段间距 + 这 8 = Android 进度条那个 `layout_marginTop=space_4`（16）。
            .padding(.top, Theme.Space.s2)
            Text(threshold > 0
                 ? "本轮已玩约 \(playedMinutes) 分钟 / 初始时长 \(threshold) 分钟"
                 : "家长还没设这一轮的时长")
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(Theme.Palette.inkFaint)
        }
        .card()
    }

    /// 只读清单。和 Android 一样：孩子看得到闸门靠什么工作，但改不了。
    /// 标题文案与 Android `home_permission_title` 逐字相同——两端同一句话，家长换机不用重学。
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text("能不能正常工作")
                .font(.system(size: Theme.Text.control, weight: .bold))
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
                .font(.system(size: Theme.Text.control, weight: .bold))
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
            // 通道状态和判定档位从这一版起是两件事：隧道只要闸门开着就一直连着，
            // 到点只是换一次路由。少这一行，"VPN 图标亮了"就会被当成"已经在拦了"。
            Text(model.vpnRouteNote)
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(Theme.Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    /// 第四段：最近发生的事。空的时候也留这一块并写"没有"——
    /// 家长要确认的是"动过没有"，一块消失的卡回答不了这个问题。
    private var faultCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("最近发生的事")
                .font(.system(size: Theme.Text.control, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
            if model.state.faults.isEmpty {
                Text("最近没有发生什么。")
                    .font(.system(size: Theme.Text.caption))
                    .foregroundStyle(Theme.Palette.inkFaint)
            } else {
                ForEach(model.state.faults.suffix(5).reversed(), id: \.self) { fault in
                    Text("· \(fault)")
                        .font(.system(size: Theme.Text.caption))
                        .foregroundStyle(Theme.Palette.inkFaint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// 第五段：绑定码，只在还没对上号时出现。那六个字符是一次性的，
    /// 认过之后继续摆着，家长会一次次抄一个用掉的码。
    ///
    /// 结构、文案、字距全部照 Android `linkCard` 抄：标题 → 大号码 → 一句怎么办。
    /// 码下面**不垫色块**（Android 没有），垫了会让这六个字符看起来像一个可点的按钮，
    /// 而它只能被抄走。
    private var bindCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("让家长和这台设备对上")
                .font(.system(size: Theme.Text.control, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
            Text(model.state.bindCode?.isEmpty == false ? model.state.bindCode! : "— — — — — —")
                .font(.system(size: Theme.Text.hero, weight: .bold))
                // Android 那边是 `letterSpacing=0.18`（em），34sp 上折成约 6pt。
                .kerning(6)
                // 取色同 Android `renderLink`：有码是 brand_600，占位那排虚线是 ink_faint。
                // 占位符要是也用深色，家长会以为那六个字符就是码。
                .foregroundStyle(model.state.bindCode?.isEmpty == false
                                 ? Theme.Palette.brand600 : Theme.Palette.inkFaint)
                .padding(.top, Theme.Space.s1)
            if model.state.bindCode?.isEmpty == false {
                Text("在家长后台打开这个孩子的页面，把上面这六个字符抄进「认领孩子手机」那一栏，这台手机的闸门记录就会出现在你名下。没认领之前记录只留在这台手机上。")
                    .font(.system(size: Theme.Text.body))
                    .foregroundStyle(Theme.Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("还没连上服务器，连上之后这里会出现绑定码。")
                    .font(.system(size: Theme.Text.body))
                    .foregroundStyle(Theme.Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// 页脚两行，逐行照 Android 页脚抄：先通道状态，后版本号 + 离线行为。
    /// 通道那一句**不跟着绑定码一起消失**：绑定之后家长还是要能看出"上报堆着了"。
    private var footer: some View {
        VStack(spacing: Theme.Space.s1) {
            Text(model.channelNote)
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(model.channelBacklogged ? Theme.Palette.warn : Theme.Palette.inkFaint)
            Text(Self.versionLine)
                .font(.system(size: Theme.Text.caption))
                .foregroundStyle(Theme.Palette.inkFaint)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        // 16 的段间距 + 这 8 = Android 页脚那个 `layout_marginTop=space_6`（24）。
        .padding(.top, Theme.Space.s2)
    }

    private static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "\(version) · 断网时使用本地题目，联网后向家长服务端同步用量与闸门状态"
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