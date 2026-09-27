import Foundation

/// Renders every changed file of a PR as one continuous, GitHub-style scrolling page with sticky file headers,
/// inline review threads, click-to-comment, expandable context and word-level highlights.
enum PRFilesHTMLBuilder {
    /// Files with more diff lines than this start collapsed behind a "Load diff" button.
    static let largeDiffLineLimit = 20_000
    /// Rows per `content-visibility` chunk: off-screen chunks skip layout and paint entirely.
    static let chunkRows = 120

    static func buildHTML(
        files: [PRFileChange],
        mode: DiffDisplayMode,
        viewedPaths: Set<String>,
        canOpenLocally: Bool,
        prURL: String,
        allowComments: Bool = true
    ) -> String {
        var body = ""
        body.reserveCapacity(files.reduce(0) { $0 + ($1.patch?.utf8.count ?? 0) } * 4 + 4096)
        for (index, file) in files.enumerated() {
            appendFile(file, index: index, mode: mode, viewed: viewedPaths.contains(file.filename),
                       canOpenLocally: canOpenLocally, prURL: prURL, into: &body)
        }
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>\(css)</style>
        <script>\(MarkedJS.source)</script>
        <script>\(ConversationHTMLBuilder.markdownRuntimeJS)</script>
        </head>
        <body class="\(mode == .split ? "mode-split" : "mode-unified")\(allowComments ? "" : " no-comments")">
        <main id="files">\(body)</main>
        <button id="addc" type="button" title="Comment on this line">+</button>
        <script>\(script)</script>
        </body></html>
        """
    }

    // MARK: - File sections

    private static func appendFile(
        _ file: PRFileChange, index: Int, mode: DiffDisplayMode, viewed: Bool,
        canOpenLocally: Bool, prURL: String, into out: inout String
    ) {
        let path = escape(file.filename)
        let status = file.status.lowercased()
        let diff = file.patch.flatMap { $0.isEmpty ? nil : $0 }.map {
            PRDiffHelper.parsePatch(patch: $0, filename: file.filename, additions: file.additions, deletions: file.deletions)
        }
        let lineCount = diff?.hunks.reduce(0) { $0 + $1.lines.count + 1 } ?? 0
        let isLarge = lineCount > largeDiffLineLimit

        var classes = ["file"]
        if viewed { classes.append("is-viewed") }
        if viewed || isLarge { classes.append("collapsed") }
        if isLarge { classes.append("large") }

        out += "<section class=\"\(classes.joined(separator: " "))\" data-path=\"\(path)\" data-index=\"\(index)\" data-status=\"\(escape(status))\">"
        out += "<header class=\"fhead\">"
        out += "<button class=\"chev\" title=\"Collapse / expand file\">▾</button>"
        out += "<span class=\"badge st-\(file.statusLetter)\">\(file.statusLetter)</span>"
        out += "<span class=\"fpath\" title=\"\(path)\">"
        if !file.directoryPath.isEmpty { out += "<span class=\"dir\">\(escape(file.directoryPath))</span>" }
        out += "<span class=\"name\">\(escape(file.fileDisplayName))</span></span>"
        if let previous = file.previousFilename, previous != file.filename {
            out += "<span class=\"renamed\" title=\"Renamed from \(escape(previous))\">← \(escape((previous as NSString).lastPathComponent))</span>"
        }
        out += "<span class=\"stat\">"
        if file.additions > 0 { out += "<span class=\"plus\">+\(file.additions)</span>" }
        if file.deletions > 0 { out += "<span class=\"minus\">−\(file.deletions)</span>" }
        out += "</span><span class=\"threads\" hidden></span><span class=\"spacer\"></span>"
        if canOpenLocally && status != "removed" {
            out += "<button class=\"hbtn open\" title=\"Open in default editor\">Open</button>"
        }
        out += "<span class=\"viewed\" role=\"checkbox\" title=\"Mark as viewed (v)\"><span class=\"box\"></span>Viewed</span>"
        out += "</header><div class=\"fbody\"><div class=\"outdated\" hidden></div>"

        if let diff, !diff.hunks.isEmpty {
            if isLarge {
                out += "<div class=\"notice large-notice\">Large diff (\(lineCount) lines) is hidden. <button class=\"hbtn load\">Load diff</button></div>"
            }
            out += "<div class=\"diff\">"
            appendRows(diff, patch: file.patch ?? "", mode: mode, expandable: status != "removed", tail: status != "added", into: &out)
            out += "</div>"
        } else {
            let githubLink = prURL.isEmpty ? "" : " <a href=\"\(escape(prURL))/files\">View on GitHub</a>"
            out += "<div class=\"notice\">No inline diff available (binary, empty, or too large for GitHub's patch API).\(githubLink)</div>"
        }
        out += "</div></section>"
    }

    private struct HunkRange { let os, oc, ns, nc: Int }

    /// `@@ -os,oc +ns,nc @@` (counts default to 1 when omitted).
    private static func hunkRanges(_ patch: String) -> [HunkRange] {
        patch.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard line.hasPrefix("@@") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 3 else { return nil }
            func pair(_ s: Substring) -> (Int, Int) {
                let nums = s.dropFirst().split(separator: ",")
                return (Int(nums.first ?? "") ?? 1, nums.count > 1 ? (Int(nums[1]) ?? 1) : 1)
            }
            let (os, oc) = pair(parts[1]), (ns, nc) = pair(parts[2])
            return HunkRange(os: os, oc: oc, ns: ns, nc: nc)
        }
    }

    private static func appendRows(_ diff: FileDiff, patch: String, mode: DiffDisplayMode, expandable: Bool, tail: Bool, into out: inout String) {
        let ranges = hunkRanges(patch)
        var rows: [String] = []
        var prevNewEnd = 0, prevOldEnd = 0

        for (hi, hunk) in diff.hunks.enumerated() {
            let r = hi < ranges.count ? ranges[hi] : nil
            var gapAttrs = ""
            if expandable, let r {
                let gapStart = prevNewEnd + 1, gapEnd = r.ns - 1
                if gapEnd >= gapStart { gapAttrs = " data-gs=\"\(gapStart)\" data-ge=\"\(gapEnd)\" data-d=\"\(r.os - r.ns)\"" }
                prevNewEnd = r.nc == 0 ? r.ns : r.ns + r.nc - 1
                prevOldEnd = r.oc == 0 ? r.os : r.os + r.oc - 1
            }
            rows.append("<div class=\"hunk\"\(gapAttrs)><span class=\"hx\"></span><span class=\"htext\">\(escape(hunk.header))</span></div>")
            appendHunkLines(hunk.lines, mode: mode, into: &rows)
        }
        if expandable, tail, !ranges.isEmpty {
            rows.append("<div class=\"hunk tail\" data-gs=\"\(prevNewEnd + 1)\" data-ge=\"-1\" data-d=\"\(prevOldEnd - prevNewEnd)\"><span class=\"hx\"></span><span class=\"htext\"></span></div>")
        }

        var index = 0
        while index < rows.count {
            let end = min(rows.count, index + chunkRows)
            out += "<div class=\"chunk\" style=\"contain-intrinsic-size: auto \((end - index) * 20)px\">"
            for row in rows[index..<end] { out += row }
            out += "</div>"
            index = end
        }
    }

    /// Runs of deletions are paired with the additions that follow them (for split rows and word highlights).
    private static func appendHunkLines(_ lines: [DiffLine], mode: DiffDisplayMode, into rows: inout [String]) {
        var dels: [DiffLine] = [], adds: [DiffLine] = []
        func flush() {
            let pairs = min(dels.count, adds.count)
            var delHTML = dels.map { codeHTML(text($0)) }
            var addHTML = adds.map { codeHTML(text($0)) }
            for i in 0..<pairs {
                if let wd = WordDiff.diff(old: text(dels[i]), new: text(adds[i])) {
                    delHTML[i] = segmentsHTML(wd.old)
                    addHTML[i] = segmentsHTML(wd.new)
                }
            }
            if mode == .split {
                for i in 0..<max(dels.count, adds.count) {
                    let d = i < dels.count ? dels[i] : nil, a = i < adds.count ? adds[i] : nil
                    var attrs = ""
                    if let o = d?.oldLineNumber { attrs += " data-o=\"\(o)\"" }
                    if let n = a?.newLineNumber { attrs += " data-n=\"\(n)\"" }
                    var row = "<div class=\"ln sp\"\(attrs)>"
                    row += d.map { "<span class=\"num del\">\($0.oldLineNumber.map(String.init) ?? "")</span><span class=\"code del\"><span class=\"mk\">−</span>\(delHTML[i])</span>" }
                        ?? "<span class=\"num empty\"></span><span class=\"code empty\"></span>"
                    row += a.map { "<span class=\"num add\">\($0.newLineNumber.map(String.init) ?? "")</span><span class=\"code add\"><span class=\"mk\">+</span>\(addHTML[i])</span>" }
                        ?? "<span class=\"num empty\"></span><span class=\"code empty\"></span>"
                    rows.append(row + "</div>")
                }
            } else {
                for (i, d) in dels.enumerated() {
                    let o = d.oldLineNumber.map(String.init) ?? ""
                    rows.append("<div class=\"ln del\" data-o=\"\(o)\"><span class=\"num\">\(o)</span><span class=\"num\"></span><span class=\"code\"><span class=\"mk\">−</span>\(delHTML[i])</span></div>")
                }
                for (i, a) in adds.enumerated() {
                    let n = a.newLineNumber.map(String.init) ?? ""
                    rows.append("<div class=\"ln add\" data-n=\"\(n)\"><span class=\"num\"></span><span class=\"num\">\(n)</span><span class=\"code\"><span class=\"mk\">+</span>\(addHTML[i])</span></div>")
                }
            }
            dels.removeAll(keepingCapacity: true)
            adds.removeAll(keepingCapacity: true)
        }
        for line in lines {
            switch line.type {
            case .deletion:
                if !adds.isEmpty { flush() }
                dels.append(line)
            case .addition:
                adds.append(line)
            default:
                flush()
                let o = line.oldLineNumber.map(String.init) ?? "", n = line.newLineNumber.map(String.init) ?? ""
                let code = codeHTML(text(line))
                if mode == .split {
                    rows.append("<div class=\"ln sp ctx\" data-o=\"\(o)\" data-n=\"\(n)\"><span class=\"num\">\(o)</span><span class=\"code\"><span class=\"mk\"> </span>\(code)</span><span class=\"num\">\(n)</span><span class=\"code\"><span class=\"mk\"> </span>\(code)</span></div>")
                } else {
                    rows.append("<div class=\"ln ctx\" data-o=\"\(o)\" data-n=\"\(n)\"><span class=\"num\">\(o)</span><span class=\"num\">\(n)</span><span class=\"code\"><span class=\"mk\"> </span>\(code)</span></div>")
                }
            }
        }
        flush()
    }

    /// Patch lines keep their leading `+` / `-` / space marker; the marker is rendered in its own span.
    private static func text(_ line: DiffLine) -> String {
        let content = line.content
        return content.first.map { "+- ".contains($0) } == true ? String(content.dropFirst()) : content
    }

    private static func codeHTML(_ s: String) -> String { s.isEmpty ? " " : escape(s) }

    private static func segmentsHTML(_ segments: [WordDiff.Segment]) -> String {
        segments.map { $0.changed ? "<span class=\"wd\">\(escape($0.text))</span>" : escape($0.text) }.joined()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - CSS

    private static let css = #"""
:root { --gitxx-top-inset: 0px; --sticky-top: var(--gitxx-top-inset); }
* { box-sizing: border-box; }
html { padding-top: var(--gitxx-top-inset, 0px); }
html::-webkit-scrollbar, body::-webkit-scrollbar { display: none; width: 0; height: 0; }
body {
  margin: 0; padding: 16px 20px 40vh; background: #0d1117; color: #e6edf3;
  font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
section.file { margin: 0 0 16px; }
section.file.filtered { display: none; }
.fhead {
  position: sticky; top: var(--sticky-top); z-index: 5;
  display: flex; align-items: center; gap: 8px; height: 40px; padding: 0 10px 0 6px;
  background: #161b22; border: 1px solid #30363d; border-radius: 6px 6px 0 0;
  box-shadow: 0 -16px 0 #0d1117;
  transition: top 0.18s ease-out;
}
section.collapsed .fhead { border-radius: 6px; }
.fbody { border: 1px solid #30363d; border-top: 0; border-radius: 0 0 6px 6px; overflow: hidden; }
section.collapsed .fbody { display: none; }
.chev {
  width: 22px; height: 22px; border: 0; border-radius: 4px; background: transparent; color: #8b949e;
  font-size: 12px; cursor: pointer; transition: transform 0.12s ease;
}
.chev:hover { background: #30363d; color: #e6edf3; }
section.collapsed .chev { transform: rotate(-90deg); }
.badge {
  flex: none; width: 18px; height: 18px; border-radius: 4px; text-align: center; line-height: 18px;
  font: 800 10px ui-monospace, SFMono-Regular, Menlo, monospace;
}
.st-A { color: #3fb950; background: rgba(63,185,80,0.18); }
.st-D { color: #f85149; background: rgba(248,81,73,0.18); }
.st-M { color: #d29922; background: rgba(210,153,34,0.18); }
.st-R { color: #58a6ff; background: rgba(88,166,255,0.18); }
.fpath { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; }
.fpath .dir { color: #8b949e; }
.fpath .name { color: #e6edf3; font-weight: 600; }
section.is-viewed .fpath .name { color: #8b949e; }
.renamed { flex: none; color: #8b949e; font: 11.5px ui-monospace, monospace; }
.stat { flex: none; display: inline-flex; gap: 6px; font: 700 11.5px ui-monospace, monospace; }
.plus { color: #3fb950; } .minus { color: #f85149; }
.threads { flex: none; color: #d29922; font-size: 11.5px; font-weight: 600; }
.spacer { flex: 1; }
.hbtn, .tbtn {
  flex: none; height: 24px; padding: 0 10px; border-radius: 6px; border: 1px solid #3d444d;
  background: #21262d; color: #e6edf3; font: 500 12px -apple-system, sans-serif; cursor: pointer;
}
.hbtn:hover, .tbtn:hover { background: #30363d; border-color: #6e7681; }
.tbtn.primary { background: #238636; border-color: rgba(240,246,252,0.1); color: #fff; }
.tbtn.primary:hover { background: #2ea043; }
.tbtn:disabled { opacity: 0.55; cursor: default; }
.viewed {
  flex: none; display: inline-flex; align-items: center; gap: 5px; height: 24px; padding: 0 9px;
  border: 1px solid #3d444d; border-radius: 6px; color: #c9d1d9; font-size: 12px; cursor: pointer; user-select: none;
}
.viewed:hover { border-color: #6e7681; }
section.is-viewed .viewed { background: rgba(56,139,253,0.12); border-color: rgba(56,139,253,0.45); }
.viewed .box { width: 13px; height: 13px; border: 1px solid #6e7681; border-radius: 3px; display: inline-flex;
  align-items: center; justify-content: center; font-size: 10px; line-height: 1; color: #fff; }
section.is-viewed .viewed .box { background: #2f81f7; border-color: #2f81f7; }
section.is-viewed .viewed .box::after { content: "✓"; }
.notice { padding: 14px 16px; color: #8b949e; font-size: 12.5px; background: #0d1117; }
.notice a { color: #58a6ff; }
section.large:not(.loaded) .diff { display: none; }
section.loaded .large-notice { display: none; }

/* Diff rows */
.chunk { content-visibility: auto; }
.diff { font: 12px/20px ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace; }
.ln { display: grid; grid-template-columns: 52px 52px minmax(0, 1fr); }
.mode-split .ln { grid-template-columns: 52px minmax(0, 1fr) 52px minmax(0, 1fr); }
.num {
  padding: 0 8px; text-align: right; color: #6e7681; user-select: none; -webkit-user-select: none;
  background: #0d1117;
}
.code { padding: 0 10px 0 4px; white-space: pre-wrap; word-break: break-all; overflow-wrap: anywhere; }
.mk { display: inline-block; width: 14px; color: #8b949e; user-select: none; -webkit-user-select: none; }
.ln.add .code, .code.add { background: rgba(46,160,67,0.15); }
.ln.add .num, .num.add { background: rgba(63,185,80,0.26); color: #c9d1d9; }
.ln.del .code, .code.del { background: rgba(248,81,73,0.12); }
.ln.del .num, .num.del { background: rgba(248,81,73,0.26); color: #c9d1d9; }
.ln.add .mk, .code.add .mk { color: #3fb950; } .ln.del .mk, .code.del .mk { color: #f85149; }
.ln.add .wd, .code.add .wd { background: rgba(46,160,67,0.45); border-radius: 2px; }
.ln.del .wd, .code.del .wd { background: rgba(248,81,73,0.4); border-radius: 2px; }
.num.empty, .code.empty { background: rgba(110,118,129,0.08); }
.mode-split .ln > .num:nth-child(3) { border-left: 1px solid #30363d; }
.ln.xctx .code, .ln.xctx .num { background: #0d1117; }
.ln.xctx .num { color: #484f58; }
.hunk { display: flex; align-items: center; min-height: 28px; background: rgba(56,139,253,0.10); color: #8b949e; }
.hunk .hx { flex: none; display: inline-flex; width: 104px; }
.mode-split .hunk .hx { width: 52px; flex-direction: column; }
.hunk .htext { padding-left: 8px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.hunk.tail:not([data-gs]) { display: none; }
.xbtn {
  width: 52px; height: 28px; border: 0; background: rgba(56,139,253,0.18); color: #c9d1d9; cursor: pointer;
  font: 600 12px -apple-system, sans-serif;
}
.mode-split .xbtn { height: 20px; }
.xbtn:hover { background: #1f6feb; color: #fff; }
.hunk.loading .hx { opacity: 0.5; }
.xerr { padding-left: 8px; color: #f85149; }

/* Click-to-comment */
#addc {
  position: absolute; z-index: 4; display: none; width: 20px; height: 20px; margin-top: 0;
  border: 0; border-radius: 6px; background: #1f6feb; color: #fff; font: 700 14px/20px -apple-system, sans-serif;
  cursor: pointer; box-shadow: 0 1px 4px rgba(0,0,0,0.4); transform: scale(0.9); transition: transform 0.08s ease;
}
#addc:hover { transform: scale(1.1); }
body.no-comments #addc { display: none !important; }

/* Threads */
.thread-row { padding: 8px 12px; background: #0d1117; border-top: 1px solid #21262d; border-bottom: 1px solid #21262d;
  font: 13px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; white-space: normal; }
.mode-split .thread-row.right { padding-left: calc(50% + 12px); }
.mode-split .thread-row.left { padding-right: calc(50% + 12px); }
.thread { max-width: 860px; border: 1px solid #30363d; border-radius: 8px; background: #161b22; overflow: hidden; }
.th-head { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid #21262d;
  color: #8b949e; font-size: 12px; }
.thread.resolved .th-head { color: #8b949e; }
.th-state.res { color: #3fb950; font-weight: 600; }
.th-state.out { color: #d29922; font-weight: 600; }
.thread.folded .th-body { display: none; }
.thread.folded .th-head { border-bottom: 0; }
.cm { display: flex; gap: 10px; padding: 10px 12px; }
.cm + .cm { border-top: 1px solid #21262d; }
.av { width: 24px; height: 24px; border-radius: 50%; flex: none; background: #30363d; }
.cm-main { min-width: 0; flex: 1; }
.cm-head { font-size: 12.5px; color: #8b949e; margin-bottom: 2px; }
.cm-head b { color: #e6edf3; font-weight: 600; margin-right: 6px; }
.reply, .composer-box { padding: 8px 12px 10px; border-top: 1px solid #21262d; }
.composer-box { border-top: 0; }
.reply textarea, .composer-box textarea {
  width: 100%; min-height: 32px; height: 32px; resize: vertical; padding: 6px 8px; border-radius: 6px;
  border: 1px solid #30363d; background: #0d1117; color: #e6edf3; font: 13px -apple-system, sans-serif;
}
.reply.active textarea, .composer-box textarea { height: 76px; }
.reply textarea:focus, .composer-box textarea:focus { outline: none; border-color: #1f6feb; box-shadow: 0 0 0 2px rgba(31,111,235,0.3); }
.acts { display: none; justify-content: flex-end; gap: 6px; margin-top: 6px; }
.reply.active .acts, .composer-box .acts { display: flex; }
.acts .hint { margin-right: auto; color: #6e7681; font-size: 11.5px; align-self: center; }
.outdated { padding: 8px 12px; background: #0d1117; border-bottom: 1px solid #21262d; }
.outdated-title { color: #d29922; font-size: 12px; font-weight: 600; cursor: pointer; user-select: none; }
.outdated.folded .outdated-list { display: none; }
.outdated-list .thread { margin-top: 8px; }
.md { font-size: 13px; line-height: 1.5; color: #e6edf3; overflow-wrap: anywhere; }
.md p { margin: 0 0 8px; } .md p:last-child { margin-bottom: 0; }
.md a { color: #58a6ff; }
.md code { font: 12px ui-monospace, monospace; padding: 1px 4px; border-radius: 4px; background: rgba(110,118,129,0.25); }
.md pre { background: #0d1117; border: 1px solid #30363d; border-radius: 6px; padding: 8px 10px; overflow-x: auto; margin: 6px 0; }
.md pre code { background: none; padding: 0; white-space: pre; }
.md blockquote { margin: 6px 0; padding: 0 10px; color: #8b949e; border-left: 3px solid #30363d; }
.md img { max-width: 100%; }
.md ul, .md ol { margin: 4px 0; padding-left: 22px; }

#backToTop {
  position: fixed; right: 22px; bottom: 22px; z-index: 60;
  display: inline-flex; align-items: center; gap: 6px; height: 34px; padding: 0 14px;
  border-radius: 17px; border: 1px solid #3d444d; background: rgba(33,38,45,0.94); color: #e6edf3;
  font: 600 12.5px -apple-system, BlinkMacSystemFont, sans-serif; cursor: pointer;
  box-shadow: 0 6px 18px rgba(0,0,0,0.45);
  opacity: 0; transform: translateY(10px); pointer-events: none;
  transition: opacity 0.16s ease, transform 0.16s ease;
}
#backToTop.visible { opacity: 1; transform: none; pointer-events: auto; }
#backToTop:hover { background: #30363d; }
"""#

    // MARK: - JS

    private static let script = #"""
(function () {
  var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gitxx;
  function post(p) { if (H) H.postMessage(p); }
  var root = document.documentElement;
  var sections = Array.prototype.slice.call(document.querySelectorAll("section.file"));
  var byPath = {};
  sections.forEach(function (s) { byPath[s.dataset.path] = s; });
  var shown = sections.slice();
  var isSplit = document.body.classList.contains("mode-split");
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function editing(t) { return t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable); }

  // ---- Hide-on-scroll chrome ----
  // The native bars float over the page's top padding. Like mobile browsers, a deliberate scroll down slides
  // them away and any scroll up brings them back. Sticky file headers sit just below whatever is showing.
  var chromeHidden = false, chromePosted = null, lastY = window.scrollY, travel = 0;
  function inset() { return parseFloat(getComputedStyle(root).getPropertyValue("--gitxx-top-inset")) || 0; }
  function stickyTop() { return chromeHidden ? 0 : inset(); }
  function setChromeHidden(value, force) {
    chromeHidden = value;
    root.style.setProperty("--sticky-top", (value ? 0 : inset()) + "px");
    if (force || value !== chromePosted) {
      chromePosted = value;
      post({ action: "chromeHidden", hidden: value });
    }
  }
  function syncChrome(force) {
    var i = inset(), y = window.scrollY, dy = y - lastY;
    lastY = y;
    if (i <= 0 || y <= 8) { travel = 0; setChromeHidden(false, force); return; }
    // Rubber-band overscroll past the bottom bounces back upward; that isn't a scroll up.
    if (y + window.innerHeight >= root.scrollHeight - 1 && dy < 0) { setChromeHidden(chromeHidden, force); return; }
    travel = (dy > 0) === (travel > 0) ? travel + dy : dy;
    if (travel > 12 && y > i * 0.6) setChromeHidden(true, force);
    else if (travel < -12) setChromeHidden(false, force);
    else setChromeHidden(chromeHidden, force);
  }
  window.gitxxInsetChanged = function () { setChromeHidden(chromeHidden, false); };
  window.gitxxSyncChrome = function () { lastY = window.scrollY; syncChrome(true); };

  // ---- Scroll spy: the file whose header is stuck at the top is the current file ----
  var current = sections.length ? sections[0].dataset.path : null, jumping = false, jumpTimer = null, spyQueued = false;
  function sectionAtTop() {
    if (!shown.length) return null;
    var line = stickyTop() + 8, lo = 0, hi = shown.length - 1, ans = 0;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (shown[mid].getBoundingClientRect().top <= line) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return shown[ans];
  }
  function setCurrent(s, notify) {
    if (!s) return;
    var path = s.dataset.path;
    if (path === current) return;
    current = path;
    if (notify) post({ action: "currentFile", path: path });
  }
  function spy() {
    spyQueued = false;
    if (!jumping) setCurrent(sectionAtTop(), true);
  }
  function endJump() { jumping = false; jumpTimer = null; }
  window.addEventListener("scroll", function () {
    syncChrome(false);
    if (jumping) { clearTimeout(jumpTimer); jumpTimer = setTimeout(endJump, 140); }
    else if (!spyQueued) { spyQueued = true; requestAnimationFrame(spy); }
    btt.classList.toggle("visible", window.scrollY > 600);
  }, { passive: true });

  function scrollToSection(s, smooth) {
    if (!s) return;
    var r = s.getBoundingClientRect();
    // Scrolling down hides the bars and scrolling up shows them, so land below whatever will be showing.
    var top = s === shown[0] ? 0 : r.top + window.scrollY - (r.top > stickyTop() ? 0 : inset());
    setCurrent(s, false);
    jumping = true;
    clearTimeout(jumpTimer);
    jumpTimer = setTimeout(endJump, 160);
    window.scrollTo({ top: Math.max(0, top), behavior: smooth ? "smooth" : "auto" });
  }
  window.gitxxScrollToFile = function (path, smooth) { scrollToSection(byPath[path], smooth); };
  function stepFile(delta) {
    var idx = shown.indexOf(byPath[current]);
    var next = shown[Math.min(shown.length - 1, Math.max(0, idx + delta))];
    if (next) { scrollToSection(next, true); post({ action: "currentFile", path: next.dataset.path }); }
  }

  // ---- Collapse / viewed ----
  /// Keeps a stuck header in place when its file collapses, instead of jumping far down the page.
  function collapse(s, value) {
    var r = s.getBoundingClientRect(), wasStuck = r.top <= stickyTop() + 1 && r.bottom > stickyTop();
    s.classList.toggle("collapsed", value);
    if (value && wasStuck) window.scrollTo({ top: s.getBoundingClientRect().top + window.scrollY - stickyTop() + 1 });
  }
  function setViewed(s, viewed) {
    if (s.classList.contains("is-viewed") === viewed) return;
    s.classList.toggle("is-viewed", viewed);
    collapse(s, viewed);
  }
  window.gitxxSetViewed = function (paths) {
    var set = {};
    paths.forEach(function (p) { set[p] = true; });
    sections.forEach(function (s) { setViewed(s, !!set[s.dataset.path]); });
  };
  function toggleViewed(s) {
    setViewed(s, !s.classList.contains("is-viewed"));
    post({ action: "toggleViewed", path: s.dataset.path });
  }

  // ---- Pending actions (reply / resolve / new comment) ----
  var pending = {}, keySeq = 0;
  function runAction(payload, buttons, onDone) {
    var key = "k" + (++keySeq);
    payload.key = key;
    buttons.forEach(function (b) { b.disabled = true; });
    pending[key] = function (ok) {
      buttons.forEach(function (b) { b.disabled = false; });
      if (onDone) onDone(ok);
    };
    post(payload);
  }
  window.gitxxActionDone = function (key, ok) {
    var cb = pending[key];
    delete pending[key];
    if (cb) cb(ok);
  };

  // ---- Inline review threads ----
  function rel(ts) {
    var d = Date.now() / 1000 - ts;
    if (d < 45) return "just now";
    if (d < 3600) return Math.round(d / 60) + "m ago";
    if (d < 86400) return Math.round(d / 3600) + "h ago";
    if (d < 86400 * 30) return Math.round(d / 86400) + "d ago";
    if (d < 86400 * 365) return Math.round(d / (86400 * 30)) + "mo ago";
    return Math.round(d / (86400 * 365)) + "y ago";
  }
  function findRow(s, t) {
    if (t.line == null) return null;
    var attr = t.side === "LEFT" ? "data-o" : "data-n";
    return s.querySelector('.ln[' + attr + '="' + t.line + '"]:not(.xctx)') || s.querySelector('.ln[' + attr + '="' + t.line + '"]');
  }
  function afterThreads(row) {
    var at = row;
    while (at.nextElementSibling && at.nextElementSibling.classList.contains("thread-row")) at = at.nextElementSibling;
    return at;
  }
  function threadEl(t, folded) {
    var box = document.createElement("div");
    box.className = "thread" + (t.resolved ? " resolved" : "") + (folded ? " folded" : "");
    box.dataset.tid = t.id;
    var state = t.resolved ? '<span class="th-state res">✓ Resolved' + (t.resolvedBy ? " by " + esc(t.resolvedBy) : "") + "</span>"
      : t.outdated ? '<span class="th-state out">Outdated</span>'
      : "<span>" + (t.side === "LEFT" ? "Left" : "Line") + " " + esc(t.line) + "</span>";
    var head = state + "<span>" + t.comments.length + " comment" + (t.comments.length === 1 ? "" : "s") + "</span><span class=\"spacer\"></span>";
    if (t.nodeId) head += '<button class="tbtn t-resolve">' + (t.resolved ? "Unresolve" : "Resolve conversation") + "</button>";
    head += '<button class="tbtn t-fold">' + (folded ? "Show" : "Hide") + "</button>";
    var body = "";
    t.comments.forEach(function (c, i) {
      body += '<div class="cm">' + (c.avatar ? '<img class="av" src="' + esc(c.avatar) + '">' : '<span class="av"></span>') +
        '<div class="cm-main"><div class="cm-head"><b>' + esc(c.author) + "</b>" + rel(c.ts) + '</div><div class="md" data-ci="' + i + '"></div></div></div>';
    });
    body += '<div class="reply"><textarea placeholder="Reply…"></textarea><div class="acts"><span class="hint">⌘↩ to send</span>' +
      '<button class="tbtn t-cancel">Cancel</button><button class="tbtn primary t-reply">Reply</button></div></div>';
    box.innerHTML = '<div class="th-head">' + head + '</div><div class="th-body">' + body + "</div>";
    box.querySelectorAll(".md").forEach(function (el) { renderInto(el, t.comments[+el.dataset.ci].body); });
    box.__thread = t;
    return box;
  }
  var threadSig = {};
  window.gitxxSetThreads = function (map) {
    sections.forEach(function (s) {
      var path = s.dataset.path, list = map[path] || [];
      var sig = JSON.stringify(list);
      if (threadSig[path] === sig) return;
      threadSig[path] = sig;
      // Keep reply drafts and fold state across re-renders.
      var drafts = {}, folds = {};
      s.querySelectorAll(".thread").forEach(function (el) {
        var ta = el.querySelector(".reply textarea");
        if (ta && ta.value) drafts[el.dataset.tid] = ta.value;
        folds[el.dataset.tid] = el.classList.contains("folded");
      });
      s.querySelectorAll(".thread-row:not(.composer)").forEach(function (el) { el.remove(); });
      var outdated = s.querySelector(".outdated");
      var outdatedThreads = [];
      list.forEach(function (t) {
        var row = t.outdated ? null : findRow(s, t);
        if (!row) { outdatedThreads.push(t); return; }
        var wrap = document.createElement("div");
        wrap.className = "thread-row " + (t.side === "LEFT" ? "left" : "right");
        wrap.appendChild(threadEl(t, t.id in folds ? folds[t.id] : t.resolved));
        afterThreads(row).after(wrap);
      });
      if (outdated) {
        outdated.hidden = outdatedThreads.length === 0;
        outdated.innerHTML = "";
        if (outdatedThreads.length) {
          var title = document.createElement("div");
          title.className = "outdated-title";
          title.textContent = "▸ " + outdatedThreads.length + " outdated conversation" + (outdatedThreads.length === 1 ? "" : "s");
          var listEl = document.createElement("div");
          listEl.className = "outdated-list";
          outdatedThreads.forEach(function (t) { listEl.appendChild(threadEl(t, t.id in folds ? folds[t.id] : false)); });
          outdated.appendChild(title);
          outdated.appendChild(listEl);
          outdated.classList.add("folded");
        }
      }
      Object.keys(drafts).forEach(function (tid) {
        var el = s.querySelector('.thread[data-tid="' + tid + '"] .reply');
        if (el) { el.querySelector("textarea").value = drafts[tid]; el.classList.add("active"); }
      });
      var open = list.filter(function (t) { return !t.resolved; }).length;
      var badge = s.querySelector(".fhead .threads");
      badge.hidden = open === 0;
      badge.textContent = "💬 " + open;
      badge.title = open + " unresolved conversation" + (open === 1 ? "" : "s");
    });
  };

  function submitReply(replyEl) {
    var thread = replyEl.closest(".thread"), t = thread.__thread, ta = replyEl.querySelector("textarea");
    var text = ta.value.trim();
    if (!text || !t.comments.length) return;
    runAction({ action: "replyThread", commentId: t.comments[0].id, body: text },
      [replyEl.querySelector(".t-reply")],
      function (ok) { if (ok) { ta.value = ""; replyEl.classList.remove("active"); } });
  }

  // ---- Click-to-comment ----
  var addc = document.getElementById("addc"), hoverTarget = null;
  function lineTarget(e) {
    var row = e.target.closest && e.target.closest(".ln");
    if (!row || row.classList.contains("xctx") || row.closest("section.collapsed")) return null;
    if (isSplit) {
      var cell = e.target.closest(".num, .code");
      if (!cell) return null;
      var idx = Array.prototype.indexOf.call(row.children, cell);
      var left = idx < 2;
      var line = left ? row.dataset.o : row.dataset.n;
      if (!line) return null;
      return { row: row, side: left ? "LEFT" : "RIGHT", line: +line, anchor: row.children[left ? 0 : 2] };
    }
    var del = row.classList.contains("del");
    var n = del ? row.dataset.o : row.dataset.n;
    if (!n) return null;
    return { row: row, side: del ? "LEFT" : "RIGHT", line: +n, anchor: row.children[del ? 0 : 1] };
  }
  document.addEventListener("mouseover", function (e) {
    if (e.target === addc) return;
    var t = lineTarget(e);
    if (!t) { addc.style.display = "none"; hoverTarget = null; return; }
    hoverTarget = t;
    var r = t.anchor.getBoundingClientRect();
    addc.style.display = "block";
    addc.style.top = (r.top + window.scrollY) + "px";
    addc.style.left = (r.right - 12 + window.scrollX) + "px";
  });
  addc.addEventListener("click", function () {
    if (!hoverTarget) return;
    openComposer(hoverTarget);
    addc.style.display = "none";
  });
  function openComposer(t) {
    var s = t.row.closest("section.file"), path = s.dataset.path;
    var existing = s.querySelector('.composer[data-at="' + t.side + t.line + '"]');
    if (existing) { existing.querySelector("textarea").focus(); return; }
    var wrap = document.createElement("div");
    wrap.className = "thread-row composer " + (t.side === "LEFT" ? "left" : "right");
    wrap.dataset.at = t.side + t.line;
    wrap.innerHTML = '<div class="thread"><div class="th-head"><span>Comment on ' + (t.side === "LEFT" ? "left line " : "line ") + t.line +
      '</span></div><div class="composer-box"><textarea placeholder="Leave a comment (Markdown supported)"></textarea><div class="acts">' +
      '<span class="hint">⌘↩ to post · Esc to cancel</span><button class="tbtn c-cancel">Cancel</button><button class="tbtn primary c-post">Add comment</button></div></div></div>';
    afterThreads(t.row).after(wrap);
    wrap.__target = { path: path, line: t.line, side: t.side };
    wrap.querySelector("textarea").focus();
  }
  function submitComposer(wrap) {
    var ta = wrap.querySelector("textarea"), text = ta.value.trim(), tg = wrap.__target;
    if (!text) return;
    runAction({ action: "newComment", path: tg.path, line: tg.line, side: tg.side, body: text },
      [wrap.querySelector(".c-post")],
      function (ok) { if (ok) wrap.remove(); });
  }

  // ---- Expand context ----
  var contents = {}, contentQueue = {};
  function gap(h) { return { s: +h.dataset.gs, e: +h.dataset.ge, d: +h.dataset.d }; }
  function xbtn(dir, label, title) { return '<button class="xbtn" data-dir="' + dir + '" title="' + title + '">' + label + "</button>"; }
  function renderExpander(h) {
    var hx = h.querySelector(".hx");
    if (!h.dataset.gs) { hx.innerHTML = ""; return; }
    var g = gap(h), tail = h.classList.contains("tail");
    if (tail) {
      var lines = contents[h.closest("section.file").dataset.path];
      if (lines && g.s > lines.length) { h.remove(); return; }
      hx.innerHTML = xbtn("down", "↓", "Expand below");
      return;
    }
    if (g.e < g.s) {
      // The gap is fully revealed: the hunk header no longer separates anything.
      h.remove();
      return;
    }
    var size = g.e - g.s + 1;
    hx.innerHTML = size <= 20 ? xbtn("all", "↕", "Expand " + size + " hidden line" + (size === 1 ? "" : "s"))
      : xbtn("up", "↑", "Expand up") + xbtn("down", "↓", "Expand down");
  }
  function contextRow(n, d, text) {
    var o = n + d, row = document.createElement("div");
    row.className = "ln ctx xctx" + (isSplit ? " sp" : "");
    row.dataset.o = o; row.dataset.n = n;
    var code = '<span class="code"><span class="mk"> </span>' + (text ? esc(text) : " ") + "</span>";
    row.innerHTML = isSplit
      ? '<span class="num">' + o + "</span>" + code + '<span class="num">' + n + "</span>" + code
      : '<span class="num">' + o + '</span><span class="num">' + n + "</span>" + code;
    return row;
  }
  function doExpand(h, dir) {
    var s = h.closest("section.file"), lines = contents[s.dataset.path];
    if (!lines) return;
    var g = gap(h), tail = h.classList.contains("tail");
    var end = tail ? lines.length : g.e;
    var from, to;
    if (dir === "all") { from = g.s; to = end; }
    else if (dir === "down") { from = g.s; to = Math.min(end, g.s + 19); }
    else { from = Math.max(g.s, end - 19); to = end; }
    var frag = document.createDocumentFragment();
    for (var n = from; n <= to; n++) frag.appendChild(contextRow(n, g.d, lines[n - 1]));
    if (dir === "up") { h.after(frag); h.dataset.ge = from - 1; }
    else { h.before(frag); h.dataset.gs = to + 1; }
    renderExpander(h);
  }
  function expand(h, dir) {
    var s = h.closest("section.file"), path = s.dataset.path;
    if (contents[path]) { doExpand(h, dir); return; }
    (contentQueue[path] = contentQueue[path] || []).push([h, dir]);
    h.classList.add("loading");
    if (contentQueue[path].length === 1) post({ action: "fileContent", path: path });
  }
  window.gitxxFileContent = function (path, text) {
    var lines = text.split("\n");
    if (lines.length && lines[lines.length - 1] === "") lines.pop();
    contents[path] = lines;
    (contentQueue[path] || []).forEach(function (job) { job[0].classList.remove("loading"); doExpand(job[0], job[1]); });
    delete contentQueue[path];
  };
  window.gitxxFileContentFailed = function (path, message) {
    (contentQueue[path] || []).forEach(function (job) {
      job[0].classList.remove("loading");
      job[0].querySelector(".hx").innerHTML = "";
      var err = document.createElement("span");
      err.className = "xerr";
      err.textContent = message || "Couldn't load the file";
      job[0].querySelector(".htext").after(err);
    });
    delete contentQueue[path];
  };
  document.querySelectorAll(".hunk").forEach(renderExpander);

  // ---- Clicks ----
  document.addEventListener("click", function (e) {
    var t = e.target;
    var x = t.closest(".xbtn");
    if (x) { expand(x.closest(".hunk"), x.dataset.dir); return; }
    var thread = t.closest(".thread");
    if (thread && thread.__thread) {
      var th = thread.__thread;
      if (t.closest(".t-fold")) {
        var folded = thread.classList.toggle("folded");
        t.textContent = folded ? "Show" : "Hide";
      } else if (t.closest(".t-resolve")) {
        runAction({ action: "resolveThread", nodeId: th.nodeId, resolve: !th.resolved }, [t]);
      } else if (t.closest(".t-reply")) {
        submitReply(t.closest(".reply"));
      } else if (t.closest(".t-cancel")) {
        var reply = t.closest(".reply");
        reply.querySelector("textarea").value = "";
        reply.classList.remove("active");
      }
      return;
    }
    var composer = t.closest(".composer");
    if (composer) {
      if (t.closest(".c-post")) submitComposer(composer);
      else if (t.closest(".c-cancel")) composer.remove();
      return;
    }
    if (t.closest(".outdated-title")) {
      var od = t.closest(".outdated");
      var nowFolded = od.classList.toggle("folded");
      t.textContent = (nowFolded ? "▸ " : "▾ ") + t.textContent.slice(2);
      return;
    }
    var s = t.closest && t.closest("section.file");
    if (!s) return;
    if (t.closest(".chev")) {
      collapse(s, !s.classList.contains("collapsed"));
    } else if (t.closest(".viewed")) {
      e.preventDefault();
      toggleViewed(s);
    } else if (t.closest(".open")) {
      post({ action: "openInEditor", path: s.dataset.path });
    } else if (t.closest(".load")) {
      s.classList.add("loaded");
    } else if (t.closest(".fpath") && s.classList.contains("collapsed")) {
      collapse(s, false);
    }
  });
  document.addEventListener("focusin", function (e) {
    var reply = e.target.closest && e.target.closest(".reply");
    if (reply) reply.classList.add("active");
  });

  // ---- Filter ----
  window.gitxxFilter = function (query) {
    var q = (query || "").toLowerCase();
    sections.forEach(function (s) { s.classList.toggle("filtered", !!q && s.dataset.path.toLowerCase().indexOf(q) < 0); });
    shown = sections.filter(function (s) { return !s.classList.contains("filtered"); });
    spy();
  };

  // ---- Keys: j/k or ]/[ next/previous file, v viewed, c conversation, s checks ----
  document.addEventListener("keydown", function (e) {
    var t = e.target;
    if (editing(t)) {
      if (t.tagName === "TEXTAREA" && e.key === "Enter" && e.metaKey) {
        var reply = t.closest(".reply"), composer = t.closest(".composer");
        if (reply) submitReply(reply); else if (composer) submitComposer(composer);
        e.preventDefault();
      } else if (e.key === "Escape") {
        var c = t.closest(".composer");
        if (c && !t.value.trim()) { c.remove(); e.preventDefault(); }
        else t.blur();
      }
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "j" || e.key === "]") stepFile(1);
    else if (e.key === "k" || e.key === "[") stepFile(-1);
    else if (e.key === "v" && byPath[current]) toggleViewed(byPath[current]);
    else if (e.key === "c") post({ action: "switchTab", tab: "overview" });
    else if (e.key === "s") post({ action: "switchTab", tab: "checks" });
    else return;
    e.preventDefault();
  });

  var btt = document.createElement("button");
  btt.id = "backToTop";
  btt.title = "Back to top";
  btt.innerHTML = "<span>↑</span><span>Top</span>";
  btt.onclick = function () { window.scrollTo({ top: 0, behavior: "smooth" }); };
  document.body.appendChild(btt);

  root.style.setProperty("--sticky-top", inset() + "px");
})();
"""#
}
