import SwiftUI
import QuizGateKit

/// 答题页。这页是闸门唯一的出口：答对才解盾，所以判分必须在服务端，
/// 客户端拿到的是「对不对 + 解析」，永远拿不到正确项下标（协议里就没有这个字段）。
struct QuizView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

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

    private func content(_ question: Quizgate_Question) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s5) {
                HStack {
                    Chip(text: label(question.subject))
                    Chip(text: "第 \(question.grade) 年级")
                    if !question.knowledgePoint.isEmpty {
                        Chip(text: question.knowledgePoint)
                    }
                    Spacer()
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

                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    OptionButton(text: option, chosen: model.explanation != nil) {
                        Task { await model.submitAnswer(index: index) }
                    }
                    .disabled(model.busy || model.explanation != nil)
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
                        Text("换一道")
                            .frame(maxWidth: .infinity, minHeight: Theme.Metric.controlHeight)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                if let banner = model.banner {
                    BannerView(text: banner, tone: .danger)
                }
            }
            .padding(Theme.Space.s5)
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