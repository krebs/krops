# pkgs.populate: given populate's arguments, it checks them, and returns a
# script running populate-unwrapped, the program in ../populate, with them,
# the sources as JSON.
{ coreutils, findutils, git, lib, nix, openssh, pass, passage, rsync, writers
, populate-unwrapped
, ...
}@args:

let
  checks = import ./checks.nix { inherit lib; };
  targets = import ./target.nix { inherit lib; };

  # Arguments populate doesn't use, which overrides written for krops 1 may
  # set.  They come through ..., because callPackage would set named ones.
  unused = builtins.filter (name: args ? ${name}) [ "dash" "implementation" "jq" ];
  unexpected = builtins.attrNames (removeAttrs args ([
    "coreutils" "findutils" "git" "lib" "nix" "openssh" "pass" "passage"
    "rsync" "writers" "populate-unwrapped"
  ] ++ unused));

  populate =
    { backup ? false, force ? false, prune ? false, source, target }:
    let
      path = (targets.parts target).path;
    in
    assert checks.checkTargetPath path;
    assert builtins.all checks.checkSourceName (builtins.attrNames source);
    assert checks.checkInputs source;
    # Populate refuses that as well, when it runs.
    assert builtins.isString target || targets.pure ||
      checks.checkCopyingWithSudo target source;
    writers.writeDash "populate.${targets.name target}" /* sh */ ''
      set -efu
      echo + "$0" >&2
      PATH=${lib.makeBinPath [
        coreutils findutils git nix openssh pass passage rsync
      ]}''${PATH:+:$PATH}
      export PATH
      # The sources on a file descriptor of their own, so the commands
      # populate runs keep standard input.  Store paths in them stay
      # dependencies of this script, so building it builds them.  The JSON is
      # a single line, which can't be the delimiter.
      exec ${populate-unwrapped}/bin/populate ${lib.escapeShellArgs (
        lib.optional backup "--backup" ++
        lib.optional force "--force" ++
        lib.optional prune "--prune"
      )} /dev/fd/3 ${lib.escapeShellArgs (targets.populateArgs target)} 3<<'EOF'
      ${builtins.toJSON source}
      EOF
    '';

in

if unexpected != [] then
  throw "krops: populate called with unexpected argument ${builtins.head unexpected}"
else
  lib.foldr
    (name: lib.warn "krops: populate's argument ${name} is unused")
    populate
    unused
