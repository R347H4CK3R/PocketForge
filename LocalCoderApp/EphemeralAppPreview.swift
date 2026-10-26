import SwiftUI
import WebKit

/// Runs HTML/JavaScript with nonpersistent website data.
struct EphemeralAppPreview: View {
    let html: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            EphemeralWebView(html: html)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Temporary App Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}
struct EphemeralWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString(html, baseURL: nil)
        return web
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}
