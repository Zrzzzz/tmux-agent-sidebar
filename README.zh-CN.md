# tmux-agent-sidebar

[English](README.md) | 简体中文

一个 tmux 侧边栏，列出所有 pane 里正在跑的 Claude Code / Codex 会话，按客户端
分组，并显示每个会话到底是在干活还是在等你。点击条目可直接跳到对应 pane。

状态来自 **agent hook**，不是抓取终端输出，所以 TUI 改了渲染方式也不会失效。
不需要插件管理器，运行时只依赖 `tmux`、`bash` 和 `jq`。

```
 AGENTS

 Claude Code · 3
● my-project
  运行中 ⏸plan · 7m 44s
  重构 auth 层
  ⚒ Edit
  ⑂ 2 Explore
  ▪▪▫▫ 2/4
  █░░░░░░░░░ 9%
  Opus 5 (1M context)

▲ api-server
  待确认 · 需要确认
  ██░░░░░░░░ 23%
  Opus 5 (1M context)

✓ api-server
  已完成 · 3m 前
  █░░░░░░░░░ 13%
  Opus 5 (1M context)

 Codex · 1
○ scratch
  空闲
  gpt-5.6-terra
```

| 标记 | 状态     | 含义                       |
|------|----------|----------------------------|
| ●    | `运行中` | 正在干活，附带已耗时       |
| ▲    | `待确认` | 卡在权限请求上             |
| ✓    | `已完成` | 刚跑完                     |
| ○    | `空闲`   | 停在空输入框               |

