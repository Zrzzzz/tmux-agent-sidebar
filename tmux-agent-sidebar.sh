#!/usr/bin/env bash
# Sidebar listing every Claude Code session running in tmux, with the live
# state of each one.
#
# State comes from Claude Code hooks and the statusline, not from scraping
# terminal output — see tmux-agent-sidebar-collect.sh. Each pane has a JSON
# file under $XDG_STATE_HOME; this script only renders them.
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

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agent-sidebar/panes"
RUN_DIR="${TMPDIR:-/tmp}/tmux-agent-sidebar-$(id -u)"
mkdir -p "$RUN_DIR"

# Row-to-pane map, one file per sidebar so several sidebars can coexist.
map_path() { printf '%s/click-%s.map' "$RUN_DIR" "${1//[^a-zA-Z0-9]/_}"; }
CLICK_MAP=$(map_path "$SELF_PANE")

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agent-sidebar.conf"

# Toggleable display elements: key|default|English label|中文标签
CONFIG_SPEC=(
    'clock|off|Clock in header|顶部时间'
    'groups|on|Client group headings|客户端分组'
    'addr|off|Pane address (0:1.2)|pane 地址 (0:1.2)'
    'title|on|Session title|会话标题'
    'path|on|Working directory|工作目录'
    'tool|on|Current tool call|当前工具调用'
    'subagents|on|Subagent count|子 agent 数量'
    'tasks|on|Plan checklist progress|plan 清单进度'
    'elapsed|on|Elapsed time|已耗时'
    'ctxbar|on|Context usage bar|context 进度条'
    'model|on|Model name|模型名称'
    'idle|on|Show idle sessions|显示空闲会话'
)

# Settings live in one shell variable per key (CFG_clock, CFG_groups, …).
# macOS ships bash 3.2, which has no associative arrays; the keys come from
# CONFIG_SPEC and are plain identifiers, so a name-built variable is safe.
cfg_get() { eval "printf '%s' \"\${CFG_$1:-off}\""; }
cfg_set() { eval "CFG_$1=\$2"; }

# Is $1 a key CONFIG_SPEC declares?
cfg_known() {
    local spec key
    for spec in "${CONFIG_SPEC[@]}"; do
        IFS='|' read -r key _ <<<"$spec"
        [[ $key == "$1" ]] && return 0
    done
    return 1
}

load_config() {
    local spec key def
    for spec in "${CONFIG_SPEC[@]}"; do
        IFS='|' read -r key def _ <<<"$spec"
        cfg_set "$key" "$def"
    done
    [[ -r $CONFIG_FILE ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        [[ $v == on || $v == off ]] || continue
        cfg_known "$k" && cfg_set "$k" "$v"
    done <"$CONFIG_FILE"
    return 0
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")" || return 1
    local spec key
    {
        for spec in "${CONFIG_SPEC[@]}"; do
            IFS='|' read -r key _ <<<"$spec"
            printf '%s=%s\n' "$key" "$(cfg_get "$key")"
        done
    } >"$CONFIG_FILE.$$" && mv -f "$CONFIG_FILE.$$" "$CONFIG_FILE"
}

# Is a display element enabled?
on() { eval "[[ \${CFG_$1:-off} == on ]]"; }

case "${SIDEBAR_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
    zh|zh[-_]*|*zh_CN*|*zh_SG*|*zh_TW*|*zh_HK*) I18N=zh ;;
    *)                                          I18N=en ;;
esac

# Display strings. State keys stay English everywhere else, so the rendering
# language never affects behaviour.
t() {
    if [[ $I18N == zh ]]; then
        case $1 in
            busy)    printf '运行中'           ;;
            wait)    printf '待确认'           ;;
            done)    printf '已完成'           ;;
            idle)    printf '空闲'             ;;
            confirm) printf '需要确认'         ;;
            ago)     printf '前'               ;;
            none)    printf '没有运行中的会话' ;;
            nohook)  printf '未检测到会话——hook 可能未安装' ;;
        esac
    else
        case $1 in
            busy)    printf 'busy'               ;;
            wait)    printf 'wait'               ;;
            done)    printf 'done'               ;;
            idle)    printf 'idle'               ;;
            confirm) printf 'needs confirmation' ;;
            ago)     printf 'ago'                ;;
            none)    printf 'No agent sessions'  ;;
            nohook)  printf 'Nothing found — hooks may not be installed' ;;
        esac
    fi
}

# Seconds to a compact "2h 5m" / "45s".
human_time() {
    local s=$1
    (( s < 0 )) && s=0
    if   (( s < 60 ));   then printf '%ds' "$s"
    elif (( s < 3600 )); then printf '%dm %ds' $(( s / 60 )) $(( s % 60 ))
    else                      printf '%dh %dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
    fi
}

