# populate

populate fills a target directory, `/var/src` by default, on the machine it
runs on or on another one via ssh, with sources: directories and files,
Git work trees, secrets from [pass](https://www.passwordstore.org/) or
[passage](https://github.com/FiloSottile/passage), the output of commands,
Nix derivations, flakes, and inputs of flakes, which can draw their own
inputs from other sources.  Running it again brings the target directory up
to date with the sources.  It doesn't change anything outside the target
directory.

[krops](../../README.md) deploys NixOS systems with it.

## Building

```sh
nix-build              # in this directory, which builds result/bin/populate
cargo build            # for development, with Rust 1.71 or later
```

`default.nix` takes nixpkgs' `rustPlatform`, from `<nixpkgs>` by default,
so `callPackage` builds it as well.  It needs nixpkgs 23.11 or later, and
fetches the program's dependencies from [crates.io](https://crates.io).


## Requirements

populate runs rsync, ssh, Git, Nix, pass, and passage as the sources need
them, found in `PATH`, as well as a POSIX shell, coreutils, and findutils.
The target needs a POSIX shell, coreutils, findutils, rsync, `patch` for
sources with `patches`, Git for `git` sources, and Nix, and, if remote,
ssh access as root, or, with `--sudo`, as a user who may use `sudo`.
NixOS has all of them but Git, and rsync as long as
`environment.defaultPackages` contains it.  Features that say so need Nix
with flake support (Nix 2.4 or later) on the machine that uses them.


## Command line

```
populate [OPTION]... SOURCES [TARGET]
```

populate delivers the sources in the file `SOURCES`, or standard input if
`SOURCES` is `-`, to `TARGET`, which is `[USER@][HOST][:PORT][PATH]`.  The
user ends at the first `@`, the host at a `:` or a `/`, and the port at a
`/`.  The user defaults to `$LOGNAME`, the host to the name of the machine
populate runs on, from `$HOSTNAME` or `/etc/hostname`, and the path to
`/var/src`.  A target is local if its user is `$LOGNAME`, and its host is
`localhost` or the name of the machine; populate reaches other targets via
ssh, as their user.

| Option            | Meaning                                                 |
|-------------------|---------------------------------------------------------|
| `--backup`        | Copy the target directory to a backup first.            |
| `--force`         | Create the target directory's sentinel if it's missing. |
| `--prune`         | Remove what isn't a source from the target directory.   |
| `--sudo`          | Deliver as root, via sudo on the target.                |
| `--ssh-arg ARG`   | Pass `ARG` to ssh; repeatable.                          |
| `--user USER`     | The target's user; empty for ssh's default.             |
| `--host HOST`     | The target's host, e.g. one `TARGET` can't express.     |
| `--port PORT`     | The port ssh connects to.                               |
| `--path PATH`     | The target directory.                                   |
| `--local`         | The target is the machine populate runs on.             |
| `--remote`        | The target isn't, even if it looks so.                  |
| `-h`, `--help`    | Print the usage and exit.                               |
| `-V`, `--version` | Print populate's version and exit.                      |

`--user`, `--host`, `--port`, and `--path` take precedence over `TARGET`'s
parts.  Options take their argument as the next argument or after `=`, and
may come before, between, or after `SOURCES` and `TARGET`, up to `--`.

Without the sentinel, `.populate` in the target directory, populate refuses
to touch the target directory, unless `--force` creates it; see
[The target directory](#the-target-directory).

Exit status:

- 0: populate delivered all sources.
- 1: populate refused the sources or the target, or delivering failed,
  with a message of its own.
- The exit status of the command that failed, if delivering failed with
  that: e.g. 255 if ssh can't reach the target, or 128 if `git fetch`
  fails.
- 2: the command line is wrong, or the sources can't be read, aren't JSON,
  or aren't sources.
- 129, 130, 143: populate got SIGHUP, SIGINT, or SIGTERM, and stopped.


## Sources

The sources are a JSON object, of sources by name.  Each source is an
object with the field `type`, the source's type, and a field named after
the type, holding its settings, which [Source types](#source-types)
describes:

```json
{
  "nixpkgs": {
    "type": "git",
    "git": { "url": "https://github.com/NixOS/nixpkgs", "ref": "nixos-26.05" }
  },
  "config": { "type": "file", "file": { "path": "/home/me/config" } },
  "nixos-config": {
    "type": "symlink",
    "symlink": { "target": "config/configuration.nix" }
  }
}
```
```sh
populate --force sources.json root@server
```

Settings with defaults may be left out.  Fields and settings populate
doesn't know are errors, so a misspelt one doesn't go unnoticed.  The
sources carry no version: this is version 0, and a later version of
populate that reads them differently will mark them.

### Sources in Nix

`lib` is populate's Nix library: the types of sources, which describe how
to write them in Nix, with shorthands, e.g. `config.file = "/home/me/config"`,
and `evalSource`, which turns sources written so, an attribute set or a list
of them, into the sources populate reads.  It takes nixpkgs' lib, from
`<nixpkgs/lib>` by default.

```sh
nix-instantiate --eval --strict --json -E '
  (import ./lib {}).evalSource {
    nixpkgs.git = {
      url = "https://github.com/NixOS/nixpkgs";
      ref = "nixos-26.05";
    };
    config.file = "/home/me/config";
    nixos-config.symlink = "config/configuration.nix";
  }
' | populate --force - root@server
```

Store paths in the sources, e.g. of a `file` source that is a derivation,
must exist when populate runs.  `nix-instantiate --eval` doesn't build
them; building a file that contains the sources, e.g. with `pkgs.writeText
"sources.json" (builtins.toJSON sources)`, builds them too.


## The target directory

Populate owns the target directory, `/var/src` by default: it replaces
whatever is at the target path of a source, and with `prune` it removes
everything else.  It doesn't change or remove anything outside:

* Target paths must be absolute, must not be the root directory, and must not
  contain `..`.  Source names must consist of letters, digits, and the
  characters `._-`, not start with `-`, and be neither `.`, `..`, nor
  `.populate`.  populate refuses anything else, and so does krops'
  `pkgs.populate` during evaluation.

* A symlink at the target path of a source gets replaced by what the source
  delivers, not followed, and populate says so.  To keep a source elsewhere,
  e.g. on another disk or in memory, mount that place at the target path, or
  make the target directory itself a symlink.  A Git work tree whose `.git`
  is a symlink, or a file naming a repository elsewhere, gets replaced by a
  `git` source as well.

* A `git` source only uses a work tree whose `.git` directory contains no
  symlinks, no `commondir` file and no linked work trees, and only the
  configuration that `git clone` and populate write, and in which each
  `.git` of a submodule is a file naming a repository in `.git/modules`.  Otherwise Git's
  commands could change what's elsewhere, or run commands, so populating
  fails, telling what's wrong, unless the source's `reclone` is set.  Git
  runs no hooks.

* A file in the target directory that has other hard links, e.g. one in
  `/etc/nixos`, gets replaced by a copy of its own before rsync syncs it, so
  the other ones keep their mode and time.  Populate writes its own files,
  and replaces lock files it rewrites, by renaming new files into place, and
  only makes directories writable that it removes.

* Populate keeps its state in the sentinel, `.populate`, which becomes a
  directory once there is state to keep.  Populating fails if the sentinel,
  or a directory populate needs therein, is a symlink.


## Source Types

### `derivation`

Nix expression to be built at the target machine.

Supported attributes:

* `text` -
  Nix expression to be built.


### `file`

The file source type transfers local files (and folders) to the target
using [`rsync`](https://rsync.samba.org/).

Supported attributes:

* `path` -
  absolute path to files that should by transferred.

* `useChecksum` (optional) -
  boolean that controls whether file contents should be checked to decide
  whether a file has changed.  This is useful when `path` points at files
  with mangled timestamps, e.g. the Nix store.

  The default value is `true` if `path` is a derivation, and `false` otherwise.

* `filters` (optional)
  List of filters that should be passed to [`rsync`](https://rsync.samba.org/).
  Filters are specified as attribute sets with the attributes `type` and
  `pattern`.  Supported filter types are `include` and `exclude`.
  Checkout the filter rules section in the
  [rsync manual](https://download.samba.org/pub/rsync/rsync.html)
  for further information.

* `deleteExcluded` (optional)
  boolean that controls whether the excluded directories should be deleted
  if they exist on the target. This is passed to the `--delete-excluded` option
  of rsync. Defaults to `true`.

* `insecureLinks` (optional) -
  what to do if rsync can't read `.rsync-filter` files that apply to `path`:
  the ones therein, and the ones in the directories above it.  rsync 3.5.0
  and later open them more strictly than the files they transfer, and ignore
  the ones they can't open, e.g. because a symlink on the way belongs to
  neither root nor the user deploying, or, with rsync 3.5.0, because a
  directory on the way may be entered but not read, like a home directory
  with mode 711.  By default, with `null`, populating fails with an error
  naming the file.  With `true`, rsync reads such files anyway
  (`--insecure-links`), which also lets it pass such symlinks on the way to
  the target path of a local target; with `false`, rsync syncs without them.
  Both print a warning.  Older versions of rsync aren't affected.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).

* `rewriteLock` (optional) -
  boolean that controls whether inputs get drawn from other sources by
  rewriting the lock file of the flake in this source, or else through a
  generated flake, see [Flake inputs from sources](#flake-inputs-from-sources).
  Defaults to `true`.


### `flake`

The flake source type delivers a flake to the target.  The flake gets
archived locally using `nix flake archive`, which includes only files tracked
by Git, so use a `file` source for work trees with untracked files.  The
flake and its inputs get copied into the target's Nix store using `nix copy`,
and the target path becomes a symlink to the flake's store path, registered
as garbage collector root.  For flakes in a subdirectory, e.g.
`git+file:/src/mono?dir=sub`, the symlink points at that subdirectory of the
store path.  The inputs get garbage collector roots in
`.populate/flake-inputs/<name>`, which turns the sentinel file into a
directory.

Supported attributes:

* `fetchOnTarget` (optional) -
  boolean that controls whether the target fetches the flake's inputs itself
  instead of receiving them from the deploying machine.  The target then uses
  the arguments recorded in the lock file, so inputs that refer to local paths
  can only be fetched if the target has these paths as well; populating fails
  otherwise, naming the input.  If the flake reference names a scheme that
  doesn't refer to the deploying machine, e.g. `github:`, the target handles
  the flake entirely on its own, and the deploying machine doesn't fetch it.
  Otherwise the target fetches the flake itself as well if its locked
  reference doesn't refer to the deploying machine, e.g. for indirect
  references resolving to `github:` flakes, or else the flake gets
  transferred using `rsync`, unless the target's Nix store has it already,
  and added to the target's Nix store, where it gets the same store path as
  on the deploying machine.  This requires Nix with flake support (Nix 2.4 or
  later) on the target, and works for targets using `sudo`.  Defaults to
  `false`.

* `url` -
  flake reference, e.g. the absolute path of a directory containing a
  `flake.nix`.  Its lock file is used as is; populating fails if the lock
  file needs to be updated.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).

* `materialize` (optional) -
  boolean that controls whether the target path becomes a writable copy
  instead of a link into the store.  The copy gets made again only if what
  it derives from changes: the delivered store path, the patches, or which
  inputs get drawn from which sources.  Until then, changes made to it on the
  target stay.  Nix copies it into the store whenever evaluating a flake
  changed it, which is noticeable for big flakes like nixpkgs.  For a flake
  in a subdirectory, only that subdirectory gets copied.  Defaults to
  `false`.

* `patches` (optional) -
  list of paths of patches on the deploying machine, which get applied in
  order with `patch -p1` on the target, in the directory the target path
  shows.  Populating fails if a patch doesn't apply.  Defaults to `[]`.

* `rewriteLock` (optional) -
  boolean that controls whether inputs get drawn from other sources by
  rewriting the lock file of the flake in this source, or else through a
  generated flake, see [Flake inputs from sources](#flake-inputs-from-sources).
  Defaults to `true`.

Instead of an attribute set, the flake reference can be given as a string.

The flake commands on the deploying machine enable flakes themselves, so
flakes don't need to be enabled there.  Without `fetchOnTarget`, the target
only needs `nix-store`.  Because the copied store paths aren't signed, the
target user must be allowed to import them, i.e. be `root` or a trusted user,
and targets using `sudo` aren't supported.


### `flake-input`

The flake-input source type delivers an input of a flake, as recorded in the
flake's lock file, to the target.  This makes the lock file of a flake the
single place that pins, e.g., nixpkgs, for flakes as well as for `NIX_PATH`.
It works like the `flake` source type, but delivers the selected input
instead of the flake, so the target path becomes a symlink to the input's
store path.  The inputs that the input's own lock file pins, which evaluating
the input needs, get delivered as well, with garbage collector roots in
`.populate/flake-inputs/<name>`.  An input without a lock file comes without
its inputs, because locking it would change it.

Because the target path points at the store path named by the lock file, it
can be used in `NIX_PATH` as well as by flakes evaluated on the target,
without network access.

Supported attributes:

* `url` -
  flake reference of the flake whose input gets delivered, e.g. the absolute
  path of a directory containing a `flake.nix`.  Its lock file is used as is;
  populating fails if the lock file needs to be updated.

* `name` -
  name of the input to deliver.  Inputs of inputs are separated by `/`,
  e.g. `stockholm/nixpkgs`, and resolved as the flake's lock file resolves
  them, so an input that follows another one names the other one.

* `requireInputs` (optional) -
  boolean that controls whether populating fails if the inputs that the
  input's own lock file pins can't be delivered, e.g. because the lock file
  pins something unreachable, or lacks an input its `flake.nix` has.  With
  `false`, populate prints a warning and delivers the input with the inputs
  Nix locks when it adds what the lock file lacks, or else without its
  inputs.  Evaluating the input as a flake then needs network access.
  Defaults to `true`.

* `fetchOnTarget` (optional) -
  boolean that controls whether the target fetches the input itself instead
  of receiving it from the deploying machine.  The target then uses the
  arguments recorded in the lock file, so inputs that refer to local paths
  can only be fetched if the target has these paths as well; populating fails
  otherwise, naming the input.  This requires Nix with flake support (Nix 2.4
  or later) on the target, and works for targets using `sudo`.  Defaults to
  `false`.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).

* `materialize` (optional) -
  boolean that controls whether the target path becomes a writable copy
  instead of a link into the store.  The copy gets made again only if what
  it derives from changes: the delivered store path, the patches, or which
  inputs get drawn from which sources.  Until then, changes made to it on the
  target stay.  Nix copies it into the store whenever evaluating a flake
  changed it, which is noticeable for big flakes like nixpkgs.  For a flake
  in a subdirectory, only that subdirectory gets copied.  Defaults to
  `false`.

* `patches` (optional) -
  list of paths of patches on the deploying machine, which get applied in
  order with `patch -p1` on the target, in the directory the target path
  shows.  Populating fails if a patch doesn't apply.  Defaults to `[]`.

* `rewriteLock` (optional) -
  boolean that controls whether inputs get drawn from other sources by
  rewriting the lock file of the flake in this source, or else through a
  generated flake, see [Flake inputs from sources](#flake-inputs-from-sources).
  Defaults to `true`.

Without `fetchOnTarget`, the same requirements as for the `flake` source type
apply.

Example:

```nix
{
  nixpkgs.flake-input = {
    url = toString ./.;
    name = "nixpkgs";
  };
}
```


### `git`

Git sources that will be fetched on the target machine.

Supported attributes:

* `url` -
  URL of the Git repository that should be fetched.

* `ref` -
  Branch / tag / commit that should be fetched.  A branch or tag gets fetched
  on every run, so the work tree follows it.  A commit, given by its hash or a
  prefix thereof of at least four hex digits, only gets fetched if the work
  tree lacks it, unless `fetchAlways` is set.  So a branch or tag whose name
  consists of hex digits only counts as a commit.

* `clean.exclude` -
  List of patterns that should be excluded from Git cleaning.

* `shallow` (optional)
  boolean that controls whether only the requested commit ref. should be fetched
  instead of the whole history, to save disk space and bandwith. Defaults to `false`.

* `reclone` (optional) -
  boolean that controls whether a work tree populate can't use, see
  [The target directory](#the-target-directory), gets replaced by a fresh
  clone, instead of failing.  Defaults to `false`.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).

* `rewriteLock` (optional) -
  boolean that controls whether inputs get drawn from other sources by
  rewriting the lock file of the flake in this source, or else through a
  generated flake, see [Flake inputs from sources](#flake-inputs-from-sources).
  Defaults to `true`.


### `pass`

The pass source type transfers contents from a local
[password store](https://www.passwordstore.org/) to the target machine.

Supported attributes:

* `dir` -
  absolute path to the password store.

* `name` -
  sub-directory in the password store.


### `passage`

The passage source type decrypts files from a local
[passage store](https://github.com/FiloSottile/passage)
and transfers them to the target using
[`rsync`](https://rsync.samba.org/).

Supported attributes:

* `dir` -
  Path to the passage store.
  For a partial transfer, this may point to a subdirectory.
  Example: `~/.passage/store/hosts/MYHOSTNAME`

* `identities_file` (optional) -
  Path to the identities file.
  Defaults to `~/.passage/identities`.

* `age` (optional) -
  Path of the age binary.
  Defaults to `age` (absolute path gets resolved using `passage`'s search path.)


### `pipe`

Executes a local command, capture its stdout, and send that as a file to the
target machine.

Supported attributes:

* `command` -
  The (shell) command to run.

### `symlink`

Symlink to create at the target, relative to the target directory.
This can be used to reference files in other sources.

Supported attributes:

* `target` -
  Content of the symlink.  This is typically a relative path.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).


## Flake inputs from sources

Sources of type `file`, `flake`, `flake-input`, `git`, and `symlink` can
declare which inputs of the flake they contain get drawn from other sources,
in the style of `flake.nix`, where `follows` names a source instead of an
input.  This makes flakes on the target use what populate delivers there,
much like `NIX_PATH` does for Nix expressions.

```nix
{
  nixpkgs.flake-input = {
    url = toString ./.;
    name = "nixpkgs";
  };
  crate2nix.flake = {
    url = "github:nix-community/crate2nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  myconf.file = {
    path = toString ./.;
    inputs = {
      crate2nix.follows = "crate2nix";
      stockholm.inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

Populate rewrites the lock file of the flake in each source that draws
inputs from other sources, using `nix flake lock --override-input`, so the
flake in the source itself uses the other sources.  `file` and `git` sources
get their lock file rewritten in place.  `flake` and `flake-input` sources
get delivered as a copy with the rewritten lock file, which gets added to the
store, unless materialized, so the target path links to that instead of the
delivered store path, as it does for patched ones.  A source drawing an input
from a source that draws inputs itself uses that source as rewritten, so in
the example above, myconf's crate2nix uses nixpkgs from the `nixpkgs` source as
well.

With `rewriteLock = false`, and for `symlink` sources, which point at other
sources, the source stays as it is, and populate generates a flake in
`.populate/flakes/<name>` instead, which re-exports the outputs of the flake
in the source, with those inputs drawn from the other sources.  A source
drawing an input from a source with a generated flake uses that flake.
krops' `writeDeploy` uses a source's generated flake automatically.

Sources in a Git work tree are referred to as `git+file:` (with submodules if
there are any), all other sources as `path:`, with symlinks resolved.  Nix
runs Git in a `git+file:` flake, with its configuration and hooks, so
that's only for work trees whose `.git` directory a `git` source would use,
see [The target directory](#the-target-directory), and has no hooks.  Lock
files get rewritten or generated on every run, so they match the sources.
Copies of `flake` and `flake-input` sources get made again only if the
delivered store path, the patches, or the sources they draw inputs from
change.  For a source in a Git work tree that Nix gets as `git+file:`,
that's its commit and tracked files, which populate checks with Git;
other sources get read entirely, to hash them.  Inputs that get drawn from other sources don't get delivered with
a `flake` or `flake-input` source, and neither does what they pin.
Generated flakes and copies get removed once their sources no longer need
them.  This requires Nix with flake support (Nix 2.4 or later) on the
target.  Populating fails if a source that draws inputs from other sources
contains no `flake.nix`, or if its flake has no such input, before anything
changes.  Sources that inputs get drawn from don't need to be flakes, as long
as the inputs drawing from them are declared with `flake = false`.


## Output

What populate prints on standard error is part of its interface: people
read it, and tests check it.  For example:

```
populating 'host:/var/src/nixpkgs'...
pruning 'host:/var/src/old'...
replacing symlink 'host:/var/src/x', which points to '/elsewhere'...
replacing the Git work tree 'host:/var/src/x', because ...
```

A target path in a message starts with `user@host:` for remote targets,
without `user@` if the user is root or not set, and is a plain path for the
local target.  Errors start with `error:` or `krops:`, warnings with
`warning:`.  rsync's itemized changes appear as `%i %n%L %'''b/%'''l`, with
sizes in units of 1024.


## Tests

`tests/` contains NixOS VM tests: one test per source type, one for
features spanning sources, such as flake inputs from sources, one for edge
cases of flakes, such as unusual lock files, and one for staying inside the
target directory, whatever links it contains.  After every run, all tests
check that nothing outside the target directory changed.  The tests deliver
combinations of a source type's settings to the machine populate runs on,
to a remote target as `root`, and to a remote target using `sudo`, and check
the result after delivering and after delivering again.  They cover every
combination that a code path tells apart; the exhaustive tests add the
remaining ones, e.g. drawing inputs combined with each of rsync's options.
The scenarios whose results depend on the version of rsync also run with
rsync 3.4.1 and 3.5.0, which `tests/rsync.nix` builds, whatever version
nixpkgs has.  The tests require KVM and nixpkgs with
`pkgs.testers.runNixOSTest` (23.05 or later), and use `<nixpkgs>` by
default.

```sh
nix-build tests                   # all tests, except the exhaustive ones
nix-build tests -A flake          # the test for one source type
nix-build tests -A exhaustive     # all exhaustive tests
nix-build tests -A exhaustive.git # the remaining combinations of one test
nix-build tests -A rsync-3-5-0    # the scenarios depending on rsync's version
nix-build tests -A smoke          # a few scenarios of each kind, in one VM
nix-build tests -A only --argstr only 'lock-hooks-.*'  # scenarios by name
cargo test                        # the unit tests, without VMs
```

[`docs/design.md`](docs/design.md) describes how populate works.
