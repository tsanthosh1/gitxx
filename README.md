# ⚡️ GitXX — High-Performance Native macOS GitHub Client

A native macOS alternative to GitHub Desktop built with **Swift 6, SwiftUI, and AppKit**. Engineered for instant responsiveness, lightweight memory footprint, and keyboard ergonomics.

---

## 🚀 Key Highlights & Philosophy

| Feature | GitHub Desktop (Electron) | **GitXX (Native macOS)** |
| :--- | :--- | :--- |
| **Runtime & Memory** | Chromium + Node.js (~500MB – 1GB RAM) | **Native Swift Mach-O (~40MB – 70MB RAM)** |
| **Binary Size** | ~420 MB | **~3.1 MB** |
| **Scrolling & Diffs** | Web DOM (~30–60 FPS) | **120Hz ProMotion Native Rendering** |
| **API Rate Limiting** | Frequent REST N+1 requests | **Zero-quota Local Git Engine + 1-point GraphQL Batching** |
| **Keyboard Ergonomics** | Basic browser shortcuts | **Universal Command Palette (⌘K) & Global macOS Shortcuts** |

---

## 🎯 Architecture Overview

```
[UI Layer: SwiftUI + AppKit]
       │
       ├── AppState (Reactive MainActor Observable)
       │       │
       │       ├── GitService (Local Process Actor)
       │       │       └── /usr/bin/git (Diffs, Commits, Branches, Stash, History)
       │       │
       │       ├── GitHubAPIService (GraphQL v4 Engine)
       │       │       └── api.github.com/graphql (PRs, Reviews, Approvals, Rate Limit)
       │       │
       │       └── KeychainHelper (Apple Security Framework)
       │               └── Encrypted Personal Access Token Storage
```

1. **Local-First Git Engine**: All staging, file diffs, commits, branches, and stashes run strictly on-device through an asynchronous `GitService` actor. This means 100% offline capability and zero consumption of your GitHub API quota.
2. **Rate-Limit-Aware GraphQL Engine**: Pull Requests, author metadata, and review states are fetched using a single consolidated GraphQL query costing **1 point per request** (against GitHub's 5,000 points/hr pool).
3. **AppKit + SwiftUI Ergonomics**: Built with native macOS controls, vibrant materials, SF Symbols, and full pointer + keyboard accessibility.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| <kbd>⌘1</kbd> | Switch to **Changes** View |
| <kbd>⌘2</kbd> | Switch to **History** View |
| <kbd>⌘3</kbd> | Switch to **Pull Requests** View |
| <kbd>⌘K</kbd> | Open **Universal Command Palette** |
| <kbd>⌘B</kbd> | Quick **Branch Switcher & Creator** |
| <kbd>⌘O</kbd> | **Open Local Repository** Folder Picker |
| <kbd>⌘Enter</kbd> | **Commit Staged Changes** |
| <kbd>⌘T</kbd> | **Fetch Origin** |
| <kbd>⌘P</kbd> | **Push to Origin** |
| <kbd>⇧⌘P</kbd> | **Pull from Origin** |
| <kbd>⌘R</kbd> | **Refresh Repository Status** |
| <kbd>⌘,</kbd> | Open **Settings & Rate Limit Telemetry** |
| <kbd>Esc</kbd> | Close Modals, Popovers, & Palette |

---

## 🛠 Features

### 1. Working Changes & Diff Viewer
- Instant staged and unstaged file inspection with status badges (`M`, `A`, `D`, `U`).
- High-performance unified and split (side-by-side) diff viewer with line numbers and hunk markers.
- Inline staging checkboxes and "Select All" support.
- Commit box with summary, description, and instant <kbd>⌘Enter</kbd> submission.
- One-click change discard and stash support.

### 2. History & Commit Log
- Searchable commit log by message, author, or SHA.
- Author avatars with relative timestamp calculations.
- Commit detail inspector with copyable SHA and full patch diff.

### 3. Pull Request Review Hub
- Search and filter PRs by status: `Open`, `Review Needed`, `Merged`, or `All`.
- Direct review workflow: **Approve**, **Request Changes**, or **Comment** with markdown feedback.
- One-click **"Checkout Branch"** to test PR code locally before merging.
- Direct links to GitHub web and live CI check statuses.

### 4. Settings & Security
- Secure storage of Personal Access Tokens via macOS Keychain.
- Live GraphQL rate limit progress monitor (Remaining / 5,000).

---

## 📦 Building & Running

### Option A: Launch Application Bundle Directly
```bash
./package-app.sh
open GitXX.app
```

### Option B: Run via Swift Package Manager
```bash
swift run
```

---

## 🔐 Secret Scanning

Commits and pushes are scanned for credentials with [gitleaks](https://github.com/gitleaks/gitleaks) (rules in `.gitleaks.toml`, including Copilot session tokens and literal `Authorization` headers).

```bash
brew install gitleaks
scripts/scan-secrets.sh install   # once per clone: enables the pre-commit and pre-push hooks
scripts/scan-secrets.sh           # full scan: all commits + uncommitted/untracked files
```

CI runs the same scan on every push and pull request (`.github/workflows/secret-scan.yml`).
