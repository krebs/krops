# Populate, which delivers sources to a target directory.  Given populate's
# arguments, it checks them, and returns a script running the program in
# this directory with them as JSON.  rustProgram is that program, e.g. one
# built with cargo during development.
{ coreutils, findutils, git, nix, openssh, pass, passage, rsync, writers
, rustPlatform ? null
, rustProgram ? import ./program.nix { inherit rustPlatform; }
, ...
}@args:

with import ../../lib;

let
  checks = import ./checks.nix;

  # Arguments populate doesn't use, which overrides written for krops 1 may
  # set.  They come through ..., because callPackage would set named ones.
  unused = filter (name: args ? ${name}) [ "dash" "implementation" "jq" ];
  unexpected = attrNames (removeAttrs args ([
    "coreutils" "findutils" "git" "nix" "openssh" "pass" "passage" "rsync"
    "writers" "rustPlatform" "rustProgram"
  ] ++ unused));

  populate =
    { backup ? false, force ? false, prune ? false, source, target }:
    assert checks.checkTargetPath target.path;
    assert all checks.checkSourceName (attrNames source);
    assert checks.checkInputs source;
    assert checks.checkCopyingWithSudo target source;
    let
      # Store paths in the arguments stay dependencies of the script, so
      # building it builds them.
      spec = toJSON {
        version = 1;
        inherit backup force prune source;
        target = {
          inherit (target) host path;
          user = target.user or null;
          port = if target.port or null == null then null else toString target.port;
          sudo = target.sudo or false;
          extraOptions = target.extraOptions or [];
          # Decided during evaluation, like the other functions of krops do.
          local = isLocalTarget target;
        };
      };
    in
    writers.writeDash "populate.${target.host}" /* sh */ ''
      set -efu
      echo + "$0" >&2
      PATH=${makeBinPath [
        coreutils findutils git nix openssh pass passage rsync
      ]}''${PATH:+:$PATH}
      export PATH
      # On a file descriptor of its own, so the commands populate runs keep
      # standard input.  The JSON is a single line, which can't be the delimiter.
      exec ${rustProgram}/bin/populate /dev/fd/3 3<<'EOF'
      ${spec}
      EOF
    '';

in

if unexpected != [] then
  throw "krops: populate called with unexpected argument ${head unexpected}"
else
  foldr
    (name: warn "krops: populate's argument ${name} is unused")
    populate
    unused
