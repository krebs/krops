//! Shell code that runs on the target, where populate can't rely on more
//! than a POSIX shell and the usual tools.  Values come as positional
//! parameters, never quoted into the code.

/// The directories below the sentinel, once that is a directory, which have
/// a directory for each source that needs one.  Besides, there is backup,
/// which holds copies of the sources.
pub const STATE_KINDS: &str = "derived flake-inputs flake-uploads flakes patches";

/// Defines use_state SENTINEL NAME..., which prepares keeping state below
/// the sentinel for the sources named NAME.  The sentinel only needs to
/// exist, so it may be a file, which becomes a directory.  Populate changes
/// and removes what's in its state directories, and a symlink in place of
/// one would make it do that to whatever the link points to, so it refuses
/// to use those.
pub fn use_state() -> String {
    format!(
        r#"
refuse_link() {{
  if test -L "$1"; then
    >&2 printf 'error: %s is a symlink, but populate needs a directory of its own there\n' "$1"
    exit 1
  fi
}}
use_state() {{
  sentinel=$1
  shift
  refuse_link "$sentinel"
  refuse_link "$sentinel"/backup
  for state_kind in {STATE_KINDS}; do
    refuse_link "$sentinel"/"$state_kind"
    for state_name; do
      refuse_link "$sentinel"/"$state_kind"/"$state_name"
    done
  done
  if test -f "$sentinel"; then
    rm "$sentinel"
    mkdir "$sentinel"
  fi
}}
"#
    )
}

/// Defines remove_tree PATH, which removes what's at PATH, with everything
/// below it, also what isn't writable.  A symlink gets removed itself,
/// instead of followed.  Only directories get made writable, which is what
/// removing what's in them needs: a file may be a hard link to one
/// elsewhere, which shares its mode.
pub const REMOVE_TREE: &str = r#"
remove_tree() {
  if test -L "$1"; then
    rm "$1"
  elif test -e "$1"; then
    find "$1" -type d -exec chmod u+w {} +
    rm -fR "$1"
  fi
}
"#;

/// Defines remove_link PATH NAME, which removes a symlink at PATH, saying
/// so, with NAME for PATH, because the link may be there on purpose, but
/// populate never follows it: what a source delivers would change or remove
/// what the link points to.  remove_foreign_link PATH NAME does so unless
/// the link points into the store, like the links populate puts there
/// itself, and make_room_for_link PATH NAME makes room at PATH for a link
/// into the store, which Nix only puts in place of another link into the
/// store.
pub const LINKS: &str = r#"
remove_link() {
  if test -L "$1"; then
    >&2 printf "replacing symlink '%s', which points to '%s'...\n" \
        "$2" "$(readlink "$1")"
    rm "$1"
  fi
}
remove_foreign_link() {
  if test -L "$1"; then
    # Resolved, so a link like /nix/store/../.. doesn't count.
    case $(readlink -f "$1") in
      /nix/store/*) ;;
      *) remove_link "$1" "$2" ;;
    esac
  fi
}
make_room_for_link() {
  remove_foreign_link "$1" "$2"
  if ! test -L "$1" && test -e "$1"; then
    rm -fR "$1"
  fi
}
"#;

/// Defines remove_others DIR LOG NAME..., which removes the entries of DIR
/// that aren't named NAME.  find, unlike a loop reading names, copes with
/// every name, e.g. ones that end in blanks or contain newlines.  With LOG
/// empty, entries get removed like remove_tree does; for entries of the
/// target directory, LOG is the directory's name in the line printed for
/// each entry, and nothing gets made writable first.  The names are
/// portable file names, which mean themselves as patterns of find.
pub const REMOVE_OTHERS: &str = r#"
remove_others() {
  dir=$1
  log=$2
  shift 2
  n=$#
  while test "$n" -gt 0; do
    set -- "$@" ! -name "$1"
    shift
    n=$((n - 1))
  done
  find "$dir" -mindepth 1 -maxdepth 1 "$@" -exec sh -c '
    log=$1
    shift
    for path; do
      if test -n "$log"; then
        >&2 printf "pruning '\''%s/%s'\''...\n" "$log" "${path##*/}"
        rm -fR "$path"
      elif test -L "$path"; then
        rm "$path"
      else
        find "$path" -type d -exec chmod u+w {\} +
        rm -fR "$path"
      fi
    done
  ' sh "$log" {} +
}
"#;

/// check SENTINEL NAME DIR FORCE: fails unless the sentinel exists, creating
/// it and the target directory DIR first if FORCE isn't empty.  NAME is the
/// sentinel's name in messages.
pub const CHECK: &str = r#"
sentinel=$1 name=$2 dir=$3 force=$4
# Before anything touches it, which would touch what it points to.
if test -L "$sentinel"; then
  >&2 printf 'error: sentinel file is a symlink: %s\n' "$name"
  exit 1
