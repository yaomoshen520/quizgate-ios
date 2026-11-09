import SwiftUI
import QuizGateKit

@main
struct QuizGateApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in
                    // 盾牌按钮在 iOS 26.5 以下跳不过来，这个入口留给未来的短链/快捷指令。
                    // 现在只认 quizgate://quiz，不做任何自动解盾。
                    if url.host == "quiz" {
                        Task { await model.loadQuestion() }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if needsSetup {
                SetupView()
            } else {
                HomeView()
            }
        }
        .sheet(isPresented: Binding(
            get: { model.question != nil },
            set: { if !$0 { model.question = nil } }
        )) {
            QuizView()
        }
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    private var needsSetup: Bool {
        model.state.authorization?.isApproved != true || model.state.selectionData == nil
    }
}