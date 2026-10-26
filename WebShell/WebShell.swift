import SwiftUI
import WebKit

@main struct WebShellApp: App {
    var body: some Scene { WindowGroup { ShellView().ignoresSafeArea() } }
}
struct ShellView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