fi
if test -n "$force"; then
  mkdir -vp "$dir" >&2
  if ! test -e "$sentinel"; then
    touch "$sentinel"
  fi
fi
if ! test -e "$sentinel"; then
  >&2 printf 'error: missing sentinel file: %s\n' "$name"
  exit 1
fi
"#;

/// backup DIR NAME: copies the target directory DIR to the sentinel's
/// backup directory.  NAME is the sentinel's name in messages.
pub fn backup() -> String {
    use_state()
        + r#"
dir=$1 name=$2
use_state "$dir"/.populate
if ! test -d "$dir"/.populate; then
  >&2 printf 'error: sentinel file is not a directory: %s\n' "$name"
  exit 1
fi
rsync >&2 \
    -aAXF \
    --delete \
    --exclude /.populate \
    --link-dest="$dir" \
    "$dir"/ \
    "$dir"/.populate/backup/
"#
}

/// prune DIR LOG NAME...: removes the entries of the target directory DIR
/// that aren't sources named NAME, logging them with LOG for DIR, and
/// populate's state that only sources that are gone needed.  The names
/// after -- are the ones of flake and flake-input sources, whose roots for
/// the garbage collector stay.
pub fn prune() -> String {
    use_state()
        + REMOVE_TREE
        + REMOVE_OTHERS
        + r#"
dir=$1 log=$2
shift 2
names=
while test "$1" != --; do
  names="$names $1"
  shift
done
shift
use_state "$dir"/.populate
cd "$dir"
# The names are portable file names, so splitting them at blanks is fine.
# shellcheck disable=SC2086
remove_others . "$log" .populate $names
roots=.populate/flake-inputs
if test -d "$roots"; then
  remove_others "$roots" "" "$@"
  if test -z "$(ls -A "$roots")"; then
    rmdir "$roots"
  fi
fi
remove_tree .populate/flake-uploads
"#
}

/// break_hard_links PATH NAME: prepares PATH for rsync.  rsync writes
/// through a symlink at the target path, e.g. one a symlink or flake source
/// left there, into what it points to.  And rsync fixes the mode and time of
/// a file it takes for unchanged in place, which changes every hard link to
/// it, e.g. one elsewhere, or a backup's.  So each file with other hard
/// links gets replaced by a copy of its own first.
pub fn break_hard_links() -> String {
    LINKS.to_string()
        + r#"
remove_link "$1" "$2"
if test -d "$1"; then
  find "$1" -type f -links +1 -exec sh -c '
    for file; do
      copy=$(mktemp "$file.XXXXXX")
      cp -p "$file" "$copy"
      mv -f "$copy" "$file"
    done
  ' sh {} +
fi
"#
}

/// derivation PATH NAME TEXT: builds the Nix expression TEXT on the target,
/// with a link to the result at PATH.
pub fn derivation() -> String {
    LINKS.to_string()
        + r#"
make_room_for_link "$1" "$2"
nix-build -E "$3" -o "$1" >&2
"#
}

/// symlink PATH TARGET: makes PATH a symlink to TARGET.
pub const SYMLINK: &str = r#"
ln -fnsT "$2" "$1"
"#;

