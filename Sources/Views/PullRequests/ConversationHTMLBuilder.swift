import Foundation

public enum ConversationHTMLBuilder {

    /// Collects raw markdown bodies so they can be embedded as a single JSON payload
    /// (script-tag text is never entity-decoded, so JSON keeps code blocks and `<` intact).
    private final class MarkdownBag {
        var entries: [(id: String, markdown: String)] = []
        func add(_ id: String, _ markdown: String) { entries.append((id, markdown)) }
    }

    public static func buildHTML(
        pr: PullRequest,
        timeline: [PRTimelineItem],
        checks: [PRCheckRun] = [],
        filter: PRConversationView.ResolvedFilter = .all,
        meta: PRDetailMeta? = nil,
        headCheckedOut: Bool = false
    ) -> String {
        let bag = MarkdownBag()
        let displayedItems: [PRTimelineItem]
        switch filter {
        case .all:
            displayedItems = timeline
        case .unresolved:
            displayedItems = timeline.filter { item in
                if case .reviewThread(let t) = item { return !t.isResolved }
                return true
            }
        case .resolved:
            displayedItems = timeline.filter { item in
                if case .reviewThread(let t) = item { return t.isResolved }
                return true
            }
        }

        let canAct = pr.state.isActive || pr.state == .closed
        var timelineHTML = ""
        for item in displayedItems {
            timelineHTML += renderTimelineItem(item, pr: pr, bag: bag, canAct: canAct)
        }

        let prDescriptionHTML = renderPRDescription(pr: pr, bag: bag)
        let mergeBoxHTML = renderMergeBox(pr: pr, checks: checks, timeline: timeline, meta: meta, headCheckedOut: headCheckedOut)
        let composerHTML = renderCommentComposer(pr: pr)

        return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
\(cssStyles)
\(extraCSS)
</style>
<script>
\(MarkedJS.source)
</script>
<script>
\(markdownRuntimeJS)
</script>
<script>window.__MD = \(markdownJSON(bag));</script>
</head>
<body>
<div class="timeline-container">
  \(prDescriptionHTML)
  \(timelineHTML)
  \(mergeBoxHTML)
  \(composerHTML)
</div>
<script>
\(bridgeScript)
</script>
</body>
</html>
"""
    }

    // MARK: - PR Description Card

    private static func renderPRDescription(pr: PullRequest, bag: MarkdownBag) -> String {
        let avatarUrl = escapeAttr(pr.authorAvatarUrl ?? "https://github.com/\(pr.authorName).png?size=76")
        let rawBody = pr.body.isEmpty ? "_No description provided._" : pr.body
        bag.add("body-desc", rawBody)
        bag.add("raw-desc", pr.body)

        return """
<div class="timeline-item" id="pr-description-card" data-nav="desc" data-nav-label="Description by \(escapeAttr(pr.authorName))">
  <div class="avatar-col">
    \(avatarImg(avatarUrl, login: pr.authorName, cls: "avatar"))
    <div class="timeline-line"></div>
  </div>
  <div class="card">
    <div class="card-header">
      <div class="card-header-left">
        <span class="author-name">\(escapeHTML(pr.authorName))</span>
        <span class="header-text">opened this pull request \(formatDate(pr.createdAt))</span>
      </div>
      <div class="card-header-right desc-header-right">
        <div class="desc-actions" role="group">
          <button type="button" class="desc-btn" onclick="openDescEditor()" title="Edit the description (Markdown)">\(HTMLIcon.pencil)<span>Edit</span></button>
          <span class="desc-actions-sep"></span>
          <button type="button" class="desc-btn desc-btn-ai" onclick="toggleDescAI()" title="Describe a change and let AI rewrite the description">\(HTMLIcon.sparkle)<span>Edit with AI</span></button>
        </div>
        <span class="badge badge-author">Author</span>
        <div class="desc-ai-pop" id="descAIPop" data-visibility style="display:none">
          <div class="desc-ai-title">\(HTMLIcon.sparkle) Edit description with AI</div>
          <textarea id="descAIInput" data-persist class="input-textarea desc-ai-input" rows="3" placeholder="What should change? e.g. “Summarize the testing done and tick the checklist”" onkeydown="descAIKey(event)"></textarea>
          <div class="desc-ai-actions">
            <button type="button" class="btn btn-secondary btn-sm" onclick="descAIOpenChat()" title="Continue in the AI chat window, which can read the PR template, lint workflows and merged PRs">\(HTMLIcon.comment) Open in chat</button>
            <span class="composer-hint">⌘↵ to submit</span>
            <button type="button" class="btn btn-secondary btn-sm" onclick="toggleDescAI(false)">Cancel</button>
            <button type="button" class="btn btn-primary btn-sm" id="descAISubmit" data-busy="Rewriting…" onclick="descAISubmit()">Submit</button>
          </div>
        </div>
      </div>
    </div>
    <div class="card-body markdown-body" id="body-desc" data-visibility></div>
    <div class="desc-editor" id="descEditor" data-visibility style="display:none">
      <div class="composer-tabs">
        <button type="button" class="composer-tab active" id="descTabWrite" onclick="setDescMode('write')">Write</button>
        <button type="button" class="composer-tab" id="descTabPreview" onclick="setDescMode('preview')">Preview</button>
      </div>
      <div class="composer">
        <textarea class="input-textarea composer-input desc-edit-input" id="descEditInput" data-persist rows="14" placeholder="Describe this pull request… (Markdown supported)" onkeydown="descEditKey(event)"></textarea>
        <div class="markdown-body composer-preview" id="descEditPreview" style="display:none"></div>
        <div class="composer-actions">
          <span class="composer-hint">⌘↵ to save · Esc to cancel</span>
          <button type="button" class="btn btn-secondary" onclick="closeDescEditor()">Cancel</button>
          <button type="button" class="btn btn-primary" onclick="saveDescEditor()">Save description</button>
        </div>
      </div>
    </div>
  </div>
</div>
"""
    }

    // MARK: - Timeline Item Router

    private static func renderTimelineItem(_ item: PRTimelineItem, pr: PullRequest, bag: MarkdownBag, canAct: Bool) -> String {
        switch item {
        case .issueComment(let c):
            return renderIssueComment(c, pr: pr, bag: bag)
        case .reviewEvent(let r):
            return renderReviewEvent(r, bag: bag)
        case .reviewThread(let t):
            return renderReviewThread(t, pr: pr, bag: bag, canAct: canAct)
        case .commitPushed(let commits):
            return renderCommitPushed(commits)
        case .merged(let author, let date, let sha):
            return renderStatusEvent(icon: HTMLIcon.merge, color: "#a371f7", text: "<strong>\(escapeHTML(author))</strong> merged commit <code>\(escapeHTML(String(sha.prefix(7))))</code> into <code>\(escapeHTML(pr.baseBranch))</code>", date: date)
        case .closed(let author, let date):
            return renderStatusEvent(icon: HTMLIcon.x, color: "#f85149", text: "<strong>\(escapeHTML(author))</strong> closed this pull request", date: date)
        case .reopened(let author, let date):
            return renderStatusEvent(icon: "↺", color: "#3fb950", text: "<strong>\(escapeHTML(author))</strong> reopened this pull request", date: date)
        case .labeled(let name, let color, let date, let actor):
            return renderStatusEvent(icon: "🏷", color: "#8b949e", text: "<strong>\(escapeHTML(actor))</strong> added the \(labelPill(name: name, color: color)) label", date: date)
        case .readyForReview(let author, let date):
            return renderStatusEvent(icon: "👁", color: "#3fb950", text: "<strong>\(escapeHTML(author))</strong> marked this pull request as ready for review", date: date)
        }
    }

    // MARK: - Issue Comment

    private static func roleBadge(for login: String, pr: PullRequest) -> String {
        if login == pr.authorName { return "<span class=\"badge badge-author\">Author</span>" }
        if login.contains("[bot]") || login.lowercased().hasSuffix("bot") { return "<span class=\"badge badge-bot\">Bot</span>" }
        return ""
    }

    private static func renderIssueComment(_ comment: PRComment, pr: PullRequest, bag: MarkdownBag) -> String {
        let avatarUrl = escapeAttr(comment.authorAvatarUrl ?? "https://github.com/\(comment.authorName).png?size=76")
        let bodyId = "body-comment-\(safeId(comment.id))"
        bag.add(bodyId, comment.body)

        return """
<div class="timeline-item" id="comment-\(safeId(comment.id))" data-nav="comment" data-nav-label="\(escapeAttr(comment.authorName)) commented">
  <div class="avatar-col">
    \(avatarImg(avatarUrl, login: comment.authorName, cls: "avatar"))
    <div class="timeline-line"></div>
  </div>
  <div class="card">
    <div class="card-header">
      <div class="card-header-left">
        <span class="author-name">\(escapeHTML(comment.authorName))</span>
        <span class="header-text">commented \(formatDate(comment.createdAt))</span>
      </div>
      <div class="card-header-right">
        \(roleBadge(for: comment.authorName, pr: pr))
        <button type="button" class="icon-btn" title="Quote reply" onclick="quoteReply('\(bodyId)', '\(escapeJS(comment.authorName))')">❝</button>
      </div>
    </div>
    <div class="card-body markdown-body" id="\(bodyId)"></div>
  </div>
</div>
"""
    }

    // MARK: - Review Event

    private static func renderReviewEvent(_ review: PRReviewEvent, bag: MarkdownBag) -> String {
        let avatarUrl = escapeAttr(review.authorAvatarUrl ?? "https://github.com/\(review.authorName).png?size=76")
        let state = review.state.uppercased()

        let badgeIcon: String
        let badgeColor: String
        let actionText: String
        let cardClass: String
        switch state {
        case "APPROVED":
            badgeIcon = HTMLIcon.check; badgeColor = "#238636"; actionText = "approved these changes"; cardClass = "review-approved"
        case "CHANGES_REQUESTED":
            badgeIcon = "!"; badgeColor = "#da3633"; actionText = "requested changes"; cardClass = "review-changes"
        case "DISMISSED":
            badgeIcon = "—"; badgeColor = "#6e7681"; actionText = "had their review dismissed"; cardClass = ""
        default:
            badgeIcon = HTMLIcon.comment; badgeColor = "#1f6feb"; actionText = review.body.isEmpty ? "reviewed" : "reviewed and commented"; cardClass = ""
        }

        let navKind = state == "APPROVED" ? "approved" : (state == "CHANGES_REQUESTED" ? "changes" : "comment")
        var bodyHTML = ""
        if !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let bodyId = "review-body-\(safeId(review.id))"
            bag.add(bodyId, review.body)
            bodyHTML = "<div class=\"review-body card-body markdown-body\" id=\"\(bodyId)\"></div>"
        }

        return """
<div class="timeline-item" id="review-\(safeId(review.id))" data-nav="\(navKind)" data-nav-label="\(escapeAttr(review.authorName)) \(escapeAttr(actionText))">
  <div class="avatar-col">
    \(avatarImg(avatarUrl, login: review.authorName, cls: "avatar"))
    <div class="timeline-line"></div>
  </div>
  <div class="card review-card \(cardClass)">
    <div class="card-header review-header">
      <div class="card-header-left">
        <span class="status-circle" style="background: \(badgeColor)">\(badgeIcon)</span>
        <span class="author-name">\(escapeHTML(review.authorName))</span>
        <span class="header-text">\(actionText) \(formatDate(review.submittedAt))</span>
      </div>
    </div>
    \(bodyHTML)
  </div>
</div>
"""
    }

    // MARK: - Review Thread

    private static func renderReviewThread(_ thread: PRReviewThread, pr: PullRequest, bag: MarkdownBag, canAct: Bool) -> String {
        let isResolved = thread.isResolved
        let threadDomId = "thread-\(safeId(thread.id))"
        let rootCommentId = thread.comments.first?.id ?? thread.id

        var pills = ""
        if thread.isOutdated == true { pills += "<span class=\"outdated-pill\">Outdated</span>" }
        if !thread.isResolutionKnown {
            pills += ""
        } else if isResolved {
            let by = thread.resolvedByName.map { " by \(escapeHTML($0))" } ?? ""
            pills += "<span class=\"resolved-pill\">\(HTMLIcon.check) Resolved\(by)</span>"
        } else {
            pills += "<span class=\"unresolved-pill\">Unresolved</span>"
        }

        var diffHTML = ""
        if let hunk = thread.diffHunk, !hunk.isEmpty {
            var lines = hunk.components(separatedBy: "\n")
            if lines.count > 8 { lines = [lines[0]] + lines.suffix(7) }
            let rendered = lines.map { line -> String in
                let cls: String
                if line.hasPrefix("@@") { cls = "dl-hunk" }
                else if line.hasPrefix("+") { cls = "dl-add" }
                else if line.hasPrefix("-") { cls = "dl-del" }
                else { cls = "dl-ctx" }
                return "<div class=\"\(cls)\">\(line.isEmpty ? "&nbsp;" : escapeHTML(line))</div>"
            }.joined()
            diffHTML = "<div class=\"diff-hunk-container\"><pre class=\"diff-hunk-pre\"><code>\(rendered)</code></pre></div>"
        }

        var commentsHTML = ""
        for (i, c) in thread.comments.enumerated() {
            let cAvatar = escapeAttr(c.authorAvatarUrl ?? "https://github.com/\(c.authorName).png?size=56")
            let bodyId = "thread-c-\(safeId(c.id))"
            bag.add(bodyId, c.body)
            commentsHTML += """
            <div class="thread-comment \(i > 0 ? "thread-comment-reply" : "")">
              <div class="thread-comment-header">
                \(avatarImg(cAvatar, login: c.authorName, cls: "avatar-small"))
                <span class="author-name">\(escapeHTML(c.authorName))</span>
                \(roleBadge(for: c.authorName, pr: pr))
                <span class="header-text">\(formatDate(c.createdAt))</span>
              </div>
              <div class="thread-comment-body markdown-body" id="\(bodyId)"></div>
            </div>
            """
        }

        let replyKey = "reply-\(safeId(rootCommentId))"
        var footerHTML = ""
        if canAct {
            var resolveButton = ""
            if let nodeId = thread.nodeId {
                let label = isResolved ? "Unresolve conversation" : "Resolve conversation"
                let busy = isResolved ? "Unresolving…" : "Resolving…"
                resolveButton = "<button type=\"button\" class=\"btn btn-secondary\" data-busy=\"\(busy)\" onclick=\"resolveThread(this, '\(escapeJS(nodeId))', \(isResolved ? "false" : "true"))\">\(label)</button>"
            }
            footerHTML = """
            <div class="thread-footer">
              <div class="reply-row" id="\(replyKey)-row" data-visibility>
                <button type="button" class="reply-placeholder" onclick="openReply('\(replyKey)')">Reply…</button>
                \(resolveButton)
              </div>
              <div class="composer reply-composer" id="\(replyKey)-box" data-visibility style="display:none">
                <textarea class="input-textarea composer-input" id="\(replyKey)" data-persist data-draft-key="\(replyKey)" rows="3" placeholder="Reply to this conversation… (⌘↵ to send)" onkeydown="composerKey(event, function(){ submitReply('\(replyKey)', '\(escapeJS(rootCommentId))'); })"></textarea>
                <div class="composer-actions">
                  <span class="composer-hint">Markdown supported · ⌘↵ to send</span>
                  <button type="button" class="btn btn-secondary" onclick="closeReply('\(replyKey)')">Cancel</button>
                  <button type="button" class="btn btn-primary" id="\(replyKey)-send" data-busy="Sending…" onclick="submitReply('\(replyKey)', '\(escapeJS(rootCommentId))')">Reply</button>
                </div>
              </div>
            </div>
            """
        }

        let collapsed = isResolved && thread.isResolutionKnown
        let summary = collapsed
            ? "<div class=\"thread-collapsed-summary\" onclick=\"toggleThread('\(threadDomId)')\">\(thread.comments.count) comment\(thread.comments.count == 1 ? "" : "s") hidden — click to expand</div>"
            : ""

        return """
<div class="timeline-item" id="\(threadDomId)" data-thread data-nav="\(isResolved ? "resolved" : "open")" data-nav-label="\(isResolved ? "Resolved" : "Open") thread · \(escapeAttr(thread.fileDisplayName))\(thread.line.map { ":\($0)" } ?? "")">
  <div class="avatar-col">
    <div class="thread-icon" style="color: \(isResolved ? "#3fb950" : "#d29922");">\(isResolved ? HTMLIcon.check : HTMLIcon.comment)</div>
    <div class="timeline-line"></div>
  </div>
  <div class="card thread-card \(isResolved ? "thread-resolved" : "")">
    <div class="card-header thread-header">
      <div class="card-header-left">
        <button type="button" class="thread-toggle" onclick="toggleThread('\(threadDomId)')" title="Show / hide conversation">\(collapsed ? "▸" : "▾")</button>
        <a class="thread-file-path" href="#" onclick="openFile('\(escapeJS(thread.path))'); return false;" title="Open in Files Changed">\(escapeHTML(thread.path))\(thread.line.map { ":\($0)" } ?? "")</a>
      </div>
      <div class="card-header-right">\(pills)</div>
    </div>
    \(summary)
    <div class="thread-body" id="\(threadDomId)-body" data-visibility style="\(collapsed ? "display:none" : "")">
      \(diffHTML)
      <div class="thread-comments-container">\(commentsHTML)</div>
      \(footerHTML)
    </div>
  </div>
</div>
"""
    }

    // MARK: - Commits Pushed

    private static func renderCommitPushed(_ commits: [PRCommitEvent]) -> String {
        var commitsList = ""
        for c in commits {
            commitsList += """
            <div class="commit-row">
              <span class="commit-dot"></span>
              <span class="commit-msg" title="\(escapeAttr(c.message))">\(escapeHTML(c.firstLine))</span>
              <span class="commit-author">\(escapeHTML(c.authorName))</span>
              <span class="commit-sha">\(escapeHTML(c.shortSha))</span>
            </div>
            """
        }

        return """
<div class="timeline-item timeline-event" data-nav="commit" data-nav-label="\(commits.count) commit\(commits.count == 1 ? "" : "s") pushed">
  <div class="avatar-col">
    <div class="event-icon-circle">●</div>
    <div class="timeline-line"></div>
  </div>
  <div class="event-content">
    <div class="commit-group-title">\(commits.count) commit\(commits.count == 1 ? "" : "s")</div>
    <div class="commit-group">\(commitsList)</div>
  </div>
</div>
"""
    }

    // MARK: - Status Events

    private static func renderStatusEvent(icon: String, color: String, text: String, date: Date) -> String {
        return """
<div class="timeline-item timeline-event" data-nav="event">
  <div class="avatar-col">
    <div class="event-icon-circle" style="color: \(color)">\(icon)</div>
    <div class="timeline-line"></div>
  </div>
  <div class="event-content status-event-row">
    <span class="status-event-text">\(text)</span>
    <span class="status-event-date">\(formatDate(date))</span>
  </div>
</div>
"""
    }

    // MARK: - Checks & Merge Box

    private static func renderMergeBox(pr: PullRequest, checks: [PRCheckRun], timeline: [PRTimelineItem], meta: PRDetailMeta?, headCheckedOut: Bool) -> String {
        let readiness = PRMergeReadiness.evaluate(pr: pr, checks: checks, timeline: timeline, meta: meta)
        let sortedChecks = PRCheckRun.sortedByBlockerPriority(checks)
        let hasChecks = !checks.isEmpty
        let isActive = pr.state.isActive
        let isMerged = pr.state == .merged
        let isClosed = pr.state == .closed

        // 1. Checks header
        let checkHeaderIcon: String
        let checkHeaderClass: String
        let checkHeaderTitle: String
        let checkHeaderSubtext: String
        let failingTotal = readiness.failedRequired + readiness.failedOptional
        let pendingTotal = readiness.pendingRequired + readiness.pendingOptional
        if !hasChecks {
            checkHeaderIcon = "ℹ"; checkHeaderClass = "check-neutral"
            checkHeaderTitle = "No checks have run yet"
            checkHeaderSubtext = "No continuous integration status checks reported."
        } else if readiness.failedRequired > 0 {
            checkHeaderIcon = HTMLIcon.x; checkHeaderClass = "check-failure"
            checkHeaderTitle = readiness.failedRequired == 1 ? "1 required check failed" : "\(readiness.failedRequired) required checks failed"
            checkHeaderSubtext = "\(failingTotal) failing, \(pendingTotal) in progress, \(readiness.passed) successful"
        } else if readiness.pendingRequired > 0 {
            checkHeaderIcon = HTMLIcon.clock; checkHeaderClass = "check-pending"
            checkHeaderTitle = "Waiting for \(readiness.pendingRequired) required check\(readiness.pendingRequired == 1 ? "" : "s")"
            checkHeaderSubtext = "\(pendingTotal) in progress, \(readiness.passed) successful" + (readiness.failedOptional > 0 ? ", \(readiness.failedOptional) optional failing" : "")
        } else if readiness.failedOptional > 0 {
            checkHeaderIcon = "!"; checkHeaderClass = "check-pending"
            checkHeaderTitle = readiness.failedOptional == 1 ? "1 optional check failed" : "\(readiness.failedOptional) optional checks failed"
            checkHeaderSubtext = "\(readiness.passed) successful · optional failures do not block merging"
        } else if pendingTotal > 0 {
            checkHeaderIcon = HTMLIcon.clock; checkHeaderClass = "check-pending"
            checkHeaderTitle = "Some checks are in progress"
            checkHeaderSubtext = "\(pendingTotal) in progress, \(readiness.passed) successful"
        } else {
            checkHeaderIcon = HTMLIcon.check; checkHeaderClass = "check-success"
            checkHeaderTitle = "All checks have passed"
            checkHeaderSubtext = "\(readiness.passed) successful \(readiness.passed == 1 ? "check" : "checks")"
        }

        let rerunnableFailed = checks.contains { ($0.isFailure || $0.conclusion?.lowercased() == "cancelled") && $0.actionsRunId != nil }
        let hasActionsChecks = checks.contains { $0.actionsRunId != nil }
        var checksHeaderActions = ""
        if isActive && rerunnableFailed {
            checksHeaderActions += "<button type=\"button\" class=\"btn btn-secondary btn-sm\" data-busy=\"Re-running…\" onclick=\"sendAction({action:'rerunFailed'}, 'rerunFailed', this)\">\(HTMLIcon.sync) Re-run failed</button>"
        }
        if hasActionsChecks {
            checksHeaderActions += "<button type=\"button\" class=\"btn btn-secondary btn-sm\" title=\"Runs for this branch in the Actions tab\" onclick=\"sendAction({action:'showPRActions'})\">\(HTMLIcon.play) Actions</button>"
        }
        if hasChecks {
            let collapseByDefault = failingTotal == 0 && pendingTotal == 0
            checksHeaderActions += "<button type=\"button\" class=\"btn-link\" id=\"checksToggleBtn\" onclick=\"toggleChecksList()\">\(collapseByDefault ? "Show all checks" : "Hide all checks")</button>"
        }

        // Proportion bar and per-state filter chips.
        var checksSummaryHTML = ""
        if hasChecks {
            let counts = PRCheckRun.Group.allCases.map { g in (g, checks.filter { $0.group == g }.count) }.filter { $0.1 > 0 }
            let bar = counts.map { g, n in
                "<span class=\"ck-bar-seg ck-bar-\(g)\" style=\"flex:\(n)\"></span>"
            }.joined()
            let chips = counts.map { g, n -> String in
                let icon: String
                switch g {
                case .failing: icon = HTMLIcon.x
                case .running: icon = HTMLIcon.dot
                case .passing: icon = HTMLIcon.check
                case .skipped: icon = HTMLIcon.skip
                }
                return "<button type=\"button\" class=\"ck-chip ck-chip-\(g)\" data-group=\"\(g)\" onclick=\"filterChecks('\(g)', this)\">\(icon)<b>\(n)</b> \(g.title.lowercased())</button>"
            }.joined()
            checksSummaryHTML = """
            <div class="ck-summary">
              <div class="ck-bar">\(bar)</div>
              <div class="ck-chips">\(chips)</div>
            </div>
            """
        }

        var checksRowsHTML = ""
        for group in PRCheckRun.Group.allCases {
            let items = sortedChecks.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            let requiredCount = items.filter(\.isRequired).count
            checksRowsHTML += "<div class=\"check-group-header check-group-\(group)\" data-group=\"\(group)\">\(group.title) <span class=\"check-group-count\">\(items.count)</span>\(requiredCount > 0 ? " <span class=\"check-group-req\">· \(requiredCount) required</span>" : "")</div>"
            for c in items {
                let icon: String
                let cssClass: String
                switch c.group {
                case .running: icon = HTMLIcon.dot; cssClass = "check-pending"
                case .passing: icon = HTMLIcon.check; cssClass = "check-success"
                case .skipped: icon = HTMLIcon.skip; cssClass = "check-neutral"
                case .failing: icon = HTMLIcon.x; cssClass = "check-failure"
                }
                let reqBadge = c.isRequired
                    ? "<span class=\"check-req-badge check-req-mandatory\">Required</span>"
                    : "<span class=\"check-req-badge check-req-optional\">Optional</span>"

                let duration = c.durationText.flatMap { $0 == "0s" ? nil : $0 } ?? ""
                let outcome: String
                switch c.group {
                case .failing:
                    let word = c.conclusion?.lowercased() == "cancelled" ? "Cancelled" : (c.conclusion?.lowercased() == "timed_out" ? "Timed out" : "Failed")
                    outcome = duration.isEmpty ? word : "\(word) after \(duration)"
                case .running: outcome = c.status.lowercased() == "queued" ? "Queued" : "In progress"
                case .passing: outcome = duration.isEmpty ? "Succeeded" : "Succeeded in \(duration)"
                case .skipped: outcome = c.displayConclusion
                }
                let source = c.appName ?? (c.actionsRunId != nil ? "GitHub Actions" : nil)
                var sub = [outcome]
                if let source, !source.isEmpty { sub.append(escapeHTML(source)) }
                if let title = c.outputTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != c.name {
                    sub.append(escapeHTML(String(title.prefix(140))))
                }

                let runId = c.actionsRunId.flatMap(Int.init)
                let jobId = c.actionsJobId.flatMap(Int.init)
                let summary = c.outputSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rowId = "ck-" + String(c.id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))

                var buttons = ""
                if c.group == .failing {
                    buttons += "<button type=\"button\" class=\"ck-btn ck-btn-ai\" title=\"Ask the AI assistant why it failed\" onclick=\"event.stopPropagation(); sendAction({action:'explainCheck', name:'\(escapeJS(c.name))'})\">\(HTMLIcon.sparkle)<span>Explain</span></button>"
                }
                if isActive, c.isRerunnable, let job = c.actionsJobId {
                    buttons += "<button type=\"button\" class=\"ck-btn\" title=\"Re-run this job\" data-busy=\"…\" onclick=\"event.stopPropagation(); sendAction({action:'rerunCheck', jobId:'\(escapeJS(job))'}, 'rerun-\(escapeJS(job))', this)\">\(HTMLIcon.sync)<span>Re-run</span></button>"
                }
                if let runId {
                    buttons += "<button type=\"button\" class=\"ck-btn ck-btn-primary\" title=\"Steps and logs in the Actions tab\" onclick=\"event.stopPropagation(); sendAction({action:'openCheckRun', runId:\(runId), jobId:\(jobId.map(String.init) ?? "null")})\">\(HTMLIcon.play)<span>Logs</span></button>"
                } else if !summary.isEmpty {
                    buttons += "<button type=\"button\" class=\"ck-btn\" title=\"Show the check's report\" onclick=\"event.stopPropagation(); toggleCheckSummary('\(rowId)')\">\(HTMLIcon.chevronDown)<span>Report</span></button>"
                }
                if let link = c.htmlUrl, !link.isEmpty {
                    buttons += "<a class=\"ck-btn ck-btn-icon\" href=\"\(escapeAttr(link))\" title=\"Open on GitHub\" onclick=\"event.stopPropagation()\">\(HTMLIcon.linkExternal)</a>"
                }

                let rowClick: String
                if let runId {
                    rowClick = "sendAction({action:'openCheckRun', runId:\(runId), jobId:\(jobId.map(String.init) ?? "null")})"
                } else if !summary.isEmpty {
                    rowClick = "toggleCheckSummary('\(rowId)')"
                } else if c.htmlUrl?.isEmpty == false {
                    rowClick = "var a=this.querySelector('a.ck-btn-icon'); if(a) a.click()"
                } else {
                    rowClick = ""
                }

                checksRowsHTML += """
                <div class="ck-row \(c.isFailure && c.isRequired ? "check-row-blocking" : "") \(rowClick.isEmpty ? "" : "ck-clickable")" data-group="\(c.group)" \(rowClick.isEmpty ? "" : "onclick=\"\(escapeAttr(rowClick))\"")>
                  <span class="ck-icon \(cssClass)">\(icon)</span>
                  <div class="ck-main">
                    <div class="ck-name-line"><span class="ck-name" title="\(escapeAttr(c.name))">\(escapeHTML(c.name))</span>\(reqBadge)</div>
                    <div class="ck-sub">\(sub.joined(separator: " · "))</div>
                  </div>
                  <div class="ck-actions">\(buttons)</div>
                </div>
                \(summary.isEmpty || runId != nil ? "" : "<div class=\"ck-report\" id=\"\(rowId)\" style=\"display:none\">\(escapeHTML(String(summary.prefix(4000))))</div>")
                """
            }
        }

        // 2. Requirement rows
        func rule(_ icon: String, _ cls: String, _ title: String, _ desc: String, action: String = "") -> String {
            """
            <div class="merge-rule-item">
              <span class="rule-icon \(cls)">\(icon)</span>
              <div class="rule-content">
                <div class="rule-title">\(title)</div>
                \(desc.isEmpty ? "" : "<div class=\"rule-desc\">\(desc)</div>")
              </div>
              \(action.isEmpty ? "" : "<div class=\"rule-action\">\(action)</div>")
            </div>
            """
        }

        var rulesHTML = ""
        if isActive {
            // Reviews
            let reviewers = meta?.reviewers ?? []
            let approvers = reviewers.filter { $0.state == "APPROVED" }.map(\.login)
            let requesters = reviewers.filter { $0.state == "CHANGES_REQUESTED" }.map(\.login)
            let awaiting = reviewers.filter { $0.state == "REQUESTED" }.map(\.login)
            let reviewAction = "<button type=\"button\" class=\"btn btn-secondary btn-sm\" onclick=\"sendAction({action:'openReview'}, 'openReview')\">Review</button>"
            switch readiness.reviewVerdict {
            case .changesRequested:
                let who = requesters.isEmpty ? "A reviewer" : requesters.map(escapeHTML).joined(separator: ", ")
                rulesHTML += rule(HTMLIcon.x, "rule-failure", "Changes requested", "\(who) requested changes.", action: reviewAction)
            case .approved:
                let who = approvers.isEmpty ? "" : "\(approvers.count) approving review\(approvers.count == 1 ? "" : "s") by \(approvers.map(escapeHTML).joined(separator: ", "))."
                rulesHTML += rule(HTMLIcon.check, "rule-success", "Changes approved", who.isEmpty ? "Required approvals have been granted." : who)
            case .pending, .commented:
                let awaitingText = awaiting.isEmpty ? "" : " Awaiting \(awaiting.map(escapeHTML).joined(separator: ", "))."
                if readiness.isReviewBlocked {
                    rulesHTML += rule(HTMLIcon.x, "rule-failure", "Review required", "At least one approving review is required.\(awaitingText)", action: reviewAction)
                } else {
                    rulesHTML += rule("●", "rule-neutral", "Review pending", "Reviews are pending or optional.\(awaitingText)", action: reviewAction)
                }
            }

            // Checks
            if hasChecks {
                if readiness.failedRequired > 0 {
                    let action = rerunnableFailed ? "<button type=\"button\" class=\"btn btn-secondary btn-sm\" data-busy=\"Re-running…\" onclick=\"sendAction({action:'rerunFailed'}, 'rerunFailed', this)\">\(HTMLIcon.sync) Re-run failed</button>" : ""
                    rulesHTML += rule(HTMLIcon.x, "rule-failure", "Required status checks failed", "\(readiness.failedRequired) of \(readiness.requiredTotal) required checks must pass before merging.", action: action)
                } else if readiness.pendingRequired > 0 {
                    rulesHTML += rule(HTMLIcon.clock, "rule-pending", "Required status checks in progress", "Waiting for \(readiness.pendingRequired) required check\(readiness.pendingRequired == 1 ? "" : "s"). This page refreshes automatically.")
                } else if readiness.requiredTotal > 0 {
                    rulesHTML += rule(HTMLIcon.check, "rule-success", "Required status checks passed", "All \(readiness.requiredTotal) required checks have passed" + (readiness.failedOptional > 0 ? " (\(readiness.failedOptional) optional failing, non-blocking)." : "."))
                } else {
                    rulesHTML += rule(HTMLIcon.check, "rule-success", "No required status checks", readiness.failedOptional > 0 ? "\(readiness.failedOptional) optional checks failed (non-blocking)." : "\(readiness.passed) checks succeeded.")
                }
            }

            // Conversations
            if readiness.totalThreads > 0 {
                if !readiness.resolutionKnown {
                    rulesHTML += rule("●", "rule-neutral", "Conversations", "Loading resolution status for \(readiness.totalThreads) review thread\(readiness.totalThreads == 1 ? "" : "s")…")
                } else if readiness.unresolvedThreads > 0 {
                    rulesHTML += rule(HTMLIcon.x, "rule-failure", "Unresolved conversations", "\(readiness.unresolvedThreads) of \(readiness.totalThreads) conversation\(readiness.totalThreads == 1 ? "" : "s") must be resolved before merging.", action: "<button type=\"button\" class=\"btn btn-secondary btn-sm\" onclick=\"jumpToUnresolved()\">Show next</button>")
                } else {
                    rulesHTML += rule(HTMLIcon.check, "rule-success", "All conversations resolved", "\(readiness.totalThreads) review thread\(readiness.totalThreads == 1 ? "" : "s") resolved.")
                }
            }

            // Branch state
            let updateBtn = "<button type=\"button\" class=\"btn btn-secondary btn-sm\" data-busy=\"Updating…\" onclick=\"sendAction({action:'updateBranch'}, 'updateBranch', this)\">\(HTMLIcon.merge) Update branch</button>"
            if pr.hasConflicts {
                rulesHTML += rule(HTMLIcon.x, "rule-failure", "This branch has conflicts that must be resolved", "Conflicting changes with <code>\(escapeHTML(pr.baseBranch))</code>.", action: updateBtn)
            } else if pr.isBehind {
                rulesHTML += rule("!", "rule-pending", "This branch is out-of-date with the base branch", "Merge the latest changes from <code>\(escapeHTML(pr.baseBranch))</code> into this branch.", action: updateBtn)
            } else if pr.mergeable == nil {
                rulesHTML += rule("●", "rule-neutral", "Checking for merge conflicts…", "GitHub is computing mergeability.")
            } else {
                rulesHTML += rule(HTMLIcon.check, "rule-success", "No conflicts with the base branch", "Changes can be cleanly merged.")
            }

            if readiness.isPushRestricted {
                rulesHTML += rule(HTMLIcon.x, "rule-failure", "You're not authorized to push to this branch", "Branch protection on <code>\(escapeHTML(pr.baseBranch))</code> restricts who can merge. <a href=\"https://docs.github.com/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches\">About protected branches</a>")
            }

            if pr.isDraft {
                rulesHTML += rule("●", "rule-neutral", "This pull request is still a draft", "Drafts cannot be merged until marked ready for review.", action: "<button type=\"button\" class=\"btn btn-secondary btn-sm\" data-busy=\"Updating…\" onclick=\"sendAction({action:'setDraft', draft:false}, 'setDraft', this)\">Ready for review</button>")
            }
        }

        // 3. Status line
        let statusBoxIcon: String
        let statusBoxClass: String
        let statusBoxTitle: String
        let statusBoxSubtext: String
        if isMerged {
            statusBoxIcon = HTMLIcon.merge; statusBoxClass = "check-merged"
            statusBoxTitle = "Pull request successfully merged and closed"
            statusBoxSubtext = "Commits have been merged into <code>\(escapeHTML(pr.baseBranch))</code>."
        } else if isClosed {
            statusBoxIcon = HTMLIcon.x; statusBoxClass = "check-closed"
            statusBoxTitle = "This pull request is closed"
            statusBoxSubtext = "Reopen this pull request to propose changes again."
        } else if readiness.status == .blocked {
            statusBoxIcon = HTMLIcon.x; statusBoxClass = "check-failure"
            statusBoxTitle = "Merging is blocked"
            statusBoxSubtext = readiness.blockers.map(escapeHTML).joined(separator: " · ")
        } else if readiness.status == .pending {
            statusBoxIcon = HTMLIcon.clock; statusBoxClass = "check-pending"
            statusBoxTitle = "Waiting on required checks"
            statusBoxSubtext = "Merging will be available once required checks pass."
        } else {
            statusBoxIcon = HTMLIcon.check; statusBoxClass = "check-success"
            statusBoxTitle = "Ready to merge"
            statusBoxSubtext = "All requirements are satisfied. Merging can be performed automatically."
        }

        // 4. Action bar
        var actionSectionHTML = ""
        if isActive {
            let allowed = meta?.allowedMergeMethods ?? ["merge", "squash", "rebase"]
            let names = ["merge": "Create a merge commit", "squash": "Squash and merge", "rebase": "Rebase and merge"]
            let options = allowed.enumerated().map { idx, m in
                "<option value=\"\(m)\"\(idx == 0 ? " selected" : "")>\(names[m] ?? m)</option>"
            }.joined()
            let firstLabel = names[allowed.first ?? "merge"] ?? "Merge pull request"
            let squashTitle = escapeAttr("\(pr.title) (#\(pr.number))")
            let mergeTitle = escapeAttr("Merge pull request #\(pr.number) from \(pr.headBranch)")
            let blocked = readiness.isMergeBlocked || pr.hasConflicts || pr.isDraft
            let deleteOption = meta?.deleteBranchOnMerge == true
                ? "<span class=\"composer-hint\">Head branch is deleted automatically after merge.</span>"
                : "<label class=\"checkbox-label\"><input type=\"checkbox\" id=\"mergeDeleteBranch\" data-persist> Delete <code>\(escapeHTML(pr.headBranch))</code> after merge</label>"

            actionSectionHTML = """
            <div class="merge-action-bar">
              <div class="merge-button-group">
                <button type="button" class="btn btn-merge \(blocked ? "btn-merge-blocked" : "")" id="btnShowMerge" onclick="toggleMergePanel()" \(pr.hasConflicts || pr.isDraft ? "disabled" : "") title="\(blocked ? "Merging is blocked until requirements are met" : "Merge this pull request")">\(firstLabel)</button>
                <select class="merge-method-select" id="mergeMethodSelect" data-persist onchange="onMergeMethodChange()" data-squash-title="\(squashTitle)" data-merge-title="\(mergeTitle)">\(options)</select>
                \(blocked ? "<span class=\"merge-blocked-badge\">Merging is blocked</span>" : "")
                <button type="button" class="btn btn-secondary btn-close-pr" data-busy="Closing…" onclick="confirmClosePR(this)">Close pull request</button>
              </div>
              <div class="merge-confirm-panel" id="mergeConfirmPanel" data-visibility style="display: none;">
                <div class="merge-inputs">
                  <input type="text" id="mergeCommitTitle" data-persist class="input-text" value="\(allowed.first == "merge" ? mergeTitle : squashTitle)" placeholder="Commit title">
                  <textarea id="mergeCommitMessage" data-persist class="input-textarea" placeholder="Add an optional extended description…" rows="3"></textarea>
                </div>
                <div class="merge-options">\(deleteOption)</div>
                \(blocked ? "<div class=\"merge-warning\">⚠ Requirements are not met — GitHub may reject this merge unless you can bypass branch protections.</div>" : "")
                <div class="merge-confirm-actions">
                  <button type="button" class="btn btn-merge" id="btnConfirmMerge" data-busy="Merging…" onclick="triggerConfirmMerge(this)">Confirm \(firstLabel.lowercased())</button>
                  <button type="button" class="btn btn-secondary" onclick="toggleMergePanel()">Cancel</button>
                </div>
              </div>
            </div>
            """
        } else if isClosed {
            actionSectionHTML = """
            <div class="merge-action-bar">
              <button type="button" class="btn btn-secondary" data-busy="Reopening…" onclick="sendAction({action:'reopenPR'}, 'reopenPR', this)">Reopen pull request</button>
            </div>
            """
        }

        let badgeIcon: String
        let badgeClass: String
        if isMerged { badgeIcon = HTMLIcon.merge; badgeClass = "badge-merged" }
        else if isClosed || readiness.status == .blocked { badgeIcon = HTMLIcon.x; badgeClass = "badge-closed" }
        else if readiness.status == .pending { badgeIcon = HTMLIcon.clock; badgeClass = "badge-pending" }
        else { badgeIcon = HTMLIcon.check; badgeClass = "badge-open" }

        let checksCollapsed = failingTotal == 0 && pendingTotal == 0

        return """
        <div class="timeline-item merge-timeline-item" id="pr-checks-merge-box" data-nav="merge" data-nav-label="Checks &amp; merge">
          <div class="avatar-col">
            <div class="event-icon-circle merge-badge-circle \(badgeClass)">\(badgeIcon)</div>
          </div>
          <div class="card merge-card">
            <div class="checks-header-row">
              <div class="checks-header-left">
                <span class="checks-badge-icon \(checkHeaderClass)">\(checkHeaderIcon)</span>
                <div>
                  <div class="checks-title">\(checkHeaderTitle)</div>
                  <div class="checks-subtext">\(checkHeaderSubtext)</div>
                </div>
              </div>
              <div class="checks-header-actions">\(checksHeaderActions)</div>
            </div>
            \(checksSummaryHTML)
            \(hasChecks ? "<div class=\"checks-list-container\" id=\"checksListContainer\" data-visibility style=\"\(checksCollapsed ? "display:none" : "")\">\(checksRowsHTML)</div>" : "")
            \(rulesHTML.isEmpty ? "" : """
            <div class="merge-divider"></div>
            <div class="merge-rules-section">
              <div class="merge-rules-title">Merge requirements</div>
              \(rulesHTML)
            </div>
            """)
            <div class="merge-divider"></div>
            <div class="branch-status-row">
              <span class="checks-badge-icon \(statusBoxClass)">\(statusBoxIcon)</span>
              <div>
                <div class="branch-title">\(statusBoxTitle)</div>
                <div class="branch-subtext">\(statusBoxSubtext)</div>
              </div>
            </div>
            \(pr.hasConflicts && isActive ? conflictHelpHTML(pr, headCheckedOut: headCheckedOut) : "")
            \(actionSectionHTML)
          </div>
        </div>
        """
    }

    private static func conflictHelpHTML(_ pr: PullRequest, headCheckedOut: Bool) -> String {
        let head = escapeHTML(pr.headBranch)
        let base = escapeHTML(pr.baseBranch)
        let desc = headCheckedOut
            ? "<code>\(head)</code> is checked out here: merge <code>\(base)</code> into it, resolve the conflicts in the merge tool, and GitXX pushes the result."
            : "Resolve them in GitHub's web editor, or check out <code>\(head)</code> to merge <code>\(base)</code> and resolve locally."
        let local = headCheckedOut
            ? "<button type=\"button\" class=\"btn btn-primary btn-sm\" data-busy=\"Merging \(base)…\" onclick=\"sendAction({action:'resolveConflictsLocally'}, 'resolveConflictsLocally', this)\">\(HTMLIcon.merge) Update &amp; resolve locally</button>"
            : ""
        return """
        <div class="conflict-callout-box">
          <div class="conflict-callout-header">
            <span class="conflict-icon">\(HTMLIcon.x)</span>
            <div>
              <div class="conflict-title">Resolve conflicts to merge</div>
              <div class="conflict-desc">\(desc)</div>
            </div>
          </div>
          <div class="conflict-actions">
            \(local)
            <a class="btn btn-secondary btn-sm" href="\(escapeAttr(pr.url))/conflicts">Resolve on GitHub \(HTMLIcon.linkExternal)</a>
          </div>
          <button type="button" class="btn-link conflict-cli-toggle" onclick="toggleConflictInstructions()">View command line instructions for resolving conflicts</button>
          <div class="conflict-cli-box" id="conflictCliInstructions" data-visibility style="display: none;">
            <div class="cli-step-title">Step 1: Check out the pull request branch and merge the base branch</div>
            <pre class="cli-pre"><code>git checkout \(escapeHTML(pr.headBranch))&#10;git pull origin \(escapeHTML(pr.baseBranch))</code></pre>
            <div class="cli-step-title">Step 2: Resolve conflicts, commit and push</div>
            <pre class="cli-pre"><code>git add .&#10;git commit -m &quot;Resolve merge conflicts&quot;&#10;git push origin \(escapeHTML(pr.headBranch))</code></pre>
          </div>
        </div>
        """
    }

    // MARK: - Bottom Comment Composer

    private static func renderCommentComposer(pr: PullRequest) -> String {
        let closeButton = pr.state.isActive
            ? "<button type=\"button\" class=\"btn btn-secondary btn-close-inline\" data-busy=\"Closing…\" onclick=\"confirmClosePR(this)\">Close pull request</button>"
            : (pr.state == .closed ? "<button type=\"button\" class=\"btn btn-secondary\" data-busy=\"Reopening…\" onclick=\"sendAction({action:'reopenPR'}, 'reopenPR', this)\">Reopen pull request</button>" : "")
        return """
        <div class="timeline-item composer-item" id="new-comment-composer" data-nav="composer" data-nav-label="Write a comment">
          <div class="avatar-col"><div class="event-icon-circle composer-icon">\(HTMLIcon.pencil)</div></div>
          <div class="card composer-card">
            <div class="composer-tabs">
              <button type="button" class="composer-tab active" id="tabWrite" onclick="setComposerMode('write')">Write</button>
              <button type="button" class="composer-tab" id="tabPreview" onclick="setComposerMode('preview')">Preview</button>
            </div>
            <div class="composer">
              <textarea class="input-textarea composer-input composer-main" id="comment-new" data-persist data-draft-key="comment-new" rows="5" placeholder="Leave a comment… (Markdown supported, ⌘↵ to comment)" onkeydown="composerKey(event, submitComment)"></textarea>
              <div class="markdown-body composer-preview" id="comment-preview" style="display:none"></div>
              <div class="composer-actions">
                <span class="composer-hint">⌘↵ to comment · C to focus</span>
                \(closeButton)
                <button type="button" class="btn btn-secondary" onclick="sendAction({action:'openReview'}, 'openReview')">Review changes</button>
                <button type="button" class="btn btn-primary" id="comment-new-send" data-busy="Posting…" onclick="submitComment()">Comment</button>
              </div>
            </div>
          </div>
        </div>
        """
    }

    // MARK: - Formatting Helpers

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Deterministic markup (absolute fallback); relative text is filled in and kept fresh by JS
    /// so the HTML string doesn't change every minute and trigger reloads.
    private static func formatDate(_ date: Date) -> String {
        let absolute = absoluteFormatter.string(from: date)
        return "<time class=\"rel-time\" data-ts=\"\(Int(date.timeIntervalSince1970))\" title=\"\(absolute)\">\(absolute)</time>"
    }

    private static func avatarImg(_ url: String, login: String, cls: String) -> String {
        let fallback = escapeAttr("https://github.com/identicons/\(login).png")
        return "<img class=\"\(cls)\" src=\"\(url)\" alt=\"\(escapeAttr(login))\" data-fallback=\"\(fallback)\" onerror=\"if(this.dataset.fallback){this.src=this.dataset.fallback;this.dataset.fallback='';}\">"
    }

    private static func labelPill(name: String, color: String) -> String {
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let valid = hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? hex : "8b949e"
        return "<span class=\"label-pill\" style=\"color:#\(valid); background: #\(valid)2e; border-color: #\(valid)73\">\(escapeHTML(name))</span>"
    }

    private static func safeId(_ raw: String) -> String {
        String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeAttr(_ string: String) -> String { escapeHTML(string) }

    /// Escapes a value for a single-quoted JS string inside a double-quoted HTML attribute.
    private static func escapeJS(_ string: String) -> String {
        escapeHTML(
            string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
        )
    }

    private static func markdownJSON(_ bag: MarkdownBag) -> String {
        var dict: [String: String] = [:]
        for entry in bag.entries { dict[entry.id] = entry.markdown }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              var json = String(data: data, encoding: .utf8) else { return "{}" }
        json = json
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return json
    }

    // MARK: - JavaScript Bridge

    /// Markdown → sanitized DOM, shared by the conversation and files pages (defines global `renderInto`).
    static let markdownRuntimeJS = #"""
  // ---- Markdown sanitizer: comment bodies are untrusted, and this page can trigger merges ----
  var ALLOWED_TAGS = {A:1,ABBR:1,B:1,BLOCKQUOTE:1,BR:1,CODE:1,DD:1,DEL:1,DETAILS:1,DIV:1,DL:1,DT:1,EM:1,
    H1:1,H2:1,H3:1,H4:1,H5:1,H6:1,HR:1,I:1,IMG:1,INPUT:1,INS:1,KBD:1,LI:1,OL:1,P:1,PICTURE:1,SOURCE:1,
    PRE:1,Q:1,S:1,SAMP:1,SMALL:1,SPAN:1,STRIKE:1,STRONG:1,SUB:1,SUMMARY:1,SUP:1,TABLE:1,TBODY:1,TD:1,
    TFOOT:1,TH:1,THEAD:1,TR:1,TT:1,U:1,UL:1,"G-EMOJI":1};
  var DROP_TAGS = {SCRIPT:1,STYLE:1,IFRAME:1,OBJECT:1,EMBED:1,FORM:1,LINK:1,META:1,BASE:1,TEXTAREA:1,
    SELECT:1,BUTTON:1,SVG:1,MATH:1,NOSCRIPT:1,TEMPLATE:1,FRAME:1,FRAMESET:1,AUDIO:1,VIDEO:1};
  var ALLOWED_ATTRS = {href:1,src:1,srcset:1,alt:1,title:1,width:1,height:1,align:1,colspan:1,rowspan:1,
    start:1,type:1,checked:1,disabled:1,open:1,media:1,lang:1,dir:1};
  function safeUrl(v) {
    var s = (v || "").replace(/[\s\u0000-\u001f]/g, "").toLowerCase();
    if (s.indexOf("javascript:") === 0 || s.indexOf("vbscript:") === 0) return false;
    if (s.indexOf("data:") === 0 && s.indexOf("data:image/") !== 0) return false;
    return true;
  }
  function sanitize(root) {
    var all = root.querySelectorAll("*");
    for (var i = all.length - 1; i >= 0; i--) {
      var el = all[i];
      var tag = el.tagName.toUpperCase();
      if (!ALLOWED_TAGS[tag]) {
        if (DROP_TAGS[tag]) { el.remove(); }
        else { el.replaceWith.apply(el, Array.prototype.slice.call(el.childNodes)); }
        continue;
      }
      if (tag === "INPUT" && (el.getAttribute("type") || "").toLowerCase() !== "checkbox") { el.remove(); continue; }
      for (var j = el.attributes.length - 1; j >= 0; j--) {
        var name = el.attributes[j].name.toLowerCase();
        if (!ALLOWED_ATTRS[name]) { el.removeAttribute(el.attributes[j].name); continue; }
        if ((name === "href" || name === "src" || name === "srcset") && !safeUrl(el.attributes[j].value)) {
          el.removeAttribute(el.attributes[j].name);
        }
      }
    }
  }
  function renderInto(target, markdown) {
    try {
      var tpl = document.createElement("template");
      tpl.innerHTML = marked.parse(markdown || "", { gfm: true, breaks: true });
      sanitize(tpl.content);
      target.textContent = "";
      target.appendChild(tpl.content);
    } catch (e) {
      target.textContent = markdown || "";
    }
  }
"""#

    private static let bridgeScript = #"""
(function () {
  var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gitxx;
  function post(p) { if (H) { H.postMessage(p); } }
  var pendingButtons = {};
  var pendingText = {};
  var focusIdx = -1;

  function renderMarkdown() {
    var md = window.__MD || {};
    Object.keys(md).forEach(function (id) {
      var target = document.getElementById(id);
      if (!target) return;
      renderInto(target, md[id]);
      var boxes = target.querySelectorAll('input[type="checkbox"]');
      boxes.forEach(function (cb, idx) {
        if (id === "body-desc") {
          cb.removeAttribute("disabled");
          cb.setAttribute("data-checklist-index", idx);
          cb.style.cursor = "pointer";
        } else {
          cb.setAttribute("disabled", "disabled");
        }
      });
    });
  }

  // ---- Relative timestamps (kept out of the HTML so it stays deterministic) ----
  function rel(ts) {
    var d = Date.now() / 1000 - ts;
    if (d < 45) return "just now";
    if (d < 3600) return Math.round(d / 60) + "m ago";
    if (d < 86400) return Math.round(d / 3600) + "h ago";
    if (d < 86400 * 30) return Math.round(d / 86400) + "d ago";
    if (d < 86400 * 365) return Math.round(d / (86400 * 30)) + "mo ago";
    return Math.round(d / (86400 * 365)) + "y ago";
  }
  function refreshTimes() {
    document.querySelectorAll("time.rel-time").forEach(function (t) {
      t.textContent = rel(parseInt(t.getAttribute("data-ts"), 10));
    });
  }

  // ---- Actions ----
  window.sendAction = function (payload, key, btn) {
    payload.key = key;
    if (btn) {
      if (btn.disabled) return;
      btn.dataset.label = btn.innerHTML;
      btn.disabled = true;
      if (btn.dataset.busy) btn.textContent = btn.dataset.busy;
      pendingButtons[key] = btn;
    }
    post(payload);
  };

  window.gitxxActionDone = function (key, ok) {
    if (key === "desc-edit" && !ok && pendingText[key] !== undefined) {
      var body = document.getElementById("body-desc");
      if (body) renderInto(body, (window.__MD || {})["body-desc"] || "");
      openDescEditor(pendingText[key]);
    }
    if (key === "desc-ai" && ok) {
      var ai = document.getElementById("descAIInput");
      if (ai) ai.value = "";
      var pop = document.getElementById("descAIPop");
      if (pop) pop.style.display = "none";
    }
    var btn = pendingButtons[key];
    delete pendingButtons[key];
    if (btn && btn.dataset.label !== undefined) {
      btn.disabled = false;
      btn.innerHTML = btn.dataset.label;
    }
    var ta = document.querySelector('[data-draft-key="' + key + '"]');
    if (ta) {
      delete ta.dataset.submitting;
      if (ok) {
        ta.value = "";
        if (key.indexOf("reply-") === 0) closeReply(key);
        if (key === "comment-new") setComposerMode("write");
      } else if (!ta.value && pendingText[key]) {
        ta.value = pendingText[key];
      }
    }
    delete pendingText[key];
  };

  window.composerKey = function (e, fn) {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); fn(); }
    if (e.key === "Escape" && e.target.id && e.target.id.indexOf("reply-") === 0) { closeReply(e.target.id); }
  };

  function submitDraft(key, payload, sendBtnId) {
    var ta = document.getElementById(key);
    if (!ta) return;
    var text = ta.value.trim();
    if (!text) { ta.focus(); return; }
    ta.dataset.submitting = "1";
    pendingText[key] = ta.value;
    payload.body = text;
    sendAction(payload, key, document.getElementById(sendBtnId));
  }

  window.submitReply = function (key, rootId) {
    submitDraft(key, { action: "replyThread", commentId: rootId }, key + "-send");
  };
  window.submitComment = function () {
    submitDraft("comment-new", { action: "postComment" }, "comment-new-send");
  };
  window.resolveThread = function (btn, nodeId, resolve) {
    sendAction({ action: "resolveThread", nodeId: nodeId, resolve: resolve }, "resolve-" + nodeId, btn);
  };
  window.openReply = function (key) {
    var row = document.getElementById(key + "-row");
    var box = document.getElementById(key + "-box");
    if (row) row.style.display = "none";
    if (box) box.style.display = "";
    var ta = document.getElementById(key);
    if (ta) ta.focus();
  };
  window.closeReply = function (key) {
    var row = document.getElementById(key + "-row");
    var box = document.getElementById(key + "-box");
    if (row) row.style.display = "";
    if (box) box.style.display = "none";
  };
  window.openFile = function (path) { post({ action: "openFile", path: path }); };

  window.confirmClosePR = function (btn) {
    if (btn.dataset.armed === "1") {
      delete btn.dataset.armed;
      sendAction({ action: "closePR" }, "closePR", btn);
      return;
    }
    btn.dataset.armed = "1";
    var original = btn.innerHTML;
    btn.textContent = "Click again to close";
    setTimeout(function () {
      if (btn.dataset.armed === "1") { delete btn.dataset.armed; btn.innerHTML = original; }
    }, 3000);
  };

  // ---- Merge panel ----
  var methodLabels = { merge: "Create a merge commit", squash: "Squash and merge", rebase: "Rebase and merge" };
  function syncMergeButtons() {
    var select = document.getElementById("mergeMethodSelect");
    if (!select) return;
    var label = methodLabels[select.value] || "Merge pull request";
    var show = document.getElementById("btnShowMerge");
    var confirmBtn = document.getElementById("btnConfirmMerge");
    if (show) show.textContent = label;
    if (confirmBtn && !confirmBtn.disabled) confirmBtn.textContent = "Confirm " + label.toLowerCase();
    var title = document.getElementById("mergeCommitTitle");
    if (title) title.style.display = select.value === "rebase" ? "none" : "";
    var msg = document.getElementById("mergeCommitMessage");
    if (msg) msg.style.display = select.value === "rebase" ? "none" : "";
  }
  window.onMergeMethodChange = function () {
    var select = document.getElementById("mergeMethodSelect");
    var title = document.getElementById("mergeCommitTitle");
    if (select && title) {
      title.value = select.value === "merge" ? select.dataset.mergeTitle : select.dataset.squashTitle;
    }
    syncMergeButtons();
  };
  window.toggleMergePanel = function () {
    var panel = document.getElementById("mergeConfirmPanel");
    if (!panel) return;
    var opening = panel.style.display === "none";
    panel.style.display = opening ? "" : "none";
    if (opening) {
      var title = document.getElementById("mergeCommitTitle");
      if (title) title.focus();
      panel.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
  };
  window.triggerConfirmMerge = function (btn) {
    var select = document.getElementById("mergeMethodSelect");
    var title = document.getElementById("mergeCommitTitle");
    var msg = document.getElementById("mergeCommitMessage");
    var del = document.getElementById("mergeDeleteBranch");
    var method = select ? select.value : "merge";
    sendAction({
      action: "mergePR",
      method: method,
      commitTitle: method === "rebase" ? "" : (title ? title.value : ""),
      commitMessage: method === "rebase" ? "" : (msg ? msg.value : ""),
      deleteBranch: !!(del && del.checked)
    }, "merge", btn);
  };

  // ---- Toggles ----
  function syncChecksToggle() {
    var el = document.getElementById("checksListContainer");
    var btn = document.getElementById("checksToggleBtn");
    if (el && btn) btn.textContent = el.style.display === "none" ? "Show all checks" : "Hide all checks";
  }
  window.filterChecks = function (group, chip) {
    var box = document.getElementById("checksListContainer");
    if (!box) return;
    var active = chip && !chip.classList.contains("active") ? group : null;
    document.querySelectorAll(".ck-chip").forEach(function (c) { c.classList.toggle("active", c === chip && !!active); });
    box.querySelectorAll("[data-group]").forEach(function (el) {
      el.style.display = !active || el.getAttribute("data-group") === active ? "" : "none";
    });
    box.querySelectorAll(".ck-report").forEach(function (el) { el.style.display = "none"; });
    if (box.style.display === "none") { box.style.display = ""; syncChecksToggle(); }
  };
  window.toggleCheckSummary = function (id) {
    var el = document.getElementById(id);
    if (el) el.style.display = el.style.display === "none" ? "" : "none";
  };
  window.toggleChecksList = function () {
    var el = document.getElementById("checksListContainer");
    if (!el) return;
    el.style.display = el.style.display === "none" ? "" : "none";
    syncChecksToggle();
  };
  window.toggleConflictInstructions = function () {
    var el = document.getElementById("conflictCliInstructions");
    if (el) el.style.display = el.style.display === "none" ? "" : "none";
  };
  function syncThreadChrome(item) {
    var body = document.getElementById(item.id + "-body");
    if (!body) return;
    var hidden = body.style.display === "none";
    var toggle = item.querySelector(".thread-toggle");
    if (toggle) toggle.textContent = hidden ? "▸" : "▾";
    var summary = item.querySelector(".thread-collapsed-summary");
    if (summary) summary.style.display = hidden ? "" : "none";
  }
  window.toggleThread = function (id) {
    var item = document.getElementById(id);
    var body = document.getElementById(id + "-body");
    if (!item || !body) return;
    body.style.display = body.style.display === "none" ? "" : "none";
    syncThreadChrome(item);
  };

  var unresolvedCursor = -1;
  window.jumpToUnresolved = function () {
    var items = Array.prototype.slice.call(document.querySelectorAll("[data-thread]")).filter(function (el) {
      return !!el.querySelector(".unresolved-pill");
    });
    if (!items.length) return;
    unresolvedCursor = (unresolvedCursor + 1) % items.length;
    highlight(items[unresolvedCursor]);
  };
  function highlight(el) {
    document.querySelectorAll(".kb-focus").forEach(function (x) { x.classList.remove("kb-focus"); });
    el.classList.add("kb-focus");
    el.scrollIntoView({ behavior: "smooth", block: "center" });
  }
  window.gitxxScrollToMerge = function () {
    var box = document.getElementById("pr-checks-merge-box");
    if (box) box.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  // ---- Composer ----
  window.setComposerMode = function (mode) {
    var ta = document.getElementById("comment-new");
    var preview = document.getElementById("comment-preview");
    var tw = document.getElementById("tabWrite");
    var tp = document.getElementById("tabPreview");
    if (!ta || !preview) return;
    if (mode === "preview") {
      renderInto(preview, ta.value.trim() ? ta.value : "_Nothing to preview_");
      preview.style.display = "";
      ta.style.display = "none";
    } else {
      preview.style.display = "none";
      ta.style.display = "";
    }
    if (tw) tw.classList.toggle("active", mode !== "preview");
    if (tp) tp.classList.toggle("active", mode === "preview");
  };
  function focusComposer() {
    setComposerMode("write");
    var ta = document.getElementById("comment-new");
    if (ta) { ta.scrollIntoView({ behavior: "smooth", block: "center" }); ta.focus(); }
  }
  window.quoteReply = function (bodyId, author) {
    var sel = window.getSelection ? String(window.getSelection()) : "";
    var target = document.getElementById(bodyId);
    var text = sel && target && target.contains(window.getSelection().anchorNode) ? sel : ((window.__MD || {})[bodyId] || "");
    var quoted = text.trim().split("\n").map(function (l) { return "> " + l; }).join("\n");
    var ta = document.getElementById("comment-new");
    if (!ta) return;
    ta.value = (ta.value ? ta.value + "\n\n" : "") + "@" + author + " wrote:\n" + quoted + "\n\n";
    focusComposer();
  };

  // ---- Description editing (manual + AI) ----
  function byId(id) { return document.getElementById(id); }
  window.setDescMode = function (mode) {
    var ta = byId("descEditInput"), pv = byId("descEditPreview");
    if (!ta || !pv) return;
    if (mode === "preview") {
      renderInto(pv, ta.value.trim() ? ta.value : "_Nothing to preview_");
      pv.style.display = ""; ta.style.display = "none";
    } else {
      pv.style.display = "none"; ta.style.display = "";
    }
    var tw = byId("descTabWrite"), tp = byId("descTabPreview");
    if (tw) tw.classList.toggle("active", mode !== "preview");
    if (tp) tp.classList.toggle("active", mode === "preview");
  };
  window.openDescEditor = function (text) {
    var ed = byId("descEditor"), body = byId("body-desc"), ta = byId("descEditInput");
    if (!ed || !body || !ta) return;
    toggleDescAI(false);
    ta.value = typeof text === "string" ? text : ((window.__MD || {})["raw-desc"] || "");
    body.style.display = "none";
    ed.style.display = "";
    setDescMode("write");
    ta.focus();
    ta.setSelectionRange(0, 0);
    ta.scrollTop = 0;
  };
  window.closeDescEditor = function () {
    var ed = byId("descEditor"), body = byId("body-desc");
    if (ed) ed.style.display = "none";
    if (body) body.style.display = "";
  };
  window.saveDescEditor = function () {
    var ta = byId("descEditInput"), body = byId("body-desc");
    if (!ta) return;
    var text = ta.value;
    if (body) renderInto(body, text.trim() ? text : "_No description provided._");
    closeDescEditor();
    pendingText["desc-edit"] = text;
    sendAction({ action: "updateDescription", body: text }, "desc-edit");
  };
  window.descEditKey = function (e) {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); saveDescEditor(); }
    else if (e.key === "Escape") { e.preventDefault(); closeDescEditor(); }
  };
  window.toggleDescAI = function (show) {
    var pop = byId("descAIPop");
    if (!pop) return;
    var visible = typeof show === "boolean" ? show : pop.style.display === "none";
    pop.style.display = visible ? "" : "none";
    if (visible) { var i = byId("descAIInput"); if (i) i.focus(); }
  };
  window.descAISubmit = function () {
    var i = byId("descAIInput");
    if (!i) return;
    var text = i.value.trim();
    if (!text) { i.focus(); return; }
    sendAction({ action: "aiEditDescription", instruction: text }, "desc-ai", byId("descAISubmit"));
  };
  window.descAIOpenChat = function () {
    var i = byId("descAIInput");
    post({ action: "openDescriptionInChat", instruction: i ? i.value.trim() : "" });
    if (i) i.value = "";
    toggleDescAI(false);
  };
  window.descAIKey = function (e) {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); descAISubmit(); }
    else if (e.key === "Escape") { e.preventDefault(); toggleDescAI(false); }
  };
  document.addEventListener("mousedown", function (e) {
    var pop = byId("descAIPop");
    if (!pop || pop.style.display === "none") return;
    if (pop.contains(e.target) || (e.target.closest && e.target.closest(".desc-btn-ai"))) return;
    if (byId("descAISubmit") && byId("descAISubmit").disabled) return;
    toggleDescAI(false);
  });

  // ---- Checklist toggles in the PR description ----
  document.addEventListener("change", function (e) {
    var t = e.target;
    if (t && t.type === "checkbox" && t.hasAttribute("data-checklist-index")) {
      post({ action: "toggleChecklist", index: parseInt(t.getAttribute("data-checklist-index"), 10) });
    }
  });

  // ---- Keyboard navigation ----
  document.addEventListener("keydown", function (e) {
    var t = e.target;
    if (t && (t.tagName === "TEXTAREA" || t.tagName === "INPUT" || t.tagName === "SELECT" || t.isContentEditable)) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (navKeyboardHandle(e)) return;
    var items = Array.prototype.slice.call(document.querySelectorAll(".timeline-item:not(.timeline-event)"));
    if (e.key === "j" || e.key === "k") {
      e.preventDefault();
      if (!items.length) return;
      focusIdx = Math.max(0, Math.min(items.length - 1, focusIdx + (e.key === "j" ? 1 : -1)));
      highlight(items[focusIdx]);
    } else if (e.key === "f" || e.key === "s") {
      e.preventDefault();
      post({ action: "switchTab", tab: e.key === "f" ? "files" : "checks" });
    } else if (e.key === "c") {
      e.preventDefault();
    } else if (e.key === "g") {
      e.preventDefault();
      window.gitxxOpenNav();
    } else if (e.key === "n") {
      e.preventDefault();
      focusComposer();
    } else if (e.key === "r" && focusIdx >= 0 && items[focusIdx]) {
      var btn = items[focusIdx].querySelector(".reply-placeholder");
      if (btn) { e.preventDefault(); btn.click(); }
    } else if (e.key === "m") {
      e.preventDefault();
      gitxxScrollToMerge();
    } else if (e.key === "u") {
      e.preventDefault();
      jumpToUnresolved();
    }
  });

  // ---- State snapshot / restore across reloads (drafts, toggles, scroll) ----
  window.__gitxxSnapshot = function () {
    var s = {
      y: window.scrollY,
      atBottom: (window.innerHeight + window.scrollY) >= document.body.scrollHeight - 40,
      values: {}, vis: {}, submitting: {}, focusIdx: focusIdx,
      active: document.activeElement && document.activeElement.id ? document.activeElement.id : null
    };
    document.querySelectorAll("[data-persist]").forEach(function (el) {
      if (!el.id) return;
      if (el.dataset.submitting) { s.submitting[el.id] = pendingText[el.id] || el.value; return; }
      s.values[el.id] = el.type === "checkbox" ? (el.checked ? "1" : "") : el.value;
    });
    document.querySelectorAll("[data-visibility]").forEach(function (el) {
      if (el.id) s.vis[el.id] = el.style.display;
    });
    return JSON.stringify(s);
  };
  window.__gitxxRestore = function (json) {
    var s;
    try { s = JSON.parse(json); } catch (e) { return; }
    Object.keys(s.values || {}).forEach(function (id) {
      var el = document.getElementById(id);
      if (!el) return;
      if (el.type === "checkbox") { el.checked = s.values[id] === "1"; } else { el.value = s.values[id]; }
    });
    Object.keys(s.vis || {}).forEach(function (id) {
      var el = document.getElementById(id);
      if (el) el.style.display = s.vis[id];
    });
    Object.keys(s.submitting || {}).forEach(function (id) { pendingText[id] = s.submitting[id]; });
    document.querySelectorAll("[data-thread]").forEach(syncThreadChrome);
    syncChecksToggle();
    syncMergeButtons();
    focusIdx = typeof s.focusIdx === "number" ? s.focusIdx : -1;
    if (s.active) {
      var a = document.getElementById(s.active);
      if (a && a.focus) a.focus({ preventScroll: true });
    }
    if (s.atBottom) { window.scrollTo(0, document.body.scrollHeight); } else { window.scrollTo(0, s.y); }
    scheduleNavRail();
  };

  // ---- Scroll navigation rail ----
  // Thin minimap of markers; hovering it briefly expands a labelled outline for easy clicking.
  var navEntries = [];
  function navLabelFor(el) {
    var label = el.dataset.navLabel;
    if (!label) {
      var t = el.querySelector(".status-event-text");
      label = t ? t.innerText : "Event";
    }
    var body = el.querySelector(".markdown-body");
    var snippet = body ? (body.innerText || "").replace(/\s+/g, " ").trim() : "";
    return { label: label.trim(), snippet: snippet.length > 90 ? snippet.slice(0, 90) + "…" : snippet };
  }
  function buildNavRail() {
    var rail = document.getElementById("navRail");
    if (!rail) {
      rail = document.createElement("nav");
      rail.id = "navRail";
      document.body.appendChild(rail);
      var enterTimer = null, leaveTimer = null;
      rail.addEventListener("mouseenter", function () {
        clearTimeout(leaveTimer);
        enterTimer = setTimeout(function () { expandNav(true); }, 350);
      });
      rail.addEventListener("mouseleave", function () {
        clearTimeout(enterTimer);
        if (navPinned) return;
        leaveTimer = setTimeout(function () { expandNav(false); }, 300);
      });
    }
    var wasExpanded = rail.classList.contains("expanded");
    rail.innerHTML =
      '<div class="nav-strip">' +
        '<button type="button" class="nav-cap" title="Top" onclick="window.scrollTo({top:0,behavior:\'smooth\'})">▲</button>' +
        '<div class="nav-track" id="navTrack"><div class="nav-viewport" id="navViewport"></div></div>' +
        '<button type="button" class="nav-cap" title="Bottom" onclick="window.scrollTo({top:document.body.scrollHeight,behavior:\'smooth\'})">▼</button>' +
      '</div>' +
      '<div class="nav-panel" id="navPanel"></div>';
    var track = document.getElementById("navTrack");
    var total = Math.max(document.documentElement.scrollHeight, 1);
    track.onclick = function (e) {
      if (e.target !== track && e.target.id !== "navViewport") return;
      var r = track.getBoundingClientRect();
      window.scrollTo({ top: (e.clientY - r.top) / r.height * total - window.innerHeight / 2, behavior: "smooth" });
    };
    navEntries = [];
    var panel = document.getElementById("navPanel");
    var panelHTML = '<div class="nav-panel-title"><span>Jump to</span><span class="nav-panel-keys">↑↓ move · ↩ jump · esc close</span></div>';
    document.querySelectorAll("[data-nav]").forEach(function (el, i) {
      if (el.offsetParent === null) return;
      var kind = el.dataset.nav;
      var info = navLabelFor(el);
      navEntries.push({ el: el, kind: kind });
      var m = document.createElement("div");
      m.className = "nav-mark nav-" + kind;
      m.style.top = (el.getBoundingClientRect().top + window.scrollY) / total * 100 + "%";
      m.setAttribute("data-tip", info.label);
      m.onclick = function (e) { e.stopPropagation(); highlight(el); };
      track.appendChild(m);
      panelHTML += '<button type="button" class="nav-row" data-idx="' + (navEntries.length - 1) + '">' +
        '<span class="nav-dot nav-' + kind + '"></span>' +
        '<span class="nav-row-text"><span class="nav-row-label"></span><span class="nav-row-snippet"></span></span></button>';
    });
    panel.innerHTML = panelHTML;
    panel.querySelectorAll(".nav-row").forEach(function (row) {
      var entry = navEntries[+row.dataset.idx];
      var info = navLabelFor(entry.el);
      row.querySelector(".nav-row-label").textContent = info.label;
      row.querySelector(".nav-row-snippet").textContent = info.snippet;
      row.title = info.label;
      row.onclick = function () { highlight(entry.el); if (navPinned) closeNav(); };
    });
    if (wasExpanded) rail.classList.add("expanded");
    if (navKb >= 0) setNavKb(Math.min(navKb, navEntries.length - 1));
    updateNavViewport();
  }
  var navKb = -1, navPinned = false;
  function navRows() { return document.querySelectorAll("#navPanel .nav-row"); }
  function setNavKb(i) {
    var rows = navRows();
    if (!rows.length) { navKb = -1; return; }
    navKb = Math.max(0, Math.min(rows.length - 1, i));
    rows.forEach(function (r, j) { r.classList.toggle("kb-active", j === navKb); });
    rows[navKb].scrollIntoView({ block: "nearest" });
  }
  function closeNav() {
    navPinned = false;
    navKb = -1;
    navRows().forEach(function (r) { r.classList.remove("kb-active"); });
    expandNav(false);
  }
  window.gitxxOpenNav = function () {
    if (!document.getElementById("navRail")) buildNavRail();
    var rail = document.getElementById("navRail");
    if (rail && rail.classList.contains("expanded") && navPinned) { closeNav(); return; }
    navPinned = true;
    expandNav(true);
    var rows = navRows(), start = 0;
    for (var i = 0; i < rows.length; i++) { if (rows[i].classList.contains("in-view")) { start = i; break; } }
    setNavKb(start);
  };
  function navKeyboardHandle(e) {
    var rail = document.getElementById("navRail");
    if (!rail || !rail.classList.contains("expanded")) return false;
    var k = e.key;
    if (k === "ArrowDown" || k === "ArrowUp" || (navPinned && (k === "j" || k === "k"))) {
      e.preventDefault();
      setNavKb(navKb < 0 ? 0 : navKb + ((k === "ArrowDown" || k === "j") ? 1 : -1));
      return true;
    }
    if (k === "Enter" && navKb >= 0) {
      e.preventDefault();
      var entry = navEntries[navKb];
      closeNav();
      if (entry) highlight(entry.el);
      return true;
    }
    if (k === "Escape" || (navPinned && k === "g")) {
      e.preventDefault();
      closeNav();
      return true;
    }
    return false;
  }
  function expandNav(on) {
    var rail = document.getElementById("navRail");
    if (!rail) return;
    rail.classList.toggle("expanded", on);
    if (on) updateNavViewport();
  }
  function updateNavViewport() {
    var v = document.getElementById("navViewport");
    if (!v) return;
    var total = Math.max(document.documentElement.scrollHeight, 1);
    v.style.top = window.scrollY / total * 100 + "%";
    v.style.height = Math.max(window.innerHeight / total * 100, 2) + "%";
    var rail = document.getElementById("navRail");
    if (!rail || !rail.classList.contains("expanded")) return;
    var rows = document.querySelectorAll("#navPanel .nav-row");
    var firstVisible = null;
    navEntries.forEach(function (entry, i) {
      var r = entry.el.getBoundingClientRect();
      var visible = r.bottom > 0 && r.top < window.innerHeight;
      if (rows[i]) rows[i].classList.toggle("in-view", visible);
      if (visible && firstVisible === null) firstVisible = rows[i];
    });
  }
  var navTimer = null;
  function scheduleNavRail() { clearTimeout(navTimer); navTimer = setTimeout(buildNavRail, 120); }
  window.addEventListener("scroll", updateNavViewport, { passive: true });
  window.addEventListener("resize", scheduleNavRail);
  document.addEventListener("click", function (e) {
    if (e.target.closest && !e.target.closest("#navRail")) {
      if (navPinned) closeNav();
      scheduleNavRail();
    }
  });

  // ---- Hide-on-scroll chrome + back-to-top ----
  // The native bars float over the page's top padding (--gitxx-top-inset). Like mobile browsers, a deliberate
  // scroll down slides them away and any scroll up brings them back; near the top they always show.
  var chromeHidden = false, chromePosted = null, lastY = window.scrollY, travel = 0;
  function chromeInset() {
    return parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--gitxx-top-inset")) || 0;
  }
  function setChromeHidden(value, force) {
    chromeHidden = value;
    document.documentElement.style.setProperty("--gitxx-chrome-visible", (value ? 0 : chromeInset()) + "px");
    if (force || value !== chromePosted) {
      chromePosted = value;
      post({ action: "chromeHidden", hidden: value });
    }
  }
  function syncChrome(force) {
    var inset = chromeInset(), y = window.scrollY, dy = y - lastY;
    lastY = y;
    if (inset <= 0 || y <= 8) { travel = 0; setChromeHidden(false, force); return; }
    // Rubber-band overscroll past the bottom bounces back upward; that isn't a scroll up.
    if (y + window.innerHeight >= document.documentElement.scrollHeight - 1 && dy < 0) { setChromeHidden(chromeHidden, force); return; }
    travel = (dy > 0) === (travel > 0) ? travel + dy : dy;
    if (travel > 12 && y > inset * 0.6) setChromeHidden(true, force);
    else if (travel < -12) setChromeHidden(false, force);
    else setChromeHidden(chromeHidden, force);
  }
  function onChromeScroll() {
    syncChrome(false);
    var top = document.getElementById("backToTop");
    if (top) top.classList.toggle("visible", window.scrollY > 600);
  }
  window.gitxxInsetChanged = function () { setChromeHidden(chromeHidden, false); };
  window.gitxxSyncChrome = function () { lastY = window.scrollY; syncChrome(true); };

  // The native "Show toolbar" button calls this while the bars are hidden.
  window.gitxxShowChrome = function () { travel = 0; setChromeHidden(false, true); };
  (function () {
    var b = document.createElement("button");
    b.type = "button";
    b.id = "backToTop";
    b.title = "Back to top";
    b.innerHTML = '<span class="btt-arrow">\#(HTMLIcon.arrowUp)</span><span>Top</span>';
    b.onclick = function () { window.scrollTo({ top: 0, behavior: "smooth" }); };
    document.body.appendChild(b);
  })();
  window.addEventListener("scroll", onChromeScroll, { passive: true });
  document.querySelectorAll("img").forEach(function (img) { if (!img.complete) img.addEventListener("load", scheduleNavRail); });
  window.gitxxRebuildNav = scheduleNavRail;

  renderMarkdown();
  refreshTimes();
  syncChecksToggle();
  syncMergeButtons();
  buildNavRail();
  setInterval(refreshTimes, 30000);
})();
"""#

    // MARK: - Larger Controls & New Components CSS

    private static let extraCSS = #"""
