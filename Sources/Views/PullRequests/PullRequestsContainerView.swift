import SwiftUI

public struct PullRequestsContainerView: View {
    @ObservedObject var state: AppState

    public var body: some View {
        Group {
            if state.selectedPR != nil {
                PRDetailView(state: state)
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
