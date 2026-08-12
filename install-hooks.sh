#!/usr/bin/env bash
# Wires an agent up to the sidebar by registering its hooks.
#
#   ./install-hooks.sh claude      Claude Code: settings.json + status line
#   ./install-hooks.sh codex       Codex: hooks.json + codex_hooks feature flag
#   ./install-hooks.sh --uninstall Remove everything this script added
#
# Existing configuration is merged, never replaced, and a .bak-agent-sidebar
# copy is written before the first change to each file.

set -u

COLLECT="${COLLECT:-$HOME/.local/bin/tmux-agent-sidebar-collect.sh}"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_STATUSLINE="$HOME/.claude/statusline-command.sh"
CODEX_CONFIG="$HOME/.codex/config.toml"
CODEX_HOOKS="$HOME/.codex/hooks.json"
MARK='tmux-agent-sidebar-collect.sh'

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

backup() {
    [[ -f $1 && ! -f "$1.bak-agent-sidebar" ]] && cp "$1" "$1.bak-agent-sidebar"
    return 0
}

have python3 || die "python3 is required"
have jq       || printf 'warning: jq not found — the sidebar needs it at runtime\n' >&2

# ---------------------------------------------------------------- claude ----
install_claude() {
    [[ -x $COLLECT ]] || die "collector not found or not executable: $COLLECT"
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    backup "$CLAUDE_SETTINGS"

    COLLECT="$COLLECT" SETTINGS="$CLAUDE_SETTINGS" python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ["SETTINGS"])
cfg = {}
if p.exists() and p.read_text().strip():
    try:
        cfg = json.loads(p.read_text())
    except json.JSONDecodeError:
        raise SystemExit(f"error: {p} is not valid JSON — fix or move it first")

C = f'bash {os.environ["COLLECT"]} claude'
def h(ev, matcher=None):
    e = {"hooks": [{"type": "command", "command": f"{C} {ev}", "async": True}]}
    if matcher is not None:
        e["matcher"] = matcher
    return e

ours = {
    "SessionStart":      h("session-start", ""),
    "UserPromptSubmit":  h("prompt"),
    "PostToolUse":       h("tool", ""),
    "PermissionRequest": h("wait", ""),
    "Stop":              h("stop"),
    "SubagentStart":     h("subagent-start", ""),
    "SubagentStop":      h("subagent-stop", ""),
    "TaskCreated":       h("task-created"),
    "TaskCompleted":     h("task-completed"),
    "SessionEnd":        h("session-end", ""),
}

hooks = cfg.setdefault("hooks", {})
for event, entry in ours.items():
    groups = hooks.setdefault(event, [])
    # Drop any previous entry of ours, keep everything else untouched.
    groups[:] = [g for g in groups
                 if not any("tmux-agent-sidebar-collect.sh" in hh.get("command", "")
                            for hh in g.get("hooks", []))]
    groups.append(entry)

p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"  hooks -> {p}")
PY

    # The status line is the only source of model, context window and title.
    if [[ -f $CLAUDE_STATUSLINE ]]; then
        if grep -q "$MARK" "$CLAUDE_STATUSLINE"; then
            printf '  status line already wired\n'
        else
            backup "$CLAUDE_STATUSLINE"
            printf '  status line -> %s\n' "$CLAUDE_STATUSLINE"
            python3 - "$CLAUDE_STATUSLINE" "$COLLECT" <<'PY'
import sys, pathlib
path, collect = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = path.read_text().splitlines(keepends=True)
snippet = f'''
# Feed the tmux sidebar: the status line is the only place model, context
# window and session title are exposed. Backgrounded so it never blocks.
if [ -x {collect} ]; then
  printf '%s' "$input" | {collect} claude statusline &
fi
'''
# Insert right after the line that captures stdin, since $input must exist.
for i, l in enumerate(lines):
    if l.strip().startswith("input=") and "cat" in l:
        lines.insert(i + 1, snippet)
        break
else:
    raise SystemExit("error: could not find `input=$(cat)` in the status line "
                     "script; add the snippet manually")
path.write_text("".join(lines))
PY
        fi
    else
        cat >"$CLAUDE_STATUSLINE" <<EOF
#!/bin/bash
input=\$(cat)
if [ -x $COLLECT ]; then
  printf '%s' "\$input" | $COLLECT claude statusline &
fi
EOF
        chmod +x "$CLAUDE_STATUSLINE"
        printf '  status line created -> %s\n' "$CLAUDE_STATUSLINE"
        printf '  note: set "statusLine" in settings.json to run it\n'
    fi
    printf 'claude: done (takes effect immediately)\n'
}

