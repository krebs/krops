#! /bin/sh
# Stands in for nixos-rebuild: records the user it runs as, NIX_PATH, and its
# arguments in /tmp/nixos-rebuild.log.
{
  id -u
  printf '%s\n' "${NIX_PATH-}"
  printf '%s\n' "$*"
} > /tmp/nixos-rebuild.log