条目里还可能出现：`⏸plan` 表示处在 plan 模式，`⚒` 是正在执行的工具，`⑂` 是
正在跑的子 agent 数量，`▪▫` 是 plan 清单的完成进度。每一项都能单独关掉，见
[配置](#配置)。

## 安装

```sh
curl -o ~/.local/bin/tmux-agent-sidebar.sh \
  https://raw.githubusercontent.com/Zrzzzz/tmux-agent-sidebar/main/tmux-agent-sidebar.sh
curl -o ~/.local/bin/tmux-agent-sidebar-collect.sh \
  https://raw.githubusercontent.com/Zrzzzz/tmux-agent-sidebar/main/tmux-agent-sidebar-collect.sh
chmod +x ~/.local/bin/tmux-agent-sidebar*.sh
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

`tmux source-file ~/.tmux.conf` 重载后按 `prefix + a`。

### 接入 agent

侧边栏里什么都不会出现，直到至少有一个 agent 向它上报。

```sh
./install-hooks.sh claude    # 写 ~/.claude/settings.json + statusline
./install-hooks.sh codex     # 写 ~/.codex/hooks.json + feature flag
./install-hooks.sh --uninstall
```

已有的 hook 配置会被**合并而不是替换**，并且首次改动前会留一份
`.bak-agent-sidebar` 备份。

Claude Code 立即生效。**Codex 必须重启**，因为 `config.toml` 里的
`hooks` 开关只在启动时读取。

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
    [ ] pane 地址 (0:1.2)
    [✓] 会话标题
    [✓] 工作目录
    [✓] 当前工具调用
    [✓] 子 agent 数量
    [✓] plan 清单进度
    [✓] 已耗时
    [✓] context 进度条
    [✓] 模型名称
    [✓] 显示空闲会话

  ↑↓/jk 移动    空格 切换    q 保存退出
```

| 键          | 默认  | 控制的内容                       |
|-------------|-------|----------------------------------|
| `clock`     | `off` | 标题旁的时间                     |
| `groups`    | `on`  | `Claude Code` / `Codex` 分组标题 |
| `addr`      | `off` | tmux 地址 `session:window.pane`  |
| `title`     | `on`  | 会话标题                         |
| `path`      | `on`  | 条目首行的工作目录               |
| `tool`      | `on`  | 正在执行的工具                   |
| `subagents` | `on`  | 正在跑的子 agent 数量            |
| `tasks`     | `on`  | plan 清单完成进度                |
| `elapsed`   | `on`  | 状态旁的已耗时                   |
| `ctxbar`    | `on`  | context 用量进度条               |
| `model`     | `on`  | 模型名称                         |
| `idle`      | `on`  | 是否列出空闲会话                 |

配置以 `key=value` 逐行存放在
`${XDG_CONFIG_HOME:-~/.config}/tmux-agent-sidebar.conf`，可以直接编辑，或者放进
自己的 dotfiles。正在运行的侧边栏每次刷新都会重读它，改完一个刷新周期内生效。

关掉某些元素后条目会变矮，而点击命中表是用渲染时同一套数字算出来的，所以任意
开关组合下点击跳转都不会错位。

### 环境变量

| 变量            | 默认值      | 说明                                     |
|-----------------|-------------|------------------------------------------|
| `SIDEBAR_WIDTH` | `34`        | 侧边栏宽度（列）                         |
| `SIDEBAR_LANG`  | 跟随 locale | `en` 或 `zh`，未设置时读 `$LC_ALL` / `$LC_MESSAGES` / `$LANG` |

`zh_CN` 环境下自动显示中文。状态 key 在状态文件里始终是英文，翻译只发生在渲染
阶段，所以显示语言不影响任何行为。

## 状态从哪来

终端输出完全不参与。两个来源各自往「每个 pane 一个 JSON 文件」里写，侧边栏只
负责渲染这些文件。

**agent hook** 驱动状态机。hook 继承 agent 的环境，所以 `TMUX_PANE` 能确定事件
属于哪个 pane——整套方案能成立全靠这一点。

| 事件 | 作用 |
|---|---|
| `SessionStart` | pane 出现，`空闲` |
| `UserPromptSubmit` | `运行中`，本轮计时开始，每轮计数器清零 |
| `PostToolUse` | 记录正在执行的工具 |
| `PermissionRequest` | `待确认`——卡在你这儿 |
| `SubagentStart` / `SubagentStop` | 子 agent 计数 |
| `TaskCreated` / `TaskCompleted` | plan 清单进度（仅 Claude） |
| `Stop` | `已完成` |
| `SessionEnd` | pane 消失 |

**Claude 的 statusline** 补上 hook 拿不到的东西：模型、context 窗口大小与用量、
会话标题、累计花费。Codex 的模型名直接在 hook payload 里，但它没有 context 用量
的对应字段，所以 Codex 条目没有 context 进度条。

每个事件都是一个 **patch**：它没设置的字段保持原值。所以 tool 事件不会擦掉
prompt，statusline 也永远不会覆盖只有 hook 才知道的状态。

### 为什么不读屏幕

最直觉的做法——grep 出 `✻ Cogitated for 32s` 这样的 spinner 行当作「在跑」——
是行不通的。这行在**任务结束后依然留在屏幕上**，于是每个跑过东西的会话都会永远
显示为忙碌。本项目早期版本靠运行态和完成态**字符串形状的差异**来区分（活跃
spinner 带括号统计 `(6m 25s · ↑ 21.1k tokens)`，完成态只有 `for 32s`），这能用，
但 TUI 一改布局就会静默失效。改用 hook 之后就不需要猜了。

## Codex 的差异

Codex 的 hooks 格式和 Claude Code 一样（事件 → matcher 组 → handler），但要先
打开实验开关：

```toml
# ~/.codex/config.toml
[features]
hooks = true
```

`install-hooks.sh codex` 会自动加这段。已有 `[features]` 表就往里插，没有就追加
到文件末尾——TOML 里裸键会归属于上一个表头，所以新表必须放最后。

支持的事件比 Claude 少：没有 `SessionEnd`（所以 Codex 会话要靠 pane 消失来清理）、
没有 `TaskCreated` / `TaskCompleted`（没有 plan 清单进度）。

## 点击跳转是怎么实现的

tmux 没法给 pane 里的某块文字挂回调，所以侧边栏自己维护了一张命中表：每次刷新
都把每个条目的 `<起始行> <结束行> <pane id>` 写进 `$TMPDIR` 下的文件，文件名带
侧边栏自己的 pane id，这样开多个侧边栏也不会互相覆盖。鼠标绑定把 `#{mouse_y}`
传进来，`--click` 查是哪个区间包含这一行。

跳转同时用了 `switch-client`、`select-window` 和 `select-pane`，因此目标在别的
window 甚至别的 session 都能跳过去。点在组标题或空行上不落在任何区间，不会有
任何动作。

## 说明

- 状态文件在 `${XDG_STATE_HOME:-~/.local/state}/tmux-agent-sidebar/panes/`，
  每个 pane 一个。pane 关掉后，下一次渲染会自动清理它的遗留文件。
- 侧边栏显示的是所有 tmux session 里的 agent，不限于当前 window。
- 如果你用 tmux-resurrect，侧边栏 pane 会像其他 pane 一样被保存，但恢复回来只是
  一个普通 shell。要么把它加进 `@resurrect-processes`，要么关掉再按一次
  `prefix + a`。

## 许可

MIT
