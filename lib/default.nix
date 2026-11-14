# krops' lib: nixpkgs' lib from <nixpkgs/lib>, builtins, and what krops
# defines, see ./with.nix, which takes nixpkgs' lib from its caller instead.
let
  lib = import <nixpkgs/lib>;
in
  lib // builtins // import ./with.nix { inherit lib; }
