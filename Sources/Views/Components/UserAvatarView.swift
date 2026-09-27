import SwiftUI

public struct UserAvatarView: View {
    public let profile: GitUserProfile
    public var size: CGFloat = 26
    public var showBorder: Bool = true

    public init(profile: GitUserProfile, size: CGFloat = 26, showBorder: Bool = true) {
        self.profile = profile
        self.size = size
        self.showBorder = showBorder
    }

    public var body: some View {
        Group {
            if let url = profile.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    case .failure, .empty:
                        fallbackInitialsView
                    @unknown default:
                        fallbackInitialsView
                    }
                }
            } else {
                fallbackInitialsView
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Group {
                if showBorder {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.12)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
            }
        )
        .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
    }

    private var fallbackInitialsView: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: profile.label.lowercased().contains("work")
                            ? [Color(red: 0.16, green: 0.54, blue: 1.00), Color(red: 0.08, green: 0.35, blue: 0.85)]
                            : [Color(red: 0.19, green: 0.82, blue: 0.35), Color(red: 0.08, green: 0.65, blue: 0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(profile.initials)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
    }
}
