#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  fkit-filter — Interactive CWD filter manager for FKit Reporter          ║
# ║                                                                          ║
# ║  PURPOSE: Prevent FKit Reporter from leaking personal Claude Code        ║
# ║  session data (prompts, messages, tokens) from non-work directories.     ║
# ║  Only sessions whose CWD matches an allowed prefix are reported.         ║
# ║                                                                          ║
# ║  ARCHITECTURE:                                                           ║
# ║    1. Filter wrapper (fkit-reporter-filter.sh) intercepts ALL hook       ║
# ║       events BEFORE they reach fkit-reporter.sh                          ║
# ║    2. CWD check: only events from allowed folders pass through           ║
# ║    3. Scrub: removes non-allowed events from queue/state/overflow        ║
# ║    4. Integrity: SHA256 hash blocks tampered reporter versions           ║
# ║    5. Auto-review: when reporter updates, Python script analyzes         ║
# ║       new code for leak vectors — auto-approves if safe, blocks if not   ║
# ║                                                                          ║
# ║  LEAK VECTORS ADDRESSED:                                                 ║
# ║    - Incoming events with non-allowed CWD                                ║
# ║    - Crash recovery replaying non-allowed sessions                       ║
# ║    - Auto-backfill scanning all transcripts                              ║
# ║    - --backfill CLI command (disabled entirely)                          ║
# ║    - --flush self-invocation bypassing filter                            ║
# ║    - Overflow file containing non-allowed events                         ║
# ║    - .sending.* / .collecting.* temp files from flush                    ║
# ║    - State files (.last_uuid) triggering recovery for non-allowed CWD    ║
# ║    - Reporter self-update introducing new unmonitored code paths         ║
# ║                                                                          ║
# ║  USAGE:                                                                  ║
# ║    bash <(curl -fsSL https://fkit.run/filter)                            ║
# ║    — or —                                                                ║
# ║    fkit-filter              (if alias installed)                          ║
# ║                                                                          ║
# ║  PREREQUISITES: Claude Code + FKit Reporter + python3                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── File paths ──────────────────────────────────────────────────────────────
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
FILTER="$HOOKS_DIR/fkit-reporter-filter.sh"        # The filter wrapper we install
ORIGINAL="$HOOKS_DIR/fkit-reporter.sh"              # The real reporter hook
CONF="$HOOKS_DIR/fkit-filter.conf"                  # Allowed CWD prefixes (one per line)
HASH_FILE="$HOOKS_DIR/fkit-reporter.sha256"         # SHA256 baseline of reporter
AUTO_REVIEW="$HOOKS_DIR/fkit-filter-auto-review.py" # Auto-review script for leak analysis
HARDEN="$HOOKS_DIR/fkit-reporter-harden.sh"         # Restores filter routing after reporter hijacks settings.json
REVIEW_LOG="$HOOKS_DIR/fkit-filter-review.log"      # Audit trail of all reviews

# ── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
  C='\033[0;36m'; B='\033[1m'; D='\033[2m'; N='\033[0m'
else
  G=''; R=''; Y=''; C=''; B=''; D=''; N=''
fi

ok()   { echo -e "  ${G}✓${N} $1"; }
warn() { echo -e "  ${Y}!${N} $1"; }
fail() { echo -e "  ${R}✗${N} $1"; exit 1; }
info() { echo -e "  ${C}→${N} $1"; }

# ── OS Detection ────────────────────────────────────────────────────────────
OS="unknown"
case "$(uname -s 2>/dev/null)" in
  Darwin*)               OS="macos"   ;;
  Linux*)                OS="linux"   ;;
  MINGW*|MSYS*|CYGWIN*)  OS="windows" ;;
esac

resolve_path() {
  local p="$1"
  p="${p/#\~/$HOME}"
  p="${p//\\//}"
  p="${p%/}"
  echo "$p"
}

# Resolve actual filesystem case for each path component.
# macOS is case-insensitive — user types "~/Dev/Fpt", real dir is "FPT".
# Without this, CWD prefix matching could silently fail on case-sensitive
# systems (Linux) or produce confusing mismatches in logs.
resolve_case() {
  local p="$1"
  [[ ! -e "$p" ]] && { echo "$p"; return; }
  python3 -c "
import os, sys
path = sys.argv[1]
if not os.path.exists(path):
    print(path); sys.exit()
parts = path.split(os.sep)
resolved = os.sep
for part in parts[1:]:
    if not part: continue
    try:
        entries = os.listdir(resolved)
        matched = next((e for e in entries if e.lower() == part.lower()), part)
        resolved = os.path.join(resolved, matched)
    except OSError:
        resolved = os.path.join(resolved, part)
print(resolved)
" "$p" 2>/dev/null || echo "$p"
}

# ── Paths management ────────────────────────────────────────────────────────
# PATHS array holds allowed CWD prefixes.
# Only events from directories matching these prefixes are reported to FKit.
PATHS=()

load_paths() {
  PATHS=()
  [[ -f "$CONF" ]] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs 2>/dev/null)"
    [[ -n "$line" ]] && PATHS+=("$line")
  done < "$CONF"
}

save_paths() {
  mkdir -p "$HOOKS_DIR" 2>/dev/null || true
  {
    echo "# fkit-filter.conf — allowed CWD prefixes (one per line)"
    echo "# Only events from these folders will be reported to FKit"
    for p in "${PATHS[@]}"; do echo "$p"; done
  } > "$CONF"
}

show_paths() {
  if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo -e "    ${D}(none)${N}"
  else
    for i in "${!PATHS[@]}"; do
      local tag=""
      [[ ! -d "${PATHS[$i]}" ]] && tag=" ${Y}(not found)${N}"
      echo -e "    $((i+1)). ${C}${PATHS[$i]}${N}${tag}"
    done
  fi
}

add_path() {
  local examples
  case "$OS" in
    macos)   examples="~/Dev/FPT  ~/projects/work" ;;
    linux)   examples="~/dev/company  /opt/projects" ;;
    windows) examples="C:\\\\Projects  D:\\\\Work  ~/Dev" ;;
    *)       examples="~/Dev/FPT" ;;
  esac
  echo ""
  echo -e "  Enter folder path ${D}(e.g. ${examples})${N}"
  echo -ne "  > "
  read -r raw
  [[ -z "$raw" ]] && return
  local resolved corrected
  resolved=$(resolve_path "$raw")
  # Auto-correct case to match actual filesystem (e.g. "Fpt" → "FPT")
  corrected=$(resolve_case "$resolved")
  if [[ "$corrected" != "$resolved" ]] && [[ -d "$corrected" ]]; then
    info "Case corrected: ${resolved} → ${corrected}"
    resolved="$corrected"
  fi
  for p in "${PATHS[@]+"${PATHS[@]}"}"; do
    [[ "$p" == "$resolved" ]] && { warn "Already added: $resolved"; return; }
  done
  [[ ! -d "$resolved" ]] && warn "Path not found: $resolved (added anyway)"
  PATHS+=("$resolved")
  ok "Added: $resolved"
}

