with import ../../lib;
with shell;

{ coreutils, dash, findutils, git, jq, nix, openssh, pass, passage, rsync, writers }:

let
  check = { force, target }: let
    sentinelFile = "${target.path}/.populate";
  in runShell target /* sh */ ''
    ${optionalString force /* sh */ ''
      mkdir -vp ${quote (dirOf sentinelFile)} >&2
      touch ${quote sentinelFile}
    ''}
    if ! test -e ${quote sentinelFile}; then
      >&2 printf 'error: missing sentinel file: %s\n' ${quote (
        optionalString (!isLocalTarget target) "${target.host}:" +
        sentinelFile
      )}
      exit 1
    fi
  '';

  do-backup = { target }: let
    sentinelFile = "${target.path}/.populate";
  in
    runShell target /* sh */ ''
      if ! test -d ${quote sentinelFile}; then
        >&2 printf 'error: sentinel file is not a directory: %s\n' ${quote (
          optionalString (!isLocalTarget target) "${target.host}:" +
          sentinelFile
        )}
        exit 1
      fi
      rsync >&2 \
          -aAXF \
          --delete \
          --exclude /.populate \
          --link-dest=${quote target.path} \
          ${target.path}/ \
          ${target.path}/.populate/backup/
    '';

  # Shell code that turns the sentinel file into a directory, which populate
  # uses for keeping state.  The sentinel only needs to exist.
  sentinelDirectory = sentinel: /* sh */ ''
    if test -f ${quote sentinel}; then
      rm ${quote sentinel}
      mkdir ${quote sentinel}
    fi
  '';

  # Generates a flake for each source that draws inputs from other sources, in
  # .populate/flakes/<name>.  Each flake re-exports the outputs of the flake in
  # its source, with those inputs drawn from the other sources' flakes, and
  # gets locked on every run, so its lock file matches the sources.
  flakes = target: sources: let
    flakesDir = "${target.path}/.populate/flakes";
    generated = filterAttrs (_: source: flakeFollows source != []) sources;
    names = attrNames generated;
    drawnFrom = name: map (x: x.source) (flakeFollows generated.${name});
    sorted = toposort (a: b: elem a (drawnFrom b)) names;
    # Generated flakes refer to each other's generated flakes, so they don't
    # need to repeat overrides.
    url = name:
      if generated ? ${name}
        then "path:${flakesDir}/${name}"
        else "$(flake_url ${quote name})";
    check = name: source:
      if source == name then
        throw "krops: source ${name} draws inputs from itself"
      else if !(sources ? ${source}) then
        throw "krops: source ${name} draws inputs from missing source ${source}"
      else
        source;
    flake = name: let
      follows = flakeFollows generated.${name};
      drawn = unique (map (x: check name x.source) follows);
      # Nix ignores overrides below an input that follows another input, so
      # an input of an input drawn from a source gets overridden at that
      # source.
      override = x: let
        drawnParents = filter
          (path: any (y: y.path == path) follows)
          (map (n: take n x.path) (range 1 (length x.path - 1)));
        parent = if drawnParents == [] then null else last drawnParents;
        base =
          if parent == null then name
          else (findFirst (y: y.path == parent) null follows).source;
        rest = if parent == null then x.path else drop (length parent) x.path;
      in
        "inputs.${toJSON base}" +
        concatMapStrings (name: ".inputs.${toJSON name}") rest +
        ".follows = ${toJSON x.source};";
    in /* sh */ ''
      (
        url=$(flake_url ${quote name})
        ${concatImapStrings (i: source: /* sh */ ''
          url${toString i}=${url source}
        '') drawn}
        rm -fR ${quote "${flakesDir}/${name}"}
        mkdir ${quote "${flakesDir}/${name}"}
        cd ${quote "${flakesDir}/${name}"}
        {
          echo '{'
          printf '  inputs.%s.url = "%s";\n' ${quote (toJSON name)} "$url"
          ${concatImapStrings (i: source: /* sh */ ''
            printf '  inputs.%s.url = "%s";\n' ${quote (toJSON source)} "$url${toString i}"
          '') drawn}
          ${concatMapStrings (x: /* sh */ ''
            printf '  %s\n' ${quote (override x)}
          '') follows}
          printf '  outputs = inputs: inputs.%s;\n' ${quote (toJSON name)}
          echo '}'
        } > flake.nix
        nix flake lock >&2
      )
    '';
  in
    if sorted ? cycle then
      throw "krops: sources draw inputs from each other: ${toString sorted.cycle}"
    else runShell target /* sh */ ''
      set -efu
      ${optionalString (names != []) /* sh */ ''
        ${requireFlakes "drawing flake inputs from sources"}

        # Prints the flake URL of the source named $1.
        flake_url() {
          path=$(readlink -f ${quote target.path}/"$1")
          if ! test -d "$path"; then
            >&2 printf 'error: source %s is not a directory\n' "$1"
            exit 1
          fi
          if test -e "$path"/.git; then
            if test -e "$path"/.gitmodules; then
              printf 'git+file:%s?submodules=1' "$path"
            else
              printf 'git+file:%s' "$path"
            fi
          else
            printf 'path:%s' "$path"
          fi
        }

        # Inputs can only be drawn into flakes, so check all sources before
        # generating anything.
        missing=
        for name in ${concatMapStringsSep " " quote names}; do
          if ! test -e ${quote target.path}/"$name"/flake.nix; then
            missing="$missing $name"
          fi
        done
        if test -n "$missing"; then
          >&2 printf 'error: source %s draws flake inputs from other sources, but contains no flake.nix\n' $missing
          exit 1
        fi

        ${sentinelDirectory "${target.path}/.populate"}
        mkdir -p ${quote flakesDir}
        ${concatMapStrings flake sorted.result}
      ''}
      # Remove roots of flake inputs of sources that are neither flake nor
      # flake-input sources anymore.
      ${concatMapStrings (name: /* sh */ ''
        rm -fR ${quote "${target.path}/.populate/flake-inputs/${name}"}
      '') (attrNames (filterAttrs
        (_: source: !elem source.type [ "flake" "flake-input" ])
        sources))}
      if test -d ${quote "${target.path}/.populate/flake-inputs"} &&
          test -z "$(ls -A ${quote "${target.path}/.populate/flake-inputs"})"; then
        rmdir ${quote "${target.path}/.populate/flake-inputs"}
      fi
      # Remove flakes of sources that no longer draw inputs from other sources.
      if test -d ${quote flakesDir}; then
        ls -A ${quote flakesDir} | while read -r name; do
          case ${quote " ${toString names} "} in
            *" $name "*) ;;
            *) rm -fR ${quote flakesDir}/"$name" ;;
          esac
        done
      fi
    '';

  # Removes entries of the target directory that aren't sources, garbage
  # collector roots of flake inputs of sources that aren't flake or
  # flake-input sources, and uploads left behind by interrupted runs.
  prune' = target: sources: let
    pattern = names: concatMapStringsSep "|" quote names;
    flakeNames = attrNames (filterAttrs
      (_: source: elem source.type [ "flake" "flake-input" ])
      sources);
  in runShell target /* sh */ ''
    set -efu
    cd ${quote target.path}
    ls -A | while read -r name; do
      case $name in
        ${pattern (attrNames sources ++ [ ".populate" ])}) ;;
        *)
          >&2 printf 'pruning %s\n' ${quote target.path}/"$name"
          rm -fR ./"$name"
          ;;
      esac
    done
    roots=.populate/flake-inputs
    if test -d "$roots"; then
      ls -A "$roots" | while read -r name; do
        case $name in
          ${optionalString (flakeNames != []) "${pattern flakeNames}) ;;"}
          *) rm -fR "$roots"/"$name" ;;
        esac
      done
      if test -z "$(ls -A "$roots")"; then
        rmdir "$roots"
      fi
    fi
    if test -e .populate/flake-uploads; then
      chmod -R u+w .populate/flake-uploads
      rm -fR .populate/flake-uploads
    fi
  '';

  pop.derivation = target: source: runShell target /* sh */ ''
    nix-build -E ${quote source.text} -o ${quote target.path} >&2
  '';

  pop.file = target: source: let
    config = rsyncDefaultConfig // derivedConfig // sourceConfig;
    derivedConfig = {
      useChecksum =
        if isStorePath source.path
          then true
          else rsyncDefaultConfig.useChecksum;
    };
    sourceConfig =
      filterAttrs (name: _: elem name (attrNames rsyncDefaultConfig)) source;
    sourcePath =
      if isStorePath source.path
        then quote (toString source.path)
        else quote source.path;
  in
    rsync' target config sourcePath;

  # Delivers the flake itself, as its input named null.
  pop.flake = target: source: pop.flake-input target (source // { name = null; });

  pop.flake-input = target: source: let
    nix' = "${nix}/bin/nix --extra-experimental-features ${quote "nix-command flakes"}";
    inputPath = if source.name == null then [] else splitString "/" source.name;
    fetchOnTarget = source.fetchOnTarget or false;
    # Tells whether a flake reference names a scheme that doesn't refer to the
    # deploying machine, so the target can fetch the flake on its own.
    # Indirect references get resolved on the deploying machine.
    isRemoteRef = ref: let
      scheme = builtins.match "([a-z0-9+]+):.*" ref;
    in
      scheme != null &&
      !elem (head scheme) [
        "file" "flake" "git+file" "hg+file" "path" "tarball+file"
      ];
    # Caches per-flake information, so it's obtained only once, even if
    # several sources use the same flake.
    cached = kind: command: /* sh */ ''
      cache=$TMPDIR/flake-${kind}.$(
        printf %s ${quote source.flake} |
        ${coreutils}/bin/sha256sum |
        ${coreutils}/bin/cut -c-32
      ).json
      if ! test -e "$cache"; then
        {
          ${command}
        } > "$cache"
      fi
    '';
    noInput = /* sh */ ''
      >&2 printf 'error: flake %s has no input %s\n' \
          ${quote source.flake} ${quote (toString source.name)}
      exit 1
    '';
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
    # Shell function printing the store path $1, followed by the inputs its
    # flake in the subdirectory $2 pins in its own lock file, using the nix
    # command nix.  Without a lock file, locking would change the flake, so
    # there are no such inputs.
    closure = nix: /* sh */ ''
      closure() {
        printf '%s\n' "$1"
        closure_dir=$1''${2:+/$2}
        if test -e "$closure_dir"/flake.nix && test -e "$closure_dir"/flake.lock; then
          ARCHIVE=$(
            ${nix} flake archive --json --no-update-lock-file \
                "path:$1''${2:+?dir=$2}"
          ) \
          ${nix} eval --impure --raw --expr '
            let
              # Inputs given by relative paths are part of their parent.
              paths = node: builtins.concatMap
                (input:
                  (if input ? path then [ input.path ] else []) ++ paths input)
                (builtins.attrValues (node.inputs or {}));
            in
              builtins.concatStringsSep "\n"
                (paths (builtins.fromJSON (builtins.getEnv "ARCHIVE")))
          '
          echo
        fi
      }
    '';
    sentinel = "${dirOf target.path}/.populate";
    # Directory of garbage collector roots for the input's own inputs.
    inputsRoots = "${sentinel}/flake-inputs/${baseNameOf target.path}";
    # Directory receiving the flake itself if the target can't fetch it.
    uploads = "${sentinel}/flake-uploads";
    upload = "${uploads}/${baseNameOf target.path}";
    removeUpload = /* sh */ ''
      if test -e ${quote upload}; then
        chmod -R u+w ${quote upload}
        rm -fR ${quote upload}
      fi
      # Sources get populated one after another, so no other source uses the
      # directory meanwhile.
      if test -d ${quote uploads} && test -z "$(ls -A ${quote uploads})"; then
        rmdir ${quote uploads}
      fi
    '';
    # Reads the subdirectory containing the flake or input, which may be
    # empty, followed by store paths from stdin.  Links the first store path,
    # or the subdirectory therein, at the target path, and registers it and
    # the remaining ones as garbage collector roots.  Roots get added before
    # obsolete ones get removed, so the inputs stay rooted.
    link = /* sh */ ''
      set -efu
      read -r dir
      read -r path
      # nix-store --add-root only replaces links into the store.
      if test -L ${quote target.path}; then
        case $(readlink ${quote target.path}) in
          /nix/store/*) ;;
          *) rm ${quote target.path} ;;
        esac
      elif test -e ${quote target.path}; then
        rm -fR ${quote target.path}
      fi
      nix-store --realise "$path" --add-root ${quote target.path} --indirect >/dev/null
      # The garbage collector follows the link into the store path.
      if test -n "$dir"; then
        ln -fns "$path/$dir" ${quote target.path}
      fi

      ${sentinelDirectory sentinel}
      mkdir -p ${quote inputsRoots}
      roots=
      while read -r path; do
        if test -z "$path"; then
          continue
        fi
        root=$(basename "$path")
        if test "$(readlink ${quote inputsRoots}/"$root")" != "$path"; then
          nix-store --realise "$path" \
              --add-root ${quote inputsRoots}/"$root" --indirect \
            >/dev/null
        fi
        roots="$roots $root"
      done
      ls -A ${quote inputsRoots} | while read -r root; do
        case " $roots " in
          *" $root "*) ;;
          *) rm ${quote inputsRoots}/"$root" ;;
        esac
      done
      # An input without own inputs leaves the directory empty.
      if test -z "$roots"; then
        rmdir ${quote inputsRoots}
      fi
    '';
    # Reads the selection, as selected produces it, and the store path of the
    # flake itself from stdin, fetches what's selected, unless it's the flake
    # itself, which gets added from the upload directory unless the store has
    # it already, then fetches the inputs its own lock file pins, and links
    # the results.
    fetchAndLink = /* sh */ ''
      set -efu
      ${requireFlakes "fetching flake inputs on the target"}
      read -r selected
      read -r self
      if test -n "$self" && ! nix-store --check-validity "$self" 2>/dev/null; then
        name=$(basename "$self" | cut -c34-)
        mv ${quote upload}/tree ${quote upload}/"$name"
        added=$(nix-store --add-fixed --recursive sha256 ${quote upload}/"$name")
        ${removeUpload}
        if test "$added" != "$self"; then
          >&2 printf 'error: flake %s arrived as %s instead of %s\n' \
              ${quote source.flake} "$added" "$self"
          exit 1
        fi
      fi
      # The store path and the subdirectory, on separate lines.  Inputs
      # referring to local paths can only be fetched if the target has them
      # as well.
      fetched=$(
        FLAKE=${quote source.flake} SELECTED=$selected SELF=$self \
        nix eval --impure --raw --expr '
          let
            selected = builtins.fromJSON (builtins.getEnv "SELECTED");
            path =
              if selected.self then builtins.getEnv "SELF"
              else (builtins.fetchTree selected.locked).outPath;
            dir = path + (if selected.subdir == "" then "" else "/" + selected.subdir);
            lock =
              if builtins.pathExists (dir + "/flake.lock")
                then builtins.fromJSON (builtins.readFile (dir + "/flake.lock"))
                else { nodes = {}; };
            localPath = locked:
              if (locked.type or null) == "path" then locked.path
              else let
                match = builtins.match "file:(//)?(.*)" (locked.url or "");
              in
                if match == null then null else builtins.elemAt match 1;
            missing = builtins.filter
              (key: let
                p = localPath (lock.nodes.''${key}.locked or {});
              in
                p != null && builtins.substring 0 1 p == "/" && !builtins.pathExists p)
              (builtins.attrNames lock.nodes);
            key = builtins.head missing;
          in
            if missing != [] then
              throw "flake ''${builtins.getEnv "FLAKE"}: input ''${key} refers to ''${localPath lock.nodes.''${key}.locked}, which does not exist on the target"
            else
              path + "\n" + selected.subdir
        '
      )
      path=$(printf '%s\n' "$fetched" | sed -n 1p)
      subdir=$(printf '%s\n' "$fetched" | sed -n 2p)
      ${closure "nix"}
      { printf '%s\n' "$subdir"; closure "$path" "$subdir"; } | {
        ${link}
      }
    '';
    # Fetches the flake and its inputs, and links the results.
    archiveAndLink = /* sh */ ''
      set -efu
      ${requireFlakes "fetching flakes on the target"}
      metadata=$(nix flake metadata --json --no-update-lock-file ${quote source.flake})
      archive=$(nix flake archive --json --no-update-lock-file ${quote source.flake})
      lines=$(
        METADATA=$metadata ARCHIVE=$archive \
        nix eval --impure --raw --expr '
          let
            # Inputs given by relative paths are part of their parent.
            paths = node:
              (if node ? path then [ node.path ] else []) ++
              builtins.concatMap paths (builtins.attrValues (node.inputs or {}));
            metadata = builtins.fromJSON (builtins.getEnv "METADATA");
            archive = builtins.fromJSON (builtins.getEnv "ARCHIVE");
            # The subdirectory, as attribute dir or as query parameter dir
            # of the URL, depending on the version of Nix.
            subdir = ref:
              ref.dir or (let
                match = builtins.match ".*[?&]dir=([^&]*).*" (ref.url or "");
              in
                if match == null then "" else builtins.head match);
            subdirs = builtins.filter (dir: dir != "")
              (map subdir [ (metadata.locked or {}) (metadata.original or {}) ]);
          in
            builtins.concatStringsSep "\n"
              ([ (if subdirs == [] then "" else builtins.head subdirs) ] ++
               paths archive)
        '
      )
      printf '%s\n' "$lines" | {
        ${link}
      }
    '';
  in
    if !fetchOnTarget && !isLocalTarget target && target.sudo then
      throw "krops: source ${target.path}: copying flakes to targets with sudo is not supported"
    else if fetchOnTarget && source.name == null && isRemoteRef source.flake then
      runShell target archiveAndLink
    else /* sh */ ''
      set -efu

      ${cached "metadata" /* sh */ ''
        ${nix'} flake metadata --json --no-update-lock-file ${quote source.flake}
      ''}

      if ! selected=$(
        ${jq}/bin/jq -ce --argjson input ${quote (toJSON inputPath)} ${quote selected} \
          "$cache" 2>/dev/null
      ); then
        ${noInput}
      fi

      self=
      if printf '%s\n' "$selected" | ${jq}/bin/jq -e .self >/dev/null; then
        ${if fetchOnTarget then /* sh */ ''
          # The flake itself has no lock entry, so the target fetches it by
          # its locked reference, if it can, or else receives it.
          if ${jq}/bin/jq -e ${quote selfIsRemote} "$cache" >/dev/null; then
            selected=$(
              ${jq}/bin/jq -c --argjson selected "$selected" ${quote selfLocked} \
                "$cache"
            )
          else
            self=$(${jq}/bin/jq -r .path "$cache")
            ${optionalString (!isLocalTarget target) /* sh */ ''
              if ! printf '%s\n' "$self" | {
                ${runShell target /* sh */ ''
                  read -r self
                  nix-store --check-validity "$self" 2>/dev/null
                ''}
              }; then
                ${runShell target /* sh */ ''
                  set -efu
                  ${sentinelDirectory sentinel}
                  ${removeUpload}
                  mkdir -p ${quote upload}
                ''}
                # Without applying .rsync-filter files, which would change the flake.
                ${rsync' (target // { path = "${upload}/tree"; })
                         (rsyncDefaultConfig // { filterFiles = false; })
                         /* sh */ ''"$self"''}
              fi
            ''}
          fi
        '' else /* sh */ ''
          self=$(${jq}/bin/jq -r .path "$cache")
        ''}
      fi

      ${if fetchOnTarget then /* sh */ ''
        printf '%s\n%s\n' "$selected" "$self" | {
          ${runShell target fetchAndLink}
        }
      '' else /* sh */ ''
        path=$self
        if test -z "$path"; then
          path=$(
            SELECTED=$selected ${nix'} eval --impure --raw --expr '
              (builtins.fetchTree
                (builtins.fromJSON (builtins.getEnv "SELECTED")).locked).outPath
            '
          )
        fi
        subdir=$(printf '%s\n' "$selected" | ${jq}/bin/jq -r .subdir)
        ${closure nix'}
        paths=$(closure "$path" "$subdir")

        ${optionalString (!isLocalTarget target) /* sh */ ''
          mkdir -p "$PWD"/bin
          ln -fns ${sshNix' target} "$PWD"/bin/ssh
          PATH=$PWD/bin:$PATH \
          ${nix'} copy --to ${quote "ssh://${target.host}"} $paths >&2
        ''}

        printf '%s\n%s\n' "$subdir" "$paths" | {
          ${runShell target link}
        }
      ''}
    '';

  pop.git = target: source: runShell target /* sh */ ''
    set -efu
    # Remove target path if it doesn't look like a git worktree.
    # This can happen e.g. when it had a different type earlier.
    if ! test -e ${quote target.path}/.git; then
      rm -fR ${quote target.path}
    fi
    if ! test -e ${quote target.path}; then
      ${if source.shallow then /* sh */ ''
        git init ${quote target.path}
      '' else /* sh */ ''
        git clone --recurse-submodules ${quote source.url} ${quote target.path}
      ''}
    fi
    cd ${quote target.path}
    if ! url=$(git config remote.origin.url); then
      git remote add origin ${quote source.url}
    elif test "$url" != ${quote source.url}; then
      git remote set-url origin ${quote source.url}
    fi

    # TODO resolve git_ref to commit hash
    hash=${quote source.ref}

    if ! test "$(git log --format=%H -1)" = "$hash"; then
      ${if source.fetchAlways then /* sh */ ''
        ${if source.shallow then /* sh */ ''
          git fetch --depth=1 origin "$hash"
        '' else /* sh */ ''
          git fetch origin
        ''}
      '' else /* sh */ ''
        if ! git log -1 "$hash" >/dev/null 2>&1; then
          ${if source.shallow then /* sh */ ''
            git fetch --depth=1 origin "$hash"
          '' else /* sh */ ''
            git fetch origin
          ''}
        fi
      ''}
      git reset --hard "$hash" >&2
      git submodule update --init --recursive
    fi

    git clean -dfx \
        ${concatMapStringsSep " "
          (pattern: /* sh */ "-e ${quote pattern}")
          source.clean.exclude }
  '';

  pop.pass = target: source: let
    passPrefix = "${source.dir}/${source.name}";
  in /* sh */ ''
    set -efu

    umask 0077
    chmod 0700 "$PWD"

    if test -e ${quote source.dir}/.git; then
      local_pass_info=${quote source.name}\ $(
        ${git}/bin/git -C ${quote source.dir} log -1 --format=%H ${quote source.name}
        # we append a hash for every symlink, otherwise we would miss updates on
        # files where the symlink points to
        ${findutils}/bin/find ${quote source.dir}/${quote source.name} -type l \
            -exec ${coreutils}/bin/realpath {} + |
          ${coreutils}/bin/sort |
          ${findutils}/bin/xargs -r -n 1 ${git}/bin/git -C ${quote source.dir} log -1 --format=%H
      )
      remote_pass_info=$(${runShell target /* sh */ ''
        cat ${quote target.path}/.pass_info || :
      ''})

      if test "$local_pass_info" = "$remote_pass_info"; then
        exit 0
      fi
    fi

    ${findutils}/bin/find ${quote passPrefix} -type f -follow ! -name .gpg-id |
    while read -r gpg_path; do

      rel_name=''${gpg_path#${quote passPrefix}}
      rel_name=''${rel_name%.gpg}

      pass_date=$(
        if test -e ${quote source.dir}/.git; then
          ${git}/bin/git -C ${quote source.dir} log -1 --format=%aI "$gpg_path"
        fi
      )
      pass_name=${quote source.name}/$rel_name
      pass_out=$PWD/$rel_name

      ${coreutils}/bin/mkdir -p "$(${coreutils}/bin/dirname "$pass_out")"
      PASSWORD_STORE_DIR=${quote source.dir} ${pass}/bin/pass show "$pass_name" > "$pass_out"
      if [ -n "$pass_date" ]; then
        ${coreutils}/bin/touch -d "$pass_date" "$pass_out"
      fi
    done

    if test -n "''${local_pass_info-}"; then
      echo "$local_pass_info" > "$PWD"/.pass_info
    fi

    ${rsync' target rsyncDefaultConfig /* sh */ "$PWD"}
  '';

  pop.passage = target: source: /* sh */ ''
    set -efu

    export PASSAGE_AGE=${quote source.age}
    export PASSAGE_DIR=${quote source.dir}
    export PASSAGE_IDENTITIES_FILE=${quote source.identities_file}

    umask 0077
    chmod 0700 "$PWD"

    ${findutils}/bin/find "$PASSAGE_DIR" -type f -name \*.age -follow |
    while read -r age_path; do

      pass_name=''${age_path#$PASSAGE_DIR/}
      pass_name=''${pass_name%.age}

      pass_out=$PWD/$pass_name

      ${coreutils}/bin/mkdir -p "$(${coreutils}/bin/dirname "$pass_out")"
      if ! ${passage}/bin/passage show "$pass_name" > "$pass_out" 2>&1; then
        echo ++ secrets ${quote (head (match "([^.]+).*" target.host))} show "$pass_name" >&2
        ${jq}/bin/jq -Rr 'select(test("^[^[]"))' "$pass_out" >&2
        exit 1
      fi

      ${coreutils}/bin/touch -r "$age_path" "$pass_out"
    done

    ${rsync' target rsyncDefaultConfig /* sh */ "$PWD"}
  '';

  pop.pipe = target: source: /* sh */ ''
    out=$PWD/out

    ${quote source.command} > "$out"
    ${coreutils}/bin/touch -t 300001010000 "$out"

    ${rsync' target rsyncDefaultConfig /* sh */ "$out"}
  '';

  # TODO rm -fR instead of ln -f?
  pop.symlink = target: source: runShell target /* sh */ ''
    ln -fnsT ${quote source.target} ${quote target.path}
  '';

  populate = target: name: source: let
    source' = source.${source.type};
    target' = target // { path = "${target.path}/${name}"; };
  in writers.writeDash "populate.${target'.host}.${name}" ''
    set -efu
    PWD=$TMPDIR/workdirs/${quote name}
    mkdir -p "$PWD"
    cd "$PWD"
    ${pop.${source.type} target' source'}
  '';

  rsync' = target: config: sourcePath: /* sh */ ''
    # rsync writes through a symlink at the target path, e.g. one a symlink or
    # flake source left there, into what it points to.
    ${runShell target /* sh */ ''
      if test -L ${quote target.path}; then
        rm ${quote target.path}
      fi
    ''}
    source_path=${sourcePath}
    if test -d "$source_path"; then
      source_path=$source_path/
    fi
    ${rsync}/bin/rsync \
        ${optionalString config.useChecksum /* sh */ "--checksum"} \
        ${optionalString target.sudo /* sh */ "--rsync-path=\"sudo rsync\""} \
        ${concatMapStringsSep " "
          (pattern: /* sh */ "--exclude ${quote pattern}")
          config.exclude} \
        ${concatMapStringsSep " "
          (filter: /* sh */ "--${filter.type} ${quote filter.pattern}")
          config.filters} \
        -e ${quote (ssh' target)} \
        --info=backup,del,copy,misc,mount,name,nonreg,remove,skip,symsafe \
        ${optionalString (config.filterFiles or true) "-F"} \
        -rlptD \
        ${optionalString config.deleteExcluded /* sh */ "--delete-excluded"} \
        "$source_path" \
        ${quote (
          optionalString (!isLocalTarget target) (
            (optionalString (target.user != "") "${target.user}@") +
            "${target.host}:"
          ) +
          target.path
        )} \
      >&2
  '';

  rsyncDefaultConfig = {
    useChecksum = false;
    exclude = [];
    filters = [];
    deleteExcluded = true;
  };

  runShell = target: command:
    if isLocalTarget target
      then command
      else
        if target.sudo then /* sh */ ''
          ${ssh' target} ${quote target.host} ${quote "sudo bash -c ${quote command}"}
        '' else ''
          ${ssh' target} ${quote target.host} ${quote command}
        '';

  # ssh for Nix's ssh:// store.  Without the control socket, because Nix waits
  # for its LocalCommand, which may not run over a multiplexed connection.
  sshNix' = target: writers.writeDash "ssh-nix-wrapper" ''
    exec ${openssh}/bin/ssh \
        ${concatMapStringsSep " " quote (mkUserPortSSHOpts target)} \
        ${concatMapStringsSep " " quote target.extraOptions} \
        "$@"
  '';

  ssh' = target: writers.writeDash "ssh-wrapper" ''
    exec ${openssh}/bin/ssh \
        ${concatMapStringsSep " " quote (mkUserPortSSHOpts target)} \
        -o ControlMaster=auto \
        -o ControlPath="$TMPDIR"/ssh-%r@%h:%p.sock \
        -o ControlPersist=1h \
        -T \
        ${concatMapStringsSep " " quote target.extraOptions} \
        "$@"
  '';

in

{ backup ? false, force ? false, prune ? false, source, target }:
writers.writeDash "populate.${target.host}" ''
  set -efu

  # Change to a private temporary directory to prevent collisions.
  TMPDIR=$(${coreutils}/bin/mktemp -dt populate.XXXXXXXX)
  readonly TMPDIR # Ensure the trap will delete the correct thing.
  export TMPDIR # Share it with the jobs and the ssh wrapper.
  trap 'rm -R "$TMPDIR"' EXIT

  ${check { inherit force target; }}
  set -x
  ${optionalString backup (do-backup { inherit target; })}
  ${concatStringsSep "\n" (mapAttrsToList (populate target) source)}
  ${flakes target source}
  ${optionalString prune (prune' target source)}

  # Stop the ssh master, if any source started one.
  if ${ssh' target} -q -O check ${quote target.host} 2>/dev/null; then
    ${ssh' target} -q -O stop ${quote target.host}
  fi
''
