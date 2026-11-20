import AVKit
import Network
import QuizGateKit
import SwiftUI

struct ExplanationMedia: View {
    let questionID: String
    @State private var player: AVPlayer?
    @State private var monitor: NWPathMonitor?
    @State private var video = false
    @State private var failed = false
    @State private var observed: NSKeyValueObservation?
    @State private var currentURL: URL?

    var body: some View {
        VStack(alignment: .leading) {
            if let player {
                VideoPlayer(player: player).frame(height: video ? 200 : 72)
                if failed {
                    Text("讲解媒体暂时无法播放，可以阅读文字讲解。")
                    Button("重试讲解") { configure(video: video, retry: true) }
                }
            }
        }
        .onAppear {
            let pathMonitor = NWPathMonitor()
            monitor = pathMonitor
            pathMonitor.pathUpdateHandler = { path in
                DispatchQueue.main.async {
                    guard monitor === pathMonitor else { return }
                    if path.status == .satisfied {
                        configure(video: !path.isExpensive && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)))
                    } else { stop() }
                }
            }
            pathMonitor.start(queue: DispatchQueue(label: "quizgate.explanation.network"))
        }
        .onDisappear { monitor?.cancel(); monitor = nil; stop() }
    }

    private func configure(video: Bool, retry: Bool = false) {
        guard let id = Int64(questionID), id > 0, String(id) == questionID, let base = AppGroup.apiBase,
              let origin = URL(string: base) else { return }
        let url = origin.appendingPathComponent("download/explain-demo/q\(id)/explain." + (video ? "mp4" : "mp3"))
        guard retry || currentURL != url else { return }
        stop()
        currentURL = url
        self.video = video
        let item = AVPlayerItem(url: url)
        let next = AVPlayer(playerItem: item)
        player = next
        observed = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard currentURL == url else { return }
                if video { configure(video: false) } else { failed = true }
            }
        }
        next.play()
    }
    private func stop() {
        observed?.invalidate(); observed = nil
        player?.pause(); player = nil; currentURL = nil; failed = false
    }
}
