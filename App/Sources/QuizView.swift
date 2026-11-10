import SwiftUI
import QuizGateKit

/// 答题页。这页是闸门唯一的出口：答对才解盾，所以判分必须在服务端，
/// 客户端拿到的是「对不对 + 解析」，永远拿不到正确项下标（协议里就没有这个字段）。
struct QuizView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSize

    /// 和首页同一个判据：宽屏上题干和选项都收进限宽列，别拉成横幅。
    private var wide: Bool { horizontalSize == .regular }

    var body: some View {
        ZStack {
            Theme.pageGradient.ignoresSafeArea()
            if let question = model.question {
                content(question)
            }
            if model.answeredCorrect {
                successLayer
            }
        }
    }

    /// 选项列数。宽屏两列、窄屏一列，和首页卡片同一个道理：
    /// 四个选项在 iPad 上竖成一列时，最后一个离题干有一屏远，孩子点它是靠记忆而不是靠读题。
    private var optionColumns: [GridItem] {
        if wide { return [GridItem(.adaptive(minimum: 280), spacing: Theme.Space.s4)] }
        return [GridItem(.flexible(), spacing: Theme.Space.s4)]
    }

    private func content(_ question: Quizgate_Question) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s5) {
                HStack {
                    // 三枚标签在窄屏上会挤到「关闭」那颗按钮 off-screen，所以标签可截断、
                    // 按钮不可压缩：知识点名字长是常态，关闭入口消失了孩子就退不出这一屏。
                    Chip(text: label(question.subject))
                        .fixedSize(horizontal: true, vertical: false)
                    Chip(text: "第 \(question.grade) 年级")
                        .fixedSize(horizontal: true, vertical: false)
                    if !question.knowledgePoint.isEmpty {
                        Chip(text: question.knowledgePoint)
                            .frame(maxWidth: wide ? 260 : 140, alignment: .leading)
                    }
                    Spacer(minLength: Theme.Space.s2)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.Palette.inkFaint)
                    }
                    .frame(width: Theme.Metric.controlHeight, height: Theme.Metric.controlHeight)
                }

                Text(question.stem)
                    .font(.system(size: Theme.Text.stem, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: optionColumns, alignment: .leading, spacing: Theme.Space.s4) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        OptionButton(text: option, chosen: model.explanation != nil) {
                            Task { await model.submitAnswer(index: index) }
                        }
                        .disabled(model.busy || model.explanation != nil)
                    }
                }

                if model.busy && model.explanation == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
                }

                if let explanation = model.explanation {
                    VStack(alignment: .leading, spacing: Theme.Space.s2) {
                        Text("再想一步")
                            .font(.system(size: Theme.Text.label, weight: .bold))
                            .foregroundStyle(Theme.Palette.noteInk)
                        Text(explanation)
                            .font(.system(size: Theme.Text.body))
                            .foregroundStyle(Theme.Palette.noteInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.s4)
                    .background(Theme.Palette.noteBg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.Palette.noteStroke, lineWidth: 1)
                    )

                    Button {
                        Task { await model.loadQuestion() }
                    } label: {
                        // 「新题」两个字是承诺：答错之后屏幕上换掉的必须是另一道题，
                        // 而不是这一道再来一遍（旧服务端有过那条回退，现在客户端会重试抹平）。
                        Text("看一道新题")
                            .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                if let banner = model.banner {
                    BannerView(text: banner, tone: .danger)
                }
            }
            .padding(Theme.Space.s5)
            .readableColumn()
        }
    }

    /// 答对确认层：整屏铺满不透明，把题目收干净，只留「可以玩了」这一句。
    /// 和 Android 那版是同一个意图 —— 别让孩子在成功页上再点回题目。
    private var successLayer: some View {
        VStack(spacing: Theme.Space.s6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.Palette.ok)
            Text("答对了")
                .font(.system(size: Theme.Text.hero, weight: .heavy))
                .foregroundStyle(Theme.Palette.ink)
            Text("这一轮重新开始计时，去玩吧")
                .font(.system(size: Theme.Text.body))
                .foregroundStyle(Theme.Palette.inkSoft)
            Button {
                model.question = nil
                dismiss()
            } label: {
                Text("继续")
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeightLarge)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Theme.Space.s8)
        // 里层限宽、外层铺满：不这么写的话 iPad 上「答对了」三个字会横贯整屏，
        // 而渐变背景必须留在外层，不然两侧会露出页面底色。
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [.white, Color(hex: 0xF2F9F4)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func label(_ subject: Quizgate_Subject) -> String {
        switch subject {
        case .math: return "数学"
        case .chinese: return "语文"
        case .english: return "英语"
        default: return "题目"
        }
    }
}

struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Theme.Text.caption))
            .foregroundStyle(Theme.Palette.brand700)
            // 限了宽度就得截断，不能让知识点名字在两行里把标签撑成一块砖。
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.s3)
            .frame(height: Theme.Metric.chipHeight)
            .background(Theme.Palette.brand100)
            .clipShape(Capsule())
    }
}

struct OptionButton: View {
    let text: String
    let chosen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: Theme.Text.option))
                .foregroundStyle(Theme.Palette.ink)
                .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight, alignment: .leading)
                .padding(.horizontal, Theme.Space.s4)
                .background(chosen ? Theme.Palette.optionPressed : Theme.Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(chosen ? Theme.Palette.brand300 : Theme.Palette.optionStroke,
                                      lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}