import SwiftUI

public struct PullRequestsContainerView: View {
    @ObservedObject var state: AppState

    public var body: some View {
        Group {
            if state.selectedPR != nil || state.openingPRNumber != nil {
                // One branch for both, so the loading page is replaced in place rather than sliding the list in and out.
                Group {
                    if state.selectedPR != nil {
                        PRDetailView(state: state)
                    } else if let number = state.openingPRNumber {
                        PROpeningView(number: number, slug: state.prRepoContext().map { "\($0.owner)/\($0.repo)" }) {
                            state.openingPRNumber = nil
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .trailing))
                ))
            } else {
                PRIndexView(state: state)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .leading)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown while a linked PR that isn't in any cached list is fetched.
private struct PROpeningView: View {
    let number: Int
    let slug: String?
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Opening pull request #\(number)")
                .font(.system(size: 13, weight: .semibold))
            if let slug {
                Text(slug).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Show all pull requests", action: onBack)
                .buttonStyle(.link)
                .font(.system(size: 11))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
