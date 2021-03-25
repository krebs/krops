self: super: {
  krops = self.callPackage ./krops {};
  populate = self.callPackage ./populate {};
}
