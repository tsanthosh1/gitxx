import SwiftUI
import AppKit

/// PR conversation / files layout: the app toolbar and PR header float over the content's top padding.
/// Like mobile browsers, scrolling down dissolves them away and scrolling up fades them back in.
struct PRChromeContainer<Content: View>: View {
    @ObservedObject var state: AppState
    let pr: PullRequest
    /// Builds the content from the reserved top inset, the currently visible chrome height (animated with the
    /// bars, for side panels) and a callback for the page's hide/show decisions.
    @ViewBuilder let content: (_ topInset: CGFloat, _ visibleHeight: CGFloat, _ onChromeHidden: @escaping (Bool) -> Void) -> Content

    @State private var hidden = false
    @State private var chromeHeight: CGFloat = PRChromeMetrics.lastChromeHeight

    static var slide: Animation { .easeInOut(duration: 0.35) }

    var body: some View {
        ZStack(alignment: .top) {
            content(chromeHeight, hidden ? 0 : chromeHeight, { setHidden($0) })

            if !hidden {
                chromeStack
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .clipped()
        .onChange(of: pr.number) { _, _ in
            setHidden(false, animated: false)
        }
    }

    private var chromeStack: some View {
        VStack(spacing: 0) {
            TopToolbarView(state: state, isReduced: state.isReducedWidth)
            Divider()
            PRDetailHeaderView(state: state, pr: pr)
            Divider()
        }
        .background(Color(NSColor.windowBackgroundColor))
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { setChromeHeight(geo.size.height) }
                    .onChange(of: geo.size.height) { _, h in setChromeHeight(h) }
            }
        )
    }

    private func setHidden(_ value: Bool, animated: Bool = true) {
        guard hidden != value else { return }
        var transaction = Transaction(animation: animated ? Self.slide : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { hidden = value }
    }

    private func setChromeHeight(_ height: CGFloat) {
        let h = height.rounded()
        guard h > 0, h != chromeHeight else { return }
        PRChromeMetrics.lastChromeHeight = h
        chromeHeight = h
    }
}

/// Last measured chrome height, so a newly opened PR or tab reserves the right space before layout measures it.
@MainActor
enum PRChromeMetrics {
    static var lastChromeHeight: CGFloat = 150
}
