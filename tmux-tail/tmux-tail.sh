#!/bin/bash
set -euo pipefail

script_name="${0##*/}"
lines=20
interactive=0
list_only=0
declare -a session_args=()
declare -a sessions=()
declare -a all_sessions=()

usage() {
        cat <<EOF
Usage: $script_name [-n LINES] [-i] [SESSION_OR_INDEX...]

Show the last N lines captured from tmux sessions.
For each session, this captures the lowest-index window and lowest-index pane.
Session indexes are 1-based and come from --list.

Options:
  -n, --lines N      Number of lines to show from each session (default: 20)
  -i, --interactive  Pick sessions by number
  -l, --list         List numbered sessions and exit
  -h, --help         Show this help

Examples:
  $script_name --list
  $script_name
  $script_name -n 80
  $script_name -n 20 1 4 9
  $script_name -n 20 agent-review issue-10852
  $script_name --interactive
EOF
}

die() {
        echo "$script_name: $*" >&2
        exit 1
}

is_positive_int() {
        [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 > 0))
}

print_sessions() {
        local i

        for ((i = 1; i <= ${#all_sessions[@]}; i++)); do
                printf '%3d  %s\n' "$i" "${all_sessions[$((i - 1))]}"
        done
}

pick_sessions() {
        local answer token line index i

        if [ "${#all_sessions[@]}" -eq 0 ]; then
                return 0
        fi

        if command -v fzf >/dev/null 2>&1 && [ -t 0 ]; then
                while IFS= read -r line; do
                        index="${line%%$'\t'*}"
                        printf '%s\n' "${all_sessions[$((10#$index - 1))]}"
                done < <(
                        for ((i = 1; i <= ${#all_sessions[@]}; i++)); do
                                printf '%d\t%s\n' "$i" "${all_sessions[$((i - 1))]}"
                        done | fzf --multi --prompt="tmux session> "
                )
                return $?
        fi

        printf 'Select tmux sessions by number, space-separated. Empty cancels.\n' >&2
        print_sessions >&2
        printf '> ' >&2

        if ! read -r answer; then
                return 1
        fi
        if [ -z "$answer" ]; then
                return 1
        fi

        for token in $answer; do
                if ! [[ "$token" =~ ^[0-9]+$ ]]; then
                        echo "Ignoring non-number selection: $token" >&2
                        continue
                fi
                if ((token < 1 || token > ${#all_sessions[@]})); then
                        echo "Ignoring out-of-range selection: $token" >&2
                        continue
                fi
                printf '%s\n' "${all_sessions[$((token - 1))]}"
        done
}

validate_session() {
        local session="$1"

        if ! tmux has-session -t "$session" 2>/dev/null; then
                die "tmux session not found: $session"
        fi
}

resolve_session_arg() {
        local arg="$1"
        local index

        if is_positive_int "$arg"; then
                index=$((10#$arg))
                if ((index < 1 || index > ${#all_sessions[@]})); then
                        die "session index out of range: $arg (run $script_name --list)"
                fi
                printf '%s\n' "${all_sessions[$((index - 1))]}"
                return
        fi

        validate_session "$arg"
        printf '%s\n' "$arg"
}

add_first_pane() {
        local session="$1"
        local tab=$'\t'
        local window_index pane_record pane_index pane_id label window_name command_name

        window_index="$(tmux list-windows -t "$session" -F '#{window_index}' | sort -n | head -n 1)"
        [ -n "$window_index" ] || die "tmux session has no windows: $session"

        pane_record="$(
                tmux list-panes -t "$session:$window_index" \
                        -F "#{pane_index}${tab}#{pane_id}${tab}#{session_name}:#{window_index}.#{pane_index}${tab}#{window_name}${tab}#{pane_current_command}" |
                        sort -n -k1,1 |
                        head -n 1
        )"
        [ -n "$pane_record" ] || die "tmux window has no panes: $session:$window_index"

        IFS=$'\t' read -r pane_index pane_id label window_name command_name <<< "$pane_record"
        printf '%s\t%s\t%s\t%s\n' "$pane_id" "$label" "$window_name" "$command_name"
}

while [ "$#" -gt 0 ]; do
        case "$1" in
                -n|--lines)
                        option="$1"
                        shift
                        [ "$#" -gt 0 ] || die "$option requires a line count"
                        lines="$1"
                        ;;
                --lines=*)
                        lines="${1#*=}"
                        ;;
                -i|--interactive|--pick)
                        interactive=1
                        ;;
                -l|--list)
                        list_only=1
                        ;;
                -h|--help)
                        usage
                        exit 0
                        ;;
                --)
                        shift
                        session_args+=("$@")
                        break
                        ;;
                -*)
                        die "unknown option: $1"
                        ;;
                *)
                        session_args+=("$1")
                        ;;
        esac
        shift
done

is_positive_int "$lines" || die "line count must be a positive integer"
command -v tmux >/dev/null 2>&1 || die "tmux command not found"

if ! tmux list-sessions >/dev/null 2>&1; then
        die "no tmux server or sessions found"
fi

mapfile -t all_sessions < <(tmux list-sessions -F '#{session_name}')

if [ "$list_only" -eq 1 ]; then
        print_sessions
        exit 0
fi

if [ "${#session_args[@]}" -eq 0 ]; then
        sessions=("${all_sessions[@]}")
else
        for session_arg in "${session_args[@]}"; do
                sessions+=("$(resolve_session_arg "$session_arg")")
        done
fi

if [ "$interactive" -eq 1 ]; then
        mapfile -t sessions < <(pick_sessions)
        [ "${#sessions[@]}" -gt 0 ] || exit 0
fi

declare -a panes=()
for session in "${sessions[@]}"; do
        panes+=("$(add_first_pane "$session")")
done

first=1
for pane in "${panes[@]}"; do
        IFS=$'\t' read -r pane_id label window_name command_name <<< "$pane"

        if [ "${#panes[@]}" -gt 1 ]; then
                if [ "$first" -eq 0 ]; then
                        printf '\n'
                fi
                printf '===== %s [%s] %s =====\n' "$label" "$window_name" "$command_name"
        fi

        tmux capture-pane -p -J -S - -E - -t "$pane_id" | tail -n "$lines"
        first=0
done
