#! /bin/sh
# Stands in for nixos-rebuild: records the user it runs as, NIX_PATH, its
# arguments, and whether its output is a terminal in /tmp/nixos-rebuild.log.
if test -t 1; then terminal=terminal; else terminal='no terminal'; fi
{
  id -u
  printf '%s\n' "${NIX_PATH-}"
  printf '%s\n' "$*"
  echo "$terminal"
} > /tmp/nixos-rebuild.log
