# Populate's design

Populate delivers sources to a target directory.  It consists of two parts:

- Nix code, which turns populate's arguments into a spec: the sources as
  `evalSource` returns them, the target, and the options, as JSON.  It
  checks the spec during evaluation, so mistakes show early.
- A program, which reads a spec and delivers the sources.  It knows
  nothing about Nix expressions: whatever produces a spec can drive it.

So there is one program for each version of populate, instead of a script
for each set of arguments, and the program can be written in any language.
This directory holds the program in Rust.  Another implementation, e.g. in
Haskell, reads the same spec, prints the same messages, and passes the same
tests.

## Nix side

`default.nix` is `pkgs.populate`.  Given populate's arguments, `{ backup ?
false, force ? false, prune ? false, source, target }`, it checks them with
`checks.nix`, turns them into a spec, and returns a script running the
program with the spec on file descriptor 3, so the commands populate runs
keep standard input.  The script puts the tools populate runs in front of
`PATH`, and depends on the store paths in the spec, so building it builds
them.  `rustProgram` is the program, by default built by `program.nix`.

`writeDeploy` and the other functions of `pkgs.krops` use `pkgs.populate`,
so their arguments stay as they are.

## Invocation

```
populate SPEC
```

`SPEC` is the path of a file containing the spec, or `-` for standard
input.  Exit status:

- 0: populate delivered all sources.
- 1: a check of the spec failed, or delivering did.
- 2: the arguments are wrong, or the spec can't be read, isn't JSON, is of
  another version, or doesn't have the spec's shape.
- 129, 130, 143: populate got SIGHUP, SIGINT, or SIGTERM, and stopped.

## Spec, version 1

The spec is a JSON object:

| Field     | Type                 | Default | Meaning                                       |
|-----------|----------------------|---------|-----------------------------------------------|
| `version` | number               |         | The version of the spec: 1.                   |
| `backup`  | boolean              | false   | Copy the sources to backup first.             |
| `force`   | boolean              | false   | Create the sentinel if it's missing.          |
| `prune`   | boolean              | false   | Remove what isn't a source.                   |
| `source`  | object of sources    |         | The sources, by name.                         |
| `target`  | object               |         | Where to deliver them.                        |

`target` has these fields:

| Field          | Type             | Default | Meaning                                  |
|----------------|------------------|---------|------------------------------------------|
| `user`         | string or null   | null    | The user to log in as.                   |
| `host`         | string           |         | The host to deliver to.                  |
| `port`         | string or null   | null    | The port ssh connects to.                |
| `path`         | string           |         | The target directory.                    |
| `sudo`         | boolean          | false   | Deliver as root, via sudo.               |
| `extraOptions` | array of strings | []      | More arguments for ssh.                  |
| `local`        | boolean or null  | null    | Whether the target is local.             |

Each source is an object with the field `type`, the source's type, and a
field named after the type, holding the source's settings:

```json
{ "type": "git", "git": { "url": "https://...", "ref": "main", ... } }
```

The types and their settings are those of `lib/types/populate.nix`, as
`evalSource` returns them: with shorthands expanded, e.g. `file =
"/etc/x"` as `{ "path": "/etc/x" }`, and without settings that are null.
The source types are `derivation`, `file`, `flake`, `flake-input`, `git`,
`pass`, `passage`, `pipe`, and `symlink`.

Fields the spec doesn't define are errors, so a misspelt option doesn't go
unnoticed, and a spec of another version gets refused before anything
else.  A new version of the spec adds fields or changes their meaning; the
program reads the versions it knows.

Store paths in the spec, e.g. of a `file` source that is a derivation, must
exist when the program runs.  The script `default.nix` writes depends on them.
Something producing a spec at run time has to build them first.

## Checks

The program checks the spec as `checks.nix` does, with the same messages:

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
refusing to copy flakes to remote targets using sudo.  `checks.nix` does
that during evaluation too, where `default.nix` decides whether the target
is local.

## Output

What populate prints on standard error is part of its interface: people
read it, and the tests check it.  For example:

```
populating 'host:/var/src/nixpkgs'...
pruning 'host:/var/src/old'...
replacing symlink 'host:/var/src/x', which points to '/elsewhere'...
replacing the Git work tree 'host:/var/src/x', because ...
```

A target path in a message starts with `user@host:` for remote targets,
without `user@` if the user is root or not set, and is a plain path for
the local target.  Errors start with `error:` or `krops:`, warnings with
`warning:`.  rsync's itemized changes appear as `%i %n%L %'''b/%'''l`, with sizes in
units of 1024.

## Safety

Populate never changes or removes anything outside the target directory,
whatever the spec and whatever it finds on the target:

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

Whether a target is local is what the target's `local` says, or, if
that's null, gets decided when the program runs: it is, if its user is
`LOGNAME` and its host is `localhost` or the host's name, from `HOSTNAME`
or `/etc/hostname`.  `default.nix` decides during evaluation, like the other
functions of krops.  For a local target, populate runs commands directly.

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

## Status

The program delivers all source types, draws inputs from sources, makes
backups, and prunes.  It decides what to do itself: the snippets it runs
on the target send back what it needs to know, e.g. what Nix prints as
JSON, where paths resolve to, or store paths.  Delivering flake and
flake-input sources is in `src/flake_input.rs`, drawing inputs and
deriving copies in `src/flake.rs`.
