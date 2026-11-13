# The program delivering sources, built from the crate in this directory.
{ rustPlatform }:

let
  cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
in

rustPlatform.buildRustPackage {
  pname = cargoToml.package.name;
  inherit (cargoToml.package) version;
  # Only what cargo builds from, so changes to the Nix files or the docs
  # don't rebuild the program.
  src = builtins.path {
    name = "populate-src";
    path = ./.;
    filter = path: type: let
      relative = builtins.substring
        (builtins.stringLength (toString ./.) + 1) (-1) (toString path);
    in
      builtins.elem relative [ "Cargo.toml" "Cargo.lock" "src" ] ||
      builtins.substring 0 4 relative == "src/";
  };
  cargoLock.lockFile = ./Cargo.lock;
}
