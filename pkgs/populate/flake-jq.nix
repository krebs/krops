# jq programs populate uses for flake and flake-input sources, in a file of
# their own, so tests can run them.
rec {
  # jq definitions for subdirectories containing flakes, which flake
  # references and lock entries name either as attribute dir or as query
  # parameter dir of their URL, depending on the version of Nix.  fetchTree
  # supports neither.
  subdirs = /* jq */ ''
    def subdir:
      .dir // ((.url // "") | capture("[?&]dir=(?<dir>[^&]*)").dir) // "";
    def withoutSubdir:
      del(.__final, .dir)
      | if (.url | type) == "string" then
          .url |= (sub("(?<sep>[?&])dir=[^&]*&?"; "\(.sep)") | sub("[?&]$"; ""))
        else . end;
    def subdirOf($node):
      [$node.locked, $node.original]
      | map(select(. != null) | subdir | select(. != ""))
      | first // "";
  '';
  # jq filter selecting the flake or input in nix flake metadata's output,
  # by the path of input names $input, as what to fetch and the
  # subdirectory containing it: {self, locked, subdir}.  Names follow the
  # flake's lock file, follows included; an empty follows path removes an
  # input.  The flake itself, and inputs given by paths relative to it, have
  # self set instead of fetchTree arguments in locked.
  selected = /* jq */ ''
    ${subdirs}
    . as $m
    | .locks as $l
    | def ref($path; $depth):
        if $depth > 64 then error("follows nest too deep") else
          reduce $path[] as $name ($l.root;
            (($l.nodes[.].inputs // {})[$name]) as $next
            | if $next == null or $next == [] then error("no input \($name)")
              elif ($next | type) == "array" then ref($next; $depth + 1)
              else $next end)
        end;
      def join($a; $b):
        if $a == "" then $b elif $b == "" then $a else "\($a)/\($b)" end;
      def resolve($key; $depth):
        $l.nodes[$key] as $node
        | if $depth > 64 then error("parents nest too deep")
          elif $key == $l.root then
            { self: true, locked: null, subdir: subdirOf($m) }
          elif $node.parent != null then
            resolve(ref($node.parent; 0); $depth + 1) as $base
            | $base + {
                subdir: join(join($base.subdir;
                  $node.locked.path | ltrimstr("./") | rtrimstr("/") | if . == "." then "" else . end);
                  subdirOf($node))
              }
          else
            { self: false, locked: ($node.locked | withoutSubdir), subdir: subdirOf($node) }
          end;
      resolve(ref($input; 0); 0)
  '';
  # jq filter telling whether the target can fetch the flake itself, i.e.
  # whether its locked reference doesn't refer to the deploying machine.
  selfIsRemote = /* jq */ ''
    .locked | (.type != "path") and ((.url // "") | startswith("file:") | not)
  '';
  # jq filter replacing self in the selection $selected with the flake's
  # locked reference.
  selfLocked = /* jq */ ''
    ${subdirs}
    .locked as $self
    | $selected + { self: false, locked: ($self | withoutSubdir) }
  '';
}
