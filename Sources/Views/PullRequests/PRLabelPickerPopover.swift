import SwiftUI

/// Label pill matching GitHub's colored label chips.
public struct PRLabelPill: View {
    let label: PRLabel

    public init(label: PRLabel) {
        self.label = label
    }

    public var body: some View {
        Text(label.name)
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .foregroundStyle(label.swiftUIColor.opacity(0.95))
            .background(label.swiftUIColor.opacity(0.18))
            .overlay(Capsule().stroke(label.swiftUIColor.opacity(0.45), lineWidth: 1))
            .clipShape(Capsule())
            .help(label.description ?? label.name)
    }
}

/// Searchable label picker. Selection is applied to GitHub when the popover closes (like github.com).
public struct PRLabelPickerPopover: View {
    @ObservedObject var state: AppState
    @State private var search: String = ""
    @State private var selected: Set<String> = []
    @State private var initial: Set<String> = []
    @FocusState private var searchFocused: Bool

    private var allLabels: [PRLabel] {
        var byName: [String: PRLabel] = [:]
        for l in state.repoLabels { byName[l.name] = l }
        for l in state.prMeta?.labels ?? [] where byName[l.name] == nil { byName[l.name] = l }
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        return byName.values
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) || ($0.description ?? "").localizedCaseInsensitiveContains(trimmed) }
            .sorted { a, b in
                let aSel = initial.contains(a.name), bSel = initial.contains(b.name)
                if aSel != bSel { return aSel }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apply labels to this pull request")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if state.isPRActionRunning("labels") {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter labels", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color(NSColor.textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            if allLabels.isEmpty {
                VStack(spacing: 8) {
                    if state.repoLabels.isEmpty {
                        ProgressView().controlSize(.small)
                        Text("Loading labels…")
                    } else {
                        Text("No labels match “\(search)”")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(allLabels) { label in
                            labelRow(label)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
            }

            Divider()

            HStack {
                Text(selected == initial ? "No changes" : "Changes apply when you close this popover")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                if selected != initial {
                    Button("Reset") { selected = initial }
                        .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            let current = Set(state.prMeta?.labels.map(\.name) ?? [])
            selected = current
            initial = current
            state.loadRepoLabels()
            searchFocused = true
        }
        .onDisappear {
            guard selected != initial else { return }
            let names = Array(selected).sorted()
            Task { try? await state.updatePRLabels(names) }
        }
    }

    @ViewBuilder
    private func labelRow(_ label: PRLabel) -> some View {
        let isOn = selected.contains(label.name)
        Button {
            if isOn { selected.remove(label.name) } else { selected.insert(label.name) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                Circle()
                    .fill(label.swiftUIColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let desc = label.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
    }
}
