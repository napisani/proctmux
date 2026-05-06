#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -gt 1 ]; then
  printf 'Usage: %s [output-path]\n' "$0" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  OUT="$1"
  case "$OUT" in
    /*) ;;
    *) OUT="$ROOT/$OUT" ;;
  esac
else
  OUT="$ROOT/bin/proctmux-go-reference"
fi

mkdir -p "$(dirname "$OUT")"
go build -o "$OUT" "$ROOT/cmd/proctmux"
printf '%s\n' "$OUT"
