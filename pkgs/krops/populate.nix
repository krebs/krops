# pkgs.populate: given populate's arguments, it checks them, and returns a
# script running populate-unwrapped, the program in ../populate, with them,
# the sources as JSON.
{ coreutils, findutils, git, lib, nix, openssh, pass, passage, rsync, writers
, populate-unwrapped
, ...
}@args:

let
  klib = import ../../lib/with.nix { inherit lib; };
  checks = import ./checks.nix { inherit lib; };

  # Arguments populate doesn't use, which overrides written for krops 1 may
  # set.  They come through ..., because callPackage would set named ones.
  unused = builtins.filter (name: args ? ${name}) [ "dash" "implementation" "jq" ];
  unexpected = builtins.attrNames (removeAttrs args ([
    "coreutils" "findutils" "git" "lib" "nix" "openssh" "pass" "passage"
    "rsync" "writers" "populate-unwrapped"
  ] ++ unused));

  # The parts of a target string, like mkTarget parses it, without its
  # defaults, which populate fills in when it runs.
  parseTarget = s: let
    parts = builtins.match "(([^@]*)@)?(([^:/]+))?(:([^/]+))?(/.*)?" s;
  in
    if parts == null then throw "krops: invalid target ${builtins.toJSON s}"
    else { host = builtins.elemAt parts 3; path = builtins.elemAt parts 6; };

  populate =
    { backup ? false, force ? false, prune ? false, source, target }:
    let
      # A target string goes to populate as it is, so populate decides what
      # it leaves out when it runs.  An attribute set, as mkTarget returns
      # it, goes part by part, with whether it's local decided now, like the
      # other functions of krops do.
      parsed = parseTarget target;
      path = if builtins.isString target then (if parsed.path != null then parsed.path else "/var/src") else target.path;
      host = if builtins.isString target then (if parsed.host != null then parsed.host else "localhost") else target.host;
      targetArgs =
        if builtins.isString target then [ target ]
        else [
          "--user" (if target.user or null == null then "" else target.user)
          "--host" target.host
          "--path" target.path
        ] ++ lib.optionals (target.port or null != null) [
          "--port" (toString target.port)
        ] ++ lib.optional (target.sudo or false) "--sudo"
          ++ builtins.concatMap (arg: [ "--ssh-arg" arg ]) (lib.flatten (target.extraOptions or []))
          ++ [ (if klib.isLocalTarget target then "--local" else "--remote") ];
    in
    assert checks.checkTargetPath path;
    assert builtins.all checks.checkSourceName (builtins.attrNames source);
    assert checks.checkInputs source;
    assert builtins.isString target || checks.checkCopyingWithSudo target source;
    writers.writeDash "populate.${host}" /* sh */ ''
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
      )} /dev/fd/3 ${lib.escapeShellArgs targetArgs} 3<<'EOF'
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
