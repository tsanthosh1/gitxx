import SwiftUI
import WebKit

public struct PRConversationWebView: NSViewRepresentable {
    public let pr: PullRequest
    public let timeline: [PRTimelineItem]
    public let checks: [PRCheckRun]
    public let filter: PRConversationView.ResolvedFilter
    public let meta: PRDetailMeta?
    public let scrollToMergeBox: Bool
    public var onAction: (@MainActor (PRWebAction) async -> Bool)?
    public var onScrolledToMergeBox: (@MainActor () -> Void)?
    /// Space reserved at the top of the page for the chrome floating over the web view.
    public var topInset: CGFloat = 0
    /// Called when the page decides the chrome should slide away (scrolling down) or come back (scrolling up).
    public var onChromeHidden: (@MainActor (Bool) -> Void)?
    public var openNavPanel: Bool = false
    public var onNavPanelOpened: (@MainActor () -> Void)?

    public init(
        pr: PullRequest,
        timeline: [PRTimelineItem],
        checks: [PRCheckRun] = [],
        filter: PRConversationView.ResolvedFilter = .all,
        meta: PRDetailMeta? = nil,
        scrollToMergeBox: Bool = false,
        onAction: (@MainActor (PRWebAction) async -> Bool)? = nil,
        onScrolledToMergeBox: (@MainActor () -> Void)? = nil,
        topInset: CGFloat = 0,
        onChromeHidden: (@MainActor (Bool) -> Void)? = nil,
        openNavPanel: Bool = false,
        onNavPanelOpened: (@MainActor () -> Void)? = nil
    ) {
        self.pr = pr
        self.timeline = timeline
        self.checks = checks
        self.filter = filter
        self.meta = meta
        self.scrollToMergeBox = scrollToMergeBox
        self.onAction = onAction
        self.onScrolledToMergeBox = onScrolledToMergeBox
        self.topInset = topInset
        self.onChromeHidden = onChromeHidden
        self.openNavPanel = openNavPanel
        self.onNavPanelOpened = onNavPanelOpened
    }

    /// Cheap fingerprint of every render input, so SwiftUI updates unrelated to the PR skip HTML generation entirely.
    fileprivate var renderKey: Int {
        var hasher = Hasher()
        hasher.combine(pr)
        hasher.combine(timeline)
        hasher.combine(checks)
        hasher.combine(filter)
        hasher.combine(meta)
        return hasher.finalize()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "gitxx")
        contentController.addUserScript(WKUserScript(
            source: "document.documentElement.style.setProperty('--gitxx-top-inset','\(Int(topInset.rounded()))px');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // Seamless dark mode blending
        webView.wantsLayer = true

        context.coordinator.webView = webView
        context.coordinator.appliedInsetForInitialLoad(topInset)
        context.coordinator.installScrollForwarding()
        context.coordinator.lastRenderKey = renderKey
        let html = ConversationHTMLBuilder.buildHTML(pr: pr, timeline: timeline, checks: checks, filter: filter, meta: meta)
        context.coordinator.lastLoadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)

        return webView
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.removeScrollForwarding()
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let key = renderKey
        if coordinator.lastRenderKey != key {
            coordinator.lastRenderKey = key
            let newHTML = ConversationHTMLBuilder.buildHTML(pr: pr, timeline: timeline, checks: checks, filter: filter, meta: meta)
            if coordinator.lastLoadedHTML != newHTML {
                coordinator.lastLoadedHTML = newHTML
                coordinator.reloadPreservingState(newHTML)
            }
        }

        if scrollToMergeBox {
            coordinator.requestScrollToMergeBox()
        }
        coordinator.applyTopInset(topInset)
        if openNavPanel {
            coordinator.requestNavPanel()
        }
    }

    @MainActor
    public class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: PRConversationWebView
        weak var webView: WKWebView?
        var lastLoadedHTML: String = ""
        var lastRenderKey: Int = 0

        private var isLoading = true
        private var snapshotInFlight = false
        private var pendingHTML: String?
        private var pendingSnapshot: String?
        private var pendingMergeScroll = false
        private var pendingNavPanel = false
        private var appliedInset: CGFloat = -1

        init(parent: PRConversationWebView) {
            self.parent = parent
        }

        /// Captures drafts / toggles / scroll position, swaps in the new HTML, and restores them in `didFinish`.
        func reloadPreservingState(_ html: String) {
            guard let webView else { return }
            pendingHTML = html
            guard !snapshotInFlight else { return }
            if isLoading {
                // Page hasn't finished loading yet: nothing meaningful to snapshot.
                pendingHTML = nil
                webView.loadHTMLString(html, baseURL: nil)
                return
            }
            snapshotInFlight = true
            webView.evaluateJavaScript("window.__gitxxSnapshot ? window.__gitxxSnapshot() : null") { [weak self] result, _ in
                MainActor.assumeIsolated {
                    guard let self, let webView = self.webView else { return }
                    self.snapshotInFlight = false
                    self.pendingSnapshot = result as? String
                    if let next = self.pendingHTML {
                        self.pendingHTML = nil
                        self.isLoading = true
                        webView.loadHTMLString(next, baseURL: nil)
                    }
                }
            }
        }

        /// Sets the page's top padding; a document-start script carries it across reloads so there's no jump.
        func appliedInsetForInitialLoad(_ inset: CGFloat) { appliedInset = inset }

