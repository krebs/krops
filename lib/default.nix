let {

  body = lib;

  lib = nixpkgs.lib // builtins // {

    evalSource = let
      eval = source: lib.evalModules {
        modules = lib.singleton {
          _file = toString ./.;
          imports = map (source: { inherit source; }) (lib.toList source);
          options.source = lib.mkOption {
            default = {};
            type = lib.types.attrsOf lib.types.source;
          };
        };
      };
      sanitize = x: lib.getAttr (lib.typeOf x) {
        set = lib.mapAttrs
                (lib.const sanitize)
                (lib.filterAttrs
                  (name: value: name != "_module" && value != null) x);
        string = x;
      };
    in
      # This function's return value can be used as pkgs.populate input.
      source: sanitize (eval source).config.source;

    getHostName = let
      # We're parsing /etc/hostname here because reading
      # /proc/sys/kernel/hostname yields ""
      y = lib.filter lib.types.label.check (lib.splitString "\n" (lib.readFile /etc/hostname));
    in
      if lib.length y != 1 then throw "malformed /etc/hostname" else
      lib.elemAt y 0;

    mkTarget = s: let
      default = defVal: val: if val != null then val else defVal;
      parse = lib.match "(([^@]+)@)?(([^:/]+))?(:([^/]+))?(/.*)?" s;
      elemAt' = xs: i: if lib.length xs > i then lib.elemAt xs i else null;
    in {
      user = default (lib.getEnv "LOGNAME") (elemAt' parse 1);
      host = default (lib.maybeEnv "HOSTNAME" lib.getHostName) (elemAt' parse 3);
      port = default "22" /* "ssh"? */ (elemAt' parse 5);
      path = default "/var/src" /* no default? */ (elemAt' parse 6);
    };

    test = re: x: lib.isString x && lib.testString re x;
    testString = re: x: lib.match re x != null;

    types = nixpkgs.lib.types // import ./types { lib = body; };
  };

  nixpkgs.lib = import <nixpkgs/lib>;

}
