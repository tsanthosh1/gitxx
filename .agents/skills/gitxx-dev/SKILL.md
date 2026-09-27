---
name: gitxx-dev
description: >-
  Development workflows, architecture patterns, and feature roadmap tracking for the
  GitXX native macOS Git & GitHub client. Use whenever adding features, fixing bugs,
  or updating the GitXX roadmap and documentation.
---

# GitXX Development & Feature Tracking Skill

Use this skill when developing, refactoring, or maintaining the GitXX native macOS application.

## Core Architectural Layers

1. **State Management (`AppState.swift`)**:
   - Central `@MainActor` observable model driving all windows and navigation.
   - Handles async task orchestration, repository path switching, error toasts, and background cache coordination.

2. **WebKit PR Conversation Stream (`ConversationHTMLBuilder.swift` & `PRConversationWebView.swift`)**:
   - Native WKWebView rendering GitHub Primer dark mode (`#0d1117`).
   - Hardware accelerated 120 FPS performance for large PR timelines.
   - Interactive checklist toggles via script message handler `gitxx.postMessage({ action: "toggleChecklist", index: n })`.
   - Update branch action via `gitxx.postMessage({ action: "updateBranch" })`.

3. **Status Checks Prioritization**:
   - Order strictly:
     1. Failed Mandatory (`isFailure && isRequired`)
     2. Failed Optional (`isFailure && !isRequired`)
     3. Pending Mandatory (`isPending && isRequired`)
     4. Pending Optional (`isPending && !isRequired`)
     5. Passed Mandatory (`isSuccess && isRequired`)
     6. Passed Optional (`isSuccess && !isRequired`)
   - Visible badges: `<span class="check-req-badge check-req-mandatory">Required</span>` / `<span class="check-req-badge check-req-optional">Optional</span>`.

4. **Mergeability & Requirement Rules Engine**:
   - Checks:
     - Review approvals verdict (`pr.reviewVerdict`)
     - Mandatory status checks
     - Unresolved review comment conversations (`PRReviewThread.isResolved`)
     - Merge conflicts (`pr.hasConflicts`)
     - Out of date (`pr.isBehind`)
     - Draft PR (`pr.isDraft`)
   - Merging blocked: button disabled with `"Merging is blocked"` status tag.
   - Merging ready: enabled button with merge/squash/rebase strategy dropdown and commit message panel.
   - Out of date / conflicts: show `"⑂ Update branch"` action calling GitHub's `update-branch` API.

## Mandatory Feature Tracking Workflow

Whenever any code change, feature, improvement, or bug fix is implemented:
1. Open [`ROADMAP.md`](../../../ROADMAP.md).
2. Locate the corresponding item (or create a new row with a unique ID).
3. Set the status to `✅ Implemented`, `🚧 In Progress`, or `📋 To Do`.
4. Update the **Summary Status Dashboard** counts.
5. Reference the modified source files in the implementation column.

## Build & Testing Runbook

```bash
# 1. Compile Swift package
swift build

# 2. Package release bundle
./package-app.sh

# 3. Relaunch and open test repository
pkill -9 -f "GitXX.app/Contents/MacOS/GitXX" || true
open -n GitXX.app --args --open /path/to/test/repo
```
