# krops' own lib, without nixpkgs' lib, which it takes as lib, e.g. a
# flake's nixpkgs.lib.  ./default.nix is nixpkgs' lib from <nixpkgs/lib>,
# builtins, and this, as one.
{ lib }:

let
  populate.lib = import ../pkgs/populate/lib { inherit lib; };

  # Whether evaluation is pure, which hides the environment and files
  # outside the store.
  pure = !(builtins ? currentSystem);
in

rec {

  # What populate's Nix library defines.
  inherit (populate.lib) evalSource flakeFollows hasGeneratedFlake derivesFlake;

  maybeHostName = default: let
    # We're parsing /etc/hostname here because reading
    # /proc/sys/kernel/hostname yields ""
    path = "/etc/hostname";
    lines = lib.splitString "\n" (lib.readFile path);
    hostNames = lib.filter types.label.check lines;
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

  # Whether target is the machine krops runs on, as the user running it.
  # Pure evaluation can't tell, so krops leaves that to populate then.
  isLocalTarget = let
    origin = mkTarget "";
  in target:
    target.user == origin.user &&
    lib.elem target.host [origin.host "localhost"];

  # A target as krops' functions take it: an attribute set, with the parts
  # the string s, [USER@][HOST][:PORT][PATH], leaves out defaulting to
  # LOGNAME, the machine's name, and /var/src.  Pure evaluation can't tell
  # the first two, so they're null then, which populate fills in when it
  # runs.  s can also be an attribute set, which the defaults fill up.
  mkTarget = s: let
    parse = lib.match "(([^@]*)@)?(([^:/]+))?(:([^/]+))?(/.*)?" s;
    elemAt' = xs: i: if lib.length xs > i then lib.elemAt xs i else null;
    filterNull = lib.filterAttrs (n: v: v != null);
  in {
    user = lib.maybeEnv "LOGNAME" null;
    host = if pure then null else lib.maybeEnv "HOSTNAME" (maybeHostName "localhost");
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
    isSafeChar = testString "[-+./0-9:=A-Z_a-z]";
    quoteChar = c:
      if isSafeChar c then c
      else if c == "\n" then "'\n'"
      else "\\${c}";
  in {
    quote = x: if x == "" then "''" else lib.stringAsChars quoteChar x;

    # Shell code defining the function url_path, which prints the path $1
    # as it goes into a URL: with every byte percent-encoded that isn't a
    # letter, a digit, or one of -._~/.  Nix decodes that, and otherwise
    # takes, e.g., ? and # for delimiters, and refuses blanks.
    urlPath = /* sh */ ''
      url_path() {
        printf %s "$1" | od -An -v -tx1 | tr -s ' ' '\n' |
        while read -r url_byte; do
          case $url_byte in
            "") ;;
            2[d-f]|3[0-9]|4[1-9a-f]|5[0-9a]|5f|6[1-9a-f]|7[0-9a]|7e)
              printf "\\$(printf %o "0x$url_byte")"
              ;;
            *)
              printf '%%%s' "$url_byte"
              ;;
          esac
        done
      }
    '';

    # Shell code that enables flakes for the Nix commands following it, and
    # fails unless Nix supports them, i.e. is version 2.4 or later.  `what`
    # names what needs flakes, for the error message.
    requireFlakes = what: /* sh */ ''
      NIX_CONFIG=$(printf '%s\n%s' "''${NIX_CONFIG-}" \
          'extra-experimental-features = nix-command flakes')
      export NIX_CONFIG
      if ! nix flake --help >/dev/null 2>&1; then
        >&2 printf 'error: %s needs Nix 2.4 or later on %s, found: %s\n' \
            ${shell.quote what} "$(uname -n)" "$(nix --version 2>&1 || :)"
        exit 1
      fi
    '';
  };

  test = re: x: lib.isString x && testString re x;
  testString = re: x: lib.match re x != null;

  types = lib.types // populate.lib.types;
}
