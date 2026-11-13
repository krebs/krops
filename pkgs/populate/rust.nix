# Populate's arguments, checked and as JSON, for the program in this
# directory, which delivers the sources.
{ coreutils, findutils, git, jq, nix, openssh, pass, passage, program, rsync
, writers
}:

with import ../../lib;

let
  checks = import ./checks.nix;
in

{ backup ? false, force ? false, prune ? false, source, target }:
assert checks.checkTargetPath target.path;
assert all checks.checkSourceName (attrNames source);
assert checks.checkInputs source;
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
  # The tools populate depends on, in front of others of the same name.
  PATH=${makeBinPath [
    rsync openssh git nix pass passage jq findutils coreutils
  ]}''${PATH:+:$PATH}
  export PATH
  # On a file descriptor of its own, so the commands populate runs keep
  # standard input.  The JSON is a single line, which can't be the delimiter.
  exec ${program}/bin/populate /dev/fd/3 3<<'EOF'
  ${spec}
  EOF
''
