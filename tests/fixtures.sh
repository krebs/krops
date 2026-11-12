#! /bin/sh
# Creates the fixtures the tests deploy from in /fixtures.
#
# usage: fixtures.sh URL GIT_HEAD
#
# URL is where /fixtures/www gets served via HTTP, e.g. http://deployer:8000.
# The tarball flakes there get locked against it, so it must be served while
# this script runs.  /fixtures/git gets served by git daemon.  GIT_HEAD is the
# commit the tests expect as HEAD of /fixtures/gitsrc.
set -efu

url=$1
git_head=$2

nix() {
  command nix --extra-experimental-features 'nix-command flakes' "$@"
}

export GIT_AUTHOR_NAME=krops GIT_AUTHOR_EMAIL=spam@krebsco.de
export GIT_COMMITTER_NAME=krops GIT_COMMITTER_EMAIL=spam@krebsco.de
export GIT_AUTHOR_DATE='1000000000 +0000' GIT_COMMITTER_DATE='1000000000 +0000'
# Configuration such as commit.gpgsign would change the commits.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# Commits everything in the current directory.  Commits are deterministic, so
# the tests can refer to them by hash.
commit() {
  git add -A
  git commit -q -m "$1"
}

tarball() {
  tar -C /fixtures/www/src --sort=name --mtime=@1 --owner=0 --group=0 \
      --numeric-owner -czf /fixtures/www/"$1".tar.gz "$1"
}

rm -fR /fixtures
mkdir -p /fixtures/www/src

# Tarball flakes, fetched via HTTP: inner, dep (with input inner), mono (with
# a flake in subdirectory sub), and remote (with input dep).
mkdir /fixtures/www/src/inner
cat > /fixtures/www/src/inner/flake.nix <<'NIX'
{ outputs = _: { who = "inner"; }; }
NIX
tarball inner

mkdir /fixtures/www/src/dep
cat > /fixtures/www/src/dep/flake.nix <<NIX
{
  inputs.inner.url = "$url/inner.tar.gz";
  outputs = { inner, ... }: { greeting = "dep+\${inner.who}"; };
}
NIX
(cd /fixtures/www/src/dep && nix flake lock)
tarball dep

mkdir -p /fixtures/www/src/mono/sub
echo mono > /fixtures/www/src/mono/README
cat > /fixtures/www/src/mono/sub/flake.nix <<'NIX'
{ outputs = _: { who = "sub"; }; }
NIX
tarball mono

mkdir /fixtures/www/src/remote
cat > /fixtures/www/src/remote/flake.nix <<NIX
{
  inputs.dep.url = "$url/dep.tar.gz";
  outputs = { dep, ... }: { msg = "remote:\${dep.greeting}"; };
}
NIX
(cd /fixtures/www/src/remote && nix flake lock)
tarball remote

# top: a flake in a Git work tree, with inputs dep and sub (a flake in a
# subdirectory).
mkdir /fixtures/top
cat > /fixtures/top/flake.nix <<NIX
{
  inputs.dep.url = "$url/dep.tar.gz";
  inputs.sub.url = "$url/mono.tar.gz?dir=sub";
  outputs = { dep, sub, ... }: { msg = "top:\${dep.greeting},\${sub.who}"; };
}
NIX
(cd /fixtures/top && nix flake lock && git init -q && commit top)

# mono: a Git work tree with a flake in subdirectory sub.
cp -R /fixtures/www/src/mono /fixtures/mono
(cd /fixtures/mono && git init -q && commit mono)

# alt: a flake to draw inputs from.
mkdir /fixtures/alt
cat > /fixtures/alt/flake.nix <<'NIX'
{ outputs = _: { greeting = "alt"; who = "alt"; }; }
NIX

# usegone: a flake with an input locked to a path that doesn't exist anymore.
mkdir /fixtures/gone /fixtures/usegone
cat > /fixtures/gone/flake.nix <<'NIX'
{ outputs = _: {}; }
NIX
cat > /fixtures/usegone/flake.nix <<'NIX'
{
  inputs.gone.url = "path:/fixtures/gone";
  outputs = _: {};
}
NIX
(cd /fixtures/usegone && nix flake lock)
rm -R /fixtures/gone

# kropsremote: a registry entry for remote, so it has an indirect reference.
nix registry add kropsremote "$url/remote.tar.gz"

