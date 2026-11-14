self: super: {
  krops = self.callPackage ./krops {};
  # populate's Nix API, a function from its arguments to a script running
  # populate-unwrapped, the program.
  populate = self.callPackage ./krops/populate.nix {};
  populate-unwrapped = self.callPackage ./populate {};
}