remove_path() {
  [[ ${#PATHS[@]} -eq 0 ]] && { warn "Nothing to remove"; return; }
  echo ""
  echo "  Enter number to remove:"
  show_paths
  echo -ne "  > "
  read -r num
  if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#PATHS[@]} )); then
    local removed="${PATHS[$((num-1))]}"
    unset 'PATHS[$((num-1))]'
    local tmp=("${PATHS[@]+"${PATHS[@]}"}")
    PATHS=("${tmp[@]+"${tmp[@]}"}")
    ok "Removed: $removed"
  else
    warn "Invalid selection"
  fi
}

# ── Folder editor submenu ──────────────────────────────────────────────────
edit_folders() {
  while true; do
    echo ""
    echo -e "  ${B}Allowed folders${N} ${D}(only these get reported)${N}:"
    show_paths
    echo ""
    echo "  [1] Add folder"
    [[ ${#PATHS[@]} -gt 0 ]] && echo "  [2] Remove folder"
    echo -e "  [${G}0${N}] Done"
    echo -ne "  > "
    read -r choice
    case "$choice" in
      1) add_path ;;
      2) [[ ${#PATHS[@]} -gt 0 ]] && remove_path || warn "Invalid" ;;
      0) break ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

# ── Integrity helpers ──────────────────────────────────────────────────────
get_hook_hash() {
  [[ -f "$ORIGINAL" ]] && shasum -a 256 "$ORIGINAL" 2>/dev/null | cut -d' ' -f1
}

get_saved_hash() {
  [[ -f "$HASH_FILE" ]] && cat "$HASH_FILE" 2>/dev/null
}

save_hash() {
  local h
  h=$(get_hook_hash)
  [[ -n "$h" ]] && echo "$h" > "$HASH_FILE"
}

check_integrity() {
  local current saved
  current=$(get_hook_hash)
  saved=$(get_saved_hash)
  [[ -z "$current" ]] && { warn "fkit-reporter.sh not found"; return 1; }
  [[ -z "$saved" ]] && { warn "No baseline hash — run install first"; return 1; }
  if [[ "$current" == "$saved" ]]; then
    ok "fkit-reporter.sh unchanged"
    return 0
  else
    echo -e "  ${R}✗${N} fkit-reporter.sh ${R}CHANGED${N} (hash mismatch)"
    echo -e "    saved:   ${D}$saved${N}"
    echo -e "    current: ${D}$current${N}"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALL — writes filter wrapper + auto-review script + patches settings
# ═══════════════════════════════════════════════════════════════════════════
do_install() {
  # Folder selection
  if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo ""
    warn "No folders configured — add at least one"
  fi
  edit_folders
  if [[ ${#PATHS[@]} -eq 0 ]]; then
    warn "No folders added. Cancelled."
    return
  fi

  echo ""
  echo -e "${B}Installing...${N}"

  # Save config
  save_paths
  ok "Config saved"

  # ── Write filter wrapper ────────────────────────────────────────────────
  # This is the main security gate. It sits between Claude Code hooks and
  # fkit-reporter.sh. Every hook event passes through here first.
  cat > "$FILTER" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════╗
# ║  fkit-reporter-filter.sh — CWD filter wrapper for FKit Reporter      ║
# ║                                                                      ║
# ║  HOW IT WORKS:                                                       ║
# ║  1. Claude Code fires a hook event (Notification/Stop/UserPrompt)    ║
# ║  2. This script intercepts — checks CWD against allowed prefixes     ║
# ║  3. If CWD matches: scrub queue → clean state → pass to reporter     ║
# ║  4. If CWD doesn't match: silently drop the event                    ║
# ║  5. After reporter runs: scrub again to catch any leaked data        ║
# ║                                                                      ║
# ║  INTEGRITY:                                                          ║
# ║  - SHA256 hash of reporter.sh checked on every invocation            ║
# ║  - If hash changed: auto-review script analyzes for leak vectors     ║
# ║  - PASS → auto-approve, update hash, resume normal operation         ║
# ║  - FAIL → block ALL events, log findings, require manual review      ║
# ║                                                                      ║
# ║  LEAK VECTORS ADDRESSED:                                             ║
# ║  - [incoming]  CWD check blocks non-allowed events at the gate       ║
# ║  - [recovery]  _pre_clean_state removes non-allowed .last_uuid       ║
# ║  - [backfill]  --backfill CLI command disabled entirely               ║
# ║  - [flush]     pre-scrub + post-scrub around reporter execution      ║
# ║  - [overflow]  _scrub cleans overflow file                           ║
# ║  - [temp]      _scrub cleans .sending.* and .collecting.* files      ║
# ║  - [state]     _scrub removes state files for non-allowed sessions   ║
# ║  - [timing]    lastflush trick prevents flush before post-scrub      ║
# ║  - [update]    auto-review blocks reporter with new leak vectors     ║
# ╚═══════════════════════════════════════════════════════════════════════╝

REAL_HOOK="$HOME/.claude/hooks/fkit-reporter.sh"
CONF="$HOME/.claude/hooks/fkit-filter.conf"
QUEUE_DIR="$HOME/.fkit-reporter-queue"
OVERFLOW="$HOME/.fkit-reporter-queue.overflow"
STATE_DIR="$HOME/.fkit-reporter-state"
HASH_FILE="$HOME/.claude/hooks/fkit-reporter.sha256"

# ── Integrity check with auto-review ────────────────────────────────────
# Called on every hook invocation. Compares reporter SHA256 against saved
# baseline. On mismatch: runs auto-review Python script to analyze the
# new reporter for leak vectors before deciding to approve or block.
#
# AUTO-REVIEW CHECKS (see fkit-filter-auto-review.py):
#   1. CWD field presence  — filter depends on events having "cwd" key
#   2. CLI flags coverage  — new --flags not in filter case = bypass risk
#   3. Data storage paths  — new paths not scrubbed = data persists
#   4. RCE patterns        — curl|bash, eval(curl) = arbitrary code exec
#   5. Events without CWD  — escape CWD filtering (scrub catches post-hoc)
#
# FLOW:
#   hash match     → return 0 (proceed normally)
#   hash mismatch  → run auto-review
#     review PASS  → save new hash, return 0 (auto-approved)
#     review FAIL  → return 1 (block all events, require manual review)
#     no script    → return 1 (block, safe default)
_check_hook_integrity() {
  [[ ! -f "$REAL_HOOK" ]] && return 0
  local current_hash
  current_hash=$(shasum -a 256 "$REAL_HOOK" 2>/dev/null | cut -d' ' -f1)
  [[ -z "$current_hash" ]] && return 0
  if [[ ! -f "$HASH_FILE" ]]; then
    echo "$current_hash" > "$HASH_FILE"
    return 0
  fi
  local saved_hash
  saved_hash=$(cat "$HASH_FILE" 2>/dev/null)
  if [[ "$current_hash" != "$saved_hash" ]]; then
    # ── Auto-review: analyze new reporter for leak vectors ──
    local _review_script="$HOME/.claude/hooks/fkit-filter-auto-review.py"
    local _review_log="$HOME/.claude/hooks/fkit-filter-review.log"

    if [[ -f "$_review_script" ]]; then
      local _review_out _review_rc
      _review_out=$(python3 "$_review_script" "$REAL_HOOK" "$0" 2>&1)
      _review_rc=$?

      # Log every review to audit trail
      {
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
        echo "hash: $saved_hash -> $current_hash"
        echo "$_review_out"
        echo ""
      } >> "$_review_log" 2>/dev/null

      if [[ $_review_rc -eq 0 ]]; then
        # PASS — auto-approve: save new hash and resume
        echo "$current_hash" > "$HASH_FILE"
        echo "[fkit-filter] Reporter updated — auto-review PASSED, approved." >&2
        echo "[fkit-filter] $_review_out" >&2
        return 0
      else
        # FAIL — block and show findings
        echo "[fkit-filter] BLOCKED: reporter changed, auto-review FAILED." >&2
        echo "[fkit-filter] $_review_out" >&2
        echo "[fkit-filter] Run: fkit-filter (to manually review & approve)" >&2
        return 1
      fi
    fi

    # No auto-review script found — block by default (safe)
    echo "[fkit-filter] BLOCKED: fkit-reporter.sh changed (hash mismatch)." >&2
    echo "[fkit-filter]   saved:   $saved_hash" >&2
    echo "[fkit-filter]   current: $current_hash" >&2
    echo "[fkit-filter]   Run: fkit-filter (to review & approve)" >&2
    return 1
  fi
  return 0
}

# ── Load allowed CWD prefixes from config ───────────────────────────────
_ALLOWED=()
if [[ -f "$CONF" ]]; then
  while IFS= read -r _line; do
    _line="${_line%%#*}"
    _line="$(echo "$_line" | xargs 2>/dev/null)"
    [[ -n "$_line" ]] && _ALLOWED+=("$_line")
  done < "$CONF"
fi
# No allowed paths = no reporting at all (safe default)
[[ ${#_ALLOWED[@]} -eq 0 ]] && exit 0

# ── CWD prefix check ───────────────────────────────────────────────────
# Returns 0 if CWD starts with any allowed prefix.
# Forward slashes normalized for cross-platform support.
_cwd_allowed() {
  local cwd="$1"
  cwd="${cwd//\\//}"
  for prefix in "${_ALLOWED[@]}"; do
    [[ "$cwd" == "$prefix"* ]] && return 0
  done
  return 1
}

# ── Scrub: remove non-allowed events from ALL data locations ────────────
# This is the defense-in-depth layer. Even if a non-allowed event somehow
# gets queued (e.g., from crash recovery), scrub removes it before flush.
#
# Locations scrubbed:
#   - Queue directory: $HOME/.fkit-reporter-queue/{project}/{session}.jsonl
#   - Overflow file:   $HOME/.fkit-reporter-queue.overflow
#   - Temp files:      $HOME/.fkit-reporter-queue.sending.*
#   - Temp dirs:       $HOME/.fkit-reporter-queue.collecting.*
#   - State files:     $HOME/.fkit-reporter-state/{session}.last_uuid
#     (state files trigger crash recovery — removing them prevents replay
#      of non-allowed sessions on next session_start)
_scrub() {
  python3 - "$CONF" "$QUEUE_DIR" "$OVERFLOW" "$STATE_DIR" "$HOME" << 'PY' 2>/dev/null || true
import json, os, sys
conf_path, qdir, ovf_path, sdir, home = sys.argv[1:6]
allowed = []
try:
    with open(conf_path) as f:
        for line in f:
            line = line.split('#')[0].strip()
            if line: allowed.append(line.replace('\\', '/'))
except: pass
if not allowed: sys.exit(0)
def norm(p): return p.replace('\\', '/')
def cwd_ok(line):
    try:
        cwd = norm(json.loads(line.strip()).get("cwd", ""))
        return any(cwd.startswith(a) for a in allowed)
    except: return False
def scrub_file(fp):
    if not os.path.isfile(fp): return
    try:
        with open(fp) as f: lines = f.readlines()
    except: return
    kept = [l for l in lines if cwd_ok(l)]
    if len(kept) == len(lines): return
    if kept:
        with open(fp, "w") as f: f.writelines(kept)
    else: os.remove(fp)
# Scrub queue directory (2-level: project/session.jsonl)
if os.path.isdir(qdir):
    for proj in os.listdir(qdir):
        pdir = os.path.join(qdir, proj)
        if not os.path.isdir(pdir): continue
        for fn in os.listdir(pdir):
            if fn.endswith(".jsonl"): scrub_file(os.path.join(pdir, fn))
        try:
            if not os.listdir(pdir): os.rmdir(pdir)
        except: pass
# Scrub overflow archive
scrub_file(ovf_path)
# Scrub temp files from flush (sending/collecting)
for fn in os.listdir(home):
    if fn.startswith(".fkit-reporter-queue.sending.") or fn.startswith(".fkit-reporter-queue.collecting."):
        fp = os.path.join(home, fn)
        if os.path.isfile(fp): scrub_file(fp)
        elif os.path.isdir(fp):
            for sf in os.listdir(fp):
                if sf.endswith(".jsonl"): scrub_file(os.path.join(fp, sf))
# Scrub state files — remove .last_uuid for non-allowed sessions
# This prevents crash recovery from replaying non-allowed sessions
if os.path.isdir(sdir):
    projects_dir = os.path.expanduser("~/.claude/projects")
    for state_fn in list(os.listdir(sdir)):
        if not state_fn.endswith(".last_uuid"): continue
        session_id = state_fn[:-len(".last_uuid")]
        cwd_found = ""
        if os.path.isdir(projects_dir):
            for root, dirs, files in os.walk(projects_dir):
                if session_id + ".jsonl" in files:
                    tp = os.path.join(root, session_id + ".jsonl")
                    try:
                        with open(tp, encoding="utf-8") as f:
                            for line in f:
                                line = line.strip()
                                if not line: continue
                                try:
                                    e = json.loads(line)
                                    if e.get("cwd"): cwd_found = norm(e["cwd"]); break
                                except: pass
                    except: pass
                    break
        if not any(cwd_found.startswith(a) for a in allowed):
            try: os.remove(os.path.join(sdir, state_fn))
            except: pass
PY
}

# ── Pre-clean state: remove non-allowed .last_uuid BEFORE reporter runs ─
# WHY: Reporter's crash recovery (on session_start) iterates state files
# and replays missed messages. If non-allowed .last_uuid exist, recovery
# generates events for personal sessions. Pre-cleaning prevents this.
#
# DIFFERENCE from _scrub: this runs BEFORE reporter, _scrub runs AFTER.
# Belt-and-suspenders — pre-clean prevents generation, scrub catches leaks.
_pre_clean_state() {
  [[ -d "$STATE_DIR" ]] || return 0
  python3 - "$CONF" "$STATE_DIR" << 'PY' 2>/dev/null || true
import json, os, sys
conf_path, sdir = sys.argv[1], sys.argv[2]
allowed = []
try:
    with open(conf_path) as f:
        for line in f:
            line = line.split('#')[0].strip()
            if line: allowed.append(line.replace('\\', '/'))
except: pass
if not allowed: sys.exit(0)
def norm(p): return p.replace('\\', '/')
projects_dir = os.path.expanduser("~/.claude/projects")
for state_fn in list(os.listdir(sdir)):
    if not state_fn.endswith(".last_uuid"): continue
    session_id = state_fn[:-len(".last_uuid")]
    cwd_found = ""
    if os.path.isdir(projects_dir):
        for root, dirs, files in os.walk(projects_dir):
            if session_id + ".jsonl" in files:
                tp = os.path.join(root, session_id + ".jsonl")
                try:
                    with open(tp, encoding="utf-8") as f:
                        for line in f:
                            line = line.strip()
                            if not line: continue
                            try:
                                e = json.loads(line)
                                if e.get("cwd"): cwd_found = norm(e["cwd"]); break
                            except: pass
                except: pass
                break
    if not any(cwd_found.startswith(a) for a in allowed):
        try: os.remove(os.path.join(sdir, state_fn))
        except: pass
PY
}

# ── CLI flag routing ────────────────────────────────────────────────────
# Reporter supports several CLI flags. We intercept them here:
#   --status    → pass through (read-only, no data exfiltration)
#   --update    → pass through (hash change caught by integrity check)
#   --flush     → scrub before + after (reporter re-invokes itself inside)
#   --backfill  → BLOCKED (scans ALL transcripts, massive leak vector)
#   --audit     → local-only leak audit (no data sent anywhere)
#   (default)   → normal event processing with CWD check
case "${1:-}" in
  --status)   exec "$REAL_HOOK" "$@" ;;
  --update)   exec "$REAL_HOOK" "$@" ;;
  --flush)
    # IMPORTANT: --flush is special because reporter's --flush creates a
    # synthetic session_start event and re-invokes ITSELF (not the filter).
    # This triggers crash recovery + auto-backfill inside the reporter,
    # bypassing our CWD check. Mitigations:
    #   1. _pre_clean_state removes non-allowed .last_uuid → no recovery
    #   2. _scrub before: clean queue before flush sends anything
    #   3. _scrub after: catch any events generated during flush
    #   4. pre-flush backup: for diffing if hash changes
    _scrub
    _pre_clean_state
    cp "$REAL_HOOK" "${REAL_HOOK}.pre-flush" 2>/dev/null || true
    "$REAL_HOOK" "$@"
    _scrub
    exit 0
    ;;
  --backfill) echo "[fkit-filter] backfill disabled."; exit 0 ;;
  --audit)
    # Local-only leak audit — checks queue/state for non-allowed events.
    # No data is sent to any server.
    echo "[fkit-filter] Leak audit"
    python3 - "$CONF" "$QUEUE_DIR" "$OVERFLOW" "$STATE_DIR" "$HOME" << 'AUDIT_PY'
import json, os, sys
conf_path, qdir, ovf_path, sdir, home = sys.argv[1:6]
allowed = []
try:
    with open(conf_path) as f:
        for line in f:
            line = line.split('#')[0].strip()
            if line: allowed.append(line.replace('\\', '/'))
except: pass
print(f"  Allowed: {allowed}")
def norm(p): return p.replace('\\', '/')
def cwd_ok(cwd):
    return any(norm(cwd).startswith(a) for a in allowed)
total = non_allowed = no_cwd = 0
if os.path.isdir(qdir):
    for proj in os.listdir(qdir):
        pdir = os.path.join(qdir, proj)
        if not os.path.isdir(pdir): continue
        for fn in os.listdir(pdir):
            if not fn.endswith(".jsonl"): continue
            try:
                with open(os.path.join(pdir, fn)) as f:
                    for line in f:
                        total += 1
                        try:
                            cwd = json.loads(line.strip()).get("cwd", "")
                            if not cwd: no_cwd += 1
                            elif not cwd_ok(cwd): non_allowed += 1
                        except: pass
            except: pass
non_state = 0; total_state = 0
projects_dir = os.path.expanduser("~/.claude/projects")
if os.path.isdir(sdir):
    for sf in os.listdir(sdir):
        if not sf.endswith(".last_uuid"): continue
        total_state += 1
        sid = sf[:-len(".last_uuid")]; cwd_found = ""
        if os.path.isdir(projects_dir):
            for root, dirs, files in os.walk(projects_dir):
                if sid + ".jsonl" in files:
                    try:
                        with open(os.path.join(root, sid + ".jsonl"), encoding="utf-8") as f:
                            for line in f:
                                line = line.strip()
                                if not line: continue
                                try:
                                    e = json.loads(line)
                                    if e.get("cwd"): cwd_found = norm(e["cwd"]); break
                                except: pass
                    except: pass
                    break
        if not any(cwd_found.startswith(a) for a in allowed): non_state += 1
print(f"  Queue: {total} events ({non_allowed} non-allowed, {no_cwd} no-cwd)")
print(f"  State: {total_state} files ({non_state} non-allowed)")
issues = non_allowed + no_cwd + non_state
print(f"  {'OK' if issues == 0 else str(issues) + ' potential leaks'}")
AUDIT_PY
    exit 0
    ;;
esac

# ── Main event processing ──────────────────────────────────────────────
# Integrity check — blocks if reporter was tampered/updated
if ! _check_hook_integrity; then exit 0; fi

# Read hook payload from stdin
PAYLOAD=$(cat)
[[ -z "$PAYLOAD" ]] && exit 0

# Extract CWD from payload JSON
CWD=$(python3 -c "import json,sys;print(json.load(sys.stdin).get('cwd',''))" <<< "$PAYLOAD" 2>/dev/null) || CWD=""

# Only process if CWD matches an allowed prefix
if _cwd_allowed "$CWD"; then
  # 1. Pre-scrub: remove any non-allowed events already in queue
  _scrub
  # 2. Pre-clean: remove state files for non-allowed sessions
  #    (prevents crash recovery from replaying personal sessions)
  _pre_clean_state
  # 3. Lastflush trick: set flush timestamp to NOW so reporter thinks
  #    it just flushed — prevents immediate flush during this invocation.
  #    This gives post-scrub a chance to clean before next flush cycle.
  #    Exception: Stop events set FORCE_FLUSH=1 in reporter, overriding this.
  #    But Stop events don't trigger crash recovery/backfill, so it's safe.
  date +%s > "$HOME/.fkit-reporter-lastflush" 2>/dev/null || true
  # 4. Pass event to real reporter
  echo "$PAYLOAD" | "$REAL_HOOK"
  # 5. Post-scrub: catch any non-allowed events generated during execution
  #    (e.g., auto-backfill scanning all transcripts on session_start)
  _scrub
fi
exit 0
WRAPPER_EOF

  chmod +x "$FILTER"
  ok "Filter wrapper installed"

  # ── Write auto-review script ──────────────────────────────────────────
  # This Python script analyzes fkit-reporter.sh for leak vectors.
  # Called automatically by the filter when reporter hash changes.
  # Survives filter reinstalls (separate file, not overwritten by filter).
  cat > "$AUTO_REVIEW" << 'REVIEW_EOF'
#!/usr/bin/env python3
"""
fkit-filter-auto-review.py — Automated leak-vector analysis of fkit-reporter.sh

Called by fkit-reporter-filter.sh when reporter SHA256 hash changes (new version).
Analyzes the new reporter code for patterns that could leak personal session data.

EXIT CODES:
  0 = PASS  → safe to auto-approve (no critical issues found)
  1 = FAIL  → block all events, require manual review

CHECKS PERFORMED:
  1. CWD FIELD PRESENCE — filter depends on events having "cwd" key for prefix
     matching. If reporter stops including "cwd", ALL events pass through
     unfiltered. CRITICAL: < 3 references = likely removed.

  2. CLI FLAGS COVERAGE — reporter's $1 flags (--flush, --backfill, etc.) must
     be handled in filter's case statement. Unhandled flags execute in reporter
     directly, bypassing CWD check. Safe flags (--status, --help) excluded.

  3. DATA STORAGE PATHS — reporter writes events to $HOME/.fkit-reporter-*
     locations. Filter's _scrub must cover ALL of them. New unmonitored paths
     mean leaked data persists on disk and eventually gets flushed to server.

  4. REMOTE CODE EXECUTION — patterns like curl|bash, eval(curl), source<(curl)
     allow reporter to download and execute arbitrary code. Hash check becomes
     meaningless if reporter can fetch and run code at runtime.

  5. EVENTS WITHOUT CWD — Python blocks constructing event dicts that omit
     "cwd" key. These events escape CWD-based filtering. Post-hoc scrub catches
     them (empty cwd fails prefix match), but timing matters if flush is immediate.

AI NOTE: If this script reports FAIL, check the specific FAIL lines to understand
which vector was detected. Common false positives:
  - "new data paths": check if filter's _scrub has startswith() patterns covering them
  - "unhandled CLI flags": check if the flag is read-only (safe to pass through)
  - "events without cwd": check if _scrub removes them post-hoc (WARN, not FAIL)
"""

import re, sys, os


def review(reporter_path, filter_path):
    with open(reporter_path, encoding="utf-8") as f:
        reporter = f.read()
    with open(filter_path, encoding="utf-8") as f:
        filt = f.read()

    fails = []   # Critical — causes BLOCK
    warns = []   # Informational — still passes
    info = []

    # ── Version ──────────────────────────────────────────────────────
    m = re.search(r"REPORTER_VERSION=(\d+)", reporter)
    ver = m.group(1) if m else "?"
    info.append(f"version=v{ver}")

    # ── CHECK 1: CWD field in event construction ────────────────────
    # Filter relies on "cwd" field in JSON events for prefix matching.
    # Count references to "cwd" or 'cwd' in reporter code.
    # Healthy reporter has 10+ references (event dicts, payload extraction).
    cwd_in_events = len(re.findall(r"""['"]cwd['"]""", reporter))
    if cwd_in_events < 3:
        fails.append(
            f"cwd field references too few ({cwd_in_events}) — "
            "filter CWD matching may be ineffective"
        )
    else:
        info.append(f"cwd_refs={cwd_in_events}")

    # ── CHECK 2: CLI flags coverage ─────────────────────────────────
    # Extract --flags checked as $1 in reporter (CLI entry points).
    # These must be handled in filter's case statement.
    reporter_cli_flags = set(
        re.findall(r'"\$\{?1[:\-]*\}?"\s*==\s*"(--[a-z][-a-z]*)"', reporter)
    )
    filter_case = re.search(
        r'case\s+"\$\{1:-\}"\s+in(.*?)esac', filt, re.DOTALL
    )
    filter_handled = set()
    if filter_case:
        filter_handled = set(re.findall(r"--[a-z][-a-z]*", filter_case.group(1)))

    # Read-only / safe flags — not data exfiltration vectors
    safe_flags = {
        "--status", "--version", "--help", "--verbose", "--quiet", "--debug",
    }
    risky_new = reporter_cli_flags - filter_handled - safe_flags
    if risky_new:
        fails.append(f"unhandled CLI flags (potential bypass): {risky_new}")
    new_safe = reporter_cli_flags - filter_handled
    if new_safe and not risky_new:
        info.append(f"new safe flags: {new_safe}")
    else:
        info.append(
            f"cli_flags: {len(reporter_cli_flags)} reporter, "
            f"{len(filter_handled)} handled"
        )

    # ── CHECK 3: Data storage paths ─────────────────────────────────
    # Reporter writes to $HOME/.fkit-reporter-* paths.
    # Filter's _scrub must cover all of them.
    path_re = r"(?:\$HOME|~/|home)/\.fkit-reporter[a-zA-Z0-9._-]*"
    reporter_paths = set(re.findall(path_re, reporter))
    filter_paths = set(re.findall(path_re, filt))

    def norm_path(p):
        return re.sub(r"^(?:~/|home/)", "$HOME/", p)

    reporter_normed = {norm_path(p) for p in reporter_paths}
    filter_normed = {norm_path(p) for p in filter_paths}

    # Filter's scrub also uses startswith() patterns in Python code.
    # e.g. fn.startswith(".fkit-reporter-queue.sending.") covers all
    # $HOME/.fkit-reporter-queue.sending.* paths.
    filter_prefixes = set(
        re.findall(
            r"""startswith\(["'](\.fkit-reporter[^"']+)["']\)""", filt
        )
    )

    # Metadata-only files — contain a PID, timestamp, or number, NOT events.
    # These can never leak personal session data.
    # "-updated" covers $HOME/.fkit-reporter-updated (version marker written
    # by reporter v25+ after background self-update; contains version int only).
    metadata_keywords = {
        "flush.lock", "lastflush", ".backoff", ".lock", ".pid", "-updated",
    }

    def is_covered(path):
        if path in filter_normed:
            return True
        # Check startswith patterns from filter's scrub code
        base = path.replace("$HOME/", "")
        for pfx in filter_prefixes:
            if base.startswith(pfx):
                return True
        # Metadata files are safe — no event data
        for kw in metadata_keywords:
            if kw in path:
                return True
        return False

    new_data_paths = {p for p in reporter_normed if not is_covered(p)}
    new_data_paths = {
        p for p in new_data_paths
        if not any(p.endswith(s) for s in (".tmp", ".trim", ".pid"))
    }
    if new_data_paths:
        fails.append(f"new data paths not in filter scrub: {new_data_paths}")
    else:
        info.append(f"data_paths: {len(reporter_normed)} all covered")

    # ── CHECK 4: Remote code execution ──────────────────────────────
    # Detect patterns where downloaded content is executed directly.
    # NOTE: curl -o FILE && chmod +x && mv (auto-update) is NOT flagged.
    # That downloads to a file — hash check catches it on next invocation.
    rce_patterns = [
        (r"curl[^;|]*\|\s*(?:bash|sh|zsh)", "curl piped to shell"),
        (r"eval\s+[\"']?\$\(curl", "eval with curl subshell"),
        (r"source\s+<\(curl", "source with curl process substitution"),
        (r"bash\s+<\(curl", "bash with curl process substitution"),
    ]
    rce_found = []
    for pattern, desc in rce_patterns:
        matches = re.findall(pattern, reporter)
        if matches:
            rce_found.append(f"{desc} ({len(matches)}x)")
    if rce_found:
        fails.append(f"remote code execution: {'; '.join(rce_found)}")
    else:
        info.append("rce_patterns: none")

    # ── CHECK 5: Events without CWD field ───────────────────────────
    # Python blocks constructing event dicts with hook_event_name but
    # missing "cwd" — these escape CWD-based filtering.
    # Post-hoc scrub catches them (empty cwd fails prefix match),
    # but if flush happens before scrub, they reach the server.
    py_blocks = re.findall(
        r"python3\s+(?:-c\s+['\"]|-)(.+?)(?:['\"](?:\s+\"\$)|^PY$|^PYEOF$)",
        reporter,
        re.DOTALL | re.MULTILINE,
    )
    events_without_cwd = 0
    for block in py_blocks:
        event_constructions = re.findall(
            r"\{[^}]*['\"]hook_event_name['\"][^}]*\}", block, re.DOTALL
        )
        for ev in event_constructions:
            if '"cwd"' not in ev and "'cwd'" not in ev:
                events_without_cwd += 1

    if events_without_cwd > 0:
        warns.append(
            f"events without cwd field: {events_without_cwd} "
            "(scrub removes them, but timing matters)"
        )
    else:
        info.append("all events have cwd field")

    # ── CHECK 6: Self-invocation (filter bypass) ────────────────────
    # Reporter calling itself directly bypasses the filter wrapper.
    # Expected in --flush (self re-invoke), but new instances are risky.
    self_invoke = re.findall(
        r'echo\s+.*\|\s*"\$(?:_SELF|0|SCRIPT_PATH)"', reporter
    )
    if self_invoke:
        warns.append(
            f"self-invocation: {len(self_invoke)} instances "
            "(expected in --flush, verify no new ones)"
        )

    return {
        "version": ver,
        "passed": len(fails) == 0,
        "fails": fails,
        "warns": warns,
        "info": info,
    }


def main():
    reporter = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.claude/hooks/fkit-reporter.sh"
    )
    filt = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser(
        "~/.claude/hooks/fkit-reporter-filter.sh"
    )

    try:
        result = review(reporter, filt)
    except Exception as e:
        print(f"FAIL: review error: {e}")
        sys.exit(1)

    for f in result["fails"]:
        print(f"FAIL: {f}")
    for w in result["warns"]:
        print(f"WARN: {w}")
    for i in result["info"]:
        print(f"INFO: {i}")

    if result["passed"]:
        print(f"PASS: v{result['version']} safe to auto-approve")
        sys.exit(0)
    else:
        print(f"BLOCK: v{result['version']} requires manual review")
        sys.exit(1)


if __name__ == "__main__":
    sys.exit(main())
REVIEW_EOF

  ok "Auto-review script installed"

  # ── Write harden script ───────────────────────────────────────────────
  # Restores filter-wrapper routing in settings.json after the reporter
  # hijacks it during --flush or --update. Called by the /report-claude
  # skill. We do NOT modify fkit-reporter.sh (company may SHA256-verify it).
  cat > "$HARDEN" << 'HARDEN_EOF'
#!/usr/bin/env bash
# fkit-reporter-harden.sh — passive guard: re-assert filter-wrapper routing
# in settings.json after a reporter invocation that may have hijacked it.
#
# We do NOT modify fkit-reporter.sh (the reporter is company-verified by
# SHA256). Instead we handle the two failure modes externally:
#
#   - Background auto-update on session_start: blocked at the OS level by
#     `chflags uchg` on the reporter binary — mv fails, the subshell exits
#     before reaching its settings.json rewrite.
#   - --flush / --update hijack: we cannot prevent the rewrite (it runs
#     regardless of mv result), so instead we re-assert routing here.
#
# Run after any explicit /report-claude invocation. Idempotent.

set -euo pipefail

FILTER="$HOME/.claude/hooks/fkit-reporter-filter.sh"
SETTINGS="$HOME/.claude/settings.json"

[[ -f "$FILTER" ]]   || { echo "[harden] filter not found: $FILTER" >&2; exit 1; }
[[ -f "$SETTINGS" ]] || { echo "[harden] settings.json not found" >&2; exit 1; }

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
if changed:
    print(f"[harden] restored {changed} hook entries → filter wrapper")
else:
    print("[harden] settings.json already routes through filter")
PY
HARDEN_EOF
  chmod +x "$HARDEN"
  ok "Harden script installed"

  # Save baseline hash
  save_hash
  ok "Integrity baseline saved"

  # ── Patch settings.json ───────────────────────────────────────────────
  # Replace fkit-reporter.sh → fkit-reporter-filter.sh in all hook commands.
  # Also dedup hooks (prevent double entries from repeated installs).
  python3 << 'PYEOF'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
with open(path) as f: data = json.load(f)
def patch(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str) and "fkit-reporter.sh" in v and "fkit-reporter-filter.sh" not in v:
                obj[k] = v.replace("fkit-reporter.sh", "fkit-reporter-filter.sh")
            else: patch(v)
    elif isinstance(obj, list):
        for item in obj: patch(item)
def dedup(obj):
    hooks = obj.get("hooks", {})
    if not isinstance(hooks, dict): return
    for name, entries in hooks.items():
        if not isinstance(entries, list): continue
        seen = set(); out = []
        for entry in entries:
            cmds = tuple(sorted(h.get("command", "") for h in entry.get("hooks", []) if isinstance(h, dict)))
            if cmds and cmds in seen: continue
            seen.add(cmds); out.append(entry)
        hooks[name] = out
patch(data); dedup(data)
with open(path, "w") as f: json.dump(data, f, indent=2, ensure_ascii=False); f.write("\n")
PYEOF
  ok "settings.json patched"

  # ── Clean local data ──────────────────────────────────────────────────
  # Remove all queued events, state files, and temp files.
  # Prevents stale non-allowed data from being flushed after install.
  rm -rf "$HOME/.fkit-reporter-queue"/* 2>/dev/null || true
  rm -rf "$HOME/.fkit-reporter-state"/* 2>/dev/null || true
  rm -f "$HOME/.fkit-reporter-queue.overflow" 2>/dev/null || true
  rm -f "$HOME/.fkit-reporter-lastflush" 2>/dev/null || true
  rm -f "$HOME/.fkit-reporter-lastflush.backoff" 2>/dev/null || true
  for f in "$HOME"/.fkit-reporter-queue.sending.* "$HOME"/.fkit-reporter-queue.collecting.*; do
    [[ -e "$f" ]] && rm -rf "$f" 2>/dev/null || true
  done
  ok "Queue/state cleaned"

  # ── Run auto-review on current reporter ───────────────────────────────
  # Verify the review script works and current reporter passes.
  echo ""
  echo -e "  ${B}Auto-review check:${N}"
  local _review_out
  _review_out=$(python3 "$AUTO_REVIEW" "$ORIGINAL" "$FILTER" 2>&1) || true
  echo "$_review_out" | while read -r line; do
    case "$line" in
      PASS*) ok "$line" ;;
      FAIL*) warn "$line" ;;
      WARN*) info "$line" ;;
      INFO*) echo -e "    ${D}$line${N}" ;;
    esac
  done

  echo ""
  echo -e "  ${G}Installed!${N} Reporting only from:"
  for p in "${PATHS[@]}"; do echo -e "    ${C}$p${N}"; done
}

# ── Approve update ─────────────────────────────────────────────────────
# Manual review flow when auto-review FAILS.
# Shows hash diff, runs leak-checks, asks for confirmation.
do_approve() {
  echo ""
  echo -e "  ${B}Review fkit-reporter.sh changes${N}"
  echo ""

  local current saved
  current=$(get_hook_hash)
  saved=$(get_saved_hash)

  if [[ "$current" == "$saved" ]]; then
    ok "No changes to approve — hashes match"
    return
  fi

  echo -e "  Hash before: ${D}${saved:-none}${N}"
  echo -e "  Hash now:    ${D}${current:-none}${N}"
  echo ""

  # Run auto-review for detailed analysis
  echo -e "  ${B}Auto leak-check:${N}"
  if [[ -f "$AUTO_REVIEW" ]]; then
    local _review_out
    _review_out=$(python3 "$AUTO_REVIEW" "$ORIGINAL" "$FILTER" 2>&1) || true
    echo "$_review_out" | while read -r line; do
      case "$line" in
        PASS*) ok "$line" ;;
        FAIL*) warn "$line" ;;
        WARN*) info "$line" ;;
        INFO*) echo -e "    ${D}$line${N}" ;;
      esac
    done
  else
    # Fallback: basic grep-based checks
    local _issues=0

    if grep -q 'get("cwd"' "$ORIGINAL" 2>/dev/null; then
      ok "CWD field preserved in payload"
    else
      warn "CWD field may be missing — filter could be ineffective"
      _issues=$((_issues+1))
    fi

    local _reporter_flags _filter_flags _unhandled
    _reporter_flags=$(grep -oE '\-\-[a-z][-a-z]*' "$ORIGINAL" 2>/dev/null | sort -u)
    _filter_flags=$(grep -oE '\-\-[a-z][-a-z]*' "$FILTER" 2>/dev/null | sort -u)
    _unhandled=$(comm -23 <(echo "$_reporter_flags") <(echo "$_filter_flags") 2>/dev/null | grep -v '^$' || true)
    if [[ -z "$_unhandled" ]]; then
      ok "All reporter CLI flags handled by filter"
    else
      warn "New flags in reporter not in filter: $_unhandled"
      _issues=$((_issues+1))
    fi

    if grep -q 'curl.*fkit-reporter' "$ORIGINAL" 2>/dev/null; then
      info "Self-update mechanism present (hash will change on next update)"
    fi

    if [[ -f "${ORIGINAL}.pre-flush" ]]; then
      local _diff_lines
      _diff_lines=$(diff "${ORIGINAL}.pre-flush" "$ORIGINAL" 2>/dev/null | wc -l || echo 0)
      if [[ "$_diff_lines" -gt 0 ]]; then
        info "$_diff_lines lines changed from previous version"
      fi
    fi

    if [[ $_issues -eq 0 ]]; then
      ok "No leak risks detected"
    else
      warn "$_issues potential issue(s) found — review before approving"
    fi
  fi

  echo ""
  echo -e "  ${Y}Approve this version?${N}"
  echo "  [1] Yes — save new hash, resume filtering"
  echo "  [0] No — keep blocking"
  echo -ne "  > "
  read -r choice

  case "$choice" in
    1)
      save_hash
      ok "Approved! New baseline saved."
      ;;
    *)
      info "Still blocking. Re-run to approve later."
      ;;
  esac
}

# ── Status dashboard ───────────────────────────────────────────────────
do_status() {
  echo ""
  echo -e "  ${B}FKit Filter Status${N}"
  echo ""

  # Filter installed?
  if [[ -f "$FILTER" ]]; then
    ok "Filter installed"
  else
    warn "Filter NOT installed"
  fi

  # Auto-review script
  if [[ -f "$AUTO_REVIEW" ]]; then
    ok "Auto-review script installed"
  else
    warn "Auto-review script MISSING — hash changes will block (safe default)"
  fi

  # Allowed folders
  echo ""
  echo -e "  ${B}Allowed folders:${N}"
  show_paths

  # Integrity
  echo ""
  echo -e "  ${B}Integrity:${N}"
  check_integrity || true

  # Auto-review current reporter
  if [[ -f "$AUTO_REVIEW" ]] && [[ -f "$ORIGINAL" ]] && [[ -f "$FILTER" ]]; then
    echo ""
    echo -e "  ${B}Auto-review:${N}"
    local _review_out
    _review_out=$(python3 "$AUTO_REVIEW" "$ORIGINAL" "$FILTER" 2>&1) || true
    echo "$_review_out" | while read -r line; do
      case "$line" in
        PASS*) ok "$line" ;;
        FAIL*) warn "$line" ;;
        WARN*) info "$line" ;;
        INFO*) echo -e "    ${D}$line${N}" ;;
      esac
    done
  fi

  # Queue
  echo ""
  echo -e "  ${B}Queue:${N}"
  local q_count=0
  if [[ -d "$HOME/.fkit-reporter-queue" ]]; then
    q_count=$(find "$HOME/.fkit-reporter-queue" -name "*.jsonl" -exec cat {} + 2>/dev/null | wc -l || echo 0)
  fi
  info "$q_count events pending"

  # Settings.json hook check
  echo ""
  echo -e "  ${B}Hooks:${N}"
  if grep -q "fkit-reporter-filter.sh" "$SETTINGS" 2>/dev/null; then
    ok "settings.json → filter"
  elif grep -q "fkit-reporter.sh" "$SETTINGS" 2>/dev/null; then
    warn "settings.json → original (not filtered!)"
  else
    info "No fkit hooks in settings.json"
  fi

  # Review log
  if [[ -f "$REVIEW_LOG" ]]; then
    local _review_count
    _review_count=$(grep -c "^===" "$REVIEW_LOG" 2>/dev/null || echo 0)
    info "Review log: $_review_count entries ($REVIEW_LOG)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN — Interactive menu
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${B}╔═══════════════════════════════════════╗${N}"
echo -e "${B}║       FKit Filter Manager             ║${N}"
echo -e "${B}╚═══════════════════════════════════════╝${N}"
echo -e "  ${D}OS: ${OS}  Shell: ${SHELL##*/}${N}"

# Prerequisites
[[ -f "$ORIGINAL" ]] || fail "fkit-reporter.sh not found — install FKit Reporter first"
[[ -f "$SETTINGS" ]] || fail "settings.json not found — is Claude Code installed?"
command -v python3 &>/dev/null || fail "python3 required"

# Load current config
load_paths

# Detect state
INSTALLED=false
[[ -f "$FILTER" ]] && INSTALLED=true

INTEGRITY_OK=true
if [[ -f "$HASH_FILE" ]]; then
  current_h=$(get_hook_hash)
  saved_h=$(get_saved_hash)
  [[ "$current_h" != "$saved_h" ]] && INTEGRITY_OK=false
fi

# Show alert if integrity broken
if [[ "$INTEGRITY_OK" == "false" ]]; then
  echo ""
  echo -e "  ${R}⚠  fkit-reporter.sh has CHANGED — all events blocked${N}"
fi

while true; do
  echo ""
  echo -e "  ${B}What do you want to do?${N}"
  echo ""

  if [[ "$INSTALLED" == "true" ]]; then
    echo "  [1] Status & health check"
    echo "  [2] Edit allowed folders"
    if [[ "$INTEGRITY_OK" == "false" ]]; then
      echo -e "  [3] ${Y}Review & approve hook update${N}"
    else
      echo "  [3] Reinstall filter"
    fi
    echo "  [4] Install fresh (reset everything)"
  else
    echo "  [1] Install filter"
  fi
  echo "  [0] Exit"
  echo -ne "  > "
  read -r choice

  if [[ "$INSTALLED" == "false" ]]; then
    case "$choice" in
      1) do_install; INSTALLED=true; save_hash; INTEGRITY_OK=true ;;
      0) echo ""; exit 0 ;;
      *) warn "Invalid" ;;
    esac
  else
    case "$choice" in
      1) do_status ;;
      2)
        edit_folders
        if [[ ${#PATHS[@]} -gt 0 ]]; then
          save_paths
          ok "Config saved"
        else
          warn "No folders — keeping previous config"
          load_paths
        fi
        ;;
      3)
        if [[ "$INTEGRITY_OK" == "false" ]]; then
          do_approve
          # Recheck
          current_h=$(get_hook_hash)
          saved_h=$(get_saved_hash)
          [[ "$current_h" == "$saved_h" ]] && INTEGRITY_OK=true
        else
          do_install; INSTALLED=true; INTEGRITY_OK=true
        fi
        ;;
      4) PATHS=(); do_install; INSTALLED=true; INTEGRITY_OK=true ;;
      0) echo ""; exit 0 ;;
      *) warn "Invalid" ;;
    esac
  fi
done
