#!/usr/bin/env bash
# Sidebar listing every Claude Code / Codex session running in tmux, with the
# live state of each one.
#
# Usage: tmux-agent-sidebar.sh [refresh seconds, default 2]
#
# Language follows $SIDEBAR_LANG (zh|en); if unset it is taken from the usual
# locale variables, so a zh_CN environment gets Chinese without configuration.

INTERVAL="${1:-2}"
SELF_PANE="${TMUX_PANE:-}"

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
C_GRAY=$'\033[90m'; C_CYAN=$'\033[36m'
C_CLAUDE=$'\033[38;5;209m'   # Claude Code group heading
C_CODEX=$'\033[38;5;114m'    # Codex group heading

STATE_DIR="${TMPDIR:-/tmp}/tmux-agent-sidebar-$(id -u)"
mkdir -p "$STATE_DIR"

# Row-to-pane map, one file per sidebar so several sidebars can coexist.
map_path() { printf '%s/click-%s.map' "$STATE_DIR" "${1//[^a-zA-Z0-9]/_}"; }
CLICK_MAP=$(map_path "$SELF_PANE")

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agent-sidebar.conf"

# Toggleable display elements: key|default|English label|中文标签
CONFIG_SPEC=(
    'clock|off|Clock in header|顶部时间'
    'groups|on|Client group headings|客户端分组'
    'path|on|Working directory|工作目录'
    'elapsed|on|Elapsed time|已耗时'
    'ctxbar|on|Context usage bar|context 进度条'
    'model|on|Model name|模型名称'
    'idle|on|Show idle sessions|显示空闲会话'
)

declare -A CFG

load_config() {
    local spec key def
    for spec in "${CONFIG_SPEC[@]}"; do
        IFS='|' read -r key def _ <<<"$spec"
        CFG["$key"]="$def"
    done
    [[ -r $CONFIG_FILE ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        [[ -n ${CFG[$k]+set} && ( $v == on || $v == off ) ]] && CFG["$k"]="$v"
    done <"$CONFIG_FILE"
    return 0
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")" || return 1
    local spec key
    {
        for spec in "${CONFIG_SPEC[@]}"; do
            IFS='|' read -r key _ <<<"$spec"
            printf '%s=%s\n' "$key" "${CFG[$key]}"
        done
    } >"$CONFIG_FILE.$$" && mv -f "$CONFIG_FILE.$$" "$CONFIG_FILE"
}

# Is a display element enabled?
on() { [[ ${CFG[$1]:-off} == on ]]; }

case "${SIDEBAR_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
    zh|zh[-_]*|*zh_CN*|*zh_SG*|*zh_TW*|*zh_HK*) I18N=zh ;;
    *)                                          I18N=en ;;
esac

# Display strings. classify() returns stable English keys and translation
# happens only at render time, so the detection logic never depends on locale.
t() {
    if [[ $I18N == zh ]]; then
        case $1 in
            busy)    printf '运行中'           ;;
            wait)    printf '待确认'           ;;
            done)    printf '已完成'           ;;
            idle)    printf '空闲'             ;;
            confirm) printf '需要确认'         ;;
            running) printf '进行中'           ;;
            none)    printf '没有运行中的会话' ;;
        esac
    else
        case $1 in
            busy)    printf 'busy'               ;;
            wait)    printf 'wait'               ;;
            done)    printf 'done'               ;;
            idle)    printf 'idle'               ;;
            confirm) printf 'needs confirmation' ;;
            running) printf 'running'            ;;
            none)    printf 'No agent sessions'  ;;
        esac
    fi
}

