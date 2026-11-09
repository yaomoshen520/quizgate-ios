import SwiftUI
import QuizGateKit

@main
struct QuizGateApp: App {
    /// 只为后台重挂那一条通道存在：BGTaskScheduler 的注册必须落在启动流程里，
    /// SwiftUI 的 App 结构体没有「启动完成之前」这个时机。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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

/// 后台重挂的接线板。除了把 BGTaskScheduler 接进来，这里刻意什么都不做 ——
/// 闸门的所有判定都留在 AppModel 里，两处各写一套就会分叉。
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 注册要趁早：晚于启动完成，系统这一次交过来的唤醒就找不到 handler，
        // 表现成「task 来过又走了」，而这条通道本来就只在真机后台跑，本机永远看不见。
        BackgroundRefresh.register { task in BackgroundRefresh.run(task) }
        BackgroundRefresh.scheduleNext()
        return true
    }

    /// 每次退到后台都重新排一次。调度器对同一个 identifier 的 submit 是替换语义，
    /// 所以反复提交不会攒出一串任务，只会把下一次的时间点往后推。
    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundRefresh.scheduleNext()
    }
}