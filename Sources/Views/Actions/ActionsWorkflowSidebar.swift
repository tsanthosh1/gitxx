import SwiftUI
import AppKit

/// Left column of the Actions tab: every workflow definition, searchable; choosing one filters the run list.
struct ActionsWorkflowSidebar: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    @State private var query = ""
    @State private var pinned: [Int] = []
    @State private var hoveredWorkflow: Int?
    @State private var hoveringAll = false

    private var pinsKey: String { "gitxx_actions_pins_" + (store.repoSlug ?? "") }

    private var pinnedWorkflows: [ActionsWorkflow] {
        pinned.compactMap { id in workflows.first { $0.id == id } }
    }

    private var unpinnedWorkflows: [ActionsWorkflow] {
        workflows.filter { !pinned.contains($0.id) }
    }

    private func togglePin(_ workflow: ActionsWorkflow) {
        withAnimation(.easeOut(duration: 0.15)) {
            if let i = pinned.firstIndex(of: workflow.id) { pinned.remove(at: i) } else { pinned.append(workflow.id) }
        }
        UserDefaults.standard.set(pinned, forKey: pinsKey)
    }

    private func loadPins() {
        pinned = UserDefaults.standard.array(forKey: pinsKey) as? [Int] ?? []
    }

    private var workflows: [ActionsWorkflow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = store.workflows.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Workflows").font(.system(size: 13, weight: .semibold))
                if !store.workflows.isEmpty {
                    Text(String(store.workflows.count))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.beginDispatch() } label: { Image(systemName: "play.fill") }
                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                    .help("Run a workflow (workflow_dispatch)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter workflows", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.hoverPlain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    if query.isEmpty {
                        row(title: "All workflows", subtitle: store.repoSlug, icon: "square.stack.3d.up",
                            latest: nil, disabled: false, selected: store.filter.workflowId == nil, hovered: hoveringAll) {
                            store.filter.workflowId = nil
                        }
                        .onHover { hoveringAll = $0 }
                    }
                    if store.workflows.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading workflows…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        .padding(12)
                    } else if workflows.isEmpty {
                        Text("No workflows match “\(query)”")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(12)
                    }
                    if !pinnedWorkflows.isEmpty {
                        sectionLabel("Pinned")
                        ForEach(pinnedWorkflows) { workflowRow($0).id("pinned-\($0.id)") }
                        sectionLabel("All")
                    }
                    ForEach(unpinnedWorkflows) { workflowRow($0).id("all-\($0.id)") }
                }
                .padding(6)
            }
        }
        .themedSurface(state.accentTheme, .sidebar)
        .onAppear(perform: loadPins)
        .onChange(of: store.repoSlug) { _, _ in loadPins() }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func workflowRow(_ workflow: ActionsWorkflow) -> some View {
        let isPinned = pinned.contains(workflow.id)
        let hovering = hoveredWorkflow == workflow.id
        return row(title: workflow.name, subtitle: workflow.fileName, icon: nil,
                   latest: store.latestByWorkflow[workflow.id], disabled: !workflow.isActive,
                   selected: store.filter.workflowId == workflow.id, hovered: hovering, trailingReserve: hovering || isPinned) {
            store.filter.workflowId = workflow.id
        }
        .overlay(alignment: .trailing) {
            if hovering {
                Button { togglePin(workflow) } label: {
                    Image(systemName: isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isPinned ? state.accentTheme.primaryColor : Color.secondary)
                }
                .buttonStyle(.icon(size: 24))
                .help(isPinned ? "Unpin" : "Pin to the top")
                .padding(.trailing, 4)
            } else if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(state.accentTheme.primaryColor.opacity(0.8))
                    .rotationEffect(.degrees(45))
                    .frame(width: 24, height: 24)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            if inside { hoveredWorkflow = workflow.id } else if hoveredWorkflow == workflow.id { hoveredWorkflow = nil }
        }
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin to Top") { togglePin(workflow) }
            Divider()
            menu(workflow)
        }
    }

    private func row(title: String, subtitle: String?, icon: String?, latest: ActionsRun?, disabled: Bool,
                     selected: Bool, hovered: Bool = false, trailingReserve: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            state.recordNavigationStep()
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else if let latest {
                        ActionsStatusIcon(status: latest.actionsStatus, size: 11)
                            .help("Latest run: \(latest.actionsStatus.label), \(ActionsFormat.relativeDate(latest.createdAt))")
                    } else {
                        Image(systemName: "circle.dashed").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(disabled ? Color.secondary : Color.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if disabled {
                    Text("Disabled")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if trailingReserve {
                    Color.clear.frame(width: 22, height: 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? state.accentTheme.primaryColor.opacity(hovered ? 0.26 : 0.2)
                        : Color.primary.opacity(hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.1), value: hovered)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(state.accentTheme.primaryColor).frame(width: 3).padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(subtitle.map { "\(title) · \($0)" } ?? title)
    }

    @ViewBuilder
    private func menu(_ workflow: ActionsWorkflow) -> some View {
        Button("Show runs") { store.filter.workflowId = workflow.id }
        if let branch = store.currentBranch {
            Button("Show runs on \(branch)") {
                var f = store.filter
                f.workflowId = workflow.id
                f.branch = branch
                store.filter = f
            }
        }
        Button("Run workflow…") { store.beginDispatch(workflow) }.disabled(!workflow.isActive)
        Divider()
        Button(workflow.isActive ? "Disable workflow" : "Enable workflow") { store.setWorkflow(workflow, enabled: !workflow.isActive) }
        if let url = workflow.htmlUrl.flatMap(URL.init(string:)) {
            Button("Open workflow file on GitHub") { NSWorkspace.shared.open(url) }
        }
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workflow.path, forType: .string)
        }
    }
}

// MARK: - Run workflow

struct ActionsWorkflowPickerSheet: View {
    @ObservedObject var store: ActionsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run workflow").font(.system(size: 15, weight: .semibold))
            Text("Choose a workflow to start with workflow_dispatch.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            List(store.workflows.filter(\.isActive)) { workflow in
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.dispatchWorkflow = workflow }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workflow.name).font(.system(size: 12.5, weight: .medium))
                        Text(workflow.path).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

struct ActionsDispatchSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    let workflow: ActionsWorkflow
    @Environment(\.dismiss) private var dismiss

    @State private var ref = ""
    @State private var inputs: [ActionsDispatchInput]?
    @State private var values: [String: String] = [:]
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var showBranches = false
    @FocusState private var focused: String?

    private var accent: Color { state.accentTheme.primaryColor }

    private var branchNames: [String] {
        var names = state.branches.filter { !$0.isRemote }.map(\.name)
        names += state.branches.filter(\.isRemote).map { $0.name.hasPrefix("origin/") ? String($0.name.dropFirst(7)) : $0.name }
        var seen = Set<String>()
        return names.filter { $0 != "HEAD" && !$0.hasSuffix("/HEAD") && seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(label: "Use workflow from", hint: "Branch or tag whose workflow file (and inputs) will run", required: true) {
                        refField
                    }
                    inputsSection
                }
                .padding(22)
            }
            .frame(minHeight: 180, maxHeight: 460)
            Divider()
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 560)
        .tint(accent)
        .onAppear {
            ref = store.currentBranch ?? "main"
            loadInputs()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(accent.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Run \(workflow.name)").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(workflow.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    private var refField: some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            TextField("Branch or tag", text: $ref)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .focused($focused, equals: "__ref")
                .padding(.horizontal, 8)
                .onSubmit { loadInputs() }
            Button { showBranches.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .help("Choose a branch")
            .popover(isPresented: $showBranches, arrowEdge: .bottom) { branchList }
        }
        .modifier(DispatchFieldChrome(focused: focused == "__ref", accent: accent))
    }

    private var branchList: some View {
        let q = ref.trimmingCharacters(in: .whitespaces).lowercased()
        let names = branchNames.filter { q.isEmpty || $0.lowercased().contains(q) }
        let shown = names.isEmpty ? branchNames : names
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(shown.prefix(150), id: \.self) { name in
                    DispatchMenuRow(title: name, selected: name == ref, accent: accent) {
                        ref = name
                        showBranches = false
                        loadInputs()
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 360, height: min(320, CGFloat(shown.prefix(150).count) * 30 + 12))
    }

    @ViewBuilder
    private var inputsSection: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading workflow inputs on \(ref)…").foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
        } else if let loadError {
            notice(loadError, icon: "exclamationmark.triangle.fill", color: .orange)
        } else if inputs == nil {
            notice("This workflow has no workflow_dispatch trigger on \(ref), so GitHub will reject a manual run.",
                   icon: "exclamationmark.triangle.fill", color: .orange)
        } else if let inputs, !inputs.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Inputs").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(inputs) { input in inputField(input) }
            }
        } else {
            notice("This workflow takes no inputs.", icon: "info.circle", color: .secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if missingRequired {
                Label("Fill in the required inputs", systemImage: "asterisk")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .regular))
                .keyboardShortcut(.cancelAction)
            Button {
                submit()
            } label: {
                PRActionLabel("Run workflow", systemImage: "play.fill", isRunning: isSubmitting)
            }
            .buttonStyle(PRActionButtonStyle(.primary(accent), size: .regular))
            .keyboardShortcut(.defaultAction)
            .disabled(ref.isEmpty || isSubmitting || missingRequired)
        }
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12.5))
            .foregroundStyle(color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var missingRequired: Bool {
        (inputs ?? []).contains { $0.required && (values[$0.name] ?? "").isEmpty && $0.type != "boolean" }
    }

    private func field<Content: View>(label: String, hint: String?, required: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 12.5, weight: .semibold))
                if required { Text("*").font(.system(size: 12.5, weight: .bold)).foregroundStyle(.red) }
            }
            if let hint, !hint.isEmpty {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    @ViewBuilder
    private func inputField(_ input: ActionsDispatchInput) -> some View {
        let binding = Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })
        switch input.type {
        case "boolean":
            let isOn = Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" })
            Button { isOn.wrappedValue.toggle() } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(input.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        if let description = input.description, !description.isEmpty {
                            Text(description).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().tint(accent)
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
        case "choice" where !input.options.isEmpty:
            field(label: input.name, hint: input.description, required: input.required) {
                Menu {
                    ForEach(input.options, id: \.self) { option in
                        Button { binding.wrappedValue = option } label: {
                            if option == binding.wrappedValue { Label(option, systemImage: "checkmark") } else { Text(option) }
                        }
                    }
                } label: {
                    HStack {
                        Text(binding.wrappedValue.isEmpty ? "Choose…" : binding.wrappedValue)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(binding.wrappedValue.isEmpty ? Color.secondary : Color.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.hoverPlain)
                .menuIndicator(.hidden)
                .modifier(DispatchFieldChrome(focused: false, accent: accent))
            }
        default:
            field(label: input.name, hint: input.description, required: input.required) {
                TextField(input.defaultValue.map { "Default: \($0)" } ?? "Value", text: binding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focused, equals: input.name)
                    .padding(.horizontal, 10)
                    .modifier(DispatchFieldChrome(focused: focused == input.name, accent: accent))
            }
        }
    }

    private func loadInputs() {
        let target = ref.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        isLoading = true
        loadError = nil
        Task {
            let result = await store.fetchDispatchInputs(workflow, ref: target)
            isLoading = false
            switch result {
            case .success(let parsed):
                inputs = parsed
                for input in parsed ?? [] where values[input.name] == nil {
                    values[input.name] = input.defaultValue ?? (input.type == "boolean" ? "false" : (input.options.first ?? ""))
                }
            case .failure(let error):
                inputs = []
                loadError = "Couldn't read the workflow file on \(target): \(error.localizedDescription)"
            }
        }
    }

    private func submit() {
        isSubmitting = true
        let names = Set((inputs ?? []).map(\.name))
        let payload = values.filter { names.contains($0.key) }
        Task {
            let ok = await store.dispatch(workflow, ref: ref.trimmingCharacters(in: .whitespaces), inputs: payload)
            isSubmitting = false
            if ok {
                store.show(branch: ref.trimmingCharacters(in: .whitespaces), workflowId: workflow.id)
                dismiss()
            }
        }
    }
}

/// Tall, clearly outlined input with an accent focus ring.
private struct DispatchFieldChrome: ViewModifier {
    let focused: Bool
    let accent: Color

    func body(content: Content) -> some View {
        content
            .frame(minHeight: 34)
            .background(Color(NSColor.textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? accent : Color.primary.opacity(0.14), lineWidth: focused ? 1.5 : 1))
    }
}

private struct DispatchMenuRow: View {
    let title: String
    let selected: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(accent) }
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(hovering ? accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .onHover { hovering = $0 }
    }
}
