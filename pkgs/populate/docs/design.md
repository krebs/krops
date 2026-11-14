# Populate's design

Populate delivers sources to a target directory.  It consists of two parts:

- Nix code, which turns populate's arguments into a command line: the
  sources as `evalSource` returns them, as JSON, the target, and the
  options.  It checks the arguments during evaluation, so mistakes show
  early.
- A program, which reads the sources and delivers them to the target its
  command line names.  It knows nothing about Nix expressions: whatever
  produces sources as JSON can drive it.

So there is one program for each version of populate, instead of a script
for each set of arguments, and the program can be written in any language.
This directory holds the program in Rust.  Another implementation, e.g. in
Haskell, takes the same command line, prints the same messages, and passes
the same tests.

## Nix side

`default.nix` is `pkgs.populate`.  Given populate's arguments, `{ backup ?
false, force ? false, prune ? false, source, target }`, it checks them with
`checks.nix`, and returns a script running the program with the sources as
JSON on file descriptor 3, so the commands populate runs keep standard
input.  A target string goes to the program as it is.  A target attribute
set, as `mkTarget` returns it, goes part by part, as options, with
`--local` or `--remote` as krops' lib's `isLocalTarget` decides during
evaluation, like the other functions of krops.  The script puts the tools
populate runs in front of `PATH`, and depends on the store paths in the
sources, so building it builds them.  `rustProgram` is the program, by
default built by `program.nix`.

`writeDeploy` and the other functions of `pkgs.krops` use `pkgs.populate`,
so their arguments stay as they are.

## Invocation

```
populate [OPTION]... SOURCES [TARGET]
```

`SOURCES` is the path of a file containing the sources, or `-` for
standard input.  `TARGET` is `[USER@][HOST][:PORT][PATH]`, parsed like
krops' lib's `mkTarget` parses it: the user up to the first `@`, the host
up to a `:` or a `/`, the port up to a `/`, and the path from there.  What
it leaves out gets filled in when the program runs, as `mkTarget` would:
the user from `LOGNAME`, the host with the machine's name, and the path
with `/var/src`.  An empty user means ssh's default.

| Option          | Meaning                                                 |
|-----------------|---------------------------------------------------------|
| `--backup`      | Copy the target directory to a backup first.            |
| `--force`       | Create the target directory's sentinel if it's missing. |
| `--prune`       | Remove what isn't a source from the target directory.   |
| `--sudo`        | Deliver as root, via sudo on the target.                |
| `--ssh-arg ARG` | Pass `ARG` to ssh; repeatable.                          |
| `--user USER`   | The target's user, instead of `TARGET`'s.               |
| `--host HOST`   | The target's host, e.g. one `TARGET` can't express.     |
| `--port PORT`   | The port ssh connects to.                               |
| `--path PATH`   | The target directory.                                   |
| `--local`       | The target is the machine populate runs on.             |
| `--remote`      | The target isn't, even if it looks so.                  |
| `-h`, `--help`  | Print the usage and exit.                               |
| `-V`, `--version` | Print populate's version and exit.                    |

Options take their argument as the next argument or after `=`, and may
come before, between, or after `SOURCES` and `TARGET`, up to `--`.  Exit
status:

- 0: populate delivered all sources.
- 1: a check of the sources or the target failed, or delivering did, with
  a message of its own.
- The exit status of the command that failed, if delivering failed with
  that, like the shell implementation does: e.g. 255 if ssh can't reach
  the target, or 128 if git fetch fails.
- 2: the command line is wrong, or the sources can't be read, aren't JSON,
  or aren't sources.
- 129, 130, 143: populate got SIGHUP, SIGINT, or SIGTERM, and stopped.

## Sources

The sources are a JSON object, of sources by name.  Each source is an
object with the field `type`, the source's type, and a field named after
the type, holding the source's settings:

```json
{ "nixpkgs": { "type": "git", "git": { "url": "https://...", "ref": "main" } } }
```

The types and their settings are those of `lib/types/populate.nix`, as
`evalSource` returns them: with shorthands expanded, e.g. `file =
"/etc/x"` as `{ "path": "/etc/x" }`, and without settings that are null.
Settings with defaults may be left out.  The source types are
`derivation`, `file`, `flake`, `flake-input`, `git`, `pass`, `passage`,
`pipe`, and `symlink`.

Fields and settings populate doesn't know are errors, so a misspelt option
doesn't go unnoticed.  The sources carry no version: this is version 0, and
a later version of populate that reads them differently will mark them.

Store paths in the sources, e.g. of a `file` source that is a derivation,
must exist when the program runs.  The script `default.nix` writes depends
on them.  Something producing sources at run time has to build them first.

## Checks

The program checks the sources and the target as `checks.nix` does, with
the same messages:

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

## Status

The program delivers all source types, draws inputs from sources, makes
backups, and prunes.  It decides what to do itself: the snippets it runs
on the target send back what it needs to know, e.g. what Nix prints as
JSON, where paths resolve to, or store paths.  Delivering flake and
flake-input sources is in `src/flake_input.rs`, drawing inputs and
deriving copies in `src/flake.rs`.
