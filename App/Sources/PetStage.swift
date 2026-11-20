import SwiftUI
import WebKit
import QuizGateKit

struct PetStage: UIViewRepresentable {
    var pet: Int
    var outfit: Quizgate_PetOutfit
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var appearance = ""
        var loaded = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            webView.evaluateJavaScript(appearance)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let stage = Bundle.main.url(forResource: "mobile-pet", withExtension: "html")
            decisionHandler(action.request.url == stage ? .allow : .cancel)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        if let url = Bundle.main.url(forResource: "mobile-pet", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let call = "window.PetApp && PetApp.setAppearance(\(pet),{head:\(outfit.head),face:\(outfit.face),neck:\(outfit.neck),hand:\(outfit.hand)})"
        guard call != context.coordinator.appearance else { return }
        context.coordinator.appearance = call
        if context.coordinator.loaded { web.evaluateJavaScript(call) }
    }
}
