#!/usr/bin/env bash
# Records Claude Code / Codex state for the tmux pane it runs in.
#
# Invoked three ways, all of which inherit the agent's environment (and so
# TMUX_PANE, which is what ties an event to a pane):
#
#   * Claude Code hooks   — ~/.claude/settings.json
#   * Codex hooks         — ~/.codex/hooks.json  (needs codex_hooks feature)
#   * the Claude status line — the only place model, context window and
#                              session title are exposed for Claude
#
# Usage: tmux-agent-sidebar-collect.sh <client> <event>
#   client: claude | codex
#   event:  statusline | session-start | prompt | tool | stop | wait
#           | subagent-start | subagent-stop | task-created | task-completed
#           | session-end
#
# Reads the event JSON on stdin and merges it into the pane's state file.
# Every event is a patch: keys it does not set keep their previous value, so
# a tool event never erases the prompt and the status line never overwrites a
# status only the event hooks can know.

client="${1:-}"
event="${2:-}"
pane="${TMUX_PANE:-}"

# Opt-in call trace, for working out why an agent is not reporting. Enable
# with `touch "${TMPDIR:-/tmp}/tmux-agent-sidebar-$(id -u)/calls.log"`,
# disable by deleting the file. Silent and near-free when absent.
_dbg="${TMPDIR:-/tmp}/tmux-agent-sidebar-$(id -u)/calls.log"
[[ -f $_dbg ]] && printf '%s %-6s %-14s pane=%s\n' \
    "$(date '+%H:%M:%S')" "$client" "$event" "${TMUX_PANE:-<unset>}" >>"$_dbg" 2>/dev/null

[[ -n $pane && -n $client && -n $event ]] || exit 0   # outside tmux: nothing to attribute

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agent-sidebar/panes"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
file="$STATE_DIR/${pane//[^a-zA-Z0-9]/_}.json"

# Mirror the session title into the tmux window name, so the tab in the status
# bar reads "refactor the parser" instead of "zsh". Off by default; the sidebar
# settings panel (prefix+A) writes `wintab=on` into the shared config file.
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agent-sidebar.conf"
wintab_on() {
    command -v tmux >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    grep -q '^wintab=on[[:space:]]*$' "$CONFIG_FILE" 2>/dev/null
}

# The title in $1 (a state file or a patch), normalised into something that
# reads well as a window name.
tab_name() {
    jq -r '(.session_name // "") | gsub("[[:space:]]+"; " ")
           | sub("^[- ]+"; "") | sub(" +$"; "")
           | .[0:30]' <<<"$1" 2>/dev/null
}

# A window is one tab but can hold several agents, so the name is every title
# in it, in pane order, joined by " | ". Empty if no agent there has a title.
window_tab_name() {
    local ids id f n out=''
    ids=$(tmux list-panes -t "$pane" -F '#{pane_id}' 2>/dev/null) || return 0
    for id in $ids; do
        f="$STATE_DIR/${id//[^a-zA-Z0-9]/_}.json"
        [[ -r $f ]] || continue
        n=$(tab_name "$(cat "$f" 2>/dev/null)")
        [[ -n $n ]] || continue
        out="${out:+$out | }$n"
    done
    printf '%s' "${out:0:60}"
}

if [[ $event == session-end ]]; then
    rm -f "$file"
    if wintab_on; then
        # Another agent may still be in this window; if not, -u drops the
        # per-window override rename-window installed and tmux takes the name
        # back over.
        name=$(window_tab_name)
        if [[ -n $name ]]; then
            tmux rename-window -t "$pane" "$name" 2>/dev/null
        else
            tmux set-window-option -t "$pane" -u automatic-rename 2>/dev/null
        fi
    fi
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
[[ -n $input ]] || exit 0
now=$(date +%s)

# Previous state, needed by the counter events below.
old='{}'
[[ -r $file ]] && old=$(cat "$file" 2>/dev/null) && [[ -n $old ]] || old='{}'
prev_sub=$(jq -r '.subagents // 0' <<<"$old" 2>/dev/null); prev_sub=${prev_sub:-0}
prev_done=$(jq -r '.tasks_done // 0' <<<"$old" 2>/dev/null); prev_done=${prev_done:-0}
prev_total=$(jq -r '.tasks_total // 0' <<<"$old" 2>/dev/null); prev_total=${prev_total:-0}

