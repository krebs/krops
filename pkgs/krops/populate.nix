# pkgs.populate: given populate's arguments, it checks them, and returns a
# script running populate-unwrapped, the program in ../populate, with them,
# the sources as JSON.
{ coreutils, findutils, git, nix, openssh, pass, passage, rsync, writers
, populate-unwrapped
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
    "writers" "populate-unwrapped"
  ] ++ unused));

  # The parts of a target string, like mkTarget parses it, without its
  # defaults, which populate fills in when it runs.
  parseTarget = s: let
    parts = match "(([^@]*)@)?(([^:/]+))?(:([^/]+))?(/.*)?" s;
  in
    if parts == null then throw "krops: invalid target ${toJSON s}"
    else { host = elemAt parts 3; path = elemAt parts 6; };

  populate =
    { backup ? false, force ? false, prune ? false, source, target }:
    let
      # A target string goes to populate as it is, so populate decides what
      # it leaves out when it runs.  An attribute set, as mkTarget returns
      # it, goes part by part, with whether it's local decided now, like the
      # other functions of krops do.
      parsed = parseTarget target;
      path = if isString target then (if parsed.path != null then parsed.path else "/var/src") else target.path;
      host = if isString target then (if parsed.host != null then parsed.host else "localhost") else target.host;
      targetArgs =
        if isString target then [ target ]
        else [
          "--user" (if target.user or null == null then "" else target.user)
          "--host" target.host
          "--path" target.path
        ] ++ optionals (target.port or null != null) [
          "--port" (toString target.port)
        ] ++ optional (target.sudo or false) "--sudo"
          ++ concatMap (arg: [ "--ssh-arg" arg ]) (flatten (target.extraOptions or []))
          ++ [ (if isLocalTarget target then "--local" else "--remote") ];
    in
    assert checks.checkTargetPath path;
    assert all checks.checkSourceName (attrNames source);
    assert checks.checkInputs source;
    assert isString target || checks.checkCopyingWithSudo target source;
    writers.writeDash "populate.${host}" /* sh */ ''
      set -efu
      echo + "$0" >&2
      PATH=${makeBinPath [
        coreutils findutils git nix openssh pass passage rsync
      ]}''${PATH:+:$PATH}
      export PATH
      # The sources on a file descriptor of their own, so the commands
      # populate runs keep standard input.  Store paths in them stay
      # dependencies of this script, so building it builds them.  The JSON is
      # a single line, which can't be the delimiter.
      exec ${populate-unwrapped}/bin/populate ${escapeShellArgs (
        optional backup "--backup" ++
        optional force "--force" ++
        optional prune "--prune"
      )} /dev/fd/3 ${escapeShellArgs targetArgs} 3<<'EOF'
      ${toJSON source}
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