# Decide a pane's state from its rendered contents.
# Prints "<state key>\t<detail>". Edit this function to tune the rules.
classify() {
    local pane_id="$1" body="$2"

    # 1) Blocked on a permission prompt or a question. Checked first, because
    #    the prompt replaces the spinner entirely.
    if grep -qE 'Do you want|Would you like|\(y/n\)|❯ 1\.|Press Enter to' <<<"$body"; then
        printf 'wait\t'
        return
    fi

    # 2) Working. The live spinner carries a parenthesised stats block:
    #      ✽ Honking… (6m 25s · ↑ 21.1k tokens · thought for 3s)
    #    whereas a finished task leaves only "✻ Cogitated for 32s" behind.
    #    That difference is the whole trick — see step 3.
    local run_line
    run_line=$(grep -oE '^[[:space:]]*[✻✽✢✳∗*·][^(]*\([0-9]+[hms][^)]*\)' <<<"$body" | tail -1)
    if [[ -n $run_line ]] || grep -qE 'esc to interrupt|ctrl\+c to (stop|interrupt)' <<<"$body"; then
        local el
        el=$(grep -oE '\(([0-9]+[hms][[:space:]]*)+' <<<"$run_line" | tr -d '(' | sed 's/[[:space:]]*$//')
        printf 'busy\t%s' "$el"
        return
    fi

    # 3) A bare "✻ Churned for 38s" line. This stays on screen after the task
    #    ends, so a single snapshot cannot tell "running" from "finished".
    #    Treat it as finished unless the seconds are still ticking across
    #    refreshes, which is how older TUI versions render the running state.
    local spin cache had_prev prev
    spin=$(grep -oE '^[[:space:]]*[✻✽✢✳∗*·][^|]*for [0-9]+[ms]' <<<"$body" | tail -1)
    cache="$STATE_DIR/${pane_id//[^a-zA-Z0-9]/_}.spin"
    had_prev=0; [[ -e $cache ]] && { had_prev=1; prev=$(cat "$cache"); }
    printf '%s' "$spin" >"$cache"

    if [[ -n $spin ]]; then
        local secs; secs=$(grep -oE 'for [0-9]+[ms]' <<<"$spin" | cut -d' ' -f2)
        if (( had_prev )) && [[ $spin != "$prev" ]]; then
            printf 'busy\t%s' "$secs"
        else
            printf 'done\t%s' "$secs"
        fi
        return
    fi

    printf 'idle\t'
}

# Which CLI is this pane running? Prints "claude", "codex", or nothing at all
# when the pane is not an agent (a plain node/bun dev server, say).
detect_client() {
    local cmd="$1" body="$2"
    case $cmd in
        claude) printf 'claude'; return ;;
        codex)  printf 'codex';  return ;;
    esac
    # Launched through a wrapper — decide from what the TUI actually renders.
    if grep -qE 'OpenAI Codex|Context [0-9]+% used' <<<"$body"; then
        printf 'codex'
    elif grep -qE '\(1M context\)|bypass permissions|esc to interrupt' <<<"$body"; then
        printf 'claude'
    fi
}

# Progress bar for context usage, coloured by how full it is.
ctx_bar() {
    local pct="$1" width=10 filled i out='' c=$C_GREEN
    filled=$(( pct * width / 100 ))
    (( filled > width )) && filled=$width
    (( filled < 0 ))     && filled=0
    for ((i = 0; i < width; i++)); do
        (( i < filled )) && out+='█' || out+='░'
    done
    (( pct >= 80 )) && c=$C_YELLOW
    printf '%s%s%s %s%d%%%s' "$c" "$out" "$C_RESET" "$C_DIM" "$pct" "$C_RESET"
}

