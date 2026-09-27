import SwiftUI
import AppKit

@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

public struct PRAvatarView: View {
    public let authorName: String
    public let avatarUrl: String?
    public var size: CGFloat = 38

    @State private var loadedImage: NSImage? = nil
    /// URL `loadedImage` came from; a reused view with a new URL must not keep showing the old face.
    @State private var loadedFor: String? = nil

    public init(authorName: String, avatarUrl: String?, size: CGFloat = 38) {
        self.authorName = authorName
        self.avatarUrl = avatarUrl
        self.size = size
        if let avatarUrl = avatarUrl, let url = URL(string: avatarUrl), let cached = AvatarImageCache.shared.image(for: url) {
            _loadedImage = State(initialValue: cached)
            _loadedFor = State(initialValue: avatarUrl)
        }
    }

    public var body: some View {
        Group {
            if let image = loadedImage, loadedFor == avatarUrl {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if let avatarUrl = avatarUrl, let url = URL(string: avatarUrl) {
                if let cached = AvatarImageCache.shared.image(for: url) {
                    Image(nsImage: cached)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    fallbackInitials
                        .task(id: url) {
                            if let (data, _) = try? await URLSession.shared.data(from: url),
                               let img = NSImage(data: data) {
                                AvatarImageCache.shared.store(img, for: url)
                                await MainActor.run {
                                    self.loadedImage = img
                                    self.loadedFor = avatarUrl
                                }
                            }
                        }
                }
            } else {
                fallbackInitials
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .stroke(Color(red: 48/255, green: 54/255, blue: 61/255).opacity(0.8), lineWidth: 1)
        )
    }

    private var fallbackInitials: some View {
        let initial = authorName.first.map { String($0).uppercased() } ?? "?"
        let hash = abs(authorName.hashValue)
        let colors: [[Color]] = [
            [Color(red: 0.16, green: 0.54, blue: 1.00), Color(red: 0.08, green: 0.35, blue: 0.85)],
            [Color(red: 0.19, green: 0.82, blue: 0.35), Color(red: 0.08, green: 0.65, blue: 0.38)],
            [Color(red: 0.68, green: 0.32, blue: 0.87), Color(red: 0.45, green: 0.18, blue: 0.65)],
            [Color(red: 0.95, green: 0.55, blue: 0.15), Color(red: 0.85, green: 0.35, blue: 0.05)],
            [Color(red: 0.85, green: 0.25, blue: 0.45), Color(red: 0.65, green: 0.15, blue: 0.35)]
        ]
        let pair = colors[hash % colors.count]

        return ZStack {
            Circle()
                .fill(LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
