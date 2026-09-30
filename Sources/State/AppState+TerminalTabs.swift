import Foundation

public struct TerminalSession: Identifiable, Equatable {
    public let id = UUID()
    public var number: Int
    public var entries: [TerminalEntry] = []
    public var input = ""
    public var history: [String] = []
    public var historyIndex = -1

    public var title: String { "Terminal \(number)" }

    public static func == (a: TerminalSession, b: TerminalSession) -> Bool {
        a.id == b.id && a.number == b.number && a.entries.count == b.entries.count
    }
}

extension AppState {
    var currentTerminalSessionID: UUID {
        if let id = activeTerminalSessionID, terminalSessions.contains(where: { $0.id == id }) { return id }
        let id = terminalSessions[0].id
        activeTerminalSessionID = id
        return id
    }

    public func newTerminalSession() {
        stashActiveTerminalSession()
        let next = (terminalSessions.map(\.number).max() ?? 0) + 1
        let session = TerminalSession(number: next)
        terminalSessions.append(session)
        load(session)
    }

    public func selectTerminalSession(_ id: UUID) {
        guard id != currentTerminalSessionID, let target = terminalSessions.first(where: { $0.id == id }) else { return }
        stashActiveTerminalSession()
        load(target)
    }

    public func closeTerminalSession(_ id: UUID) {
        guard terminalSessions.count > 1, let index = terminalSessions.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == currentTerminalSessionID
        if !wasActive { stashActiveTerminalSession() }
        terminalSessions.remove(at: index)
        if wasActive {
            load(terminalSessions[min(index, terminalSessions.count - 1)])
        }
    }

    /// Output goes to the tab that ran the command, even if another tab is showing now.
    func appendTerminalEntry(_ entry: TerminalEntry, to sessionID: UUID) {
        if sessionID == currentTerminalSessionID {
            terminalEntries.append(entry)
        } else if let index = terminalSessions.firstIndex(where: { $0.id == sessionID }) {
            terminalSessions[index].entries.append(entry)
        }
    }

    private func stashActiveTerminalSession() {
        guard let index = terminalSessions.firstIndex(where: { $0.id == currentTerminalSessionID }) else { return }
        terminalSessions[index].entries = terminalEntries
        terminalSessions[index].input = terminalInput
        terminalSessions[index].history = terminalCommandHistory
        terminalSessions[index].historyIndex = terminalHistoryIndex
    }

    private func load(_ session: TerminalSession) {
        activeTerminalSessionID = session.id
        terminalEntries = session.entries
        terminalInput = session.input
        terminalCommandHistory = session.history
        terminalHistoryIndex = session.historyIndex
    }
}