render() {
    load_config

    if on clock; then
        printf '%s AGENTS%s%s  %s%s\n\n' \
            "$C_BOLD$C_CYAN" "$C_RESET" "$C_GRAY" "$(date +%H:%M:%S)" "$C_RESET"
    else
        printf '%s AGENTS%s\n\n' "$C_BOLD$C_CYAN" "$C_RESET"
    fi

    local g_claude='' g_codex='' m_claude='' m_codex='' n_claude=0 n_codex=0
    while IFS=$'\t' read -r pane_id addr cmd path; do
        [[ $pane_id == "$SELF_PANE" ]] && continue
        # Only agent CLIs. Add other command names here as needed.
        [[ $cmd =~ ^(claude|codex|node|bun)$ ]] || continue

        local body client status extra label ctx model dot color entry
        # Strip blank lines before truncating: Codex leaves dozens of empty
        # lines below its status line, and a plain tail would push the line we
        # actually need out of range.
        body=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null \
               | grep -v '^[[:space:]]*$' | tail -30)

        client=$(detect_client "$cmd" "$body")
        [[ -n $client ]] || continue

        IFS=$'\t' read -r status extra < <(classify "$pane_id" "$body")
        on idle || [[ $status != idle ]] || continue
        label=$(t "$status")
        case $status in
            wait) extra=$(t confirm) ;;
            busy) [[ -n $extra ]] || extra=$(t running) ;;
        esac
        # "elapsed" only governs timings; a wait entry keeps its explanation.
        [[ $status == wait ]] || on elapsed || extra=''

        # The two CLIs render different status lines:
        #   Claude Code: "  my-project | Opus 5 (1M context) · medium | [██░░░░░░░░] 22%"
        #   Codex:       "  gpt-5.6-terra medium · /path · Full Access · Context 1% used"
        ctx=$(grep -oE '\[[█░ ]+\][[:space:]]*[0-9]+%|Context [0-9]+% used' <<<"$body" \
              | tail -1 | grep -oE '[0-9]+' | tail -1)
        model=$(grep -oE '(Opus|Sonnet|Haiku|Fable) [0-9][^|·]*|gpt-[0-9][^ ]*( [a-z]+)?' <<<"$body" \
                | tail -1 | sed 's/[[:space:]]*$//')

        case $status in
            busy) dot='●'; color=$C_GREEN  ;;
            wait) dot='▲'; color=$C_YELLOW ;;
            done) dot='✓'; color=$C_CYAN   ;;
            *)    dot='○'; color=$C_GRAY   ;;
        esac

        local dir='' height=3   # header + state + trailing blank line
        on path && dir=" $(basename "$path")"
        printf -v entry '%s%s%s %s%-7s%s%s\n  %s%s%s%s%s\n' \
            "$color" "$dot" "$C_RESET" "$C_BOLD" "$addr" "$C_RESET" "$dir" \
            "$color" "$label" "$C_RESET" "${extra:+$C_DIM · $extra}" "$C_RESET"
        if [[ -n $ctx ]] && on ctxbar; then
            printf -v entry '%s  %s\n' "$entry" "$(ctx_bar "$ctx")"
            height=$(( height + 1 ))
        fi
        if on model; then
            printf -v entry '%s  %s%s%s\n' "$entry" "$C_DIM$C_GRAY" "${model:-$cmd}" "$C_RESET"
            height=$(( height + 1 ))
        fi
        entry+=$'\n'
        if [[ $client == codex ]]; then
            g_codex+="$entry";  m_codex+="$pane_id $height"$'\n';  n_codex=$(( n_codex + 1 ))
        else
            g_claude+="$entry"; m_claude+="$pane_id $height"$'\n'; n_claude=$(( n_claude + 1 ))
        fi
    done < <(tmux list-panes -a -F \
        '#{pane_id}	#{session_name}:#{window_index}.#{pane_index}	#{pane_current_command}	#{pane_current_path}')

    # Record which screen rows belong to which pane, so --click can map a
    # mouse_y back to a target. Row 0 is the header, row 1 the blank after it.
    local map_tmp="$CLICK_MAP.$$" line=2
    : >"$map_tmp"

    emit_group() {  # $1=heading  $2=colour  $3=count  $4=entries  $5=meta
        (( $3 )) || return 0
        if on groups; then
            printf '%s %s%s %s· %d%s\n' "$C_BOLD$2" "$1" "$C_RESET" "$C_DIM" "$3" "$C_RESET"
            line=$(( line + 1 ))
        fi
        printf '%s' "$4"
        local pid h
        while read -r pid h; do
            [[ -n $pid ]] || continue
            printf '%d %d %s\n' "$line" "$(( line + h - 1 ))" "$pid" >>"$map_tmp"
            line=$(( line + h ))
        done <<<"$5"
    }

    emit_group 'Claude Code' "$C_CLAUDE" "$n_claude" "$g_claude" "$m_claude"
    emit_group 'Codex'       "$C_CODEX"  "$n_codex"  "$g_codex"  "$m_codex"

    mv -f "$map_tmp" "$CLICK_MAP" 2>/dev/null || rm -f "$map_tmp"

    (( n_claude + n_codex )) || printf '%s  %s%s\n' "$C_DIM" "$(t none)" "$C_RESET"
}

