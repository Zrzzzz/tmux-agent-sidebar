#!/usr/bin/env bash
# Records Claude Code state for the tmux pane it runs in.
#
# Invoked two ways, both of which inherit Claude Code's environment (and so
# TMUX_PANE, which is what ties an event to a pane):
#
#   * as a hook command   — settings.json "hooks", one event per invocation
#   * from the statusline — which is the only place model, context window and
#                           session title are exposed
#
# Usage: tmux-agent-sidebar-collect.sh <event>
#   statusline | session-start | prompt | tool | stop | notify | session-end
#
# Reads the event JSON on stdin and merges it into the pane's state file.

event="${1:-}"
pane="${TMUX_PANE:-}"
[[ -n $pane && -n $event ]] || exit 0     # outside tmux: nothing to attribute

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agent-sidebar/panes"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
file="$STATE_DIR/${pane//[^a-zA-Z0-9]/_}.json"

if [[ $event == session-end ]]; then
    rm -f "$file"
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
[[ -n $input ]] || exit 0
now=$(date +%s)

# Per-event patch. Keys absent from a patch keep their previous value, so a
# tool event does not erase the prompt and the statusline never overwrites a
# status that only the event hooks can know.
case $event in
    statusline)
        patch=$(jq -c --argjson now "$now" '{
            client:       "claude",
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
            client: "claude", session_id: (.session_id // ""),
            cwd: (.cwd // ""), status: "idle", since: $now,
            tool: null, updated: $now
        }' <<<"$input" 2>/dev/null) ;;

    prompt)
        patch=$(jq -c --argjson now "$now" '{
            status: "busy", since: $now, tool: null,
            prompt: ((.prompt // .user_prompt // "") | gsub("\\s+"; " ")
                     | if length > 80 then .[0:80] + "…" else . end),
            updated: $now
        }' <<<"$input" 2>/dev/null) ;;

    tool)
        # Keep `since` — it marks when the turn started, not this tool call.
        patch=$(jq -c --argjson now "$now" '{
            status: "busy", tool: (.tool_name // null), updated: $now
        }' <<<"$input" 2>/dev/null) ;;

    stop)
        patch=$(jq -c --argjson now "$now" '{
            status: "done", since: $now, tool: null, updated: $now
        }' <<<"$input" 2>/dev/null) ;;

    notify)
        # Only a permission prompt means "blocked on the user"; other
        # notifications must not clobber a running state.
        patch=$(jq -c --argjson now "$now" '
            if ((.notification_type // .type // "") | test("permission"))
               or ((.message // "") | test("permission|approve|confirm"; "i"))
            then {status: "wait", since: $now, updated: $now}
            else {updated: $now} end' <<<"$input" 2>/dev/null) ;;

    *) exit 0 ;;
esac

[[ -n $patch ]] || exit 0

old='{}'
[[ -r $file ]] && old=$(cat "$file" 2>/dev/null) && [[ -n $old ]] || old='{}'

tmp="$file.$$"
if jq -c -n --argjson old "$old" --argjson patch "$patch" \
       --arg pane "$pane" '$old + $patch + {pane: $pane}' >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file"
else
    rm -f "$tmp"
fi
exit 0
