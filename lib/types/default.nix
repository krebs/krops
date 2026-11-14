# The types of krops' lib that aren't nixpkgs', which populate's Nix library
# defines.
{ lib }: (import ../../pkgs/populate/lib { inherit lib; }).types
