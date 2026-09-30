import SwiftUI

public struct ToastNotificationView: View {
    @ObservedObject var state: AppState

    public var body: some View {
        if let message = state.toastMessage {
            HStack(spacing: 10) {
                Image(systemName: state.toastType.iconName)
                    .foregroundStyle(state.toastType.color)
                    .font(.system(size: 14, weight: .bold))

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        state.toastMessage = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 380)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(state.toastType.color.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
        }
    }
}
