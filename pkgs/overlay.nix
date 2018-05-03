let
  lib = import ../lib;
in

self: super: {
  krops = self.callPackage ./krops {};
  populate = self.callPackage ./populate {};
  writeDash = name: text: self.writeScript name ''
    #! ${self.dash}/bin/dash
    ${text}
  '';
  writeJSON = name: value: self.runCommand name {
    json = lib.toJSON value;
    passAsFile = [ "json" ];
  } /* sh */ ''
    ${self.jq}/bin/jq . "$jsonPath" > "$out"
  '';
}
