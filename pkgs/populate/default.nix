# populate, built from the crate in this directory: nix-build here, or
# callPackage.
{ rustPlatform ? (import <nixpkgs> {}).rustPlatform }:

let
  cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
in

rustPlatform.buildRustPackage {
  pname = cargoToml.package.name;
  inherit (cargoToml.package) version;
  # Without what cargo doesn't build from, so changes to the Nix files, the
  # docs, or the tests don't rebuild the program.  By names, not by paths
  # relative to this directory: the paths the filter gets needn't start
  # with toString ./., e.g. if a symlink leads to this directory.
  src = builtins.path {
    name = "populate-src";
    path = ./.;
    filter = path: type: let
      name = baseNameOf path;
    in
      !(builtins.elem name [
        ".gitignore" "README.md" "docs" "lib" "target" "tests"
      ] ||
        builtins.match ".*\\.nix" name != null);
  };
  cargoLock.lockFile = ./Cargo.lock;
}
