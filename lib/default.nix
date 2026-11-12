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
      lib.flakeFollows source != [] &&
      (source.type == "symlink" || !(source.${source.type}.rewriteLock or true));

    # Tells whether a flake or flake-input source gets delivered as a copy,
    # which gets patched, gets its lock file rewritten, or is materialized.
    derivesFlake = source: let
      source' = source.${source.type};
    in
      lib.elem source.type [ "flake" "flake-input" ] &&
      (source'.materialize or false || source'.patches or [] != [] ||
       (source'.rewriteLock or true && lib.flakeFollows source != []));

    maybeHostName = default: let
      # We're parsing /etc/hostname here because reading
      # /proc/sys/kernel/hostname yields ""
      path = "/etc/hostname";
      lines = lib.splitString "\n" (lib.readFile path);
      hostNames = lib.filter lib.types.label.check lines;
    in
      if lib.pathExists path then
        if lib.length hostNames == 1 then
          lib.head hostNames
        else
          lib.trace "malformed ${path}" default
      else
        default;

    firstWord = s:
      lib.head (lib.match "^([^[:space:]]*).*" s);

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
      user = lib.maybeEnv "LOGNAME" null;
      host = lib.maybeEnv "HOSTNAME" (lib.maybeHostName "localhost");
      port = null;
      path = "/var/src";
      sudo = false;
      extraOptions = [];
    } // (if lib.isString s then filterNull {
      user = elemAt' parse 1;
      host = elemAt' parse 3;
      port = elemAt' parse 5;
      path = elemAt' parse 6;
    } else s);

    mkUserPortSSHOpts = target:
      (lib.optionals (target.user != null) ["-l" target.user]) ++
      (lib.optionals (target.port != null) ["-p" target.port]);

    shell = let
      isSafeChar = lib.testString "[-+./0-9:=A-Z_a-z]";
      quoteChar = c:
        if isSafeChar c then c
        else if c == "\n" then "'\n'"
        else "\\${c}";
    in {
      quote = x: if x == "" then "''" else lib.stringAsChars quoteChar x;

      # Shell code that enables flakes for the Nix commands following it, and
      # fails unless Nix supports them, i.e. is version 2.4 or later.  `what`
      # names what needs flakes, for the error message.
      requireFlakes = what: /* sh */ ''
        NIX_CONFIG=$(printf '%s\n%s' "''${NIX_CONFIG-}" \
            'extra-experimental-features = nix-command flakes')
        export NIX_CONFIG
        if ! nix flake --help >/dev/null 2>&1; then
          >&2 printf 'error: %s needs Nix 2.4 or later on %s, found: %s\n' \
              ${lib.shell.quote what} "$(uname -n)" "$(nix --version 2>&1 || :)"
          exit 1
        fi
      '';
    };

    test = re: x: lib.isString x && lib.testString re x;
    testString = re: x: lib.match re x != null;

    types = nixpkgs.lib.types // import ./types { lib = body; };
  };

  nixpkgs.lib = import <nixpkgs/lib>;

}
