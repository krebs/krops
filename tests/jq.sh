#! /bin/sh
# Runs populate's jq programs for flakes over lock files in the shapes
# different versions of Nix write, without VMs.
#
# usage: jq.sh DIR
#
# DIR contains the programs as selected.jq, selfIsRemote.jq, and
# selfLocked.jq, and the Nix function for the target as metadataSubdir.nix.
set -efu

programs=$1
failed=0

# usage: expect WHAT ACTUAL EXPECTED
expect() {
  if test "$2" != "$3"; then
    printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2" >&2
    failed=1
  fi
}

# usage: expect_error WHAT ACTUAL MESSAGE
expect_error() {
  case $2 in
    *"$3"*) ;;
    *)
      printf 'FAIL: %s\n  expected an error: %s\n  got: %s\n' "$1" "$3" "$2" >&2
      failed=1
      ;;
  esac
}

# usage: selection METADATA INPUT
selection() {
  printf '%s\n' "$1" |
    timeout 10 jq -c --argjson input "$2" --from-file "$programs"/selected.jq 2>&1 ||
    :
}

# A flake with an input dep, which has an input inner following the flake's
# input inner, and an input sub, a flake in a subdirectory, written as
# attribute dir or as query parameter dir of the URL.
metadata() {
  cat <<JSON
{
  "locked": { "type": "path", "path": "/src/top", "narHash": "sha256-top" },
  "path": "/nix/store/top-source",
  "locks": {
    "root": "root",
    "version": 7,
    "nodes": {
      "root": { "inputs": { "dep": "dep", "inner": "inner", "sub": "sub" } },
      "dep": {
        "inputs": { "inner": [ "inner" ] },
        "locked": { "type": "tarball", "url": "http://x/dep.tar.gz", "narHash": "sha256-dep" }
      },
      "inner": {
        "locked": { "type": "tarball", "url": "http://x/inner.tar.gz", "narHash": "sha256-inner" }
      },
      "sub": {
        "locked": $1,
        "original": $2
      }
    }
  }
}
JSON
}
attribute=$(metadata \
  '{ "type": "tarball", "url": "http://x/mono.tar.gz", "dir": "sub", "narHash": "sha256-mono" }' \
  '{ "type": "tarball", "url": "http://x/mono.tar.gz", "dir": "sub" }')
url=$(metadata \
  '{ "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub", "narHash": "sha256-mono" }' \
  '{ "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub" }')

mono='{"self":false,"locked":{"type":"tarball","url":"http://x/mono.tar.gz","narHash":"sha256-mono"},"subdir":"sub"}'
expect "subdirectory as attribute" "$(selection "$attribute" '["sub"]')" "$mono"
expect "subdirectory in the URL" "$(selection "$url" '["sub"]')" "$mono"
expect "the flake itself" "$(selection "$attribute" '[]')" \
  '{"self":true,"locked":null,"subdir":""}'
expect "name through follows" "$(selection "$attribute" '["dep","inner"]')" \
  '{"self":false,"locked":{"type":"tarball","url":"http://x/inner.tar.gz","narHash":"sha256-inner"},"subdir":""}'
expect_error "missing input" "$(selection "$attribute" '["nope"]')" "no input nope"

# An empty follows path removes an input.
removed=$(printf '%s\n' "$attribute" | jq -c '.locks.nodes.dep.inputs.inner = []')
expect_error "removed input" "$(selection "$removed" '["dep","inner"]')" "no input inner"

# Inputs following each other.
cyclic=$(printf '%s\n' "$attribute" | jq -c '
  .locks.nodes.dep.inputs.inner = ["inner", "x"]
  | .locks.nodes.inner.inputs = { x: ["dep", "inner"] }
')
expect_error "cyclic follows" "$(selection "$cyclic" '["dep","inner"]')" "follows nest too deep"

# An input given by a path relative to the flake, which is in subdirectory
# sub itself.
relative=$(printf '%s\n' "$attribute" | jq -c '
  .locked.dir = "sub"
  | .locks.nodes.root.inputs.lib = "lib"
  | .locks.nodes.lib = { locked: { type: "path", path: "./lib" }, parent: [] }
')
expect "relative path" "$(selection "$relative" '["lib"]')" \
  '{"self":true,"locked":null,"subdir":"sub/lib"}'

# usage: remote LOCKED
remote() {
  printf '{ "locked": %s }\n' "$1" |
    jq --from-file "$programs"/selfIsRemote.jq
}
expect "path" "$(remote '{ "type": "path", "path": "/src" }')" false
expect "local Git" "$(remote '{ "type": "git", "url": "file:///src" }')" false
expect "remote Git" "$(remote '{ "type": "git", "url": "https://x/y" }')" true
expect "GitHub" "$(remote '{ "type": "github", "owner": "o", "repo": "r" }')" true

expect "locked reference of the flake itself" "$(
  printf '%s\n' '{ "locked": { "__final": true, "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub", "narHash": "sha256-mono" } }' |
    jq -c --argjson selected '{"self":true,"locked":null,"subdir":"sub"}' \
      --from-file "$programs"/selfLocked.jq
)" "$mono"

# The Nix function finding the subdirectory on the target, which may lack
# jq.
# usage: metadata_subdir METADATA
metadata_subdir() {
  METADATA=$1 nix-instantiate --eval --strict --json --store dummy:// --expr "
    (import $programs/metadataSubdir.nix)
      (builtins.fromJSON (builtins.getEnv \"METADATA\"))
  " 2>&1 || :
}
export HOME=${TMPDIR:-/tmp}
export NIX_STATE_DIR=$HOME/nix-state
expect "subdirectory as attribute, on the target" "$(metadata_subdir '{
  "locked": { "type": "tarball", "url": "http://x/mono.tar.gz", "dir": "sub" },
  "original": { "type": "tarball", "url": "http://x/mono.tar.gz", "dir": "sub" }
}')" '"sub"'
expect "subdirectory in the URL, on the target" "$(metadata_subdir '{
  "locked": { "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub&narHash=sha256-mono" },
  "original": { "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub" }
}')" '"sub"'
expect "subdirectory in the original reference only, on the target" "$(metadata_subdir '{
  "locked": { "type": "tarball", "url": "http://x/mono.tar.gz" },
  "original": { "type": "tarball", "url": "http://x/mono.tar.gz?rev=1&dir=sub" }
}')" '"sub"'
expect "no subdirectory, on the target" "$(metadata_subdir '{
  "locked": { "type": "path", "path": "/src/top" }
}')" '""'

exit "$failed"
