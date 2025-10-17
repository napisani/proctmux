#!/usr/bin/env bash
set -euo pipefail

# Simple stateless tmux mock returning deterministic outputs.
# Recognized commands:
#  list-sessions -F ...            -> prints nothing
#  display-message -p #{session_id} -> prints $0
#  display-message -p #{pane_id}   -> prints %0
#  display-message -p -t <pane> #{pane_pid} -> prints 4242
#  new-session -d -s <name> -P -F '#{session_id}' -> prints $100
#  split-window ... -P -F '#{pane_id}:#{pane_pid}' -> prints %100:4242
#  new-window  ... -P -F '#{pane_id}:#{pane_pid}' -> prints %200:4242
#  list-panes ... -F '<format>' -> if format contains 'window_zoomed_flag', echo '1 1'; else echo '0 1'
#  All other commands exit 0 silently.

cmd=${1:-}
shift || true

case "$cmd" in
  list-sessions)
    # produce no sessions by default
    echo -n ""
    ;;
  display-message)
    if [[ "${1:-}" == "-p" ]]; then
      shift
      if [[ "${1:-}" == "-t" ]]; then
        # display-message -p -t <pane> <fmt>
        shift # -t
        shift # <pane>
        fmt=${1:-}
        if [[ "$fmt" == "#{pane_pid}" ]]; then
          echo "4242"
        else
          echo ""
        fi
      else
        fmt=${1:-}
        if [[ "$fmt" == "#{session_id}" ]]; then
          echo "\$0"
        elif [[ "$fmt" == "#{pane_id}" ]]; then
          echo "%0"
        else
          echo ""
        fi
      fi
    fi
    ;;
  new-session)
    # Expect: -d -s <name> -P -F '#{session_id}'
    echo "\$100"
    ;;
  set-option)
    ;;
  kill-session)
    ;;
  has-session)
    ;;
  kill-pane)
    ;;
  break-pane)
    ;;
  join-pane)
    ;;
  select-pane)
    ;;
  resize-pane)
    ;;
  split-window)
    echo "%100:4242"
    ;;
  new-window)
    echo "%200:4242"
    ;;
  list-panes)
    # if requesting zoom+active flags, return 1 1; otherwise 0 1
    fmt=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-F" ]]; then
        shift; fmt=${1:-}
        break
      fi
      shift || true
    done
    if [[ "$fmt" == *"window_zoomed_flag"* ]]; then
      echo "1 1"
    else
      echo "0 1"
    fi
    ;;
  -C)
    # control mode attach-session; do nothing, keep process alive briefly
    # To give pipes something valid, just sleep shortly then exit.
    # But since exec.Command.Start() doesn't wait, exiting immediately is fine.
    ;;
  display-popup)
    ;;
  *)
    ;;
 esac
