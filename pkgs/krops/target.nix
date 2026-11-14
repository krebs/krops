# Targets as krops' functions take them: strings, which go to populate as
# they are, so it fills in what they leave out when it runs, and attribute
# sets, as mkTarget returns them, which go part by part, with whether the
# target is local decided during evaluation, unless that's pure.
{ lib }:

let
  klib = import ../../lib/with.nix { inherit lib; };
in

rec {
  # Whether evaluation is pure, which can't tell mkTarget's defaults for
  # the user and the host, nor whether a target is local.
  pure = !(builtins ? currentSystem);

  # The parts of target, a string parsed like mkTarget parses it, but with
  # only the path defaulting, to /var/src, or an attribute set.
  parts = target:
    if builtins.isString target then let
      parsed = builtins.match "(([^@]*)@)?(([^:/]+))?(:([^/]+))?(/.*)?" target;
      part = builtins.elemAt parsed;
    in
      if parsed == null then
        throw "krops: invalid target ${builtins.toJSON target}"
      else {
        user = part 1;
        host = part 3;
        port = part 5;
        path = if part 6 == null then "/var/src" else part 6;
        sudo = false;
        extraOptions = [];
      }
    else target;

  # populate's or populate shell's options for an attribute set target,
  # the first with the path, if withPath.  Pure evaluation leaves out the
  # user and the host if they're null, and whether the target is local,
  # which populate decides.
  options = withPath: target:
    lib.optionals (!pure || target.user or null != null) [
      "--user" (if target.user or null == null then "" else target.user)
    ] ++ lib.optionals (!pure || target.host or null != null) [
      "--host" target.host
    ] ++ lib.optionals withPath [
      "--path" target.path
    ] ++ lib.optionals (target.port or null != null) [
      "--port" (toString target.port)
    ] ++ lib.optional (target.sudo or false) "--sudo"
      ++ builtins.concatMap (arg: [ "--ssh-arg" arg ])
        (lib.flatten (target.extraOptions or []))
      ++ lib.optional (!pure)
        (if klib.isLocalTarget target then "--local" else "--remote");

  # populate's arguments for target, after the sources.
  populateArgs = target:
    if builtins.isString target then [ target ]
    else options true target;

  # populate shell's arguments for running script on target.
  shellArgs = target: script:
    if builtins.isString target then [ "--" target script ]
    else options false target ++ [ "--" "" script ];

  # The host of target, for naming scripts, or localhost if it has none.
  name = target: let host = (parts target).host; in
    if host == null then "localhost" else host;
}
