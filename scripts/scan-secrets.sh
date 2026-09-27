#!/usr/bin/env bash
# Secret scanning with gitleaks (config: .gitleaks.toml).
#
#   scripts/scan-secrets.sh            full scan: every commit + files not yet committed
#   scripts/scan-secrets.sh staged     staged changes only (pre-commit hook)
#   scripts/scan-secrets.sh push <remote-sha> <local-sha>
#                                      commits about to be pushed (pre-push hook)
#   scripts/scan-secrets.sh install    point git at .githooks so the hooks run automatically
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
config="$root/.gitleaks.toml"
zero="0000000000000000000000000000000000000000"

if [ "${1:-}" = "install" ]; then
    git config core.hooksPath .githooks
    echo "Secret scanning hooks installed (core.hooksPath=.githooks)."
    exit 0
fi

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "gitleaks is not installed. Install it with: brew install gitleaks" >&2
    exit 1
fi

common=(--config "$config" --redact --no-banner --verbose)

case "${1:-all}" in
    staged)
        gitleaks git --staged --pre-commit "${common[@]}" .
        ;;
    push)
        remote_sha="${2:?remote sha}"
        local_sha="${3:?local sha}"
        if [ "$local_sha" = "$zero" ]; then exit 0; fi   # deleting a remote branch
        if [ "$remote_sha" = "$zero" ]; then
            range="$local_sha --not --remotes"            # new branch: commits no remote has yet
        else
            range="$remote_sha..$local_sha"
        fi
        gitleaks git --log-opts="$range" "${common[@]}" .
        ;;
    all)
        echo "== Commit history"
        gitleaks git "${common[@]}" .
        echo "== Uncommitted and untracked files"
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        # Only files git would commit (tracked + untracked, minus .gitignore), not build output.
        { git ls-files -z; git ls-files -z --others --exclude-standard; } |
            while IFS= read -r -d '' f; do
                [ -f "$f" ] || continue
                mkdir -p "$tmp/$(dirname "$f")"
                cp "$f" "$tmp/$f"
            done
        gitleaks dir "${common[@]}" "$tmp"
        ;;
    *)
        sed -n '2,9p' "$0" >&2
        exit 2
        ;;
esac
