# Helpers for preparing and checking scenarios, sourced on the machine
# populate deploys to.
set -efu

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# usage: expect_eq WHAT ACTUAL EXPECTED
expect_eq() {
  if test "$2" != "$3"; then
    fail "$1: expected '$3', got '$2'"
  fi
}

nix() {
  command nix --extra-experimental-features 'nix-command flakes' "$@"
}

# Evaluates a flake output without network access to the fixtures, so all
# inputs must be in the store.  An empty cache directory keeps Nix from
# restoring inputs from its fetcher cache.
nix_eval() {
  nix_eval_cache=$(mktemp -d)
  nix_eval_status=0
  env \
      XDG_CACHE_HOME="$nix_eval_cache" \
      http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
      HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
      all_proxy=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 \
      no_proxy= NO_PROXY= \
    nix --extra-experimental-features 'nix-command flakes' eval --raw "$@" ||
    nix_eval_status=$?
  rm -fR "$nix_eval_cache"
  return "$nix_eval_status"
}

# Evaluates a flake output, fetching missing inputs.
nix_eval_online() {
  nix eval --raw "$@"
}

# Collects garbage if KROPS_TEST_GC is set, so evaluating afterwards checks
# that delivered store paths are registered as garbage collector roots.
gc() {
  if test -n "${KROPS_TEST_GC-}"; then
    nix-store --gc >/dev/null
  fi
}
