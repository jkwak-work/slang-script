# tmux-tail.sh

`tmux-tail.sh` prints the last lines from tmux sessions without attaching to them.

For each selected session, it captures the lowest-index window and the lowest-index pane. It does not inspect every window or pane.

## Usage

```sh
tmux-tail.sh [-n LINES] [-i] [SESSION_OR_INDEX...]
```

## Session Selection

List sessions with stable 1-based indexes:

```sh
tmux-tail.sh --list
```

Example output:

```text
  1  agent-review
  2  issue-10852
  3  workgraph-as-module
```

Use those indexes as positional arguments:

```sh
tmux-tail.sh -n 20 1 3
```

Session names also work:

```sh
tmux-tail.sh -n 20 agent-review workgraph-as-module
```

With no session arguments, the script prints output for every tmux session:

```sh
tmux-tail.sh
```

## Options

`-n N`, `--lines N`

Show the last `N` lines from each selected session. The default is `20`.

```sh
tmux-tail.sh -n 80 1
```

`-i`, `--interactive`, `--pick`

Prompt for session numbers. If `fzf` is installed and stdin is a terminal, the prompt uses `fzf`; otherwise it uses a simple numbered prompt.

```sh
tmux-tail.sh -i -n 20
```

`-l`, `--list`

List numbered tmux sessions and exit.

```sh
tmux-tail.sh --list
```

`-h`, `--help`

Show the command help.

## Notes

Bare numbers are session indexes, not line counts. Use `-n` to set the number of lines.

When multiple sessions are selected, each session is separated by a header:

```text
===== agent-review:0.0 [bash] bash =====
```

The header format is:

```text
session:window.pane [window-name] current-command
```