/// Defines git_problems PATH, which prints why populate can't use the .git
/// directory of the Git work tree at PATH, or nothing.  A .git directory
/// that git clone and populate made has no symlinks, no commondir file,
/// which names another repository, no linked work trees, and only the
/// configuration they write: the repository's format, the remote, branches,
/// and submodules, whose repositories have their work tree in the work
/// tree.
pub const GIT_PROBLEMS: &str = r#"
git_problems() (
  path=$1
  git_dir=$1/.git
  links=$(find "$git_dir" -type l | head -n 3 | paste -s -d ' ' -)
  if test -n "$links"; then
    printf '%s contains symlinks: %s' "$git_dir" "$links"
    exit
  fi
  common=$(find "$git_dir" -name commondir | head -n 1)
  if test -n "$common"; then
    printf '%s names another repository' "$common"
    exit
  fi
  if test -e "$git_dir"/worktrees; then
    printf '%s has linked work trees' "$git_dir"
    exit
  fi
  find "$git_dir" -name config -type f | while IFS= read -r config; do
    command git config --file "$config" --list --name-only |
    while IFS= read -r key; do
      case $key in
        core.repositoryformatversion|core.filemode|core.bare|\
        core.logallrefupdates|core.symlinks|core.ignorecase|\
        core.precomposeunicode|\
        extensions.objectformat|extensions.refstorage|\
        remote.origin.url|remote.origin.fetch|\
        branch.*.remote|branch.*.merge|\
        submodule.active|submodule.*.url|submodule.*.active) ;;
        core.worktree)
          # Submodules' repositories have their work tree in the work tree.
          worktree=$(command git config --file "$config" core.worktree)
          dir=$(dirname "$config")
          case $dir/$worktree in
            "$git_dir"/modules/*)
              resolved=$(cd "$dir" && cd "$worktree" 2>/dev/null && pwd -P) || :
              case $resolved in
                "$(cd "$path" && pwd -P)"/*) continue ;;
              esac
              ;;
          esac
          printf '%s sets core.worktree to %s' "$config" "$worktree"
          exit 1
          ;;
        *)
          printf '%s sets %s, which neither git clone nor populate does' "$config" "$key"
          exit 1
          ;;
      esac
    done || exit 1
  done || :
)
"#;

/// git PATH NAME URL REF SHALLOW FETCH_ALWAYS RECLONE EXCLUDE...: makes
/// PATH a Git work tree of the repository at URL, with REF checked out,
/// and everything removed that Git doesn't track, except what matches an
/// EXCLUDE pattern.  SHALLOW, FETCH_ALWAYS, and RECLONE are flags, empty
/// for false.  NAME is PATH's name in messages.
pub fn git() -> String {
    LINKS.to_string()
        + GIT_PROBLEMS
        + r#"
path=$1 name=$2 url=$3 ref=$4 shallow=$5 fetch_always=$6 reclone=$7
shift 7
# Hooks and commands a repository's configuration names run with Git's
# commands, so populate's Git doesn't run any.  The configuration gets
# checked as well, but Git also runs a hook it has itself.
git() {
  command git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}
# A target path that doesn't look like a Git work tree gets removed, e.g.
# when it had another type before.  A work tree that a symlink points to,
# or whose .git is a symlink or a file naming a repository elsewhere, isn't
# populate's own: fetching, resetting, and cleaning would change what's
# elsewhere.
remove_link "$path" "$name"
if test -L "$path"/.git || ! test -d "$path"/.git; then
  rm -fR "$path"
fi
# A .git directory can name places elsewhere too, which Git's commands
# change, or commands, which they run.  Populate only uses a work tree
# whose .git directory has nothing like that, and else replaces it if
# reclone is set, or fails, telling why.
if test -e "$path"; then
  if problems=$(git_problems "$path"); then :; else
    exit 1
  fi
  if test -n "$problems"; then
    if test -n "$reclone"; then
      >&2 printf "replacing the Git work tree '%s', because %s...\n" \
          "$name" "$problems"
      rm -fR "$path"
    else
      >&2 printf 'error: populate doesn'"'"'t use the Git work tree %s, because %s.  Fix that, remove the work tree, or set the source'"'"'s reclone to true to replace it by a fresh clone.\n' \
          "$name" "$problems"
      exit 1
    fi
  fi
fi
if ! test -e "$path"; then
  if test -n "$shallow"; then
    git init "$path"
  else
    git clone --recurse-submodules "$url" "$path"
  fi
fi
cd "$path"
if ! origin=$(git config remote.origin.url); then
  git remote add origin "$url"
elif test "$origin" != "$url"; then
  git remote set-url origin "$url"
fi
# A commit, given by its hash or a prefix thereof, gets fetched only if the
# work tree lacks it, unless fetchAlways is set.  A branch or tag gets
# fetched on every run, so the work tree follows it: resetting to its name
# would reset to a local branch, which fetching doesn't move.
fetch() {
  if test -n "$shallow"; then
    git fetch --depth=1 origin "$1"
  else
    git fetch origin "$1"
  fi
}
fetch_commit() {
  if test -n "$shallow"; then
    fetch "$hash"
  else
    git fetch origin
  fi
}
if printf %s "$ref" | grep -Eqx '[0-9a-f]{4,40}'; then
  hash=$ref
  if ! test "$(git log --format=%H -1)" = "$hash"; then
    if test -n "$fetch_always"; then
      fetch_commit
    elif ! git log -1 "$hash" >/dev/null 2>&1; then
      fetch_commit
    fi
  fi
else
  fetch "$ref"
  hash=$(git rev-parse --verify 'FETCH_HEAD^{commit}')
fi
# Also if HEAD is there already: rewriting a lock file in place, e.g.,
# changes the work tree, and stages the lock file if Nix created it.
git reset --hard "$hash" >&2
git submodule update --init --recursive
n=$#
while test "$n" -gt 0; do
  set -- "$@" -e "$1"
  shift
  n=$((n - 1))
done
git clean -dfx "$@"
"#
}

/// Shell code running on the deploying machine, in the source's working
/// directory.
pub mod local {
    /// pass_info DIR NAME: prints what tells whether the pass source of the
    /// passwords below NAME in the store DIR changed: the last commits of
    /// NAME, and of what symlinks therein point to, whose changes the
    /// commits of NAME miss.  Prints nothing if the store isn't a Git
    /// repository.
    pub const PASS_INFO: &str = r#"
dir=$1 name=$2
if test -e "$dir"/.git; then
  printf '%s %s\n' "$name" "$(
    git -C "$dir" log -1 --format=%H "$name"
    find "$dir"/"$name" -type l -exec realpath {} + |
      sort |
      xargs -r -n 1 git -C "$dir" log -1 --format=%H
  )"
fi
"#;

    /// pass DIR NAME INFO: decrypts the passwords below NAME in the store
    /// DIR into the working directory, with the times of their last
    /// commits, and INFO, unless empty, in .pass_info.
    pub const PASS: &str = r#"
dir=$1 name=$2 info=$3
umask 0077
chmod 0700 "$PWD"
prefix=$dir/$name
find "$prefix" -type f -follow ! -name .gpg-id |
while read -r gpg_path; do
  rel_name=${gpg_path#"$prefix"}
  rel_name=${rel_name%.gpg}
  pass_date=$(
    if test -e "$dir"/.git; then
      git -C "$dir" log -1 --format=%aI "$gpg_path"
    fi
  )
  pass_name=$name/$rel_name
  pass_out=$PWD/$rel_name
  mkdir -p "$(dirname "$pass_out")"
  PASSWORD_STORE_DIR=$dir pass show "$pass_name" > "$pass_out"
  if [ -n "$pass_date" ]; then
    touch -d "$pass_date" "$pass_out"
  fi
done
if test -n "$info"; then
  printf '%s\n' "$info" > "$PWD"/.pass_info
fi
"#;

    /// passage HOST: decrypts the secrets in $PASSAGE_DIR into the working
    /// directory, with the times of their files.  HOST is the first label
    /// of the target's host, for the command a failure prints.
    pub const PASSAGE: &str = r#"
host=$1
umask 0077
chmod 0700 "$PWD"
find "$PASSAGE_DIR" -type f -name \*.age -follow |
while read -r age_path; do
  pass_name=${age_path#"$PASSAGE_DIR"/}
  pass_name=${pass_name%.age}
  pass_out=$PWD/$pass_name
  mkdir -p "$(dirname "$pass_out")"
  if ! passage show "$pass_name" > "$pass_out" 2>&1; then
    echo ++ secrets "$host" show "$pass_name" >&2
    jq -Rr 'select(test("^[^[]"))' "$pass_out" >&2
    exit 1
  fi
  touch -r "$age_path" "$pass_out"
done
"#;
}

/// pass_info PATH: prints the .pass_info the pass source at PATH got last.
pub const PASS_INFO: &str = r#"
cat "$1"/.pass_info || :
"#;

/// Defines url_path PATH, which prints PATH as it goes into a URL: with
/// every byte percent-encoded that isn't a letter, a digit, or one of
/// -._~/.  Nix decodes that, and otherwise takes, e.g., ? and # for
/// delimiters, and refuses blanks.
pub const URL_PATH: &str = r#"
url_path() {
  printf %s "$1" | od -An -v -tx1 | tr -s ' ' '\n' |
  while read -r url_byte; do
    case $url_byte in
      "") ;;
      2[d-f]|3[0-9]|4[1-9a-f]|5[0-9a]|5f|6[1-9a-f]|7[0-9a]|7e)
        printf "\\$(printf %o "0x$url_byte")"
        ;;
      *)
        printf '%%%s' "$url_byte"
        ;;
    esac
  done
}
"#;

/// Defines require_flakes WHAT, which enables flakes for the Nix commands
/// following it, and fails unless Nix supports them, i.e. is version 2.4 or
/// later.  WHAT names what needs flakes, for the error message.
pub const REQUIRE_FLAKES: &str = r#"
require_flakes() {
  NIX_CONFIG=$(printf '%s\n%s' "${NIX_CONFIG-}" \
      'extra-experimental-features = nix-command flakes')
  export NIX_CONFIG
  if ! nix flake --help >/dev/null 2>&1; then
    >&2 printf 'error: %s needs Nix 2.4 or later on %s, found: %s\n' \
        "$1" "$(uname -n)" "$(nix --version 2>&1 || :)"
    exit 1
  fi
}
"#;

/// The definitions shell code generated for flakes uses.
pub fn prelude() -> String {
    [
        &use_state(),
        REMOVE_TREE,
        LINKS,
        REMOVE_OTHERS,
        URL_PATH,
        REQUIRE_FLAKES,
    ]
    .concat()
}
