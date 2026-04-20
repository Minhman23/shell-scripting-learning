#!/usr/bin/env bash
# fkit-reporter-harden.sh — strip auto-update + settings.json rewrite blocks
# from fkit-reporter.sh and re-assert filter-wrapper routing in settings.json.
#
# Run:
#   - once after installing the filter
#   - after every /report-claude update (the skill invokes this automatically)
#
# Idempotent: safe to run repeatedly. Exits 0 on success, non-zero on any error.

set -euo pipefail

REPORTER="$HOME/.claude/hooks/fkit-reporter.sh"
FILTER="$HOME/.claude/hooks/fkit-reporter-filter.sh"
HASH_FILE="$HOME/.claude/hooks/fkit-reporter.sha256"
SETTINGS="$HOME/.claude/settings.json"

[[ -f "$REPORTER" ]] || { echo "[harden] reporter not found: $REPORTER" >&2; exit 1; }
[[ -f "$FILTER" ]]   || { echo "[harden] filter not found: $FILTER" >&2; exit 1; }

# ── 1. Strip every settings.json rewrite block and associated auto-update logic.
python3 - "$REPORTER" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
orig = src

# Pattern: any python3 -c '...hooks rewrite...' block used by reporter to
# re-register hooks in settings.json. Matches both the inline ` && \` variant
# (--flush, --update) and the bare variant (background auto-update).
rewrite_re = re.compile(
    r"[ \t]*(?:\[\[\s*-f\s+\"\$_settings\"\s*\]\]\s*&&\s*)?"
    r"python3\s+-c\s+'\s*\nimport json,sys[\s\S]*?"
    r"json\.dump\(s,f,indent=2\)\s*\n'\s*\"\$_settings\"[^\n]*\n"
    r"(?:\s*echo[^\n]*\n)?"
)
src = rewrite_re.sub("    # [harden] settings.json rewrite stripped\n", src)

# Strip bare `curl ... | bash` / `mv "$_tmp" "$_SELF_PATH"` auto-replace blocks
# in the Notification session_start background path. Match the subshell.
bg_re = re.compile(
    r"[ \t]*_SELF_PATH=\"\$\(realpath[^\n]*\n\s*\(\s*\n"
    r"[\s\S]*?echo \"\$_latest\" > \"\$HOME/\.fkit-reporter-updated\"[^\n]*\n"
    r"\s*\)\s*&>/dev/null\s*&\s*\n"
    r"\s*disown[^\n]*\n"
    r"\s*unset _SELF_PATH\s*\n",
    re.MULTILINE,
)
src = bg_re.sub("    # [harden] background session_start auto-update stripped\n", src)

# Strip --flush auto-update block (curl version check + download + mv).
flush_re = re.compile(
    r"[ \t]*# ── Auto-update check[^\n]*\n"
    r"[\s\S]*?unset _ver_info _latest _tmp _SCRIPT_PATH\s*\n",
    re.MULTILINE,
)
src = flush_re.sub("  # [harden] --flush auto-update stripped\n", src)

if src != orig:
    p.write_text(src)
    print("[harden] stripped auto-update / settings.json rewrite blocks")
else:
    print("[harden] reporter already clean")
PY

# ── 2. Sanity: bash syntax still valid
bash -n "$REPORTER" || { echo "[harden] reporter syntax broken — aborting" >&2; exit 2; }

# ── 3. Update baseline hash so filter recognizes the patched reporter
shasum -a 256 "$REPORTER" | awk '{print $1}' > "$HASH_FILE"
echo "[harden] baseline: $(cat "$HASH_FILE")"

# ── 4. Force settings.json routing through filter wrapper
if [[ -f "$SETTINGS" ]]; then
  python3 - "$SETTINGS" "$FILTER" <<'PY'
import json, sys
path, filt = sys.argv[1], sys.argv[2]
s = json.load(open(path))
changed = 0
for ev, hooks in (s.get("hooks") or {}).items():
    for h in hooks:
        for c in h.get("hooks", []):
            cmd = c.get("command", "")
            if cmd.endswith("/fkit-reporter.sh") and "fkit-reporter-filter.sh" not in cmd:
                c["command"] = cmd.replace("/fkit-reporter.sh", "/fkit-reporter-filter.sh")
                changed += 1
json.dump(s, open(path, "w"), indent=2)
print(f"[harden] rewrote {changed} hook entries in settings.json")
PY
fi

# ── 5. Run auto-review to confirm PASS
if [[ -f "$HOME/.claude/hooks/fkit-filter-auto-review.py" ]]; then
  python3 "$HOME/.claude/hooks/fkit-filter-auto-review.py" "$REPORTER" "$FILTER" \
    | tail -1
fi

echo "[harden] done"