        private var scrollMonitor: Any?

        /// The native chrome floats over the page; wheel events landing on it scroll the page, like on github.com.
        func installScrollForwarding() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let webView = self.webView, let window = webView.window,
                      event.window === window, self.parent.topInset > 0 else { return event }
                let point = webView.convert(event.locationInWindow, from: nil)
                guard webView.bounds.contains(point),
                      let hit = window.contentView?.hitTest(event.locationInWindow),
                      !hit.isDescendant(of: webView) else { return event }
                webView.scrollWheel(with: event)
                return nil
            }
        }

        func removeScrollForwarding() {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }

        func applyTopInset(_ inset: CGFloat) {
            guard inset != appliedInset, let webView else { return }
            appliedInset = inset
            let js = "document.documentElement.style.setProperty('--gitxx-top-inset','\(Int(inset.rounded()))px');"
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            webView.evaluateJavaScript(js + "window.gitxxInsetChanged && window.gitxxInsetChanged();", completionHandler: nil)
        }

        func requestNavPanel() {
            pendingNavPanel = true
            if !isLoading { performNavPanel() }
        }

        private func performNavPanel() {
            guard pendingNavPanel, let webView else { return }
            pendingNavPanel = false
            webView.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript("window.gitxxOpenNav && window.gitxxOpenNav()", completionHandler: nil)
            let done = parent.onNavPanelOpened
            DispatchQueue.main.async { done?() }
        }

        func requestScrollToMergeBox() {
            pendingMergeScroll = true
            if !isLoading { performMergeScroll() }
        }

        private func performMergeScroll() {
            guard pendingMergeScroll, let webView else { return }
            pendingMergeScroll = false
            webView.evaluateJavaScript("window.gitxxScrollToMerge && window.gitxxScrollToMerge()", completionHandler: nil)
            let done = parent.onScrolledToMergeBox
            DispatchQueue.main.async { done?() }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            if let snapshot = pendingSnapshot {
                pendingSnapshot = nil
                if let data = try? JSONSerialization.data(withJSONObject: [snapshot]),
                   let arrayLiteral = String(data: data, encoding: .utf8) {
                    webView.evaluateJavaScript("window.__gitxxRestore && window.__gitxxRestore(\(arrayLiteral)[0])", completionHandler: nil)
                    webView.evaluateJavaScript("window.gitxxSyncChrome && window.gitxxSyncChrome()", completionHandler: nil)
                }
            }
            performMergeScroll()
            performNavPanel()
            if let next = pendingHTML, !snapshotInFlight {
                pendingHTML = nil
                reloadPreservingState(next)
            }
        }

        // Intercept external links and open in default browser
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "gitxx",
                  message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let actionName = body["action"] as? String else {
                return
            }
            if actionName == "chromeHidden" {
                parent.onChromeHidden?((body["hidden"] as? Bool) ?? false)
                return
            }
            guard let action = Self.parseAction(actionName, body) else { return }
            let key = body["key"] as? String
            guard let handler = parent.onAction else { return }
            Task { @MainActor [weak self] in
                let ok = await handler(action)
                guard let key, let webView = self?.webView,
                      let data = try? JSONSerialization.data(withJSONObject: [key]),
                      let keyLiteral = String(data: data, encoding: .utf8) else { return }
                webView.evaluateJavaScript("window.gitxxActionDone && window.gitxxActionDone(\(keyLiteral)[0], \(ok))", completionHandler: nil)
            }
        }

        private static func parseAction(_ name: String, _ body: [String: Any]) -> PRWebAction? {
            switch name {
            case "toggleChecklist":
                return (body["index"] as? Int).map { .toggleChecklist(index: $0) }
            case "mergePR":
                let method = GitHubAPIService.MergeMethod(rawValue: (body["method"] as? String) ?? "merge") ?? .merge
                let title = (body["commitTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let message = (body["commitMessage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .merge(method: method, title: title, message: message, deleteBranch: (body["deleteBranch"] as? Bool) ?? false)
            case "closePR":
                return .close
            case "reopenPR":
                return .reopen
            case "updateBranch":
                return .updateBranch
            case "postComment":
                return (body["body"] as? String).map { .postComment(body: $0) }
            case "replyThread":
                guard let id = body["commentId"] as? String, let text = body["body"] as? String else { return nil }
                return .replyToThread(commentId: id, body: text)
            case "resolveThread":
                guard let nodeId = body["nodeId"] as? String else { return nil }
                return .resolveThread(nodeId: nodeId, resolve: (body["resolve"] as? Bool) ?? true)
            case "rerunFailed":
                return .rerunFailedChecks
            case "rerunCheck":
                return (body["jobId"] as? String).map { .rerunCheck(jobId: $0) }
            case "setDraft":
                return .setDraft((body["draft"] as? Bool) ?? false)
            case "openFile":
                return (body["path"] as? String).map { .openFile(path: $0) }
            case "openReview":
                return .openReviewModal
            case "refresh":
                return .refresh
            case "switchTab":
                switch body["tab"] as? String {
                case "files": return .switchTab(.filesChanged)
                case "checks": return .switchTab(.checks)
                default: return .switchTab(.overview)
                }

            default:
                return nil
            }
        }
    }
}