body { padding-right: 44px; background: transparent !important; }
html { background: transparent; }
html::-webkit-scrollbar, body::-webkit-scrollbar { display: none; width: 0; height: 0; }
html { padding-top: var(--gitxx-top-inset, 0px); scroll-padding-top: calc(var(--gitxx-chrome-visible, 0px) + 16px); }
.check-group-header {
  padding: 8px 16px 6px; font-size: 11.5px; font-weight: 600; color: #8b949e;
  background: rgba(110,118,129,0.06); border-top: 1px solid #21262d;
}
.check-group-header:first-child { border-top: none; }
.check-group-count { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #6e7681; margin-left: 4px; }
.check-group-failing .check-group-req { color: #f85149; }
.check-group-req { font-weight: 500; }
.check-grid-row {
  display: grid;
  grid-template-columns: 18px 84px 76px minmax(0, 1fr) 64px 66px 60px;
  align-items: center; column-gap: 10px;
  padding: 7px 16px; font-size: 12.5px; border-top: 1px solid #21262d;
}
.check-grid-row .check-row-icon { text-align: center; }
.check-col-status { font-size: 12px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.check-col-status.check-success { color: #3fb950; }
.check-col-status.check-failure { color: #f85149; }
.check-col-status.check-pending { color: #d29922; }
.check-col-status.check-neutral, .check-row-icon.check-neutral { color: #8b949e; }
.check-col-req .check-req-badge { display: inline-block; width: 70px; text-align: center; box-sizing: border-box; margin: 0; }
.check-col-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #e6edf3; }
.check-col-duration { text-align: right; color: #8b949e; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; }
.check-col-rerun, .check-col-details { text-align: right; }
.ck-summary { padding: 0 16px 12px; display: flex; flex-direction: column; gap: 8px; }
.ck-bar { display: flex; height: 6px; border-radius: 3px; overflow: hidden; gap: 2px; background: rgba(110,118,129,0.12); }
.ck-bar-seg { min-width: 4px; }
.ck-bar-failing { background: #f85149; } .ck-bar-running { background: #d29922; }
.ck-bar-passing { background: #3fb950; } .ck-bar-skipped { background: #6e7681; }
.ck-chips { display: flex; flex-wrap: wrap; gap: 6px; }
.ck-chip {
  display: inline-flex; align-items: center; gap: 5px; height: 24px; padding: 0 10px; border-radius: 12px;
  font-size: 11.5px; color: #c9d1d9; background: rgba(110,118,129,0.12); border: 1px solid transparent; cursor: pointer;
}
.ck-chip b { font-weight: 700; }
.ck-chip:hover { background: rgba(110,118,129,0.22); }
.ck-chip.active { border-color: currentColor; }
.ck-chip-failing { color: #ff7b72; } .ck-chip-running { color: #e3b341; } .ck-chip-passing { color: #56d364; } .ck-chip-skipped { color: #8b949e; }
.ck-row {
  display: grid; grid-template-columns: 22px minmax(0, 1fr) auto; align-items: center; column-gap: 10px;
  padding: 8px 12px 8px 16px; border-top: 1px solid #21262d; transition: background 0.1s;
}
.ck-row.ck-clickable { cursor: pointer; }
.ck-row.ck-clickable:hover { background: rgba(110,118,129,0.10); }
.ck-icon {
  width: 20px; height: 20px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-size: 12px;
}
.ck-icon.check-pending .octicon { animation: ck-pulse 1.4s ease-in-out infinite; }
@keyframes ck-pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }
.ck-main { min-width: 0; }
.ck-name-line { display: flex; align-items: center; gap: 8px; min-width: 0; }
.ck-name { font-size: 13px; font-weight: 600; color: #e6edf3; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ck-name-line .check-req-badge { flex-shrink: 0; margin: 0; }
.ck-sub { font-size: 11.5px; color: #8b949e; margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ck-row[data-group="failing"] .ck-sub { color: #ff9b94; }
.ck-actions { display: flex; align-items: center; gap: 4px; }
.ck-btn {
  display: inline-flex; align-items: center; gap: 5px; height: 26px; padding: 0 9px; border-radius: 6px;
  font-size: 12px; font-weight: 500; color: #c9d1d9; background: transparent; border: 1px solid rgba(240,246,252,0.10);
  cursor: pointer; text-decoration: none; white-space: nowrap;
}
.ck-btn:hover { background: rgba(110,118,129,0.18); text-decoration: none; color: #e6edf3; }
.ck-btn-primary { border-color: rgba(88,166,255,0.35); color: #79c0ff; }
.ck-btn-primary:hover { background: rgba(56,139,253,0.15); color: #a5d6ff; }
.ck-btn-ai { color: #d2a8ff; border-color: rgba(210,168,255,0.3); }
.ck-btn-ai:hover { background: rgba(163,113,247,0.15); color: #e2c5ff; }
.ck-btn-icon { width: 26px; padding: 0; justify-content: center; border-color: transparent; color: #8b949e; }
.ck-btn[disabled] { opacity: 0.6; cursor: default; }
.ck-report {
  margin: 0 16px 10px 48px; padding: 10px 12px; font-size: 12px; line-height: 1.5; color: #c9d1d9; white-space: pre-wrap;
  background: rgba(110,118,129,0.08); border: 1px solid #21262d; border-radius: 6px; max-height: 240px; overflow: auto;
}

#navRail {
  position: fixed; top: calc(var(--gitxx-chrome-visible, var(--gitxx-top-inset, 0px)) + 10px); bottom: 10px; right: 8px; width: 18px; z-index: 50;
  transition: top 0.18s ease-out;
}
.nav-strip {
  position: absolute; top: 0; bottom: 0; right: 0; width: 18px;
  display: flex; flex-direction: column; align-items: center; gap: 4px;
}
.nav-cap {
  width: 18px; height: 18px; padding: 0; border: none; border-radius: 4px; cursor: pointer;
  background: transparent; color: #6e7681; font-size: 9px; line-height: 18px;
}
.nav-cap:hover { background: rgba(110,118,129,0.25); color: #e6edf3; }
.nav-track {
  position: relative; flex: 1; width: 12px; border-radius: 6px; cursor: pointer;
  background: rgba(110,118,129,0.10); transition: width 0.12s ease;
}
#navRail:hover .nav-track { width: 16px; background: rgba(110,118,129,0.18); }
.nav-viewport {
  position: absolute; left: 0; right: 0; border-radius: 6px; pointer-events: none;
  background: rgba(230,237,243,0.10); border: 1px solid rgba(230,237,243,0.18);
}
.nav-mark {
  position: absolute; left: 1px; right: 1px; height: 4px; border-radius: 2px; cursor: pointer;
  background: #6e7681; transform: translateY(-1px);
}
.nav-mark:hover { left: -3px; right: -3px; height: 6px; z-index: 2; }
#navRail:not(.expanded) .nav-mark:hover::after {
  content: attr(data-tip); position: absolute; right: 22px; top: 50%; transform: translateY(-50%);
  white-space: nowrap; padding: 4px 8px; border-radius: 6px; font-size: 11.5px; font-weight: 500;
  background: #2d333b; color: #e6edf3; border: 1px solid #444c56; box-shadow: 0 4px 12px rgba(0,0,0,0.4);
  pointer-events: none;
}
.nav-panel {
  position: absolute; top: 0; bottom: 0; right: 24px; width: 320px;
  overflow-y: auto; padding: 6px; box-sizing: border-box;
  background: rgba(22,27,34,0.97); border: 1px solid #30363d; border-radius: 10px;
  box-shadow: 0 12px 32px rgba(0,0,0,0.5);
  opacity: 0; transform: translateX(8px); pointer-events: none;
  transition: opacity 0.14s ease, transform 0.14s ease;
}
#navRail.expanded .nav-panel { opacity: 1; transform: none; pointer-events: auto; }
.nav-panel-title { display: flex; justify-content: space-between; align-items: baseline; font-size: 11px; font-weight: 600; color: #8b949e; padding: 6px 8px 8px; text-transform: uppercase; letter-spacing: 0.04em; }
.nav-panel-keys { text-transform: none; letter-spacing: 0; font-weight: 500; color: #6e7681; font-size: 10.5px; }
.nav-row.kb-active, .nav-row.kb-active:hover { background: rgba(56,139,253,0.18); box-shadow: inset 0 0 0 1px rgba(56,139,253,0.55); }
#backToTop {
  position: fixed; left: clamp(32px, 16%, 180px); bottom: 22px; z-index: 60;
  display: inline-flex; align-items: center; gap: 6px; height: 34px; padding: 0 14px;
  border-radius: 17px; border: 1px solid #3d444d; background: rgba(33,38,45,0.94); color: #e6edf3;
  font: 600 12.5px -apple-system, BlinkMacSystemFont, sans-serif; cursor: pointer;
  box-shadow: 0 6px 18px rgba(0,0,0,0.45);
  opacity: 0; transform: translateY(10px); pointer-events: none;
  transition: opacity 0.16s ease, transform 0.16s ease, background 0.12s ease;
}
#backToTop.visible { opacity: 1; transform: none; pointer-events: auto; }
#backToTop:hover { background: #30363d; border-color: #6e7681; }
.btt-arrow { font-size: 14px; line-height: 1; }
.nav-row {
  display: flex; align-items: flex-start; gap: 9px; width: 100%; min-height: 34px;
  padding: 7px 8px; border: none; border-radius: 6px; background: transparent;
  color: #c9d1d9; text-align: left; cursor: pointer; font: inherit;
}
.nav-row:hover { background: rgba(110,118,129,0.22); }
.nav-row.in-view { background: rgba(110,118,129,0.12); }
.nav-row.in-view:hover { background: rgba(110,118,129,0.26); }
.nav-dot { flex: none; width: 8px; height: 8px; border-radius: 50%; margin-top: 5px; background: #6e7681; }
.nav-row-text { display: flex; flex-direction: column; min-width: 0; }
.nav-row-label { font-size: 12.5px; font-weight: 600; color: #e6edf3; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.nav-row-snippet { font-size: 11.5px; color: #8b949e; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.nav-row-snippet:empty { display: none; }
.nav-commit { background: #484f58; }
.nav-event { background: #3d444d; }
.nav-composer { background: #8b949e; }
.nav-desc { background: #8b949e; }
.nav-mark.nav-desc, .nav-mark.nav-merge { height: 6px; }
.nav-comment { background: #768390; }
.nav-approved { background: #3fb950; }
.nav-changes { background: #f85149; }
.nav-open { background: #d29922; }
.nav-resolved { background: #2ea04366; }
.nav-merge { background: #e6edf3; }
.btn {
  min-height: 32px;
  padding: 6px 16px;
  font-size: 13px;
  border-radius: 7px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  white-space: nowrap;
}
.btn:disabled { cursor: default; opacity: 0.6; }
.btn-sm { min-height: 28px; padding: 4px 12px; font-size: 12.5px; }
.btn-xs { min-height: 24px; padding: 2px 10px; font-size: 12px; border-radius: 6px; }
.btn-primary:disabled:hover { background-color: #238636; }
.btn-merge {
  background-color: #238636;
  color: #fff;
  border: 1px solid rgba(240, 246, 252, 0.1);
  min-height: 34px;
  padding: 6px 18px;
  font-size: 13.5px;
}
.btn-merge:hover { background-color: #2ea043; }
.btn-merge-blocked { background-color: #21262d; color: #c9d1d9; border-color: var(--color-border-default); }
.btn-merge-blocked:hover { background-color: #30363d; }
.btn-merge:disabled { background-color: #21262d; color: #6e7681; }
.merge-method-select { min-height: 34px; padding: 6px 10px; font-size: 13px; border-radius: 7px; }
.btn-link { font-size: 12.5px; padding: 4px 6px; border-radius: 6px; }
.btn-link:hover { background: rgba(88, 166, 255, 0.1); text-decoration: none; }
.icon-btn {
  background: none; border: 1px solid transparent; color: var(--color-fg-muted);
  width: 26px; height: 26px; border-radius: 6px; cursor: pointer; font-size: 14px; margin-left: 4px;
}
.icon-btn:hover { background: rgba(110, 118, 129, 0.2); color: var(--color-fg-default); }
.card-header-right { display: flex; align-items: center; gap: 6px; }
.desc-header-right { position: relative; }
\#(HTMLIcon.css)
.desc-actions {
  display: inline-flex; align-items: stretch; height: 26px; border-radius: 7px; overflow: hidden;
  border: 1px solid var(--color-border-default); background: rgba(110, 118, 129, 0.08);
}
.desc-actions-sep { width: 1px; background: var(--color-border-default); }
.desc-btn {
  display: inline-flex; align-items: center; gap: 6px; background: transparent; border: 0; color: var(--color-fg-default);
  font-size: 12px; font-weight: 600; font-family: inherit; padding: 0 10px; cursor: pointer;
  transition: background-color 0.12s ease, color 0.12s ease;
}
.desc-btn .octicon { font-size: 13px; color: var(--color-fg-muted); transition: color 0.12s ease; }
.desc-btn:hover { background: rgba(110, 118, 129, 0.2); }
.desc-btn:hover .octicon { color: var(--color-fg-default); }
.desc-btn:active { background: rgba(110, 118, 129, 0.3); }
.desc-btn-ai .octicon { color: #bc8cff; }
.desc-btn-ai:hover { background: rgba(163, 113, 247, 0.16); color: #e2c5ff; }
.desc-btn-ai:hover .octicon { color: #d2a8ff; }
.desc-ai-title { display: flex; align-items: center; gap: 6px; }
.desc-ai-title .octicon { color: #bc8cff; }
.desc-ai-pop {
  position: absolute; top: calc(100% + 8px); right: 0; z-index: 60; width: min(460px, 80vw);
  padding: 12px; display: flex; flex-direction: column; gap: 10px;
  background: rgba(22, 27, 34, 0.96); border: 1px solid rgba(163, 113, 247, 0.45); border-radius: 10px;
  box-shadow: 0 12px 32px rgba(1, 4, 9, 0.6);
  -webkit-backdrop-filter: blur(14px); backdrop-filter: blur(14px);
}
.desc-ai-title { font-size: 12.5px; font-weight: 600; color: var(--color-fg-default); }
.desc-ai-input { min-height: 76px; background: var(--color-canvas-default); }
.desc-ai-actions { display: flex; align-items: center; gap: 8px; }
.desc-ai-actions .composer-hint { margin-left: auto; margin-right: 4px; }
.desc-editor { background: var(--color-canvas-subtle); }
.desc-editor .composer { padding: 12px 14px; }
.desc-edit-input { min-height: 260px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px; }
.desc-editor .composer-preview { min-height: 260px; }

.input-text, .input-textarea { font-size: 13px; padding: 8px 12px; line-height: 1.5; }
.input-text { min-height: 34px; }
.input-textarea { resize: vertical; min-height: 72px; }

/* Keyboard focus */
.kb-focus > .card, .kb-focus > .event-content { box-shadow: 0 0 0 2px rgba(56, 139, 253, 0.6); border-radius: 6px; }

/* Reviews */
.review-approved { border-color: rgba(35, 134, 54, 0.6); }
.review-changes { border-color: rgba(218, 54, 51, 0.6); }
.badge-author { color: #58a6ff; border-color: rgba(56, 139, 253, 0.4); }

/* Threads */
.thread-toggle {
  background: none; border: none; color: var(--color-fg-muted); cursor: pointer;
  width: 22px; height: 22px; font-size: 12px; border-radius: 5px;
}
.thread-toggle:hover { background: rgba(110, 118, 129, 0.2); }
.thread-file-path { color: var(--color-accent-fg); text-decoration: none; font-size: 12px; }
.thread-file-path:hover { text-decoration: underline; }
.thread-resolved { opacity: 0.92; }
.thread-collapsed-summary {
  padding: 8px 14px; font-size: 12px; color: var(--color-fg-muted); cursor: pointer;
}
.thread-collapsed-summary:hover { color: var(--color-accent-fg); }
.outdated-pill {
  font-size: 10.5px; background: rgba(210, 153, 34, 0.12); color: #d29922;
  padding: 2px 8px; border-radius: 12px; border: 1px solid rgba(210, 153, 34, 0.3);
}
.diff-hunk-pre div { white-space: pre; padding: 0 4px; }
.dl-add { color: #aff5b4; background: rgba(46, 160, 67, 0.15); }
.dl-del { color: #ffdcd7; background: rgba(248, 81, 73, 0.15); }
.dl-hunk { color: #79c0ff; }
.dl-ctx { color: #c9d1d9; }
.thread-footer {
  border-top: 1px solid var(--color-border-default);
  background: var(--color-canvas-subtle);
  padding: 10px 14px;
}
.reply-row { display: flex; align-items: center; gap: 10px; }
.reply-placeholder {
  flex: 1; text-align: left; min-height: 34px; padding: 6px 12px; font-size: 13px;
  color: var(--color-fg-muted); background: var(--color-canvas-default);
  border: 1px solid var(--color-border-default); border-radius: 7px; cursor: text; font-family: inherit;
}
.reply-placeholder:hover { border-color: var(--color-accent-fg); }

/* Composer */
.composer { display: flex; flex-direction: column; gap: 8px; }
.composer-card { background: var(--color-canvas-subtle); padding: 0; }
.composer-card .composer { padding: 12px 14px; }
.composer-input { margin-bottom: 0; background: var(--color-canvas-default); }
.composer-main { min-height: 110px; }
.composer-preview {
  min-height: 110px; padding: 10px 12px; border: 1px solid var(--color-border-default);
  border-radius: 7px; background: var(--color-canvas-default);
}
.composer-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
.composer-hint { font-size: 11.5px; color: var(--color-fg-muted); margin-right: auto; }
.composer-tabs { display: flex; gap: 2px; padding: 8px 10px 0; border-bottom: 1px solid var(--color-border-default); }
.composer-tab {
  background: none; border: 1px solid transparent; border-bottom: none; color: var(--color-fg-muted);
  padding: 7px 14px; font-size: 13px; cursor: pointer; border-radius: 6px 6px 0 0; font-family: inherit;
}
.composer-tab.active { background: var(--color-canvas-default); color: var(--color-fg-default); border-color: var(--color-border-default); margin-bottom: -1px; }
.composer-icon { color: var(--color-fg-muted); background: var(--color-canvas-subtle); border: 1px solid var(--color-border-default); }
.btn-close-inline { color: #f85149; }

/* Checks */
.checks-header-actions { display: flex; align-items: center; gap: 8px; }
.check-item-row { padding: 9px 16px; font-size: 12.5px; gap: 8px; }
.check-row-blocking { background: rgba(248, 81, 73, 0.06); }
.check-row-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.check-row-main { min-width: 0; }
.check-row-status { white-space: nowrap; }
.check-row-actions { display: inline-flex; align-items: center; gap: 8px; }
.check-details-link { padding: 3px 8px; border-radius: 6px; }
.check-details-link:hover { background: rgba(88, 166, 255, 0.1); text-decoration: none; }
.checks-list-container { max-height: 360px; }
.badge-pending { color: #d29922 !important; background: rgba(210, 153, 34, 0.15) !important; }

/* Merge rules */
.merge-rule-item { align-items: center; padding: 7px 0; font-size: 12.5px; }
.rule-content { flex: 1; min-width: 0; }
.rule-action { flex-shrink: 0; }
.rule-desc code, .rule-title code { font-family: ui-monospace, monospace; font-size: 11.5px; padding: 1px 4px; background: rgba(110, 118, 129, 0.2); border-radius: 3px; }
.merge-action-bar { padding: 14px 16px; }
.merge-button-group { flex-wrap: wrap; }
.merge-options { margin: 4px 0 10px; font-size: 12.5px; color: var(--color-fg-default); }
.checkbox-label { display: inline-flex; align-items: center; gap: 8px; cursor: pointer; }
.checkbox-label input { width: 15px; height: 15px; accent-color: #238636; }
.checkbox-label code { font-family: ui-monospace, monospace; font-size: 11.5px; padding: 1px 4px; background: rgba(110, 118, 129, 0.2); border-radius: 3px; }
.merge-warning { font-size: 12px; color: #d29922; margin-bottom: 10px; }
.merge-blocked-badge { font-size: 12.5px; }

/* Commits & events */
.commit-group-title { font-size: 12px; color: var(--color-fg-muted); margin-bottom: 4px; }
.commit-dot { width: 8px; height: 8px; border-radius: 50%; border: 2px solid var(--color-fg-muted); flex-shrink: 0; }
.commit-msg { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.commit-author { font-size: 11.5px; color: var(--color-fg-muted); white-space: nowrap; }
.label-pill { border: 1px solid transparent; font-weight: 600; }
time.rel-time { white-space: nowrap; }
"""#

    // MARK: - GitHub Primer Dark CSS

    private static let cssStyles = """
:root {
  --color-canvas-default: #0d1117;
  --color-canvas-subtle: #161b22;
  --color-border-default: #30363d;
  --color-border-muted: #21262d;
  --color-fg-default: #e6edf3;
  --color-fg-muted: #7d8590;
  --color-accent-fg: #58a6ff;
  --color-success-fg: #3fb950;
  --color-danger-fg: #f85149;
  --color-attention-fg: #d29922;
}

* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
  background-color: var(--color-canvas-default);
  color: var(--color-fg-default);
  font-size: 13.5px;
  line-height: 1.5;
  padding: 20px 24px;
  overflow-x: hidden;
  user-select: text;
  -webkit-user-select: text;
}

.timeline-container {
  max-width: 980px;
  margin: 0 auto;
}

.timeline-item {
  display: flex;
  gap: 14px;
  position: relative;
  margin-bottom: 20px;
}

.avatar-col {
  width: 38px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  position: relative;
}

.avatar {
  width: 38px;
  height: 38px;
  border-radius: 50%;
  background: var(--color-canvas-subtle);
  border: 1px solid var(--color-border-default);
  object-fit: cover;
  z-index: 2;
}

.avatar-small {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--color-canvas-subtle);
  border: 1px solid var(--color-border-default);
  object-fit: cover;
}

.timeline-line {
  position: absolute;
  top: 38px;
  bottom: -20px;
  left: 18px;
  width: 2px;
  background: rgba(48, 54, 61, 0.6);
  z-index: 1;
}

.card {
  flex-grow: 1;
  background: var(--color-canvas-default);
  border: 1px solid var(--color-border-default);
  border-radius: 6px;
  overflow: hidden;
  position: relative;
  min-width: 0;
}

.card-header {
  background: var(--color-canvas-subtle);
  border-bottom: 1px solid var(--color-border-default);
  padding: 8px 14px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 12.5px;
}

.card-header-left {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}

.author-name {
  font-weight: 600;
  color: var(--color-fg-default);
}

.header-text {
  color: var(--color-fg-muted);
}

.badge {
  font-size: 11px;
  font-weight: 500;
  padding: 1px 7px;
  border-radius: 12px;
  border: 1px solid var(--color-border-default);
  color: var(--color-fg-muted);
}

.badge-bot {
  background: rgba(48, 54, 61, 0.7);
  color: #c9d1d9;
}

.card-body {
  padding: 16px;
  background: var(--color-canvas-default);
}

/* Markdown typography */
.markdown-body {
  font-size: 13.5px;
  color: var(--color-fg-default);
  line-height: 1.6;
  word-break: break-word;
}

.markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4 {
  color: var(--color-fg-default);
  margin-top: 16px;
  margin-bottom: 8px;
  font-weight: 600;
}

.markdown-body h1 { font-size: 1.4em; border-bottom: 1px solid var(--color-border-default); padding-bottom: 6px; }
.markdown-body h2 { font-size: 1.25em; border-bottom: 1px solid var(--color-border-default); padding-bottom: 5px; }
.markdown-body h3 { font-size: 1.1em; }
.markdown-body h4 { font-size: 1.0em; }

.markdown-body p {
  margin-bottom: 12px;
}

.markdown-body p:last-child {
  margin-bottom: 0;
}

.markdown-body a {
  color: var(--color-accent-fg);
  text-decoration: none;
}

.markdown-body a:hover {
  text-decoration: underline;
}

.markdown-body code {
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  font-size: 12px;
  background: rgba(110, 118, 129, 0.2);
  padding: 2px 5px;
  border-radius: 4px;
}

.markdown-body pre {
  background: var(--color-canvas-subtle);
  border: 1px solid var(--color-border-default);
  border-radius: 6px;
  padding: 12px 14px;
  overflow-x: auto;
  margin: 12px 0;
}

.markdown-body pre code {
  background: transparent;
  padding: 0;
  font-size: 12px;
  line-height: 1.5;
}

.markdown-body ul, .markdown-body ol {
  padding-left: 24px;
  margin-bottom: 12px;
}

.markdown-body li {
  margin-bottom: 4px;
}

.markdown-body blockquote {
  border-left: 3px solid var(--color-border-default);
  padding-left: 12px;
  color: var(--color-fg-muted);
  margin: 10px 0;
}

/* GitHub Tables (DangerJS, CodeRabbit, Snyk) */
.markdown-body table {
  border-collapse: collapse;
  width: 100%;
  margin: 14px 0;
  border: 1px solid var(--color-border-default);
  border-radius: 6px;
  overflow: hidden;
  display: table;
}

.markdown-body th {
  background: var(--color-canvas-subtle);
  font-weight: 600;
  padding: 8px 12px;
  border: 1px solid var(--color-border-default);
  color: var(--color-fg-default);
  text-align: left;
}

.markdown-body td {
  padding: 8px 12px;
  border: 1px solid var(--color-border-default);
  color: var(--color-fg-default);
  vertical-align: top;
}

.markdown-body tr:nth-child(even) {
  background: rgba(110, 118, 129, 0.05);
}

.markdown-body hr {
  height: 1px;
  background: var(--color-border-default);
  border: none;
  margin: 16px 0;
}

/* Collapsible Details */
.markdown-body details {
  background: rgba(22, 27, 34, 0.5);
  border: 1px solid var(--color-border-default);
  border-radius: 6px;
  padding: 8px 12px;
  margin: 8px 0;
}

.markdown-body summary {
  font-weight: 600;
  color: var(--color-accent-fg);
  cursor: pointer;
  outline: none;
}

.markdown-body summary:hover {
  text-decoration: underline;
}

/* Interactive Checklists */
.markdown-body input[type="checkbox"] {
  margin-right: 6px;
  accent-color: #238636;
  width: 14px;
  height: 14px;
  vertical-align: -2px;
}

/* Review Event rows */
.status-circle {
  width: 18px;
  height: 18px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 11px;
  font-weight: bold;
  color: white;
}

/* Review Thread rows */
.thread-card {
  background: var(--color-canvas-default);
}

.thread-header {
  font-size: 12px;
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
}

.resolved-pill {
  font-size: 10.5px;
  background: rgba(63, 185, 80, 0.15);
  color: #3fb950;
  padding: 2px 8px;
  border-radius: 12px;
}

.unresolved-pill {
  font-size: 10.5px;
  background: rgba(210, 153, 34, 0.15);
  color: #d29922;
  padding: 2px 8px;
  border-radius: 12px;
}

.diff-hunk-container {
  background: #05070a;
  border-bottom: 1px solid var(--color-border-default);
  overflow-x: auto;
}

.diff-hunk-pre {
  padding: 8px 12px;
  font-family: ui-monospace, monospace;
  font-size: 11.5px;
  line-height: 1.4;
  color: var(--color-fg-muted);
}

.thread-comment {
  padding: 12px 14px;
}

.thread-comment-reply {
  border-top: 1px solid var(--color-border-default);
}

.thread-comment-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
  font-size: 12px;
}

/* Status Event rows */
.timeline-event {
  margin-bottom: 12px;
  gap: 14px;
  align-items: center;
}

.event-icon-circle {
  width: 28px;
  height: 28px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  z-index: 2;
}

.status-event-row {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12.5px;
  color: var(--color-fg-muted);
}

.label-pill {
  padding: 2px 7px;
  border-radius: 10px;
  background: rgba(110, 118, 129, 0.2);
  color: var(--color-fg-default);
  font-size: 11px;
}

/* Commits pushed group */
.commit-group {
  display: flex;
  flex-direction: column;
  gap: 6px;
  width: 100%;
}

.commit-row {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
}

.commit-icon {
  font-size: 10px;
  color: var(--color-fg-muted);
}

.commit-msg {
  color: var(--color-fg-default);
  flex-grow: 1;
}

.commit-sha {
  font-family: ui-monospace, monospace;
  font-size: 11px;
  color: var(--color-accent-fg);
  background: rgba(88, 166, 255, 0.1);
  padding: 1px 5px;
  border-radius: 4px;
}

/* Checks & Merge Box Styles */
.merge-timeline-item {
  margin-top: 10px;
}

.merge-badge-circle {
  font-size: 13px;
  font-weight: 700;
}

.badge-open {
  color: #3fb950 !important;
  background: rgba(63, 185, 80, 0.15) !important;
}

.badge-merged {
  color: #a371f7 !important;
  background: rgba(163, 113, 247, 0.15) !important;
}

.badge-closed {
  color: #f85149 !important;
  background: rgba(248, 81, 73, 0.15) !important;
}

.merge-card {
  width: 100%;
  overflow: hidden;
  background-color: var(--color-canvas-subtle);
  border: 1px solid var(--color-border-default);
  border-radius: 6px;
}

.checks-header-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px 16px;
}

.checks-header-left {
  display: flex;
  align-items: center;
  gap: 12px;
}

.checks-badge-icon {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 700;
  flex-shrink: 0;
}

.check-success {
  color: #3fb950;
  background: rgba(63, 185, 80, 0.15);
}

.check-failure {
  color: #f85149;
  background: rgba(248, 81, 73, 0.15);
}

.check-pending {
  color: #d29922;
  background: rgba(210, 153, 34, 0.15);
}

.check-neutral {
  color: #7d8590;
  background: rgba(125, 133, 144, 0.15);
}

.check-merged {
  color: #a371f7;
  background: rgba(163, 113, 247, 0.15);
}

.check-closed {
  color: #f85149;
  background: rgba(248, 81, 73, 0.15);
}

.checks-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-fg-default);
}

.checks-subtext {
  font-size: 11.5px;
  color: var(--color-fg-muted);
}

.checks-list-container {
  border-top: 1px solid var(--color-border-muted);
  max-height: 280px;
  overflow-y: auto;
}

.check-item-row {
  display: flex;
  align-items: center;
  padding: 8px 16px;
  border-bottom: 1px solid var(--color-border-muted);
  font-size: 12px;
}

.check-item-row:last-child {
  border-bottom: none;
}

.check-row-icon {
  width: 18px;
  height: 18px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 11px;
  font-weight: 700;
  margin-right: 10px;
  flex-shrink: 0;
}

.check-row-name {
  font-weight: 500;
  color: var(--color-fg-default);
  flex-grow: 1;
}

.check-row-status {
  color: var(--color-fg-muted);
  margin-right: 14px;
  font-size: 11.5px;
}

.check-details-link {
  color: var(--color-accent-fg);
  text-decoration: none;
  font-size: 11.5px;
  font-weight: 500;
}

.check-details-link:hover {
  text-decoration: underline;
}

.merge-divider {
  height: 1px;
  background-color: var(--color-border-default);
}

.branch-status-row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 16px;
}

.branch-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-fg-default);
}

.branch-subtext {
  font-size: 11.5px;
  color: var(--color-fg-muted);
}

.branch-subtext code {
  font-family: ui-monospace, monospace;
  font-size: 11px;
  padding: 1px 4px;
  background: rgba(110, 118, 129, 0.2);
  border-radius: 3px;
}

.merge-action-bar {
  padding: 12px 16px;
  background-color: var(--color-canvas-default);
  border-top: 1px solid var(--color-border-default);
}

.merge-button-group {
  display: flex;
  align-items: center;
  gap: 8px;
}

.btn {
  border-radius: 6px;
  padding: 5px 12px;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
  line-height: 20px;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}

.btn-primary {
  background-color: #238636;
  color: #ffffff;
  border: 1px solid rgba(240, 246, 252, 0.1);
}

.btn-primary:hover {
  background-color: #2ea043;
}

.btn-secondary {
  background-color: #21262d;
  color: #c9d1d9;
  border: 1px solid var(--color-border-default);
}

.btn-secondary:hover {
  background-color: #30363d;
  border-color: #8b949e;
}

.btn-close-pr {
  margin-left: auto;
  color: #f85149;
}

.btn-close-pr:hover {
  background-color: rgba(248, 81, 73, 0.15);
  border-color: #f85149;
}

.btn-link {
  background: none;
  border: none;
  color: var(--color-accent-fg);
  font-size: 12px;
  cursor: pointer;
  padding: 0;
}

.btn-link:hover {
  text-decoration: underline;
}

.merge-method-select {
  background-color: #21262d;
  color: #c9d1d9;
  border: 1px solid var(--color-border-default);
  border-radius: 6px;
  padding: 5px 8px;
  font-size: 12px;
  font-family: inherit;
  outline: none;
  cursor: pointer;
}

.merge-confirm-panel {
  margin-top: 12px;
  padding-top: 12px;
  border-top: 1px solid var(--color-border-muted);
}

.input-text, .input-textarea {
  width: 100%;
  background-color: var(--color-canvas-subtle);
  border: 1px solid var(--color-border-default);
  border-radius: 6px;
  padding: 6px 10px;
  color: var(--color-fg-default);
  font-size: 12px;
  font-family: inherit;
  margin-bottom: 8px;
  outline: none;
  box-sizing: border-box;
}

.input-text:focus, .input-textarea:focus {
  border-color: var(--color-accent-fg);
  box-shadow: 0 0 0 2px rgba(88, 166, 255, 0.2);
}

.merge-confirm-actions {
  display: flex;
  gap: 8px;
}

.check-row-main {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-grow: 1;
}

.check-req-badge {
  font-size: 9.5px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  padding: 1px 6px;
  border-radius: 4px;
  line-height: 1.4;
}

.check-req-mandatory {
  background: rgba(248, 81, 73, 0.15);
  color: #f85149;
  border: 1px solid rgba(248, 81, 73, 0.3);
}

.check-req-optional {
  background: rgba(110, 118, 129, 0.15);
  color: #8b949e;
  border: 1px solid rgba(110, 118, 129, 0.2);
}

.merge-rules-section {
  padding: 12px 16px;
  background-color: var(--color-canvas-subtle);
}

.merge-rules-title {
  font-size: 11.5px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: var(--color-fg-muted);
  margin-bottom: 8px;
}

.merge-rule-item {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 5px 0;
  font-size: 12px;
}

.rule-icon {
  width: 18px;
  height: 18px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 10px;
  font-weight: 700;
  flex-shrink: 0;
  margin-top: 1px;
}

.rule-success {
  color: #3fb950;
  background: rgba(63, 185, 80, 0.15);
}

.rule-failure {
  color: #f85149;
  background: rgba(248, 81, 73, 0.15);
}

.rule-pending {
  color: #d29922;
  background: rgba(210, 153, 34, 0.15);
}

.rule-neutral {
  color: #7d8590;
  background: rgba(125, 133, 144, 0.15);
}

.rule-content {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.rule-title {
  font-weight: 600;
  color: var(--color-fg-default);
}

.rule-desc {
  font-size: 11.5px;
  color: var(--color-fg-muted);
}
.rule-desc a {
  color: #4493f8;
  text-decoration: none;
}
.rule-desc a:hover {
  text-decoration: underline;
}

.conflict-callout-box {
  border: 1px solid rgba(248, 81, 73, 0.35);
  background: rgba(248, 81, 73, 0.08);
  border-radius: 6px;
  padding: 12px 16px;
  margin: 12px 16px;
}

.conflict-callout-header {
  display: flex;
  gap: 10px;
  align-items: flex-start;
}

.conflict-icon {
  font-size: 16px;
  line-height: 1.2;
}

.conflict-title {
  font-size: 12.5px;
  font-weight: 600;
  color: #f85149;
}

.conflict-desc {
  font-size: 11.5px;
  color: var(--color-fg-muted);
  margin-top: 2px;
}

.conflict-actions {
  display: flex;
  gap: 8px;
  margin-top: 10px;
  margin-left: 26px;
  flex-wrap: wrap;
}

.conflict-actions .btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  text-decoration: none;
}

.conflict-actions .btn svg,
.conflict-icon svg {
  width: 14px;
  height: 14px;
}

.conflict-icon {
  color: #f85149;
}

.conflict-cli-toggle {
  margin: 10px 0 0 26px;
}

.conflict-cli-box {
  margin-top: 12px;
  padding: 10px;
  background: #05070a;
  border-radius: 6px;
  border: 1px solid var(--color-border-default);
}

.cli-step-title {
  font-size: 11px;
  font-weight: 600;
  color: var(--color-fg-muted);
  margin-bottom: 4px;
}

.cli-pre {
  padding: 6px 10px;
  background: rgba(110, 118, 129, 0.1);
  border-radius: 4px;
  margin-bottom: 8px;
  font-family: ui-monospace, monospace;
  font-size: 11px;
  color: var(--color-fg-default);
  overflow-x: auto;
}

.update-callout-box {
  border: 1px solid var(--color-border-default);
  background: rgba(110, 118, 129, 0.08);
  border-radius: 6px;
  padding: 10px 16px;
  margin: 12px 16px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.update-callout-text {
  font-size: 12px;
  color: var(--color-fg-default);
}

.update-subtext {
  font-size: 11.5px;
  color: var(--color-fg-muted);
  margin-top: 2px;
}

.btn-disabled {
  opacity: 0.55;
  cursor: not-allowed !important;
  background-color: #21262d !important;
  color: #8b949e !important;
  border-color: rgba(240, 246, 252, 0.1) !important;
}

.merge-blocked-badge {
  font-size: 11.5px;
  color: #f85149;
  font-weight: 500;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin-left: 8px;
}
"""
}
