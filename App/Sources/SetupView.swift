import FamilyControls
import SwiftUI
import UserNotifications
import QuizGateKit

/// 一次性本机 setup。家长拿着孩子这台手机做完这几步，之后才回 Vue 后台调时长。
///
/// 为什么选 App 必须在这里做：FamilyActivitySelection 里的 token 是不透明的，
/// 不能转成 bundle id 传后端再传回来。家长在自己手机上选了也传不过来。
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSize

    private var wide: Bool { horizontalSize == .regular }

    var body: some View {
        ZStack {
            Theme.pageGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s6) {
                    header
                    // 四步是有序的，宽屏上两列也仍然从左到右、从上到下读得通；
                    // 单列在 iPad 上会把每一步都拉成一条横幅，家长反而看不清哪一步还没做。
                    LazyVGrid(columns: cardGridColumns(wide: wide), alignment: .leading,
                              spacing: Theme.Space.s6) {
                        authorizationCard
                        selectionCard
                        promptCard
                        bindCard
                    }
                    if let banner = model.banner {
                        BannerView(text: banner, tone: .warn)
                    }
                }
                .padding(Theme.Space.s5)
                .readableColumn()
            }
        }
        .familyActivityPicker(isPresented: $model.showSelectionPicker, selection: $model.selection)
        .onChange(of: model.showSelectionPicker) { presented in
            // 选择器收起时才落盘：中途每勾一下就写一次会把 App Group 写爆。
            if !presented { model.saveSelection() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            // 这句原来写死「这台 iPhone」。同一枚包现在也装 iPad，指引不能跟着设备变口径。
            Text("把这台设备交给家长")
                .font(.system(size: Theme.Text.title, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
            Text("下面几步必须在这台机器上做一次。做完之后，时长规则可以在家长后台远程改。")
                .font(.system(size: Theme.Text.body))
                .foregroundStyle(Theme.Palette.inkSoft)
        }
    }

    private var authorizationCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            StepTitle(index: 1, text: "允许管理屏幕使用时间",
                      done: model.state.authorization?.isApproved == true)
            Text("系统会弹出一个窗口，需要家长用自己的 Apple 账号批准。")
                .font(.system(size: Theme.Text.label))
                .foregroundStyle(Theme.Palette.inkSoft)
            Toggle("这是孩子的设备（需要家庭共享）", isOn: $model.useChildAuthorization)
                .font(.system(size: Theme.Text.label))
                .tint(Theme.Palette.brand500)
            Button {
                Task { await model.requestAuthorization() }
            } label: {
                Text(model.state.authorization?.isApproved == true ? "已授权" : "去授权")
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
            }
            .buttonStyle(PrimaryButtonStyle(disabled: model.busy))
            .disabled(model.busy)
        }
        .card()
    }

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            StepTitle(index: 2, text: "选出要管的 App", done: model.state.selectionData != nil)
            Text("选中的 App 玩满设定时长后会被挡住，孩子答对一道题才能继续。")
                .font(.system(size: Theme.Text.label))
                .foregroundStyle(Theme.Palette.inkSoft)
            Button {
                model.showSelectionPicker = true
            } label: {
                Text(model.state.selectionData == nil ? "去选择" : "重新选择")
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
            }
            .buttonStyle(PrimaryButtonStyle(disabled: model.state.authorization?.isApproved != true))
            .disabled(model.state.authorization?.isApproved != true)
        }
        .card()
    }

    private var promptCard: some View {
        let status = model.promptStatus
        let granted = status?.promptGranted == true
        return VStack(alignment: .leading, spacing: Theme.Space.s4) {
            StepTitle(index: 3, text: "允许答题提醒", done: granted)
            Text("盾牌只能把 App 挡住，不会替我们说「去答题」。这一项不开，孩子看到的就是一个打不开的图标，多半直接放弃，闸门就变成了纯粹的坏体验。")
                .font(.system(size: Theme.Text.label))
                .foregroundStyle(Theme.Palette.inkSoft)
            if status == .denied {
                // 被拒过一次之后，App 里再调 requestAuthorization 永远拿回 false，
                // 弹窗不会再出现。这一格里唯一有用的是那颗跳设置的按钮。
                Text("提醒被拒了，系统里不会再问第二次，只能去设置里手动打开。")
                    .font(.system(size: Theme.Text.label))
                    .foregroundStyle(Theme.Palette.warn)
                Button {
                    model.openPromptSettings()
                } label: {
                    Text("去系统设置")
                        .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    Task { await model.enablePrompt() }
                } label: {
                    Text(granted ? "已开启" : "开启提醒")
                        .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
                }
                .buttonStyle(PrimaryButtonStyle(disabled: granted))
                .disabled(granted)
            }
        }
        .card()
    }

    private var bindCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            StepTitle(index: 4, text: "在家长后台输入绑定码", done: model.state.deviceBound)
            if let code = model.state.bindCode, !model.state.deviceBound {
                Text(code)
                    .font(.system(size: Theme.Text.hero, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Palette.brand600)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeightLarge)
                    .background(Theme.Palette.brand100)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                Text("家长登录后台，在「孩子设置」里输入这六个字符。")
                    .font(.system(size: Theme.Text.label))
                    .foregroundStyle(Theme.Palette.inkSoft)
            } else if model.state.deviceBound {
                Text("已经绑定好了")
                    .font(.system(size: Theme.Text.body))
                    .foregroundStyle(Theme.Palette.ok)
            } else {
                Text("还没连上服务器，连上之后这里会出现绑定码。")
                    .font(.system(size: Theme.Text.label))
                    .foregroundStyle(Theme.Palette.inkSoft)
            }
        }
        .card()
    }
}

struct StepTitle: View {
    let index: Int
    let text: String
    let done: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s3) {
            Text(done ? "✓" : "\(index)")
                .font(.system(size: Theme.Text.label, weight: .bold))
                .foregroundStyle(done ? Theme.Palette.ok : Theme.Palette.inkOnBrand)
                .frame(width: 26, height: 26)
                .background(done ? Theme.Palette.okBg : Theme.Palette.brand500)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: Theme.Text.control, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer()
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var disabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.Text.control, weight: .semibold))
            .foregroundStyle(Theme.Palette.inkOnBrand)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(disabled ? Theme.Palette.brand300
                          : (configuration.isPressed ? Theme.Palette.brand700 : Theme.Palette.brand500))
            )
            .contentShape(Rectangle())
    }
}

struct BannerView: View {
    enum Tone { case ok, warn, danger }
    let text: String
    var tone: Tone = .warn

    var body: some View {
        Text(text)
            .font(.system(size: Theme.Text.label))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.s4)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var foreground: Color {
        switch tone {
        case .ok: return Theme.Palette.ok
        case .warn: return Theme.Palette.warn
        case .danger: return Theme.Palette.danger
        }
    }

    private var background: Color {
        switch tone {
        case .ok: return Theme.Palette.okBg
        case .warn: return Theme.Palette.warnBg
        case .danger: return Theme.Palette.dangerBg
        }
    }
}