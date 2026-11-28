import SwiftUI
import IControlCore
@preconcurrency import WebKit

@MainActor
final class ViewerDriver: ObservableObject {
    weak var webView: WKWebView?
    weak var fpsController: FPSController?
    func execute(_ function: String, argument: String? = nil) {
        let arguments: String
        if let argument, let json = try? JSONSerialization.data(withJSONObject: [argument]), let text = String(data: json, encoding: .utf8) {
            arguments = String(text.dropFirst().dropLast())
        } else { arguments = "" }
        webView?.evaluateJavaScript("window.iControl?.\(function)(\(arguments))", completionHandler: nil)
    }
    /// Pin all packets (including the final up) to the web view that accepted entry.
    func edgePointerChannel() -> EdgePointerChannel? { webView.map { EdgePointerChannel(view: $0) } }
    func disconnect() { execute("disconnect") }
    func credentials(_ password: String) { execute("credentials", argument: password) }
    func home() { fpsController?.releaseCapture(); execute("home") }
    func power() { fpsController?.releaseCapture(); execute("power") }
    func sendText(_ text: String) { execute("sendText", argument: text) }
}

struct ViewerView: NSViewRepresentable {
    @ObservedObject var model: ControlModel
    @ObservedObject var fps: FPSController
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> ViewerContainer {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "iControl")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        model.viewerDriver.webView = view
        context.coordinator.view = view
        let container = ViewerContainer(webView: view)
        container.gameCapture.controller = fps
        fps.captureChanged = { [weak capture = container.gameCapture] value in capture?.updateCapture(value) }
        fps.cursorModeChanged = { [weak capture = container.gameCapture] value in capture?.updateCursorMode(value) }
        fps.visualsChanged = { [weak coordinator = context.coordinator] in coordinator?.applyFPS() }
        return container
    }
    func updateNSView(_ view: ViewerContainer, context: Context) {
        context.coordinator.update(url: url, attempt: model.connectionAttempt, password: model.vncPassword)
        view.gameCapture.updateCapture(fps.captured)
        view.gameCapture.updateCursorMode(fps.cursorMode)
        context.coordinator.applyFPS()
    }
    static func dismantleNSView(_ view: ViewerContainer, coordinator: Coordinator) {
        coordinator.model?.fpsController.releaseCapture()
        coordinator.model?.fpsController.captureChanged = nil
        coordinator.model?.fpsController.cursorModeChanged = nil
        coordinator.model?.fpsController.visualsChanged = nil
        view.gameCapture.restoreCursor()
        view.webView.evaluateJavaScript("window.iControl?.disconnect()", completionHandler: nil)
        view.webView.configuration.userContentController.removeScriptMessageHandler(forName: "iControl")
        view.webView.stopLoading(); view.webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var model: ControlModel?
        weak var view: WKWebView?
        var url: URL?
        var ready = false
        var requestedAttempt = 0
        var appliedAttempt = -1
        var password = ""
        var lastFPSPayload = ""
        init(model: ControlModel) { self.model = model }

        func update(url: URL, attempt: Int, password: String) {
            self.password = password; requestedAttempt = attempt
            if self.url != url {
                self.url = url; ready = false; appliedAttempt = -1; lastFPSPayload = ""
                view?.load(URLRequest(url: url))
            }
            connectIfReady()
        }
        private func connectIfReady() {
            guard ready, appliedAttempt != requestedAttempt, requestedAttempt > 0 else { return }
            appliedAttempt = requestedAttempt
            model?.viewerDriver.execute("connect", argument: password)
            applyFPS()
        }
        func applyFPS() {
            guard ready, let fps = model?.fpsController else { return }
            // Keep the native capture surface and its canvas bounds alive, but skip
            // building and bridging the mapping overlay while watching the iPad.
            let json: String
            if fps.directView { json = "{}" }
            else if let profile = try? fps.viewerJSON() { json = profile }
            else { return }
            let enabled = fps.enabled ? "true" : "false"
            let markers = fps.showMarkers && !fps.captured && !fps.layoutTesting ? "true" : "false"
            let captured = fps.captured ? "true" : "false"
            let cursor = fps.cursorMode ? "true" : "false"
            let key = FPSKey.title(fps.profile.cursorToggleKey)
            let keyJSON = String(data: (try? JSONSerialization.data(withJSONObject: [key])) ?? Data("[\"`\"]".utf8), encoding: .utf8) ?? "[\"`\"]"
            let paused = fps.directView ? "true" : "false"
            let script = "window.iControl?.setFPSMode(\(enabled), \(json), \(markers), \(captured), \(cursor), \(keyJSON)[0], \(paused))"
            guard script != lastFPSPayload else { return }
            lastFPSPayload = script
            view?.evaluateJavaScript(script, completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let event = message.body as? [String: Any] else { return }
            if event["type"] as? String == "ready" { ready = true; connectIfReady(); applyFPS() }
            else { model?.viewerEvent(event, source: url) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let destination = navigationAction.request.url, let url,
                  destination.scheme == url.scheme, destination.host == url.host, destination.port == url.port,
                  destination.path.hasPrefix(url.deletingLastPathComponent().path + "/") else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { model?.viewerEvent(["type": "error"], source: url) }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            model?.viewerEvent(["type": "disconnected"], source: url)
            ready = false; appliedAttempt = -1; lastFPSPayload = ""; webView.reload()
        }
    }
}
