# tmux-agent-sidebar

[English](README.md) | 简体中文

一个 tmux 侧边栏，列出所有 pane 里正在跑的 Claude Code / Codex 会话，按客户端
分组，并显示每个会话到底是在干活还是在等你。点击条目可直接跳到对应 pane。

不需要插件管理器，除 `tmux` 和 `bash` 外无任何依赖，只有一个脚本。

```
 AGENTS

 Claude Code · 3
● 0:0.1   my-project
  运行中 · 7m 44s
  █░░░░░░░░░ 9%
  Opus 5 (1M context)

▲ 0:1.0   api-server
  待确认 · 需要确认
  ██░░░░░░░░ 23%
  Opus 5 (1M context)

✓ 0:1.1   api-server
  已完成 · 3m
  █░░░░░░░░░ 13%
  Opus 5 (1M context)

 Codex · 1
○ 0:3.0   scratch
  空闲
  █░░░░░░░░░ 1%
  gpt-5.6-terra medium
```

| 标记 | 状态     | 含义                       |
|------|----------|----------------------------|
| ●    | `运行中` | 正在干活，附带已耗时       |
| ▲    | `待确认` | 卡在权限弹窗或提问上       |
| ✓    | `已完成` | 刚跑完，输出还留在屏幕上   |
| ○    | `空闲`   | 停在空输入框               |