# monoin: a Git work tree with a flake in subdirectory sub that has an input.
mkdir -p /fixtures/monoin/sub
echo monoin > /fixtures/monoin/README
cat > /fixtures/monoin/sub/flake.nix <<NIX
{
  inputs.dep.url = "$url/dep.tar.gz";
  outputs = { dep, ... }: { msg = "monoin:\${dep.greeting}"; };
}
NIX
(cd /fixtures/monoin/sub && nix flake lock)
(cd /fixtures/monoin && git init -q && commit monoin)

# dirty: a copy of top with an uncommitted change and an untracked file.
cp -R /fixtures/top /fixtures/dirty
sed -i 's/top:/dirty:/' /fixtures/dirty/flake.nix
echo untracked > /fixtures/dirty/untracked

# unlocked: a flake whose lock file is missing.
mkdir /fixtures/unlocked
cat > /fixtures/unlocked/flake.nix <<NIX
{
  inputs.inner.url = "$url/inner.tar.gz";
  outputs = { inner, ... }: { msg = inner.who; };
}
NIX

# uselocal: a flake with an input locked to a path on the deploying machine.
mkdir /fixtures/uselocal
cat > /fixtures/uselocal/flake.nix <<'NIX'
{
  inputs.a.url = "path:/fixtures/alt";
  outputs = { a, ... }: { msg = "uselocal:${a.who}"; };
}
NIX
(cd /fixtures/uselocal && nix flake lock)

# noflake: a directory without flake.nix.
mkdir /fixtures/noflake
echo noflake > /fixtures/noflake/README

# filesrc: a copy of top, with files for testing the file source type's
# options.  same has the same size and modification time as the file the
# tests put on the target beforehand, while skip-ex and skip-f have the same
# size but an older modification time than theirs, so rsync's quick check
# tells them apart.
mkdir /fixtures/filesrc
cp /fixtures/top/flake.nix /fixtures/top/flake.lock /fixtures/filesrc
echo keep > /fixtures/filesrc/keep
echo src > /fixtures/filesrc/skip-ex
echo src > /fixtures/filesrc/skip-f
echo AAAA > /fixtures/filesrc/same
touch -d @1000000000 /fixtures/filesrc/same
touch -d @999999999 /fixtures/filesrc/skip-ex /fixtures/filesrc/skip-f

# gitsrc: a Git repository with two commits, served by git daemon.  Its flake
# has an input that only exists when drawn from a source.
mkdir /fixtures/gitsrc
cat > /fixtures/gitsrc/flake.nix <<'NIX'
{
  inputs.dep.url = "path:/nonexistent";
  outputs = { dep, ... }: { msg = "git:${dep.greeting}"; };
}
NIX
(cd /fixtures/gitsrc && git init -q -b master && commit one)
echo two > /fixtures/gitsrc/two
(cd /fixtures/gitsrc && commit two)
if test "$(git -C /fixtures/gitsrc rev-parse HEAD)" != "$git_head"; then
  >&2 printf 'error: HEAD of /fixtures/gitsrc is %s, but the tests expect %s\n' \
      "$(git -C /fixtures/gitsrc rev-parse HEAD)" "$git_head"
  exit 1
fi
mkdir /fixtures/git
git clone -q --bare /fixtures/gitsrc /fixtures/git/gitsrc.git
git -C /fixtures/git/gitsrc.git config uploadpack.allowReachableSHA1InWant true

# pass: password stores with x/a, without and with Git.
if ! gpg --list-secret-keys spam@krebsco.de >/dev/null 2>&1; then
  gpg --batch --passphrase '' --quick-gen-key spam@krebsco.de default default never
fi
for store in pass pass-git; do
  export PASSWORD_STORE_DIR=/fixtures/$store
  pass init spam@krebsco.de >/dev/null
  if test $store = pass-git; then
    pass git init >/dev/null
  fi
  printf 'secret-a\n' | pass insert -m x/a >/dev/null
done
unset PASSWORD_STORE_DIR

# passage: a passage store with x/a.
mkdir -p /fixtures/passage/store
age-keygen -o /fixtures/passage/identities 2>/dev/null
age-keygen -y /fixtures/passage/identities > /fixtures/passage/store/.age-recipients
printf 'secret-a\n' |
  PASSAGE_DIR=/fixtures/passage/store \
  PASSAGE_IDENTITIES_FILE=/fixtures/passage/identities \
  passage insert -m x/a >/dev/null

# pipe: a command for the pipe source type.
cat > /fixtures/pipe <<'SH'
#! /bin/sh
echo piped
SH
chmod +x /fixtures/pipe
