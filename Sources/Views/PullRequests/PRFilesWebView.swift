import SwiftUI
import WebKit

/// Continuous "Files changed" page: every file's diff in one WebKit scroll with sticky file headers.
/// Viewed state, the filter and the selected file are pushed in with JS so they never reload the page.
struct PRFilesWebView: NSViewRepresentable {
    let files: [PRFileChange]
    let mode: DiffDisplayMode
    let viewedPaths: Set<String>
    /// JSON map of path → review threads, pushed into the page without reloading it.
    let threadsPayload: String
    let filter: String
    let selectedPath: String?
    let canOpenLocally: Bool
    let prURL: String
    var topInset: CGFloat = 0
    /// Commit diffs are read-only: no click-to-comment.
    var allowComments = true
    var onChromeHidden: (@MainActor (Bool) -> Void)?
    var onCurrentFile: (@MainActor (String) -> Void)?
    var onToggleViewed: (@MainActor (String) -> Void)?
    var onOpenInEditor: (@MainActor (String) -> Void)?
    var onSwitchTab: (@MainActor (PRDetailTab) -> Void)?
    var onAction: (@MainActor (PRWebAction) async -> Bool)?
    var onNewComment: (@MainActor (_ path: String, _ line: Int, _ side: String, _ body: String) async -> Bool)?
    var onFileContent: (@MainActor (_ path: String) async throws -> String)?

    fileprivate var renderKey: Int {
        var hasher = Hasher()
        hasher.combine(files)
        hasher.combine(mode)
        hasher.combine(canOpenLocally)
        hasher.combine(prURL)
        hasher.combine(allowComments)
        return hasher.finalize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "gitxx")
        controller.addUserScript(Coordinator.insetScript(topInset))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true