上面每一项都可以单独关掉，见 [配置](#配置)。

## 安装

```sh
curl -o ~/.local/bin/tmux-agent-sidebar.sh \
  https://raw.githubusercontent.com/Zrzzzz/tmux-agent-sidebar/main/tmux-agent-sidebar.sh
chmod +x ~/.local/bin/tmux-agent-sidebar.sh
```

加进 `~/.tmux.conf`：

```tmux
# prefix + a 开关侧边栏，prefix + A 打开设置面板
bind a run-shell '~/.local/bin/tmux-agent-sidebar.sh --toggle #{pane_id}'
bind A display-popup -E -w 46 -h 15 '~/.local/bin/tmux-agent-sidebar.sh --config'

# 点击条目跳转；点其他地方保持 tmux 默认行为
set -g mouse on
bind -n MouseDown1Pane if -F '#{==:#{@agent_sidebar},1}' \
    "run-shell '~/.local/bin/tmux-agent-sidebar.sh --click #{pane_id} #{mouse_y}'" \
    'select-pane -t=; send-keys -M'
```

`tmux source-file ~/.tmux.conf` 重载后按 `prefix + a` 即可。

**`#{pane_id}` 不能省。** `run-shell` 不会把 `TMUX_PANE` 传给子进程，没有显式
目标时，`list-panes` 和 `split-window` 各自会退化到「当前活动 window」——那未必
是你按键所在的 window。结果就是侧边栏开到别的地方去，而且 toggle 再也找不回它。

## 用法

```sh
tmux-agent-sidebar.sh              # 前台运行，每 2 秒刷新
tmux-agent-sidebar.sh 5            # 每 5 秒刷新
tmux-agent-sidebar.sh --once       # 只输出一帧就退出
tmux-agent-sidebar.sh --toggle     # 开关侧边栏 pane
tmux-agent-sidebar.sh --config     # 设置面板
```

## 配置

`prefix + A` 打开面板，切换侧边栏显示哪些内容：

```
  侧边栏显示设置

  ❯ [ ] 顶部时间
    [✓] 客户端分组
    [✓] 工作目录
    [✓] 已耗时
    [✓] context 进度条
    [✓] 模型名称
    [✓] 显示空闲会话

  ↑↓/jk 移动    空格 切换    q 保存退出
```

| 键        | 默认  | 控制的内容                     |
|-----------|-------|--------------------------------|
| `clock`   | `off` | 标题旁的时间                   |
| `groups`  | `on`  | `Claude Code` / `Codex` 分组标题 |
| `path`    | `on`  | 条目首行的工作目录             |
| `elapsed` | `on`  | 状态旁的已耗时                 |
| `ctxbar`  | `on`  | context 用量进度条             |
| `model`   | `on`  | 模型名称                       |
| `idle`    | `on`  | 是否列出空闲会话               |

配置以 `key=value` 逐行存放在
`${XDG_CONFIG_HOME:-~/.config}/tmux-agent-sidebar.conf`，所以你也可以直接编辑
这个文件，或者把它放进自己的 dotfiles。正在运行的侧边栏每次刷新都会重读它，改完
一个刷新周期内就生效，不用重启。

关掉某些元素后条目会变矮，而点击命中表是用渲染时同一套数字算出来的，所以任意
开关组合下点击跳转都不会错位。

### 环境变量

| 变量            | 默认值 | 说明                                     |
|-----------------|--------|------------------------------------------|
| `SIDEBAR_WIDTH` | `34`   | 侧边栏宽度（列）                         |
| `SIDEBAR_LANG`  | 跟随 locale | `en` 或 `zh`，未设置时读 `$LC_ALL` / `$LC_MESSAGES` / `$LANG` |

```tmux
bind a run-shell 'SIDEBAR_WIDTH=42 SIDEBAR_LANG=zh ~/.local/bin/tmux-agent-sidebar.sh --toggle #{pane_id}'
```

`zh_CN` 环境下会自动显示中文。状态判定本身不依赖语言——`classify()` 返回固定的
英文 key，翻译只发生在渲染阶段。

## busy/idle 是怎么判出来的

这部分最容易做错，值得说清楚。

最直觉的做法——grep 出 `✻ Cogitated for 32s` 这样的 spinner 行当作「在跑」——
是**行不通的**。这行在**任务结束后依然留在屏幕上**，于是每个跑过东西的会话都会
永远显示为忙碌。

可靠的信号是：运行态和完成态这两行的**格式本来就不同**。

```
✽ Honking… (6m 25s · ↑ 21.1k tokens · thought for 3s)   <- 运行中：带括号统计
✻ Cogitated for 32s                                      <- 已完成：只有 "for Ns"
```

所以脚本认的是那个只有活跃 spinner 才有的括号统计块。光有 `for Ns` 的一律判为
`已完成` 而不是 `运行中`。

作为兜底（应对运行态渲染格式不同的 TUI 版本），脚本会把每个 pane 的 spinner 行
缓存到 `$TMPDIR`，跨刷新比对：如果秒数还在跳，那就是真的在跑。

`待确认` 放在最前面判，因为权限弹窗会把 spinner 整个顶掉。

## 点击跳转是怎么实现的

tmux 没法给 pane 里的某块文字挂回调，所以侧边栏自己维护了一张命中表：每次刷新
都把每个条目的 `<起始行> <结束行> <pane id>` 写进 `$TMPDIR` 下的文件，文件名带
侧边栏自己的 pane id，这样开多个侧边栏也不会互相覆盖。鼠标绑定把 `#{mouse_y}`
传进来，`--click` 查是哪个区间包含这一行。

跳转同时用了 `switch-client`、`select-window` 和 `select-pane`，因此目标在别的
window 甚至别的 session 都能跳过去。点在组标题或空行上不落在任何区间，不会有
任何动作。

## 客户端区分

直接跑 `claude` 或 `codex` 的 pane 按命令名归类。如果 agent 是通过 wrapper
（`node`、`bun`）启动的，就从 TUI 渲染的内容反推——`OpenAI Codex` / `Context N%
used` 归 Codex，`(1M context)` / `bypass permissions` / `esc to interrupt` 归
Claude Code。两者都不匹配的 `node` pane 不是 agent，直接跳过，所以随手起的开发
服务器不会混进来。

要支持别的 CLI，需要改三处：`detect_client()`、`render()` 里的命令名过滤、以及
模型和 context 的状态行解析：

```
Claude Code:  my-project | Opus 5 (1M context) · medium | [██░░░░░░░░] 22%
Codex:        gpt-5.6-terra medium · /path · Full Access · Context 1% used
```

状态判定集中在 `classify()`，显示文案集中在 `t()`，可开关的元素声明在
`CONFIG_SPEC`。

## 说明

- 用 `tmux list-panes -a` 发现 pane，所以其他 window、其他 tmux session 里的
  会话都会列出来。
- Codex 的 TUI 在状态行下方留了几十行空白，所以脚本先滤掉空行再截断抓取内容。
  直接 `tail -n` 会把真正需要的状态行挤出范围。
- Codex 的**运行态**目前靠通用的 `esc to interrupt` 规则匹配，尚未在真实运行中
  验证过；Claude Code 的已实测。
- 如果你用 tmux-resurrect，侧边栏 pane 会像其他 pane 一样被保存，但恢复回来只是
  一个普通 shell。要么把它加进 `@resurrect-processes`，要么直接关掉再按一次
  `prefix + a`。

## 许可

MIT
