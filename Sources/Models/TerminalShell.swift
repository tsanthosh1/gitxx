import Foundation

public enum TerminalShell: String, CaseIterable, Identifiable, Codable, Sendable {
    case bash = "Bash"
    case zsh = "Zsh"

    public var id: String { rawValue }

    public var executablePath: String {
        switch self {
        case .bash:
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/bash") {
                return "/opt/homebrew/bin/bash"
            } else if FileManager.default.fileExists(atPath: "/usr/local/bin/bash") {
                return "/usr/local/bin/bash"
            }
            return "/bin/bash"
        case .zsh:
            if FileManager.default.fileExists(atPath: "/bin/zsh") {
                return "/bin/zsh"
            } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/zsh") {
                return "/opt/homebrew/bin/zsh"
            }
            return "/bin/zsh"
        }
    }

    /// Shell wrapper that enables alias expansion, sources user profile/rc dotfiles, and executes via eval so aliases are parsed at runtime
    public var wrapperScript: String {
        switch self {
        case .bash:
            return "shopt -s expand_aliases 2>/dev/null; [[ -f ~/.bash_profile ]] && source ~/.bash_profile 2>/dev/null; [[ -f ~/.bashrc ]] && source ~/.bashrc 2>/dev/null; eval \"$GITXX_CMD\""
        case .zsh:
            return "setopt aliases 2>/dev/null; [[ -f ~/.zshenv ]] && source ~/.zshenv 2>/dev/null; [[ -f ~/.zshrc ]] && source ~/.zshrc 2>/dev/null; eval \"$GITXX_CMD\""
        }
    }
}
