# krops' lib as krops 1 had it, for backwards compatibility: nixpkgs' lib
# from <nixpkgs/lib>, builtins, and krops' own lib, ./with.nix, which krops
# uses, with nixpkgs' lib from its caller.
let
  lib = import <nixpkgs/lib>;
in
  lib // builtins // import ./with.nix { inherit lib; }
