# Populate's design

Populate delivers sources to a target directory.  It consists of:

- A program, which reads the sources as JSON and delivers them to the
  target its command line names.  It knows nothing about Nix expressions:
  whatever produces sources as JSON can drive it.
- A Nix library, `lib`, with the types of sources, which describe how to
  write them in Nix, and `evalSource`, which turns sources written so into
  the JSON the program reads.

krops uses both: its `pkgs.populate` turns populate's arguments into a
command line, and checks them during evaluation, so mistakes show early.
So there is one program for each version of populate, instead of a script
for each set of arguments, and the program can be written in any language.
This directory holds the program in Rust.  Another implementation, e.g. in
Haskell, takes the same command line, prints the same messages, and passes
the same tests.

## Nix side

`default.nix` builds the program: `nix-build` in this directory, or
`callPackage`, as krops' `pkgs.populate-unwrapped`.  `lib/default.nix` is
the Nix library, taking nixpkgs' lib.

krops' `pkgs.populate`, in its `pkgs/krops/populate.nix`, is populate's Nix
API there.  Given populate's arguments, `{ backup ? false, force ? false,
prune ? false, source, target }`, it checks them with krops'
`pkgs/krops/checks.nix`, and returns a script running the program with the
sources as JSON on file descriptor 3, so the commands populate runs keep
standard input.  A target string goes to the program as it is.  A target
attribute set, as `mkTarget` returns it, goes part by part, as options,
with `--local` or `--remote` as krops' lib's `isLocalTarget` decides
during evaluation, like the other functions of krops.  The script puts the
tools populate runs in front of `PATH`, and depends on the store paths in
the sources, so building it builds them.  krops' `writeDeploy` and its
other functions use `pkgs.populate`, so their arguments stay as they are.

## Command line and sources

[`../README.md`](../README.md) describes populate's command line, the
sources, and what populate prints, which are its interface.  The program
reads the sources into `spec::Sources`, and parses the target with
`spec::TargetParts`, completing it with `run::Origin`, the user running
populate and the machine's name, when it runs.

## Checks

The program checks the sources and the target as krops' `checks.nix` does
during evaluation, with the same messages:

- The target's host isn't empty, and neither it nor its user starts with
  `-`, so ssh can't take them for options.  `checks.nix` doesn't check
  this, since krops' targets come from the configuration.
- Source names are portable file names: letters, digits, and `._-`, not
  starting with `-`, and neither `.`, `..`, nor `.populate`.
- The target path is absolute, not the root directory, and contains
  neither `..` nor control characters.
- Inputs get drawn from sources that exist, not from the source itself,
  and not in circles.
- The settings of a source are those `lib/types/populate.nix` defines for
  its type, of the kinds it defines, e.g. absolute paths for the paths of
  `file`, `pass`, and `pipe` sources.  `checks.nix` doesn't repeat this,
  since `evalSource` checks the types.

Checks that depend on whether the target is local come on top, e.g.
refusing to copy flakes to remote targets using sudo.  krops' `checks.nix`
does that during evaluation too, where `pkgs.populate` decides whether the
target is local.

## Safety

Populate never changes or removes anything outside the target directory,
whatever the sources and whatever it finds on the target:

- The checks above keep source names and the target path inside it.
- A symlink at the target path of a source gets replaced, never written
  through, and populate's state directory, `.populate`, must not be one.
- Removing a tree makes only its directories writable, and removes what's
  below them, not what symlinks point to.
- Hard links to files of a source get broken before rsync writes to them.
- A Git work tree gets reused only if its `.git` is a directory of its
  own, with no other configuration than `git clone` and populate set,
  and Git runs without hooks and file system monitors.
- Temporary files get created with `mktemp`, and moved into place.

The tests' canaries, files around the target directories and in other
places populate must not touch, check this after every phase.

## Execution

Whether a target is local is what `--local` or `--remote` says, or else
gets decided when the program runs, like krops' lib's `isLocalTarget`
does: it is, if its user is `LOGNAME`, or null if that's empty or unset,
and its host is `localhost` or the machine's name, from `HOSTNAME`, or, if
that's empty or unset, the only line of `/etc/hostname` that is a label.
For a local target, populate runs commands directly.

For a remote target, populate runs commands over ssh, sharing one master
connection per target.  The commands are fixed POSIX shell snippets, with
values passed as positional arguments, so nothing gets quoted into them.
The target needs a POSIX shell, coreutils, findutils, rsync, `patch` for
patches, Git for `git` sources, and Nix; NixOS lacks Git.  With `sudo`,
the snippets run via `sudo`.

Populate runs rsync, Git, ssh, and Nix as programs, found in `PATH`.

## Development

- `cargo test` in this directory runs the program's unit tests.
- `nix-build tests -A smoke` runs the smoke test, a few scenarios covering
  each source type and each kind of target.
- `nix-build tests` runs all scenarios but the exhaustive ones.
- krops' tests run populate's scenarios that expect refusals, and those of
  the smoke test, through krops' `pkgs.populate`, with `tests/builder.nix`.

## Status

The program delivers all source types, draws inputs from sources, makes
backups, and prunes.  It decides what to do itself: the snippets it runs
on the target send back what it needs to know, e.g. what Nix prints as
JSON, where paths resolve to, or store paths.  Delivering flake and
flake-input sources is in `src/flake_input.rs`, drawing inputs and
deriving copies in `src/flake.rs`.
