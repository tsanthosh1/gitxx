import SwiftUI
import AppKit

public struct PageHistoryPopoverView: View {
    @ObservedObject var state: AppState
    @State private var filterText: String = ""
    @State private var selectedIndex: Int = 0

    private var items: [NavigationLocation] {
        var list = state.visitedHistory
        if list.isEmpty {
            list = [state.currentNavigationLocation]
        }
        if filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return list
        }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(filterText) ||
            $0.subtitle.localizedCaseInsensitiveContains(filterText)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header: Title, page count, and clear action
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)

                Text("Page History")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)

                Text("\(items.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())

                Spacer()

                if !state.visitedHistory.isEmpty {
                    Button {
                        state.clearVisitedHistory()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hoverPlain)
                    .help("Clear session page history")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search / Filter Input Field with Arrow Key Navigation Hooks
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HistorySearchField(
                    text: $filterText,
                    placeholder: "Filter visited pages... (↑↓ to select, ↵ to jump)",
                    onSubmit: {
                        selectCurrentIndex()
                    },
                    onDownArrow: {
                        moveSelection(by: 1)
                    },
                    onUpArrow: {
                        moveSelection(by: -1)
                    },
                    onEscape: {
                        state.showPageHistoryPopover = false
                    }
                )
                .frame(height: 22)

                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                        selectedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Visited Pages List
            if items.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No matching pages in history")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 180)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                let isSelected = (index == selectedIndex)
                                let isCurrent = (item == state.currentNavigationLocation)

                                PageHistoryRowView(
                                    item: item,
                                    isSelected: isSelected,
                                    isCurrent: isCurrent
                                )
                                .id(index)
                                .onHover { hovering in
                                    if hovering {
                                        selectedIndex = index
                                    }
                                }
                                .onTapGesture {
                                    state.navigateToHistoryItem(item)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .frame(maxHeight: 280)
                    .onChange(of: selectedIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            // Footer keyboard hints
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("↑↓")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("Navigate")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Text("↵")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("Jump")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Text("esc")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("Close")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("⌘E")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
        }
        .frame(width: 390)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            selectedIndex = 0
        }
        .onChange(of: filterText) { _, _ in
            selectedIndex = 0
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let newIndex = selectedIndex + delta
        if newIndex >= 0 && newIndex < items.count {
            selectedIndex = newIndex
        } else if newIndex < 0 {
            selectedIndex = items.count - 1
        } else {
            selectedIndex = 0
        }
    }

    private func selectCurrentIndex() {
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        let selectedItem = items[selectedIndex]
        state.navigateToHistoryItem(selectedItem)
    }
}

// MARK: - Row View

private struct PageHistoryRowView: View {
    let item: NavigationLocation
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Icon Pill
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(iconBackgroundColor)
                    .frame(width: 26, height: 26)

                Image(systemName: item.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconForegroundColor)
            }

            // Title & Subtitle
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isCurrent {
                        Text("Current")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }

                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Timestamp
            Text(item.timeAgo)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var iconBackgroundColor: Color {
        if isSelected {
            return Color.white.opacity(0.2)
        }
        switch item.page {
        case .changes:
            return Color.green.opacity(0.15)
        case .history:
            return Color.purple.opacity(0.15)
        case .pullRequestsIndex, .pullRequestDetail:
            return Color.blue.opacity(0.15)
        case .actions:
            return Color.orange.opacity(0.15)
        case .terminal, .home:
            return Color.gray.opacity(0.15)
        }
    }

    private var iconForegroundColor: Color {
        if isSelected {
            return .white
        }
        switch item.page {
        case .changes:
            return .green
        case .history:
            return .purple
        case .pullRequestsIndex, .pullRequestDetail:
            return .blue
        case .actions:
            return .orange
        case .terminal, .home:
            return .secondary
        }
    }
}

// MARK: - Native Keyboard Intercepting Search Field

private struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onDownArrow: () -> Void
    var onUpArrow: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.stringValue = text
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 12)
        tf.delegate = context.coordinator
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true

        DispatchQueue.main.async {
            tf.window?.makeFirstResponder(tf)
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        DispatchQueue.main.async {
            if let w = nsView.window, w.firstResponder != nsView.currentEditor() && w.firstResponder != nsView {
                w.makeFirstResponder(nsView)
            }
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HistorySearchField

        init(_ parent: HistorySearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onDownArrow()
                return true
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onUpArrow()
                return true
            } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
