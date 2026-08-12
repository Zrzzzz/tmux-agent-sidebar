# tmux-agent-sidebar

English | [简体中文](README.zh-CN.md)

A tmux sidebar that shows every Claude Code / Codex session running across your
panes — grouped by client, with whether each one is actually working or waiting
for you. Click an entry to jump straight to that pane.

No plugin manager, no dependencies beyond `tmux` and `bash`. One script.

```
 AGENTS

 Claude Code · 3
● 0:0.1   my-project
  busy · 7m 44s
  █░░░░░░░░░ 9%
  Opus 5 (1M context)

▲ 0:1.0   api-server
  wait · needs confirmation
  ██░░░░░░░░ 23%
  Opus 5 (1M context)

✓ 0:1.1   api-server
  done · 3m
  █░░░░░░░░░ 13%
  Opus 5 (1M context)

 Codex · 1
○ 0:3.0   scratch
  idle
  █░░░░░░░░░ 1%
  gpt-5.6-terra medium
```

| Mark | State  | Meaning                                    |
|------|--------|--------------------------------------------|
| ●    | `busy` | Actively working, with elapsed time        |
| ▲    | `wait` | Blocked on a permission prompt or question |
| ✓    | `done` | Just finished; output still on screen      |
| ○    | `idle` | Sitting at an empty prompt                 |

