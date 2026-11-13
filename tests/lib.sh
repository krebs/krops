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

# Canaries are files outside the target directories, which populate must
# never change, whatever the target directories contain.  Some scenarios
# point links at them.  The manifest lists every entry with its type, mode,
# modification time, and link target, and every file with its checksum.
# Entries beside the target directories whose names start like the
# canaries' count as well, so files created next to them show.
canary_manifest() {
  set -- /var/krops-outside $(
    find /var/krops -mindepth 1 -maxdepth 1 \
        \( -name 'canary*' -o -name 'sibling*' \) 2>/dev/null
  )
  {
    find "$@" -printf '%y %m %T@ %p -> %l\n'
    find "$@" -type f -exec sha256sum {} +
  } 2>&1 | sort
}

# Creates the canaries, unless they are there unchanged: a file beside the
# target directories, a directory beside them, and a directory elsewhere
# with files, a read-only directory, and a Git work tree with a changed and
# an untracked file, which resetting and cleaning would lose.
canary_setup() {
  if test -e /var/krops-outside.manifest &&
      canary_manifest | cmp -s - /var/krops-outside.manifest; then
    return
  fi
  rm -fR /var/krops/canary /var/krops/sibling /var/krops-outside
  mkdir -p /var/krops/sibling /var/krops-outside/dir/sub
  echo canary > /var/krops/canary
  echo sibling > /var/krops/sibling/file
  echo outside > /var/krops-outside/file
  echo outside > /var/krops-outside/dir/file
  echo outside > /var/krops-outside/dir/sub/file
  chmod a-w /var/krops-outside/dir/sub/file /var/krops-outside/dir/sub
  git init -q /var/krops-outside/repo
  (
    cd /var/krops-outside/repo
    echo tracked > tracked
    git add tracked
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git -c user.name=krops -c user.email=spam@krebsco.de commit -q -m canary
    echo changed > tracked
    echo untracked > untracked
  )
  canary_manifest > /var/krops-outside.manifest
}

# Fails if a canary changed, or if a store path that an entry of the target
# directory $T links to doesn't match its hash anymore.
canary_check() {
  if ! canary_manifest | cmp -s - /var/krops-outside.manifest; then
    canary_manifest | diff /var/krops-outside.manifest - >&2 || :
    fail "something outside the target directory changed"
  fi
  if test -n "${T-}" && test -d "$T"; then
    ls -A "$T" | while IFS= read -r canary_name; do
      canary_link=$(readlink "$T/$canary_name" 2>/dev/null) || continue
      case $canary_link in
        /nix/store/*)
          nix-store --verify-path \
              "$(printf '%s\n' "$canary_link" | cut -d/ -f1-4)" ||
            fail "$T/$canary_name links to a store path that changed"
          ;;
      esac
    done
  fi
}