# Interactive toggle panel, meant to be run inside `tmux display-popup -E`.
config_panel() {
    load_config
    local n=${#CONFIG_SPEC[@]} sel=0 title hint i key label le lz mark box ch rest

    if [[ $I18N == zh ]]; then
        title='侧边栏显示设置'
        hint='↑↓/jk 移动    空格 切换    q 保存退出'
    else
        title='Sidebar display settings'
        hint='↑↓/jk move    space toggle    q save & quit'
    fi

    trap 'tput cnorm 2>/dev/null' EXIT
    tput civis 2>/dev/null

    while :; do
        printf '\033[H\033[2J'
        printf '  %s%s%s\n\n' "$C_BOLD$C_CYAN" "$title" "$C_RESET"

        for ((i = 0; i < n; i++)); do
            IFS='|' read -r key _ le lz <<<"${CONFIG_SPEC[$i]}"
            [[ $I18N == zh ]] && label="$lz" || label="$le"
            (( i == sel )) && mark="${C_CYAN}❯${C_RESET}" || mark=' '
            if on "$key"; then
                box="${C_GREEN}[✓]${C_RESET}"
            else
                box="${C_GRAY}[ ]${C_RESET}"
            fi
            printf '  %s %s %s\n' "$mark" "$box" "$label"
        done

        printf '\n  %s%s%s\n' "$C_DIM" "$hint" "$C_RESET"

        IFS= read -rsn1 ch || break
        case $ch in
            $'\x1b')                       # arrow keys arrive as ESC [ A/B
                read -rsn2 -t 0.05 rest
                case $rest in
                    '[A') sel=$(( (sel - 1 + n) % n )) ;;
                    '[B') sel=$(( (sel + 1) % n )) ;;
                esac ;;
            k|K)   sel=$(( (sel - 1 + n) % n )) ;;
            j|J)   sel=$(( (sel + 1) % n )) ;;
            ' '|'')
                IFS='|' read -r key _ <<<"${CONFIG_SPEC[$sel]}"
                if on "$key"; then CFG[$key]=off; else CFG[$key]=on; fi ;;
            q|Q)   break ;;
        esac
    done

    save_config          # cursor is restored by the EXIT trap
    printf '\033[H\033[2J'
}

if [[ $1 == --config ]]; then config_panel; exit 0; fi

if [[ $1 == --once ]]; then render; exit 0; fi

# Jump to the session the user clicked on. Called from the mouse binding as
#   --click <sidebar pane id> <mouse_y>
# where mouse_y is 0-based from the top of the sidebar pane.
if [[ $1 == --click ]]; then
    map=$(map_path "$2"); y="${3:-}"
    [[ -r $map && $y =~ ^[0-9]+$ ]] || exit 0
    while read -r from to pid; do
        if (( y >= from && y <= to )); then
            # switch-client handles a target in another session; select-window
            # and select-pane cover the same-session case.
            tmux switch-client -t "$pid" 2>/dev/null
            tmux select-window -t "$pid" 2>/dev/null
            tmux select-pane -t "$pid" 2>/dev/null
            break
        fi
    done <"$map"
    exit 0
fi

# Toggle: close the sidebar if this window already has one, else open it.
if [[ $1 == --toggle ]]; then
    # Pin every tmux call to the window the key was pressed in. run-shell does
    # not export TMUX_PANE to its child, so the key binding passes #{pane_id}
    # as $2. Without it, list-panes and split-window each fall back to the
    # *currently active* window and the sidebar opens in the wrong place.
    caller="${2:-$SELF_PANE}"
    tgt=(); [[ -n $caller ]] && tgt=(-t "$caller")

    existing=$(tmux list-panes "${tgt[@]}" -F '#{pane_id} #{@agent_sidebar}' \
               | awk '$2=="1"{print $1; exit}')
    if [[ -n $existing ]]; then
        tmux kill-pane -t "$existing"
    else
        new=$(tmux split-window "${tgt[@]}" -hbd -l "${SIDEBAR_WIDTH:-34}" \
                -P -F '#{pane_id}' "exec '$0'")
        tmux set-option -p -t "$new" @agent_sidebar 1
    fi
    exit 0
fi

trap 'tput cnorm 2>/dev/null; exit 0' INT TERM
tput civis 2>/dev/null
while :; do
    out=$(render)
    printf '\033[H\033[2J%s' "$out"
    sleep "$INTERVAL"
done
