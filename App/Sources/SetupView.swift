import FamilyControls
import SwiftUI
import QuizGateKit

/// 一次性本机 setup。家长拿着孩子这台手机做完这两步，之后才回 Vue 后台调时长。
///
/// 为什么选 App 必须在这里做：FamilyActivitySelection 里的 token 是不透明的，
/// 不能转成 bundle id 传后端再传回来。家长在自己手机上选了也传不过来。
struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.pageGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s6) {
                    header
                    authorizationCard
                    selectionCard
                    bindCard
                    if let banner = model.banner {
                        BannerView(text: banner, tone: .warn)
                    }
                }
                .padding(Theme.Space.s5)
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
            Text("把这台 iPhone 交给家长")
                .font(.system(size: Theme.Text.title, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
            Text("下面两步必须在这台机器上做一次。做完之后，时长规则可以在家长后台远程改。")
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

    private var bindCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            StepTitle(index: 3, text: "在家长后台输入绑定码", done: model.state.deviceBound)
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