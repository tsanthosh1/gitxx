import SwiftUI

/// Rich preview hovercard shown when lingering over a Pull Request in the index list.
/// Displays comprehensive PR metadata, status, author, description snippet, branches, and quick action links.
public struct PRHoverCardView: View {
    public let pr: PullRequest
    public let accentColor: Color
    public let onOpen: (PRDetailTab) -> Void

    public init(pr: PullRequest, accentColor: Color = .blue, onOpen: @escaping (PRDetailTab) -> Void) {
        self.pr = pr
        self.accentColor = accentColor
        self.onOpen = onOpen
    }

    private var cleanBodySnippet: String? {
        let trimmed = pr.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") && !$0.hasPrefix("```") }
        let summary = lines.prefix(2).joined(separator: " ")
        return summary.isEmpty ? nil : summary
    }

    private var ciStatusText: String {
        switch pr.ciStatus {
        case "SUCCESS": return "All checks passed"
        case "FAILURE": return "Checks failing"
        case "PENDING": return "Checks in progress"
        default: return "Checks status available"
        }
    }

    private var ciStatusColor: Color {
        switch pr.ciStatus {
        case "SUCCESS": return .green
        case "FAILURE": return .red
        case "PENDING": return .yellow
        default: return .secondary
        }
    }

    private var ciStatusIcon: String {
        switch pr.ciStatus {
        case "SUCCESS": return "checkmark.circle.fill"
        case "FAILURE": return "xmark.circle.fill"
        case "PENDING": return "circle.dotted"
        default: return "checkmark.seal"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Header: State badge + PR number + Review Verdict
            HStack(alignment: .center, spacing: 8) {
                // State Badge Pill
                HStack(spacing: 5) {
                    PullRequestGlyph(size: 13, color: pr.state.badgeColor)
                    Text(pr.state.rawValue.capitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pr.state.badgeColor)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(pr.state.badgeColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                Text(verbatim: "#\(pr.number)")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                // Review Verdict
                HStack(spacing: 5) {
                    Circle()
                        .fill(pr.reviewVerdict.color)
                        .frame(width: 6, height: 6)
                    Text(pr.reviewVerdict.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(pr.reviewVerdict.color)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            // 2. PR Title (Completely untruncated)
            Text(pr.title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            // 3. Author & Timestamp
            HStack(spacing: 6) {
                PRAvatarView(authorName: pr.authorName, avatarUrl: pr.authorAvatarUrl, size: 18)
                Text(pr.authorName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                Text("opened \(pr.relativeDateString)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            // 4. Description Snippet (if available)
            if let snippet = cleanBodySnippet {
                Text(snippet)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // 5. Branch & Metrics Info
            VStack(alignment: .leading, spacing: 6) {
                // Branch flow
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(pr.headBranch)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(pr.baseBranch)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // CI Status & Line Diff
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: ciStatusIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(ciStatusColor)
                        Text(ciStatusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 5) {
                        Text("\(pr.changedFilesCount) \(pr.changedFilesCount == 1 ? "file" : "files")")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 2) {
                            Text("+\(pr.additions.formatted())")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green.opacity(0.85))
                            Text("-\(pr.deletions.formatted())")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                }
            }

            Divider()
                .padding(.vertical, 2)

            // 6. Action Links
            HStack(spacing: 8) {
                Button {
                    onOpen(.overview)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 11))
                        Text(pr.commentsCount > 0 ? "Conversation (\(pr.commentsCount))" : "Conversation")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                }
                .buttonStyle(.hoverPlain)

                Button {
                    onOpen(.checks)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: ciStatusIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(ciStatusColor)
                        Text("Checks")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                }
                .buttonStyle(.hoverPlain)

                Button {
                    onOpen(.filesChanged)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.badge.ellipsis")
                            .font(.system(size: 11))
                        Text("Files (\(pr.changedFilesCount))")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                }
                .buttonStyle(.hoverPlain)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}
