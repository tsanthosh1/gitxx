import Foundation

/// Something on the current page that can be handed to another application.
public struct OpenWithTarget: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case file = "File", folder = "Repository", web = "Web page" }
    public let kind: Kind
    public let url: URL
    public let title: String
    public let subtitle: String
    public var id: String { kind.rawValue + url.absoluteString }
}

extension AppState {
    /// Most specific first: the selected file, then the repository folder, then the page on GitHub.
    public var openWithTargets: [OpenWithTarget] {
        var targets: [OpenWithTarget] = []
        let fm = FileManager.default
        if !showHome, let repo = currentRepo {
            let relative: String? = {
                switch activeTab {
                case .changes: return selectedFile?.path
                case .pullRequests: return selectedPRTab == .filesChanged ? selectedPRFile?.filename : nil
                default: return nil
                }
            }()
            if let relative {
                let url = URL(fileURLWithPath: repo.path).appendingPathComponent(relative)
                if fm.fileExists(atPath: url.path) {
                    targets.append(OpenWithTarget(kind: .file, url: url, title: url.lastPathComponent,
                                                  subtitle: activeTab == .pullRequests ? "\(relative) · local working copy" : relative))
                }
            }
            targets.append(OpenWithTarget(kind: .folder, url: URL(fileURLWithPath: repo.path, isDirectory: true),
                                          title: repo.name, subtitle: (repo.path as NSString).abbreviatingWithTildeInPath))
        }
        if !showHome, let link = currentBrowserURLString, let url = URL(string: link) {
            targets.append(OpenWithTarget(kind: .web, url: url, title: currentNavigationLocation.title,
                                          subtitle: link.replacingOccurrences(of: "https://", with: "")))
        }
        return targets
    }
}
