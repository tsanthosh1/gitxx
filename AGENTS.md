# GitXX — Agent Developer Guide & Guidelines

> **Instructions for AI Coding Assistants working on GitXX**  
> This file outlines architectural principles, build/packaging workflows, coding standards, and the feature tracking requirements for GitXX.

---

## 1. Project Overview & Architecture

GitXX is a native macOS application built using **Swift 5.9+**, **SwiftUI**, **AppKit**, and **WebKit**. It combines local Git operations (`git` CLI execution) with GitHub REST and GraphQL APIs.

### Directory Layout
- **`Sources/Models/`**: Pure data models (`PullRequest.swift`, `GitFileStatus.swift`, `GitUserProfile.swift`, `TerminalEntry.swift`).
- **`Sources/Services/`**: API and execution services:
  - `GitService.swift`: Runs local git commands with standard output parsers.
  - `GitHubAPIService.swift`: GitHub REST & GraphQL integration (PRs, issues, rulesets, merges).
  - `PRTimelineCache.swift`: Dual in-memory + disk cache for conversation items.
  - `AICommitService.swift`: Multi-provider AI commit message generator.
  - `RepoFileWatcher.swift`: FSEvents file system monitoring for working directory changes.
- **`Sources/State/AppState.swift`**: `@MainActor` observable single-source-of-truth state object managing navigation, selected repos, active PRs, timeline data, checks, and git operations.
- **`Sources/Views/`**:
  - `PullRequests/`: PR list sidebar, detail view, WebKit conversation stream (`PRConversationWebView.swift`, `ConversationHTMLBuilder.swift`), and diff viewer.
  - `Changes/`: Staged/unstaged files list, commit message box, AI commit assistant.
  - `History/`: Commit graph, log sidebar, and commit detail inspector.
 - `Actions/`: GitHub Actions tab: searchable workflow sidebar, run list with filters, run detail (jobs, per-step logs, annotations, artifacts), and the workflow_dispatch sheet. State lives in `Sources/State/ActionsStore.swift`, owned by `AppState.actions`.
  - `Terminal/`: Embedded interactive PTY terminal emulator.
  - `Components/`: Popovers, sheets (Settings, Help, Auth), toasts, and top toolbars.

---

## 2. Key Engineering Rules & Invariants

### 1. PR Conversation Stream (WebKit 120 FPS Architecture)
- Do **not** use SwiftUI `ScrollView` + `LazyVStack` with markdown parsing for large PR timelines; it causes UI freezing and jank on large threads.
- All conversation rendering is managed by `PRConversationWebView` and `ConversationHTMLBuilder.swift` via a hardware-accelerated `WKWebView`.
- Zero-flicker updates: compare HTML content strings before loading (`lastLoadedHTML != newHTML`).
- Instant load: check `PRTimelineCache` for cached timeline items before or while fetching the latest from the GitHub API.

### 2. CI/CD Checks Ordering & Status Badges
- CI/CD checks must **always** be sorted by blocker priority:
  1. `Failed Mandatory` (Required checks that failed &mdash; top priority blockers).
  2. `Failed Optional` (Non-mandatory checks that failed).
  3. `Pending Mandatory` (Required checks currently running).
  4. `Pending Optional` (Optional checks currently running).
  5. `Passed Mandatory` (Required checks that passed).
  6. `Passed Optional` (Optional checks that passed).
- Each check row must display its requirement badge (`Required` in red tint or `Optional` in neutral gray).
- Use fast REST branch rulesets (`GET /repos/{owner}/{repo}/rules/branches/{branch}`) to check required context names; avoid heavy GraphQL status rollups that timeout with 504 on large monorepos.

### 3. Mergeability Engine & Actions
- Every PR must evaluate all merge criteria:
  - **Approvals**: `pr.reviewVerdict` (`.approved`, `.changesRequested`, or `.pending` when reviews are required).
  - **Checks**: All mandatory checks must pass.
  - **Conversations**: All review comment threads (`PRReviewThread`) must have `isResolved == true`.
  - **Conflicts**: Check `pr.hasConflicts` (`mergeable == false` or `mergeableState == "dirty"`).
  - **Behind Base**: Check `pr.isBehind` (`mergeableState == "behind"`).
  - **Draft Status**: Check `pr.isDraft`.
- If blocked: the "Merge pull request" button must be disabled (`.btn-disabled` / `disabled`) with a visible `"Merging is blocked"` tag.
- When behind or conflicting: provide an **"⑂ Update branch"** action calling `PUT /repos/{owner}/{repo}/pulls/{number}/update-branch`.

---

## 3. Mandatory Roadmap & Feature Tracking Rule

> ⚠️ **CRITICAL INSTRUCTION FOR ALL AGENTS**:  
> Whenever you complete a feature, bug fix, performance optimization, or UI improvement:
> 1. Open [ROADMAP.md](ROADMAP.md).
> 2. Mark the feature as `✅ Implemented` (or update its status to `🚧 In Progress`).
> 3. Provide the brief requirement description, category, and list of modified source files.
> 4. Update the **Summary Status Dashboard** counts at the top of `ROADMAP.md`.
> 5. Keep the roadmap file in sync with the user's requirements at all times.

---

## 4. Build, Package & Verification Workflow

1. **Compile**:
   ```bash
   swift build
   ```
2. **Package Application Bundle**:
   ```bash
   ./package-app.sh
   ```
   This generates `GitXX.app` in the repository root and updates the CLI symlink at `~/.local/bin/gitxx`.
3. **Relaunch App**:
   ```bash
   pkill -9 -f "GitXX.app/Contents/MacOS/GitXX" || true
   open -n GitXX.app --args --open /path/to/test/repo
   ```
