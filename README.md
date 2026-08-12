# tmux-agent-sidebar

A tmux sidebar that shows every Claude Code / Codex session running across your
panes, and whether each one is actually working or waiting for you.

No plugin manager, no dependencies beyond `tmux` and `bash`. One script.

```
 AGENTS  15:20:06

● 0:0.1   my-project
  busy · 7m 44s · ctx 9%
  Opus 5 (1M context)

▲ 0:1.0   api-server
  wait · needs confirmation · ctx 23%
  Opus 5 (1M context)

✓ 0:1.1   api-server
  done · 3m · ctx 13%
  Opus 5 (1M context)

○ 0:3.0   scratch
  idle · ctx 1%
  gpt-5.6-terra medium
```

| Mark | State  | Meaning                                    |
|------|--------|--------------------------------------------|
| ●    | `busy` | Actively working, with elapsed time        |
| ▲    | `wait` | Blocked on a permission prompt or question |
| ✓    | `done` | Just finished; output still on screen      |
| ○    | `idle` | Sitting at an empty prompt                 |

Each entry shows the tmux address (`session:window.pane`), the working
directory, the model, and context usage.

## Install

```sh
curl -o ~/.local/bin/tmux-agent-sidebar.sh \
  https://raw.githubusercontent.com/Zrzzzz/tmux-agent-sidebar/main/tmux-agent-sidebar.sh
chmod +x ~/.local/bin/tmux-agent-sidebar.sh
```

Add to `~/.tmux.conf`:

```tmux
bind a run-shell '~/.local/bin/tmux-agent-sidebar.sh --toggle #{pane_id}'
```

Reload with `tmux source-file ~/.tmux.conf`, then press `prefix + a` to toggle
the sidebar.

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
```

`SIDEBAR_WIDTH` sets the pane width (default `34`):

```tmux
bind a run-shell 'SIDEBAR_WIDTH=42 ~/.local/bin/tmux-agent-sidebar.sh --toggle #{pane_id}'
```

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

## Adding another agent CLI

Two places, both near the top of `render()`:

1. The command-name filter — `[[ $cmd =~ ^(claude|codex|node|bun)$ ]]`.
   `node`/`bun` are accepted only if the pane also looks like an agent TUI,
   so a stray dev server does not show up.
2. The status-line parsing for model and context. The two supported formats:

   ```
   Claude Code:  my-project | Opus 5 (1M context) · medium | [██░░░░░░░░] 22%
   Codex:        gpt-5.6-terra medium · /path · Full Access · Context 1% used
   ```

State classification lives in one function, `classify()`.

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
