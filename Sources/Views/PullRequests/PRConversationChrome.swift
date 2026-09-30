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
            } else {
                PRShowChromeButton(pr: pr) {
                    setHidden(false)
                    NotificationCenter.default.post(name: .gitxxShowPRChrome, object: nil)
                }
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(2)
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
        .themedSurface(state.accentTheme, .toolbar)
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

extension Notification.Name {
    /// Asks the PR web views to reset their hide-on-scroll state and show the bars.
    static let gitxxShowPRChrome = Notification.Name("GitXXShowPRChrome")
}

/// Floating glass pill shown while the PR bars are scrolled away; brings them back.
private struct PRShowChromeButton: View {
    let pr: PullRequest
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                Text("#\(String(pr.number))")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Text("Show toolbar")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 30)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.primary.opacity(hovering ? 0.08 : 0.02), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: hovering ? 12 : 8, y: 4)
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverPlain)
        .pointerCursor()
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help("Show the toolbar and PR header")
    }
}
