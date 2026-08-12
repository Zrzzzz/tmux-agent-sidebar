#!/usr/bin/env bash
# 在 tmux pane 里显示所有 Claude Code / Codex 会话的状态。
# 用法: tmux-agent-sidebar.sh [刷新间隔秒数, 默认 2]

INTERVAL="${1:-2}"
SELF_PANE="${TMUX_PANE:-}"

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
C_GRAY=$'\033[90m'; C_CYAN=$'\033[36m'

STATE_DIR="${TMPDIR:-/tmp}/tmux-agent-sidebar-$(id -u)"
mkdir -p "$STATE_DIR"

# 从 pane 内容判断状态，输出 "状态\t补充信息"
# 想调整判断规则，改这个函数就行。
classify() {
    local pane_id="$1" body="$2"

    # 1) 等待用户确认（权限弹窗 / 选择题）—— 优先级最高
    if grep -qE 'Do you want|Would you like|\(y/n\)|❯ 1\.|Press Enter to' <<<"$body"; then
        printf 'wait\t需要确认'
        return
    fi

    # 2) 正在工作。运行态的 spinner 行带括号统计：
    #      ✽ Honking… (6m 25s · ↑ 21.1k tokens · thought for 3s)
    #    而任务结束后的残留行只有 "✻ Cogitated for 32s"，没有括号——这是关键区别。
    local run_line
    run_line=$(grep -oE '^[[:space:]]*[✻✽✢✳∗*·][^(]*\([0-9]+[hms][^)]*\)' <<<"$body" | tail -1)
    if [[ -n $run_line ]] || grep -qE 'esc to interrupt|ctrl\+c to (stop|interrupt)' <<<"$body"; then
        local el
        el=$(grep -oE '\(([0-9]+[hms][[:space:]]*)+' <<<"$run_line" | tr -d '(' | sed 's/[[:space:]]*$//')
        printf 'busy\t%s' "${el:-运行中}"
        return
    fi

    # 3) spinner 行 "✻ Churned for 38s"。这行在任务结束后也会留在屏幕上，
    #    所以单次快照区分不了"在跑"和"跑完了"——靠跨轮比较秒数是否还在变。
    local spin cache had_prev prev
    spin=$(grep -oE '^[[:space:]]*[✻✽✢✳∗*·][^|]*for [0-9]+[ms]' <<<"$body" | tail -1)
    cache="$STATE_DIR/${pane_id//[^a-zA-Z0-9]/_}.spin"
    had_prev=0; [[ -e $cache ]] && { had_prev=1; prev=$(cat "$cache"); }
    printf '%s' "$spin" >"$cache"

    if [[ -n $spin ]]; then
        local secs; secs=$(grep -oE 'for [0-9]+[ms]' <<<"$spin" | cut -d' ' -f2)
        # 无括号统计 = 已完成的残留行。除非秒数还在跳（老版本 TUI 的运行态格式），
        # 那种情况下跨轮一比就能看出来。
        if (( had_prev )) && [[ $spin != "$prev" ]]; then
            printf 'busy\t%s' "$secs"
        else
            printf 'done\t%s' "$secs"
        fi
        return
    fi

    printf 'idle\t'
}

render() {
    printf '%s AGENTS%s%s  %s%s\n\n' \
        "$C_BOLD$C_CYAN" "$C_RESET" "$C_GRAY" "$(date +%H:%M:%S)" "$C_RESET"

    local found=0
    while IFS=$'\t' read -r pane_id addr cmd path; do
        [[ $pane_id == "$SELF_PANE" ]] && continue
        # 只关心 agent CLI；按需在这里加别的命令名
        [[ $cmd =~ ^(claude|codex|node|bun)$ ]] || continue

        local body status extra ctx model dot color
        # 先滤空行再截断：Codex 的 TUI 在状态行后面留几十行空白，
        # 直接 tail 会把真正有用的状态行挤出抓取范围。
        body=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null \
               | grep -v '^[[:space:]]*$' | tail -30)
        # 排除误匹配的普通 node 进程
        [[ $cmd == claude || $cmd == codex ]] || \
            grep -qE 'esc to interrupt|context left|tokens' <<<"$body" || continue

        found=1
        IFS=$'\t' read -r status extra < <(classify "$pane_id" "$body")

        # 两家的底部状态行格式不同：
        #   Claude Code: "  arvo2i | Opus 5 (1M context) · medium | [██░░░░░░░░] 22%"
        #   Codex:       "  gpt-5.6-terra medium · /path · Full Access · Context 1% used · Fast on"
        ctx=$(grep -oE '\[[█░ ]+\][[:space:]]*[0-9]+%|Context [0-9]+% used' <<<"$body" \
              | tail -1 | grep -oE '[0-9]+%')
        model=$(grep -oE '(Opus|Sonnet|Haiku|Fable) [0-9][^|·]*|gpt-[0-9][^ ]*( [a-z]+)?' <<<"$body" \
                | tail -1 | sed 's/[[:space:]]*$//')

        case $status in
            busy) dot='●'; color=$C_GREEN  ;;
            wait) dot='▲'; color=$C_YELLOW ;;
            done) dot='✓'; color=$C_CYAN   ;;
            *)    dot='○'; color=$C_GRAY   ;;
        esac

        printf '%s%s%s %s%-7s%s %s\n' \
            "$color" "$dot" "$C_RESET" "$C_BOLD" "$addr" "$C_RESET" "$(basename "$path")"
        printf '  %s%s%s%s%s%s\n' \
            "$color" "$status" "$C_RESET" \
            "${extra:+$C_DIM · $extra}" \
            "${ctx:+$C_DIM · ctx $ctx}" "$C_RESET"
        printf '  %s%s%s\n\n' "$C_DIM$C_GRAY" "${model:-$cmd}" "$C_RESET"
    done < <(tmux list-panes -a -F \
        '#{pane_id}	#{session_name}:#{window_index}.#{pane_index}	#{pane_current_command}	#{pane_current_path}')

    (( found )) || printf '%s  没有运行中的会话%s\n' "$C_DIM" "$C_RESET"
}

if [[ $1 == --once ]]; then render; exit 0; fi

# 开关：当前 window 里已有侧边栏就关掉，否则在左侧开一个
if [[ $1 == --toggle ]]; then
    # 锁定到触发所在的 window。run-shell 的子进程环境里没有 TMUX_PANE，
    # 所以键绑定通过 #{pane_id} 把触发 pane 作为 $2 显式传进来；
    # 不指定的话 list-panes/split-window 会各自作用于"当前活动 window"，开错地方。
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
