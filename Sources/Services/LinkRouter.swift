import AppKit
import CryptoKit

/// Every "open in browser" in GitXX goes through here. GitHub links get a `gitxx_browser=1` marker so the
/// GitXX Links browser extension leaves them in the browser instead of sending them straight back to GitXX.
@MainActor
enum LinkRouter {
    static let skipParameter = "gitxx_browser"

    static func open(_ url: URL) {
        NSWorkspace.shared.open(markedForBrowser(url))
    }

    static func openInBrowser(_ urls: [URL]) {
        urls.forEach(open)
    }

    static func markedForBrowser(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), GitHubHost.isWebHost(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == skipParameter }) else { return url }
        items.append(URLQueryItem(name: skipParameter, value: "1"))
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: Chrome extension

    /// The extension ships inside the app; installing copies it to a stable folder Chrome can keep loading
    /// after GitXX is rebuilt or moved.
    static var bundledExtension: URL? { Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) }

    static var installedExtension: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitXX/ChromeExtension", isDirectory: true)
    }

    static var isExtensionCopied: Bool {
        FileManager.default.fileExists(atPath: installedExtension.appendingPathComponent("manifest.json").path)
    }

    /// Copies (or refreshes) the extension folder. Chrome picks up changes with the extension's reload button.
    static func copyExtension() throws {
        guard let source = bundledExtension else {
            throw NSError(domain: "GitXX", code: 1, userInfo: [NSLocalizedDescriptionKey: "The extension isn't in this GitXX build."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: installedExtension.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: installedExtension.path) { try fm.removeItem(at: installedExtension) }
        try fm.copyItem(at: source, to: installedExtension)
        try installNativeHost()
    }

    // MARK: Native messaging host

    /// Lets the extension hand links over directly instead of through `gitxx://`, which makes Chrome ask
    /// "Open GitXX?" and needs a tab to stay open while it does.
    static let nativeHostName = "com.gitxx.links"
    /// Chrome's ID for an unpacked extension: the first 128 bits of SHA-256 of the folder's resolved path, written
    /// with the letters a–p. Loading the installed folder therefore always yields this ID.
    static var extensionID: String {
        let path = installedExtension.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(16).map { byte in
            [byte >> 4, byte & 0x0f].map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }.joined()
        }.joined()
    }

    private static var installedNativeHost: URL {
        installedExtension.deletingLastPathComponent().appendingPathComponent("NativeHost/gitxx-link-host")
    }

    /// Chromium browsers read host manifests from `<profile root>/NativeMessagingHosts`.
    private static let browserRoots = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data",
    ]

    static func installNativeHost() throws {
        guard let source = Bundle.main.url(forResource: "gitxx-link-host", withExtension: nil) else {
            throw NSError(domain: "GitXX", code: 1, userInfo: [NSLocalizedDescriptionKey: "The link helper isn't in this GitXX build."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: installedNativeHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: installedNativeHost.path) { try fm.removeItem(at: installedNativeHost) }
        try fm.copyItem(at: source, to: installedNativeHost)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedNativeHost.path)

        let manifest: [String: Any] = [
            "name": nativeHostName,
            "description": "Opens GitHub links from the GitXX Links extension in GitXX",
            "path": installedNativeHost.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for root in browserRoots {
            let browserDir = support.appendingPathComponent(root, isDirectory: true)
            guard fm.fileExists(atPath: browserDir.path) else { continue }
            let hosts = browserDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try fm.createDirectory(at: hosts, withIntermediateDirectories: true)
            try data.write(to: hosts.appendingPathComponent("\(nativeHostName).json"), options: .atomic)
        }
    }

    /// Keeps the extension folder and helper current after GitXX updates, once the extension has been set up.
    static func refreshExtensionIfInstalled() {
        guard isExtensionCopied else { return }
        try? copyExtension()
    }

    /// Opens Chrome's extensions page (so "Load unpacked" is one click away) and reveals the folder to pick.
    static func showExtensionSetup() {
        NSWorkspace.shared.activateFileViewerSelecting([installedExtension])
        let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
        if let chrome, let page = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
