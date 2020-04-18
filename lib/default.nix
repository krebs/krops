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
        bool = x;
        list = map sanitize x;
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

    isLocalTarget = let
      origin = lib.mkTarget "";
    in target:
      target.user == origin.user &&
      lib.elem target.host [origin.host "localhost"];

    mkTarget = s: let
      parse = lib.match "(([^@]*)@)?(([^:/]+))?(:([^/]+))?(/.*)?" s;
      elemAt' = xs: i: if lib.length xs > i then lib.elemAt xs i else null;
      filterNull = lib.filterAttrs (n: v: v != null);
    in {
      user = lib.getEnv "LOGNAME";
      host = lib.maybeEnv "HOSTNAME" lib.getHostName;
      port = "22";
      path = "/var/src";
      sudo = false;
      extraOptions = [];
    } // (if lib.isString s then filterNull {
      user = elemAt' parse 1;
      host = elemAt' parse 3;
      port = elemAt' parse 5;
      path = elemAt' parse 6;
    } else s);

    shell = let
      isSafeChar = lib.testString "[-+./0-9:=A-Z_a-z]";
      quoteChar = c:
        if isSafeChar c then c
        else if c == "\n" then "'\n'"
        else "\\${c}";
    in {
      quote = x: if x == "" then "''" else lib.stringAsChars quoteChar x;
    };

    test = re: x: lib.isString x && lib.testString re x;
    testString = re: x: lib.match re x != null;

    types = nixpkgs.lib.types // import ./types { lib = body; };
  };

  nixpkgs.lib = import <nixpkgs/lib>;

}