# ----------------------------------------------------------------- codex ----
install_codex() {
    [[ -x $COLLECT ]] || die "collector not found or not executable: $COLLECT"
    mkdir -p "$(dirname "$CODEX_HOOKS")"
    backup "$CODEX_CONFIG"; backup "$CODEX_HOOKS"

    # Hooks are behind a feature flag that is only read at startup.
    CONFIG="$CODEX_CONFIG" python3 - <<'PY'
import os, pathlib, re
p = pathlib.Path(os.environ["CONFIG"])
t = p.read_text() if p.exists() else ""
if re.search(r'^\s*codex_hooks\s*=', t, re.M):
    print("  codex_hooks already enabled")
elif re.search(r'^\[features\]', t, re.M):
    p.write_text(re.sub(r'^\[features\]', '[features]\ncodex_hooks = true',
                        t, count=1, flags=re.M))
    print("  codex_hooks = true (added to [features])")
else:
    # A bare key after an existing table header would belong to that table,
    # so the new table has to go at the end of the file.
    p.write_text((t.rstrip() + "\n\n" if t.strip() else "")
                 + "[features]\ncodex_hooks = true\n")
    print("  [features] codex_hooks = true (appended)")
PY

    COLLECT="$COLLECT" HOOKS="$CODEX_HOOKS" python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ["HOOKS"])
cfg = {}
if p.exists() and p.read_text().strip():
    try:
        cfg = json.loads(p.read_text())
    except json.JSONDecodeError:
        raise SystemExit(f"error: {p} is not valid JSON — fix or move it first")

C = f'bash {os.environ["COLLECT"]} codex'
def h(ev, matcher=None):
    e = {"hooks": [{"type": "command", "command": f"{C} {ev}"}]}
    if matcher is not None:
        e["matcher"] = matcher
    return e

# Codex has no SessionEnd, Notification, or Task* events.
ours = {
    "SessionStart":      h("session-start", "startup|resume|clear"),
    "UserPromptSubmit":  h("prompt"),
    "PostToolUse":       h("tool", ""),
    "PermissionRequest": h("wait", ""),
    "Stop":              h("stop"),
    "SubagentStart":     h("subagent-start", ""),
    "SubagentStop":      h("subagent-stop", ""),
}

hooks = cfg.setdefault("hooks", {})
for event, entry in ours.items():
    groups = hooks.setdefault(event, [])
    groups[:] = [g for g in groups
                 if not any("tmux-agent-sidebar-collect.sh" in hh.get("command", "")
                            for hh in g.get("hooks", []))]
    groups.append(entry)

p.write_text(json.dumps(cfg, indent=2) + "\n")
print(f"  hooks -> {p}")
PY
    printf 'codex: done — RESTART Codex so the feature flag takes effect\n'
}

# ------------------------------------------------------------- uninstall ----
uninstall() {
    for f in "$CLAUDE_SETTINGS" "$CODEX_HOOKS"; do
        [[ -f $f ]] || continue
        FILE="$f" python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ["FILE"])
try:
    cfg = json.loads(p.read_text())
except Exception:
    raise SystemExit(0)
hooks = cfg.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit(0)
changed = False
for event in list(hooks):
    groups = hooks[event]
    if not isinstance(groups, list):
        continue
    kept = [g for g in groups
            if not any("tmux-agent-sidebar-collect.sh" in hh.get("command", "")
                       for hh in g.get("hooks", []))]
    if len(kept) != len(groups):
        changed = True
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if not hooks:
    cfg.pop("hooks", None)
if changed:
    p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
    print(f"  cleaned {p}")
PY
    done

    if [[ -f $CLAUDE_STATUSLINE ]] && grep -q "$MARK" "$CLAUDE_STATUSLINE"; then
        python3 - "$CLAUDE_STATUSLINE" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
t = p.read_text()
# Remove the guarded block we inserted, plus its comment lines.
t = re.sub(r'\n?# Feed the tmux sidebar.*?\nfi\n', '\n', t, flags=re.S)
t = re.sub(r'\n?if \[ -x [^\]]*tmux-agent-sidebar-collect\.sh \]; then.*?\nfi\n',
           '\n', t, flags=re.S)
p.write_text(t)
print(f"  cleaned {p}")
PY
    fi

    printf 'note: [features] codex_hooks in %s was left in place —\n' "$CODEX_CONFIG"
    printf '      it is a Codex feature flag, harmless without hooks.\n'
    printf 'uninstall: done\n'
}

case "${1:-}" in
    claude)      install_claude ;;
    codex)       install_codex ;;
    both|all)    install_claude; printf '\n'; install_codex ;;
    --uninstall) uninstall ;;
    *)
        printf 'usage: %s [claude|codex|both|--uninstall]\n' "${0##*/}"
        exit 1 ;;
esac