case $event in
    statusline)
        # Claude only. Supplies what no hook exposes.
        patch=$(jq -c --argjson now "$now" '{
            session_id:   (.session_id // ""),
            session_name: (.session_name // ""),
            model:        (.model.display_name // .model.id // ""),
            cwd:          (.workspace.current_dir // .cwd // ""),
            ctx_pct:      (if (.context_window.context_window_size // 0) > 0
                           then (((.context_window.current_usage.input_tokens // 0)
                                + (.context_window.current_usage.cache_creation_input_tokens // 0)
                                + (.context_window.current_usage.cache_read_input_tokens // 0))
                               * 100 / .context_window.context_window_size) | floor
                           else null end),
            cost_usd:     (.cost.total_cost_usd // null),
            updated:      $now
        }' <<<"$input" 2>/dev/null) ;;

    session-start)
        patch=$(jq -c --argjson now "$now" '{
            session_id: (.session_id // ""), cwd: (.cwd // ""),
            model: (.model // null),
            status: "idle", since: $now, tool: null,
            subagents: 0, tasks_done: 0, tasks_total: 0,
            updated: $now
        } | with_entries(select(.value != null))' <<<"$input" 2>/dev/null) ;;

    prompt)
        # A new turn resets the per-turn counters.
        patch=$(jq -c --argjson now "$now" '{
            status: "busy", since: $now, tool: null,
            subagents: 0, tasks_done: 0, tasks_total: 0,
            plan: ((.permission_mode // "") == "plan"),
            cwd: (.cwd // ""),
            prompt: ((.prompt // .user_prompt // "") | gsub("\\s+"; " ")
                     | if length > 80 then .[0:80] + "…" else . end),
            updated: $now
        }' <<<"$input" 2>/dev/null) ;;

    tool)
        # Keep `since` — it marks when the turn started, not this tool call.
        patch=$(jq -c --argjson now "$now" '{
            status: "busy", tool: (.tool_name // null),
            plan: ((.permission_mode // "") == "plan"),
            model: (.model // null),
            updated: $now
        } | with_entries(select(.value != null))' <<<"$input" 2>/dev/null) ;;

    wait)
        # PermissionRequest: the agent is blocked on the user.
        patch=$(jq -c --argjson now "$now" '{
            status: "wait", since: $now,
            tool: (.tool_name // null), updated: $now
        }' <<<"$input" 2>/dev/null) ;;

    stop)
        patch=$(jq -c --argjson now "$now" '{
            status: "done", since: $now, tool: null, subagents: 0, updated: $now
        }' <<<"$input" 2>/dev/null) ;;

    subagent-start)
        patch=$(jq -c --argjson now "$now" --argjson n "$(( prev_sub + 1 ))" '{
            subagents: $n, status: "busy",
            subagent_type: (.agent_type // null), updated: $now
        } | with_entries(select(.value != null))' <<<"$input" 2>/dev/null) ;;

    subagent-stop)
        patch=$(jq -c --argjson now "$now" \
                   --argjson n "$(( prev_sub > 0 ? prev_sub - 1 : 0 ))" \
                   '{subagents: $n, updated: $now}' <<<"$input" 2>/dev/null) ;;

    task-created)
        patch=$(jq -c --argjson now "$now" --argjson n "$(( prev_total + 1 ))" \
                   '{tasks_total: $n, updated: $now}' <<<"$input" 2>/dev/null) ;;

    task-completed)
        patch=$(jq -c --argjson now "$now" --argjson n "$(( prev_done + 1 ))" \
                   '{tasks_done: $n, updated: $now}' <<<"$input" 2>/dev/null) ;;

    *) exit 0 ;;
esac

[[ -n $patch ]] || exit 0

tmp="$file.$$"
if jq -c -n --argjson old "$old" --argjson patch "$patch" \
       --arg pane "$pane" --arg client "$client" \
       '$old + $patch + {pane: $pane, client: $client}' >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file"
else
    rm -f "$tmp"
fi

# The status line is the only event that carries the title, and it fires often,
# so recompose the name only when this pane's title differs from the one the
# last rename used — one tmux call per new title, not one per redraw, and the
# first status line after the option is switched on still renames. Every other
# agent has its own status line and renames the window itself when its title
# moves, so nothing is missed. rename-window turns automatic-rename off for the
# window; session-end puts it back once the last agent there is gone.
if [[ $event == statusline ]] && wintab_on; then
    mine=$(tab_name "$patch")
    used=$(jq -r '.wintab // ""' <<<"$old" 2>/dev/null)
    if [[ -n $mine && $mine != "$used" ]]; then
        name=$(window_tab_name)
        if [[ -n $name ]] && tmux rename-window -t "$pane" "$name" 2>/dev/null; then
            # Remember what was used, so the next redraw is a no-op.
            tmp="$file.$$"
            if jq -c --arg n "$mine" '. + {wintab: $n}' "$file" >"$tmp" 2>/dev/null; then
                mv -f "$tmp" "$file"
            else
                rm -f "$tmp"
            fi
        fi
    fi
fi
exit 0
