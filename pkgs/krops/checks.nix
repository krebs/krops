# Checks of populate's arguments during evaluation.  Each returns true, or
# throws an error naming what's wrong.  lib is nixpkgs' lib.
{ lib }:

with lib;
with builtins;
with import ../../lib/with.nix { inherit lib; };

{
  # Populate replaces and removes what's at the target paths of sources, so
  # it refuses names that lead out of the target directory, to the directory
  # itself, or to its own state.  The remaining names are portable file
  # names, which mean themselves to shells, find, and in URLs, and which the
  # names of the scripts populating the sources may contain.
  checkSourceName = name:
    if elem name [ "." ".." ".populate" ] ||
        builtins.match "[0-9A-Za-z._][0-9A-Za-z._-]*" name == null then
      throw "krops: source name ${toJSON name} can't be used: it must consist of letters, digits, and the characters ._-, not start with -, and be neither ., .., nor .populate"
    else
      true;

  # Populate removes what it finds in the target directory, so it refuses
  # paths that aren't absolute, that are the root directory, or that the
  # target would resolve to another directory than the one they name.
  checkTargetPath = path: let
    components = filter (x: x != "" && x != ".") (splitString "/" path);
  in
    if !isString path || substring 0 1 path != "/" then
      throw "krops: target path ${toJSON path} can't be used: it must be absolute"
    else if components == [] then
      throw "krops: target path ${toJSON path} can't be used: it must not be the root directory"
    else if elem ".." components ||
        builtins.match "[^[:cntrl:]]+" path == null then
      throw "krops: target path ${toJSON path} can't be used: it must not contain .. or control characters"
    else
      true;

  # Inputs get drawn from other sources, so they must exist, and drawing
  # must not go round in circles.
  checkInputs = source: let
    drawnFrom = name: map (x: x.source) (flakeFollows source.${name});
    check = name: from:
      if from == name then
        throw "krops: source ${name} draws inputs from itself"
      else if !(source ? ${from}) then
        throw "krops: source ${name} draws inputs from missing source ${from}"
      else
        true;
    sorted = toposort (a: b: elem a (drawnFrom b)) (attrNames source);
  in
    all (name: all (check name) (drawnFrom name)) (attrNames source) &&
    (if sorted ? cycle then
      throw "krops: sources draw inputs from each other: ${toString sorted.cycle}"
    else
      true);

  # nix copy logs in as the target's user, so populate can't copy flakes to
  # remote targets using sudo, which flake and flake-input sources without
  # fetchOnTarget do.
  checkCopyingWithSudo = target: source: let
    copies = name: let s = source.${name}; in
      elem s.type [ "flake" "flake-input" ] &&
      !(s.${s.type}.fetchOnTarget or false);
    name = findFirst copies null (attrNames source);
  in
    if name != null && target.sudo or false && !isLocalTarget target then
      throw "krops: source ${target.path}/${name}: copying flakes to targets with sudo is not supported"
    else
      true;
}
