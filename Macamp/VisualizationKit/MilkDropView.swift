import AppKit
import WebKit

@MainActor
final class MilkDropView: NSObject, WKNavigationDelegate {
    static let presets = ["Aqua Orbit", "Magenta Trails", "Lime Pulse"]

    let webView: WKWebView
    private let onFailure: () -> Void
    private var isReady = false
    private var renderTask: Task<Void, Never>?

    init?(onFailure: @escaping () -> Void) {
        let bundle = Bundle.main
        func script(_ name: String) -> String? {
            guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "Butterchurn") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }

        // Adapted from hfyeomans/MacAmp's ButterchurnWebView (MIT).
        // WKUserScript takes a classic script, so expose the pinned module's default export.
        guard var engine = script("butterchurn.min"), let bridge = script("macamp-milkdrop"),
              let export = engine.range(of: #"export\{[\w$]+ as default\};"#, options: .regularExpression) else { return nil }
        let defaultExport = engine[export].dropFirst("export{".count).dropLast(" as default};".count)
        let entryPoint = "window.butterchurn = \(defaultExport);"
        engine.replaceSubrange(export, with: entryPoint)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: engine, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.onFailure = onFailure
        super.init()
        webView.navigationDelegate = self
        webView.setAccessibilityLabel("MilkDrop visualization")
        webView.loadHTMLString("""
            <!doctype html><html lang="en"><head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-eval'; style-src 'unsafe-inline'">
            <style>html,body,canvas{width:100%;height:100%;margin:0;display:block;background:black;overflow:hidden}</style>
            </head><body><canvas aria-label="MilkDrop visualization"></canvas></body></html>
            """, baseURL: nil)
    }

    func render(samples: [Float], presetIndex: Int) {
        guard isReady, renderTask == nil, !samples.isEmpty else { return }
        renderTask = Task { [weak self, webView] in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "return await window.renderMacampMilkDrop(samples, presetIndex);",
                    arguments: ["samples": samples, "presetIndex": presetIndex], in: nil, contentWorld: .page
                )
                self?.renderTask = nil
            } catch {
                self?.renderTask = nil
                if !Task.isCancelled { self?.onFailure() }
            }
        }
    }

    func stop() {
        isReady = false
        renderTask?.cancel()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isReady = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { onFailure() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { onFailure() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }
}
