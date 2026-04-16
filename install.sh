#!/usr/bin/env bash
# fkit-filter — Interactive CWD filter manager for FKit Reporter
# Works on macOS, Linux, and Windows (Git Bash / MSYS2)
#
# Usage:
#   bash <(curl -fsSL https://fkit.run/filter)
#   — or —
#   fkit-filter              (if alias installed)
#
# One command: install, update, check, manage — all interactive.
# Prerequisites: Claude Code + FKit Reporter + python3

set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
FILTER="$HOOKS_DIR/fkit-reporter-filter.sh"
ORIGINAL="$HOOKS_DIR/fkit-reporter.sh"
CONF="$HOOKS_DIR/fkit-filter.conf"
HASH_FILE="$HOOKS_DIR/fkit-reporter.sha256"

# ── Colors ───────────────────────────────────────────────────────────────────
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

# ── OS Detection ─────────────────────────────────────────────────────────────
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

# ── Paths management ─────────────────────────────────────────────────────────
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
  local resolved
  resolved=$(resolve_path "$raw")
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

# ── Folder editor submenu ────────────────────────────────────────────────────
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

# ── Integrity helpers ────────────────────────────────────────────────────────
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

# ── Install / reinstall ─────────────────────────────────────────────────────
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

  # Write filter wrapper
  cat > "$FILTER" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# fkit-reporter-filter.sh — CWD filter for FKit Reporter
# Leak vectors addressed: incoming events, crash recovery, auto-backfill,
#   backfill CLI, flush, overflow, .sending.*, state files, exec bypass.

REAL_HOOK="$HOME/.claude/hooks/fkit-reporter.sh"
CONF="$HOME/.claude/hooks/fkit-filter.conf"
QUEUE_DIR="$HOME/.fkit-reporter-queue"
OVERFLOW="$HOME/.fkit-reporter-queue.overflow"
STATE_DIR="$HOME/.fkit-reporter-state"
HASH_FILE="$HOME/.claude/hooks/fkit-reporter.sha256"

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
    echo "[fkit-filter] BLOCKED: fkit-reporter.sh changed (hash mismatch)." >&2
    echo "[fkit-filter]   saved:   $saved_hash" >&2
    echo "[fkit-filter]   current: $current_hash" >&2
    echo "[fkit-filter]   Run: fkit-filter (to review & approve)" >&2
    return 1
  fi
  return 0
}

_ALLOWED=()
if [[ -f "$CONF" ]]; then
  while IFS= read -r _line; do
    _line="${_line%%#*}"
    _line="$(echo "$_line" | xargs 2>/dev/null)"
    [[ -n "$_line" ]] && _ALLOWED+=("$_line")
  done < "$CONF"
fi
[[ ${#_ALLOWED[@]} -eq 0 ]] && exit 0

_cwd_allowed() {
  local cwd="$1"
  cwd="${cwd//\\//}"
  for prefix in "${_ALLOWED[@]}"; do
    [[ "$cwd" == "$prefix"* ]] && return 0
  done
  return 1
}

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
if os.path.isdir(qdir):
    for proj in os.listdir(qdir):
        pdir = os.path.join(qdir, proj)
        if not os.path.isdir(pdir): continue
        for fn in os.listdir(pdir):
            if fn.endswith(".jsonl"): scrub_file(os.path.join(pdir, fn))
        try:
            if not os.listdir(pdir): os.rmdir(pdir)
        except: pass
scrub_file(ovf_path)
for fn in os.listdir(home):
    if fn.startswith(".fkit-reporter-queue.sending.") or fn.startswith(".fkit-reporter-queue.collecting."):
        fp = os.path.join(home, fn)
        if os.path.isfile(fp): scrub_file(fp)
        elif os.path.isdir(fp):
            for sf in os.listdir(fp):
                if sf.endswith(".jsonl"): scrub_file(os.path.join(fp, sf))
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

# Pre-clean non-allowed state files so crash recovery won't generate personal events
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

case "${1:-}" in
  --status)   exec "$REAL_HOOK" "$@" ;;
  --update)   exec "$REAL_HOOK" "$@" ;;
  --flush)
    _scrub
    _pre_clean_state
    cp "$REAL_HOOK" "${REAL_HOOK}.pre-flush" 2>/dev/null || true
    "$REAL_HOOK" "$@"
    _scrub
    exit 0
    ;;
  --backfill) echo "[fkit-filter] backfill disabled."; exit 0 ;;
  --audit)
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

if ! _check_hook_integrity; then exit 0; fi

PAYLOAD=$(cat)
[[ -z "$PAYLOAD" ]] && exit 0
CWD=$(python3 -c "import json,sys;print(json.load(sys.stdin).get('cwd',''))" <<< "$PAYLOAD" 2>/dev/null) || CWD=""
if _cwd_allowed "$CWD"; then
  _scrub
  _pre_clean_state
  date +%s > "$HOME/.fkit-reporter-lastflush" 2>/dev/null || true
  echo "$PAYLOAD" | "$REAL_HOOK"
  _scrub
fi
exit 0
WRAPPER_EOF

  chmod +x "$FILTER"
  ok "Filter wrapper installed"

  # Save baseline hash
  save_hash
  ok "Integrity baseline saved"

  # Patch settings.json
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

  # Clean local data
  rm -rf "$HOME/.fkit-reporter-queue"/* 2>/dev/null || true
  rm -rf "$HOME/.fkit-reporter-state"/* 2>/dev/null || true
  rm -f "$HOME/.fkit-reporter-queue.overflow" 2>/dev/null || true
  rm -f "$HOME/.fkit-reporter-lastflush" 2>/dev/null || true
  rm -f "$HOME/.fkit-reporter-lastflush.backoff" 2>/dev/null || true
  for f in "$HOME"/.fkit-reporter-queue.sending.* "$HOME"/.fkit-reporter-queue.collecting.*; do
    [[ -e "$f" ]] && rm -rf "$f" 2>/dev/null || true
  done
  ok "Queue/state cleaned"

  echo ""
  echo -e "  ${G}Installed!${N} Reporting only from:"
  for p in "${PATHS[@]}"; do echo -e "    ${C}$p${N}"; done
}

# ── Approve update ───────────────────────────────────────────────────────────
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

  # Auto leak-check: analyze new reporter for risks
  echo -e "  ${B}Auto leak-check:${N}"
  local _issues=0

  # 1. CWD field still in payload?
  if grep -q 'get("cwd"' "$ORIGINAL" 2>/dev/null; then
    ok "CWD field preserved in payload"
  else
    warn "CWD field may be missing — filter could be ineffective"
    _issues=$((_issues+1))
  fi

  # 2. New CLI flags not handled by filter?
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

  # 3. Self-update mechanism?
  if grep -q 'curl.*fkit-reporter' "$ORIGINAL" 2>/dev/null; then
    info "Self-update mechanism present (hash will change on next update)"
  fi

  # 4. Diff with pre-flush backup if available
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

# ── Status dashboard ─────────────────────────────────────────────────────────
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

  # Allowed folders
  echo ""
  echo -e "  ${B}Allowed folders:${N}"
  show_paths

  # Integrity
  echo ""
  echo -e "  ${B}Integrity:${N}"
  check_integrity || true

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
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN — Interactive menu
# ═════════════════════════════════════════════════════════════════════════════

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
