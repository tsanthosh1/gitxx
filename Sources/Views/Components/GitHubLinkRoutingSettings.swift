import SwiftUI
import AppKit

/// Settings › General › GitHub links: the GitXX Links Chrome extension and the Shortcuts hook.
struct GitHubLinkRoutingSettings: View {
    @State private var copiedExtension = LinkRouter.isExtensionCopied
    @State private var errorText = ""
    @State private var copiedScript = false

    private static let shortcutScript = #"~/.local/bin/gitxx --link "$1""#

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(icon: "puzzlepiece.extension", title: "GitXX Links for Chrome",
                detail: "Every repository, pull request, commit and Actions link goes to GitXX, whether it comes from Slack, Mail, another site or GitHub itself. Other GitHub pages (issues, files, branches, settings) and every other site stay in Chrome.") {
                Button(copiedExtension ? "Update & Show…" : "Install…") { install() }
                    .buttonStyle(PRActionButtonStyle(copiedExtension ? .secondary : .primary(.accentColor), size: .compact))
            }
            if !errorText.isEmpty {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.orange).padding(.leading, 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("1. Install… opens chrome://extensions and shows the extension folder in Finder.")
                Text("2. Turn on Developer mode (top right), click Load unpacked, and pick the ChromeExtension folder.")
                Text("3. That's it: Install… also registers GitXX's link helper, so links open without an “Open GitXX?” prompt.")
                Text("After a GitXX update, click Update & Show… and the extension's reload button in Chrome.")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 34)

            Divider()
            row(icon: "safari", title: "Keeping a link in the browser",
                detail: "Use Open in browser in GitXX: that tab then browses GitHub normally until you close it. Repositories that aren't on this Mac come back to Chrome on their own. The extension's toolbar popup can pause it or limit it to some owners.") {
                EmptyView()
            }

            Divider()
            row(icon: "command.square", title: "Shortcuts & Quick Actions",
                detail: "In a Run Shell Script action (input passed as arguments) use `\(Self.shortcutScript)`. With no link passed, it opens the current tab of your frontmost browser (Safari, Chrome, Arc, Brave, Edge).") {
                Button(copiedScript ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.shortcutScript, forType: .string)
                    copiedScript = true
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
            }
        }
    }

    private func install() {
        do {
            try LinkRouter.copyExtension()
            copiedExtension = true
            errorText = ""
            LinkRouter.showExtensionSetup()
        } catch {
            errorText = "Couldn't copy the extension: \(error.localizedDescription)"
        }
    }

    private func row<Trailing: View>(icon: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(.init(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}