        let coordinator = context.coordinator
        coordinator.webView = webView
        coordinator.appliedInset = topInset
        coordinator.installScrollForwarding()
        coordinator.load(renderKey: renderKey, html: html(), scrollTo: selectedPath)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.removeScrollForwarding()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let key = renderKey
        if key != coordinator.lastRenderKey {
            coordinator.load(renderKey: key, html: html(), scrollTo: coordinator.pagePath ?? selectedPath)
            return
        }
        coordinator.applyTopInset(topInset)
        coordinator.syncDynamicState()
    }

    private func html() -> String {
        PRFilesHTMLBuilder.buildHTML(
            files: files, mode: mode, viewedPaths: viewedPaths,
            canOpenLocally: canOpenLocally, prURL: prURL, allowComments: allowComments
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: PRFilesWebView
        weak var webView: WKWebView? {
            didSet {
                guard chromeRevealObserver == nil, let webView else { return }
                chromeRevealObserver = NotificationCenter.default.addObserver(forName: .gitxxShowPRChrome, object: nil, queue: .main) { [weak webView] _ in
                    MainActor.assumeIsolated {
                        _ = webView?.evaluateJavaScript("window.gitxxShowChrome && window.gitxxShowChrome()", completionHandler: nil)
                    }
                }
            }
        }
        nonisolated(unsafe) private var chromeRevealObserver: NSObjectProtocol?

        deinit {
            if let chromeRevealObserver { NotificationCenter.default.removeObserver(chromeRevealObserver) }
        }
        var lastRenderKey = 0
        var appliedInset: CGFloat = -1
        /// The file the page reports as current; selections equal to it came from scrolling, not from the list.
        private(set) var pagePath: String?

        private var isLoading = true
        private var pendingScrollPath: String?
        private var appliedViewed: Set<String> = []
        private var appliedFilter = ""
        private var appliedSelection: String?
        private var appliedThreads = ""
        private var scrollMonitor: Any?

        init(parent: PRFilesWebView) { self.parent = parent }

        static func insetScript(_ inset: CGFloat) -> WKUserScript {
            WKUserScript(source: insetJS(inset), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        }

        private static func insetJS(_ inset: CGFloat) -> String {
            "document.documentElement.style.setProperty('--gitxx-top-inset','\(Int(inset.rounded()))px');"
        }

        func load(renderKey: Int, html: String, scrollTo path: String?) {
            guard let webView else { return }
            lastRenderKey = renderKey
            isLoading = true
            pendingScrollPath = path
            appliedViewed = parent.viewedPaths
            appliedFilter = ""
            appliedSelection = path
            appliedThreads = ""
            webView.loadHTMLString(html, baseURL: nil)
        }

        func syncDynamicState() {
            guard !isLoading, let webView else { return }
            if parent.viewedPaths != appliedViewed {
                appliedViewed = parent.viewedPaths
                webView.evaluateJavaScript("window.gitxxSetViewed(\(Self.jsonLiteral(Array(appliedViewed))))", completionHandler: nil)
            }
            if parent.threadsPayload != appliedThreads {
                appliedThreads = parent.threadsPayload
                webView.evaluateJavaScript("window.gitxxSetThreads(\(appliedThreads))", completionHandler: nil)
            }
            if parent.filter != appliedFilter {
                appliedFilter = parent.filter
                webView.evaluateJavaScript("window.gitxxFilter(\(Self.jsonLiteral(appliedFilter)))", completionHandler: nil)
            }
            if parent.selectedPath != appliedSelection {
                appliedSelection = parent.selectedPath
                if let path = parent.selectedPath, path != pagePath {
                    pagePath = path
                    scroll(to: path, smooth: true)
                }
            }
        }

        private func scroll(to path: String, smooth: Bool) {
            webView?.evaluateJavaScript("window.gitxxScrollToFile(\(Self.jsonLiteral(path)), \(smooth))", completionHandler: nil)
        }

        func applyTopInset(_ inset: CGFloat) {
            guard inset != appliedInset, let webView else { return }
            appliedInset = inset
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(Self.insetScript(inset))
            webView.evaluateJavaScript(Self.insetJS(inset) + "window.gitxxInsetChanged && window.gitxxInsetChanged();", completionHandler: nil)
        }

        /// The native chrome floats over the page; wheel events landing on it scroll the page.
        func installScrollForwarding() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let webView = self.webView, let window = webView.window,
                      event.window === window, self.parent.topInset > 0 else { return event }
                let point = webView.convert(event.locationInWindow, from: nil)
                guard webView.bounds.contains(point),
                      let hit = window.contentView?.hitTest(event.locationInWindow),
                      !hit.isDescendant(of: webView),
                      WebScrollForwarding.shouldForward(hit: hit) else { return event }
                webView.scrollWheel(with: event)
                return nil
            }
        }

        func removeScrollForwarding() {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            if let path = pendingScrollPath {
                pendingScrollPath = nil
                pagePath = path
                scroll(to: path, smooth: false)
            }
            webView.evaluateJavaScript("window.gitxxSyncChrome && window.gitxxSyncChrome()", completionHandler: nil)
            syncDynamicState()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    LinkRouter.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "gitxx", message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            let path = body["path"] as? String
            switch action {
            case "chromeHidden":
                parent.onChromeHidden?((body["hidden"] as? Bool) ?? false)
            case "currentFile":
                guard let path else { return }
                pagePath = path
                appliedSelection = path
                parent.onCurrentFile?(path)
            case "toggleViewed":
                guard let path else { return }
                // The page already reflects the new state; record it so the round trip doesn't re-apply it.
                if appliedViewed.contains(path) { appliedViewed.remove(path) } else { appliedViewed.insert(path) }
                parent.onToggleViewed?(path)
            case "openInEditor":
                if let path { parent.onOpenInEditor?(path) }
            case "switchTab":
                parent.onSwitchTab?((body["tab"] as? String) == "checks" ? .checks : .overview)
            case "replyThread":
                guard let id = body["commentId"] as? String, let text = body["body"] as? String else { return }
                runAction(key: body["key"] as? String) { [parent] in await parent.onAction?(.replyToThread(commentId: id, body: text)) ?? false }
            case "resolveThread":
                guard let nodeId = body["nodeId"] as? String else { return }
                let resolve = (body["resolve"] as? Bool) ?? true
                runAction(key: body["key"] as? String) { [parent] in await parent.onAction?(.resolveThread(nodeId: nodeId, resolve: resolve)) ?? false }
            case "newComment":
                guard let path, let line = body["line"] as? Int, let text = body["body"] as? String else { return }
                let side = (body["side"] as? String) ?? "RIGHT"
                runAction(key: body["key"] as? String) { [parent] in await parent.onNewComment?(path, line, side, text) ?? false }
            case "fileContent":
                guard let path else { return }
                Task { @MainActor [weak self, parent] in
                    do {
                        guard let text = try await parent.onFileContent?(path) else { throw CancellationError() }
                        self?.webView?.evaluateJavaScript("window.gitxxFileContent(\(Self.jsonLiteral(path)), \(Self.jsonLiteral(text)))", completionHandler: nil)
                    } catch {
                        self?.webView?.evaluateJavaScript("window.gitxxFileContentFailed(\(Self.jsonLiteral(path)), \(Self.jsonLiteral("Couldn't load the file: \(error.localizedDescription)")))", completionHandler: nil)
                    }
                }
            default:
                break
            }
        }

        private func runAction(key: String?, _ work: @escaping @MainActor () async -> Bool) {
            Task { @MainActor [weak self] in
                let ok = await work()
                guard let key, let webView = self?.webView else { return }
                webView.evaluateJavaScript("window.gitxxActionDone(\(Self.jsonLiteral(key)), \(ok))", completionHandler: nil)
            }
        }

        private static func jsonLiteral(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let s = String(data: data, encoding: .utf8) else { return "null" }
            return "\(s)[0]"
        }
    }
}

/// Rules for redirecting wheel events from the native chrome to the page web view underneath.
@MainActor
enum WebScrollForwarding {
    /// Set while a floating overlay (command palette) is open; its own list must receive the wheel.
    static var suspended = false

    static func shouldForward(hit: NSView) -> Bool {
        guard !suspended else { return false }
        var view: NSView? = hit
        while let current = view {
            if current is NSScrollView { return false }
            view = current.superview
        }
        return true
    }
}