Every element above can be turned off individually — see
[Configuration](#configuration).

## Install

```sh
curl -o ~/.local/bin/tmux-agent-sidebar.sh \
  https://raw.githubusercontent.com/Zrzzzz/tmux-agent-sidebar/main/tmux-agent-sidebar.sh
chmod +x ~/.local/bin/tmux-agent-sidebar.sh
```

Add to `~/.tmux.conf`:

```tmux
# prefix + a toggles the sidebar, prefix + A opens the settings panel
bind a run-shell '~/.local/bin/tmux-agent-sidebar.sh --toggle #{pane_id}'
bind A display-popup -E -w 46 -h 15 '~/.local/bin/tmux-agent-sidebar.sh --config'

# Click an entry to jump to it; clicks elsewhere behave normally
set -g mouse on
bind -n MouseDown1Pane if -F '#{==:#{@agent_sidebar},1}' \
    "run-shell '~/.local/bin/tmux-agent-sidebar.sh --click #{pane_id} #{mouse_y}'" \
    'select-pane -t=; send-keys -M'
```

Reload with `tmux source-file ~/.tmux.conf`, then press `prefix + a`.

Passing `#{pane_id}` is not optional. `run-shell` does not export `TMUX_PANE`
to its child, and without an explicit target both `list-panes` and
`split-window` fall back to the *currently active* window — which may not be
the one you pressed the key in. The sidebar would open somewhere else and the
toggle would fail to find it again.

## Usage

```sh
tmux-agent-sidebar.sh              # run in the foreground, refresh every 2s
tmux-agent-sidebar.sh 5            # refresh every 5s
tmux-agent-sidebar.sh --once       # print one frame and exit
tmux-agent-sidebar.sh --toggle     # open/close the sidebar pane
tmux-agent-sidebar.sh --config     # settings panel
```

## Configuration

`prefix + A` opens a panel for toggling what the sidebar shows:

```
  Sidebar display settings

  ❯ [ ] Clock in header
    [✓] Client group headings
    [✓] Working directory
    [✓] Elapsed time
    [✓] Context usage bar
    [✓] Model name
    [✓] Show idle sessions

  ↑↓/jk move    space toggle    q save & quit
```

| Key       | Default | Element                                   |
|-----------|---------|-------------------------------------------|
| `clock`   | `off`   | Clock next to the header                  |
| `groups`  | `on`    | `Claude Code` / `Codex` group headings    |
| `path`    | `on`    | Working directory on the entry's top line |
| `elapsed` | `on`    | Elapsed time next to the state            |
| `ctxbar`  | `on`    | Context usage bar                         |
| `model`   | `on`    | Model name                                |
| `idle`    | `on`    | List sessions that are sitting idle       |

Settings are stored as `key=value` lines in
`${XDG_CONFIG_HOME:-~/.config}/tmux-agent-sidebar.conf`, so you can also edit
the file directly or keep it in your dotfiles. A running sidebar re-reads it on
every refresh — changes show up within one interval, no restart needed.

Turning elements off shrinks each entry, and the click map is rebuilt from the
same numbers that drive rendering, so click-to-jump stays aligned in every
combination.

### Environment variables

| Variable        | Default | Meaning                                  |
|-----------------|---------|------------------------------------------|
| `SIDEBAR_WIDTH` | `34`    | Sidebar pane width in columns            |
| `SIDEBAR_LANG`  | locale  | `en` or `zh`; falls back to `$LC_ALL` / `$LC_MESSAGES` / `$LANG` |

```tmux
bind a run-shell 'SIDEBAR_WIDTH=42 SIDEBAR_LANG=en ~/.local/bin/tmux-agent-sidebar.sh --toggle #{pane_id}'
```

A `zh_CN` environment gets Chinese labels automatically. State detection never
depends on the locale — `classify()` returns fixed English keys and translation
happens only at render time.

## How the busy/idle detection works

This is the part that is easy to get wrong, so it is worth explaining.

The obvious approach — grep the pane for a spinner line like
`✻ Cogitated for 32s` — does not work. That line **stays on screen after the
task finishes**, so every session that had ever done anything would read as
busy forever.

The reliable signal is that the running and finished lines have different
shapes:

```
✽ Honking… (6m 25s · ↑ 21.1k tokens · thought for 3s)   <- running: parenthesised stats
✻ Cogitated for 32s                                      <- finished: bare "for Ns"
```

So the script keys on the parenthesised statistics block, which only the live
spinner has. A bare `for Ns` is reported as `done` rather than `busy`.

As a fallback for TUI versions that render the running state differently, the
script caches each pane's spinner line under `$TMPDIR` and compares across
refreshes: if the seconds are still ticking, it is genuinely running.

`wait` is checked first, since a permission prompt replaces the spinner
entirely.

## How click-to-jump works

tmux cannot attach a callback to a region of pane text, so the sidebar keeps
its own hit map. On every refresh it writes `<first row> <last row> <pane id>`
per entry to a file under `$TMPDIR`, named after the sidebar's own pane id so
multiple sidebars do not collide. The mouse binding passes `#{mouse_y}`, and
`--click` looks up which range contains that row.

Jumping uses `switch-client`, `select-window` and `select-pane` together, which
covers targets in another window or another session. Clicks on headings or
blank rows match no range and do nothing.

## Client detection

Panes running `claude` or `codex` directly are classified by command name.
When an agent is launched through a wrapper (`node`, `bun`), the client is
inferred from what the TUI renders — `OpenAI Codex` / `Context N% used` for
Codex, `(1M context)` / `bypass permissions` / `esc to interrupt` for Claude
Code. A `node` pane matching neither is not an agent and is skipped, so a stray
dev server never shows up.

To support another CLI, extend `detect_client()`, the command-name filter in
`render()`, and the status-line parsing for model and context:

```
Claude Code:  my-project | Opus 5 (1M context) · medium | [██░░░░░░░░] 22%
Codex:        gpt-5.6-terra medium · /path · Full Access · Context 1% used
```

State classification lives in `classify()`; display strings live in `t()`;
toggleable elements are declared in `CONFIG_SPEC`.

## Notes

- Panes are discovered with `tmux list-panes -a`, so sessions in other windows
  and other tmux sessions all show up.
- Codex's TUI leaves dozens of blank lines below its status line, so the script
  strips blank lines before truncating the capture. Plain `tail -n` would push
  the status line out of range.
- Codex's *running* state is matched by the generic `esc to interrupt` rule and
  has not been verified against a live run. Claude Code's is tested.
- If you use tmux-resurrect, the sidebar pane is saved like any other but comes
  back as a plain shell. Either add it to `@resurrect-processes` or just close
  it and hit `prefix + a` again.

## License

MIT
