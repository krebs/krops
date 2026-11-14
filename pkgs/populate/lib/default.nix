# populate's Nix library: the types of sources, which describe how to write
# them in Nix, and evalSource, which turns sources written so into the
# sources populate reads as JSON.  lib is nixpkgs' lib.
{ lib ? import <nixpkgs/lib> }:

let
  # nixpkgs' lib, with what the types use besides.
  lib' = lib // {
    test = re: x: lib.isString x && lib.match re x != null;
    types = lib.types // types;
  };

  types =
    import ./types/posix.nix { lib = lib'; } //
    import ./types/populate.nix { lib = lib'; };

in rec {

  inherit types;

  # The sources, a list of attribute sets of sources by name, or one, with
  # shorthands expanded and defaults filled in, and without settings that
  # are null, as populate reads them, e.g. with builtins.toJSON.
  evalSource = let
    eval = source: lib.evalModules {
      modules = lib.singleton {
        _file = toString ./.;
        imports = map (source: { inherit source; }) (lib.toList source);
        options.source = lib.mkOption {
          default = {};
          type = lib.types.attrsOf types.source;
        };
      };
    };
    sanitize = x: lib.getAttr (lib.typeOf x) {
      bool = x;
      list = map sanitize x;
      set = lib.mapAttrs
              (lib.const sanitize)
              (lib.filterAttrs
                (name: value: name != "_module" && value != null) x);
      string = x;
    };
  in
    source: sanitize (eval source).config.source;

  # Inputs a source draws from other sources, as list of attribute sets like
  # { path = [ "stockholm" "nixpkgs" ]; source = "nixpkgs"; }.
  flakeFollows = source: let
    flatten = prefix: inputs: lib.concatLists (lib.mapAttrsToList
      (name: input:
        lib.optional (input.follows or null != null) {
          path = prefix ++ [ name ];
          source = input.follows;
        } ++
        flatten (prefix ++ [ name ]) (input.inputs or {}))
      inputs);
  in
    flatten [] (source.${source.type}.inputs or {});

  # Tells whether a source's inputs get drawn from other sources by a
  # generated flake in .populate/flakes, instead of by rewriting the lock
  # file of the flake in the source.  Symlink sources point at other
  # sources, whose lock files stay as they are.
  hasGeneratedFlake = source:
    flakeFollows source != [] &&
    (source.type == "symlink" || !(source.${source.type}.rewriteLock or true));

  # Tells whether a flake or flake-input source gets delivered as a copy,
  # which gets patched, gets its lock file rewritten, or is materialized.
  derivesFlake = source: let
    source' = source.${source.type};
  in
    lib.elem source.type [ "flake" "flake-input" ] &&
    (source'.materialize or false || source'.patches or [] != [] ||
     (source'.rewriteLock or true && flakeFollows source != []));

}
