# Changes

## 1.31.0

- New source types `flake` and `flake-input` deliver a flake, or one input
  of a flake as its lock file pins it, as a link into the store, with
  garbage collector roots for its inputs.  With `fetchOnTarget`, the target
  fetches them itself, which also works with `sudo`.
- `inputs` draws inputs of the flake in a source from other sources, by
  rewriting its lock file, or through a generated flake.  `flake` and
  `flake-input` sources can also get `patches` applied, and be
  `materialize`d as writable copies.
- `writeDeploy` deploys a flake from a source with its new `flake`
  parameter.
- `prune` removes everything from the target directory that isn't a
  configured source.
- Populate never changes or removes anything outside the target directory:
  a symlink at the target path of a source gets replaced instead of written
  through, source names must be portable file names, target paths must be
  absolute and not `/`, and `git` sources refuse work trees whose `.git`
  directory names places elsewhere, unless `reclone` is set.
- With rsync 3.5.0 or later, populating a `file` source fails if rsync
  can't read `.rsync-filter` files that apply to it; `insecureLinks`
  decides what to do instead.
- `writeDeploy` passes `--use-remote-sudo` only with a separate
  `buildTarget`, and `--no-flake` if `/etc/nixos/flake.nix` exists and no
  flake gets deployed.
- krops' flake provides krops' functions, and NixOS VM tests in `tests/`
  cover populate.