# Progress bar for context usage, coloured by how full it is.
ctx_bar() {
    local pct="$1" width=10 filled i out='' c=$C_GREEN
    filled=$(( pct * width / 100 ))
    (( filled > width ))         && filled=$width
    (( filled < 0 ))             && filled=0
    (( pct > 0 && filled == 0 )) && filled=1   # never render nonzero as empty
    for ((i = 0; i < width; i++)); do
        (( i < filled )) && out+='█' || out+='░'
    done
    (( pct >= 80 )) && c=$C_YELLOW
    printf '%s%s%s %s%d%%%s' "$c" "$out" "$C_RESET" "$C_DIM" "$pct" "$C_RESET"
}

# Look pane $1 up in the tmux pane listing $2, setting PANE_ADDR / PANE_CMD.
# Returns 1 when tmux no longer has the pane.
pane_info() {
    local pid addr pcmd
    while IFS=$'\t' read -r pid addr pcmd; do
        if [[ $pid == "$1" ]]; then
            PANE_ADDR="$addr"; PANE_CMD="$pcmd"
            return 0
        fi
    done <<<"$2"
    PANE_ADDR=''; PANE_CMD=''
    return 1
}

render() {
    load_config

    if on clock; then
        printf '%s AGENTS%s%s  %s%s\n\n' \
            "$C_BOLD$C_CYAN" "$C_RESET" "$C_GRAY" "$(date +%H:%M:%S)" "$C_RESET"
    else
        printf '%s AGENTS%s\n\n' "$C_BOLD$C_CYAN" "$C_RESET"
    fi

    # Panes that still exist, plus what each is running now, so state left
    # behind by a closed pane — or by an agent that exited inside a pane that
    # is still open — is ignored.
    # One tab-separated record per line; pane_info() looks a pane up in it.
    local LIVE
    LIVE=$(tmux list-panes -a -F '#{pane_id}	#{session_name}:#{window_index}.#{pane_index}	#{pane_current_command}' 2>/dev/null)

    local g_claude='' g_codex='' m_claude='' m_codex='' n_claude=0 n_codex=0
    local now; now=$(date +%s)
    local f

    for f in "$STATE_DIR"/*.json; do
        [[ -r $f ]] || continue

        local pane client status since tool title model ctx cwd
        local plan subs subtype tdone ttotal
        # Fields are joined with US (0x1f), not tab: tab is an IFS whitespace
        # character, so `read` would collapse runs of them and silently shift
        # every field left of an empty one — which is what happens the moment a
        # session has no tool running.
        IFS=$'\x1f' read -r pane client status since tool title model ctx cwd \
                            plan subs subtype tdone ttotal \
            < <(jq -r '[.pane // "", .client // "claude", .status // "idle",
                        (.since // 0), .tool // "",
                        .session_name // "", .model // "",
                        (.ctx_pct // ""), .cwd // "",
                        (.plan // false), (.subagents // 0),
                        .subagent_type // "",
                        (.tasks_done // 0), (.tasks_total // 0)]
                       | map(tostring | gsub("[\n\r]"; " "))
                       | join("")' "$f" 2>/dev/null)

        [[ -n $pane ]] || continue
        # Drop state for panes tmux no longer has, and for panes that have
        # dropped back to a shell — Codex has no SessionEnd event, so an agent
        # that exits inside a surviving pane would otherwise linger forever.
        # Claude keeps reporting `claude` as the pane command even while a Bash
        # tool call runs, so this does not race with normal tool use.
        if ! pane_info "$pane" "$LIVE" ||
           [[ $PANE_CMD =~ ^(bash|zsh|sh|fish|tcsh|ksh|dash|screen|tmux)$ ]]; then
            rm -f "$f" 2>/dev/null
            continue
        fi
        [[ $pane == "$SELF_PANE" ]] && continue
        on idle || [[ $status != idle ]] || continue

        local addr="$PANE_ADDR" label extra='' dot color entry height=3
        label=$(t "$status")

        case $status in
            busy) dot='●'; color=$C_GREEN
                  (( since > 0 )) && extra=$(human_time $(( now - since ))) ;;
            wait) dot='▲'; color=$C_YELLOW; extra=$(t confirm) ;;
            done) dot='✓'; color=$C_CYAN
                  (( since > 0 )) && extra="$(human_time $(( now - since ))) $(t ago)" ;;
            *)    dot='○'; color=$C_GRAY ;;
        esac
        # "elapsed" governs timings only; a wait entry keeps its explanation.
        [[ $status == wait ]] || on elapsed || extra=''

        # Headline: the tmux address, the directory, or both. Whichever is
        # leftmost identifies the entry and gets the emphasis; if both are
        # switched off the address comes back, since a row needs a label.
        local a='' d='' head
        on addr && a="$addr"
        on path && [[ -n $cwd ]] && d=$(basename "$cwd")
        [[ -n $a || -n $d ]] || a="$addr"
        if [[ -n $a && -n $d ]]; then
            printf -v head '%s%-7s%s %s' "$C_BOLD" "$a" "$C_RESET" "$d"
        else
            printf -v head '%s%s%s' "$C_BOLD" "${a:-$d}" "$C_RESET"
        fi

        local planmark=''
        [[ $plan == true ]] && planmark="$C_YELLOW ⏸plan$C_RESET"

        printf -v entry '%s%s%s %s\n  %s%s%s%s%s%s\n' \
            "$color" "$dot" "$C_RESET" "$head" \
            "$color" "$label" "$C_RESET" "$planmark" \
            "${extra:+$C_DIM · $extra}" "$C_RESET"

        if on title && [[ -n $title ]]; then
            printf -v entry '%s  %s%.28s%s\n' "$entry" "$C_DIM" "$title" "$C_RESET"
            height=$(( height + 1 ))
        fi
        if on tool && [[ -n $tool && $status == busy ]]; then
            printf -v entry '%s  %s⚒ %s%s\n' "$entry" "$C_DIM$C_CYAN" "$tool" "$C_RESET"
            height=$(( height + 1 ))
        fi
        if on subagents && (( subs > 0 )); then
            printf -v entry '%s  %s⑂ %d%s%s\n' "$entry" "$C_DIM$C_CYAN" \
                "$subs" "${subtype:+ $subtype}" "$C_RESET"
            height=$(( height + 1 ))
        fi
        # Plan checklist: a filled cell per completed task.
        if on tasks && (( ttotal > 0 )); then
            local bar='' i
            for ((i = 0; i < ttotal && i < 12; i++)); do
                (( i < tdone )) && bar+='▪' || bar+='▫'
            done
            printf -v entry '%s  %s%s %d/%d%s\n' "$entry" "$C_CYAN" \
                "$bar" "$tdone" "$ttotal" "$C_RESET"
            height=$(( height + 1 ))
        fi
        if on ctxbar && [[ -n $ctx ]]; then
            printf -v entry '%s  %s\n' "$entry" "$(ctx_bar "$ctx")"
            height=$(( height + 1 ))
        fi
        if on model && [[ -n $model ]]; then
            printf -v entry '%s  %s%s%s\n' "$entry" "$C_DIM$C_GRAY" "$model" "$C_RESET"
            height=$(( height + 1 ))
        fi
        entry+=$'\n'

        if [[ $client == codex ]]; then
            g_codex+="$entry";  m_codex+="$pane $height"$'\n';  n_codex=$(( n_codex + 1 ))
        else
            g_claude+="$entry"; m_claude+="$pane $height"$'\n'; n_claude=$(( n_claude + 1 ))
        fi
    done

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

    if (( n_claude + n_codex == 0 )); then
        if compgen -G "$STATE_DIR/*.json" >/dev/null; then
            printf '%s  %s%s\n' "$C_DIM" "$(t none)" "$C_RESET"
        else
            printf '%s  %s%s\n' "$C_DIM" "$(t nohook)" "$C_RESET"
        fi
    fi
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
                # bash 3.2 (the macOS system bash) only takes whole seconds.
                read -rsn2 -t 1 rest
                case $rest in
                    '[A') sel=$(( (sel - 1 + n) % n )) ;;
                    '[B') sel=$(( (sel + 1) % n )) ;;
                esac ;;
            k|K)   sel=$(( (sel - 1 + n) % n )) ;;
            j|J)   sel=$(( (sel + 1) % n )) ;;
            ' '|'')
                IFS='|' read -r key _ <<<"${CONFIG_SPEC[$sel]}"
                if on "$key"; then cfg_set "$key" off; else cfg_set "$key" on; fi ;;
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
        width="${SIDEBAR_WIDTH:-34}"
        new=$(tmux split-window "${tgt[@]}" -hbd -l "$width" \
                -P -F '#{pane_id}' "exec '$0'")
        tmux set-option -p -t "$new" @agent_sidebar 1
        # split-window -l is not always honoured: a window that has had panes
        # closed keeps layout history that overrides it. Set the width again.
        tmux resize-pane -t "$new" -x "$width" 2>/dev/null
    fi
    exit 0
fi

# Anything left over is the refresh interval. Reject anything else instead of
# handing it to sleep, which reports it as an illegal option.
if [[ ! $INTERVAL =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s: unknown argument %s\n' "${0##*/}" "$INTERVAL" >&2
    printf 'usage: %s [refresh seconds | --once | --toggle | --config]\n' \
        "${0##*/}" >&2
    exit 2
fi

# Switch to the alternate screen. It has no scrollback, so the pane cannot be
# scrolled back through every frame ever drawn; leaving it restores whatever
# was on screen before.
cleanup() { printf '\033[?1049l'; tput cnorm 2>/dev/null; }
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT
printf '\033[?1049h'
tput civis 2>/dev/null
while :; do
    out=$(render)
    printf '\033[H\033[2J%s' "$out"
    sleep "$INTERVAL"
done
