with import ../../lib;
with shell;

{ coreutils, dash, findutils, git, jq, nix, openssh, pass, passage, rsync, writers }:

let
  # Populate replaces and removes what's at the target paths of sources, so
  # it refuses names that lead out of the target directory, to the directory
  # itself, or to its own state.  The remaining names are portable file
  # names, which mean themselves to shells, find, and in URLs, and which the
  # names of the scripts populating the sources may contain.
  checkSourceName = name:
    if elem name [ "." ".." ".populate" ] ||
        builtins.match "[0-9A-Za-z._][0-9A-Za-z._-]*" name == null then
      throw "krops: source name ${toJSON name} can't be used: it must consist of letters, digits, and the characters ._-, not start with -, and be neither ., .., nor .populate"
    else
      true;

  # Populate removes what it finds in the target directory, so it refuses
  # paths that aren't absolute, that are the root directory, or that the
  # target would resolve to another directory than the one they name.
  checkTargetPath = path: let
    components = filter (x: x != "" && x != ".") (splitString "/" path);
  in
    if !isString path || substring 0 1 path != "/" then
      throw "krops: target path ${toJSON path} can't be used: it must be absolute"
    else if components == [] then
      throw "krops: target path ${toJSON path} can't be used: it must not be the root directory"
    else if elem ".." components ||
        builtins.match "[^[:cntrl:]]+" path == null then
      throw "krops: target path ${toJSON path} can't be used: it must not contain .. or control characters"
    else
      true;

  # The directories below the sentinel, once that is a directory, which
  # have a directory for each source that needs one.  Besides, there is
  # backup, which holds copies of the sources.
  stateKinds = [ "derived" "flake-inputs" "flake-uploads" "flakes" "patches" ];

  # Shell code that prepares keeping state below the sentinel for the sources
  # named names.  The sentinel only needs to exist, so it may be a file,
  # which becomes a directory.  Populate changes and removes what's in its
  # state directories, and a symlink in place of one would make it do that to
  # whatever the link points to, so it refuses to use those.
  useState = sentinel: names: /* sh */ ''
    refuse_link() {
      if test -L "$1"; then
        >&2 printf 'error: %s is a symlink, but populate needs a directory of its own there\n' "$1"
        exit 1
      fi
    }
    refuse_link ${quote sentinel}
    refuse_link ${quote sentinel}/backup
    for state_kind in ${toString stateKinds}; do
      refuse_link ${quote sentinel}/"$state_kind"
      for state_name in ${concatMapStringsSep " " quote names}; do
        refuse_link ${quote sentinel}/"$state_kind"/"$state_name"
      done
    done
    if test -f ${quote sentinel}; then
      rm ${quote sentinel}
      mkdir ${quote sentinel}
    fi
  '';

  # Shell code that removes what's at path, a shell word, with everything
  # below it, also what isn't writable.  A symlink gets removed itself,
  # instead of followed.  Only directories get made writable, which is what
  # removing what's in them needs: a file may be a hard link to one
  # elsewhere, which shares its mode.
  removeTree = path: /* sh */ ''
    if test -L ${path}; then
      rm ${path}
    elif test -e ${path}; then
      find ${path} -type d -exec chmod u+w {} +
      rm -fR ${path}
    fi
  '';

  # The path on the target, as populate names it in what it prints:
  # prefixed by the host if the target isn't local, and by the user as well
  # if that isn't root.
  targetName = target: path:
    optionalString (!isLocalTarget target) (
      optionalString
        (!elem target.user [ null "" "root" ])
        "${target.user}@" +
      "${target.host}:"
    ) +
    path;

  # Shell code that removes the entries of the directory dir, a shell word,
  # that aren't named names.  find, unlike a loop reading names, copes with
  # every name, e.g. ones that end in blanks or contain newlines.  Entries of
  # populate's own state get removed like removeTree does.  Entries of the
  # target directory get removed without making anything writable first; for
  # those, log is a shell word for the directory's name in the line that
  # gets printed for each entry.
  removeOthers = { dir, names, log ? null }: /* sh */ ''
    find ${dir} -mindepth 1 -maxdepth 1 \
        ${concatMapStringsSep " " (name: "! -name ${quote name}") names} \
        -exec sh -c ${quote /* sh */ ''
          ${optionalString (log != null) /* sh */ ''
            log=$1
            shift
          ''}
          for path; do
            ${optionalString (log != null) /* sh */ ''
              >&2 printf "pruning '%s/%s'...\n" "$log" "''${path##*/}"
            ''}
            ${if log != null then /* sh */ ''
              rm -fR "$path"
            '' else /* sh */ ''
              if test -L "$path"; then
                rm "$path"
              else
                # Escaped, or the outer find takes the braces for its own.
                find "$path" -type d -exec chmod u+w {\} +
                rm -fR "$path"
              fi
            ''}
          done
        ''} sh ${optionalString (log != null) log} {} +
  '';

  # Shell code that removes a symlink at path, saying so, because the link
  # may be there on purpose, but populate never follows it: what a source
  # delivers would change or remove what the link points to.
  removeLink = path: /* sh */ ''
    if test -L ${quote path}; then
      >&2 printf 'replacing symlink %s, which points to %s\n' \
          ${quote path} "$(readlink ${quote path})"
      rm ${quote path}
    fi
  '';

  # Shell code that removes a symlink at path like removeLink does, unless
  # it points into the store, like the links populate puts there itself.
  removeForeignLink = path: /* sh */ ''
    if test -L ${quote path}; then
      # Resolved, so a link like /nix/store/../.. doesn't count.
      case $(readlink -f ${quote path}) in
        /nix/store/*) ;;
        *)
          ${removeLink path}
          ;;
      esac
    fi
  '';

  # Shell code that makes room at path for a link into the store, which Nix
  # only puts in place of another link into the store.
  makeRoomForLink = path: /* sh */ ''
    ${removeForeignLink path}
    if ! test -L ${quote path} && test -e ${quote path}; then
      rm -fR ${quote path}
    fi
  '';

  # Shell code printing why populate can't use the .git directory of the
  # Git work tree at path, or nothing.  A .git directory that git clone and
  # populate made has no symlinks, no commondir file, which names another
  # repository, no linked work trees, and only the configuration they write:
  # the repository's format, the remote, branches, and submodules, whose
  # repositories have their work tree in the work tree.
  gitProblems = path: let
    gitDir = "${path}/.git";
    # Keys of the configuration git clone writes, as patterns of case.
    keys = [
      "core.repositoryformatversion" "core.filemode" "core.bare"
      "core.logallrefupdates" "core.symlinks" "core.ignorecase"
      "core.precomposeunicode"
      "extensions.objectformat" "extensions.refstorage"
      "remote.origin.url" "remote.origin.fetch"
      "branch.*.remote" "branch.*.merge"
      "submodule.active" "submodule.*.url" "submodule.*.active"
    ];
  in /* sh */ ''(
    links=$(find ${quote gitDir} -type l | head -n 3 | paste -s -d ' ' -)
    if test -n "$links"; then
      printf '%s contains symlinks: %s' ${quote gitDir} "$links"
      exit
    fi
    common=$(find ${quote gitDir} -name commondir | head -n 1)
    if test -n "$common"; then
      printf '%s names another repository' "$common"
      exit
    fi
    if test -e ${quote gitDir}/worktrees; then
      printf '%s has linked work trees' ${quote gitDir}
      exit
    fi
    find ${quote gitDir} -name config -type f | while IFS= read -r config; do
      command git config --file "$config" --list --name-only |
      while IFS= read -r key; do
        case $key in
          ${concatStringsSep "|" keys}) ;;
          core.worktree)
            # Submodules' repositories have their work tree in the work tree.
            worktree=$(command git config --file "$config" core.worktree)
            dir=$(dirname "$config")
            case $dir/$worktree in
              ${quote gitDir}/modules/*)
                resolved=$(cd "$dir" && cd "$worktree" 2>/dev/null && pwd -P) || :
                case $resolved in
                  "$(cd ${quote path} && pwd -P)"/*) continue ;;
                esac
                ;;
            esac
            printf '%s sets core.worktree to %s' "$config" "$worktree"
            exit 1
            ;;
          *)
            printf '%s sets %s, which neither git clone nor populate does' "$config" "$key"
            exit 1
            ;;
        esac
      done || exit 1
    done || :
  )'';

  check = { force, target }: let
    sentinelFile = "${target.path}/.populate";
  in runShell target /* sh */ ''
    # Before anything touches it, which would touch what it points to.
    if test -L ${quote sentinelFile}; then
      >&2 printf 'error: sentinel file is a symlink: %s\n' \
          ${quote (targetName target sentinelFile)}
      exit 1
    fi
    ${optionalString force /* sh */ ''
      mkdir -vp ${quote (dirOf sentinelFile)} >&2
      if ! test -e ${quote sentinelFile}; then
        touch ${quote sentinelFile}
      fi
    ''}
    if ! test -e ${quote sentinelFile}; then
      >&2 printf 'error: missing sentinel file: %s\n' \
          ${quote (targetName target sentinelFile)}
      exit 1
    fi
  '';

  do-backup = { target }: let
    sentinelFile = "${target.path}/.populate";
  in
    runShell target /* sh */ ''
      ${useState sentinelFile []}
      if ! test -d ${quote sentinelFile}; then
        >&2 printf 'error: sentinel file is not a directory: %s\n' \
            ${quote (targetName target sentinelFile)}
        exit 1
      fi
      rsync >&2 \
          -aAXF \
          --delete \
          --exclude /.populate \
          --link-dest=${quote target.path} \
          ${quote target.path}/ \
          ${quote target.path}/.populate/backup/
    '';

  # Draws inputs of flakes in sources from other sources, and derives what the
  # target paths of flake and flake-input sources that get patched, get their
  # lock files rewritten, or are materialized get.  Sources get processed in
  # the order they draw inputs from each other.
  #
  # Inputs get drawn by rewriting the lock file of the flake in the source
  # with nix flake lock --override-input: in place for file and git sources,
  # and in a copy for flake and flake-input sources.  Sources with rewriteLock
  # set to false, and symlink sources, get a generated flake in
  # .populate/flakes/<name> instead, which re-exports the outputs of the flake
  # in the source, with those inputs drawn from the other sources.  Lock files
  # get rewritten or generated on every run, so they match the sources.
  flakes = target: sources: let
    inherit (import ./flake-jq.nix) lockHasInput;
    sentinel = "${target.path}/.populate";
    flakesDir = "${sentinel}/flakes";
    derivedDir = "${sentinel}/derived";
    patchesDir = "${sentinel}/patches";
    drawing = filterAttrs (_: source: flakeFollows source != []) sources;
    generated = filterAttrs (_: hasGeneratedFlake) sources;
    derived = filterAttrs (_: derivesFlake) sources;
    patched = filterAttrs
      (_: source: source.${source.type}.patches or [] != [])
      sources;
    names = attrNames (drawing // derived);
    # Source names become input names in generated flakes, where Nix accepts
    # fewer names than populate.  Others get replaced by one derived from
    # them.
    inputName = name:
      if builtins.match "[a-zA-Z][a-zA-Z0-9_-]*" name != null && name != "self"
        then name
        else "source-${substring 0 16 (builtins.hashString "sha256" name)}";
    drawnFrom = name: map (x: x.source) (flakeFollows sources.${name});
    sorted = toposort (a: b: elem a (drawnFrom b)) names;
    # Shell word for the URL of the flake that inputs drawn from a source use:
    # its generated flake, if it has one, so overrides don't need to be
    # repeated, or else the flake in the source.
    # Nix refuses path: URLs with symlinks on the way, which the target
    # directory may be, so paths get resolved.
    url = name:
      if generated ? ${name}
        then ''"path:$(url_path "$(readlink -f ${quote "${flakesDir}/${name}"})")"''
        else ''"$(flake_url ${quote name})"'';
    check = name: source:
      if source == name then
        throw "krops: source ${name} draws inputs from itself"
      else if !(sources ? ${source}) then
        throw "krops: source ${name} draws inputs from missing source ${source}"
      else
        source;
    # Where the input at path, a list of input names, of the flake in the
    # source named name is in the flake that the source's inputs get drawn
    # into: the flake itself, or its generated flake.  On the way, inputs
    # that get drawn from sources are the flakes of those sources, where
    # drawing went on, so the path continues there.  A generated flake has
    # its source and the sources that one draws from as inputs, and nothing
    # else, so the path names them there.
    drawnPath = name: path: let
      follows = flakeFollows sources.${name};
      parents = filter
        (prefix: any (x: x.path == prefix) follows)
        (map (n: take n path) (range 1 (length path - 1)));
      parent = last parents;
      from = (findFirst (x: x.path == parent) null follows).source;
      rest = drawnPath from (drop (length parent) path);
    in
      if generated ? ${name} then
        if parents == [] then [ (inputName name) ] ++ path
        else [ (inputName from) ] ++ rest
      else
        if parents == [] then path
        else parent ++ rest;
    # The inputs that drawing the input at path of the flake in the source
    # named name needs to exist, as { name, path } of the source whose flake
    # has the input at path.  Like drawnPath, the part below an input drawn
    # from a source is the flake of that source's.
    inputChecks = name: path: let
      follows = flakeFollows sources.${name};
      parents = filter
        (prefix: any (x: x.path == prefix) follows)
        (map (n: take n path) (range 1 (length path - 1)));
      parent = last parents;
      from = (findFirst (x: x.path == parent) null follows).source;
    in
      if parents == [] then [ { inherit name path; } ]
      else [ { inherit name; path = parent; } ]
        ++ inputChecks from (drop (length parent) path);
    # Sets the positional parameters to nix flake lock's arguments for
    # drawing the inputs of the flake in source name from other sources.
    overrideArgs = name: /* sh */ ''
      set --
      ${concatMapStrings (x: /* sh */ ''
        set -- "$@" --override-input ${quote (concatStringsSep "/" (drawnPath name x.path))} ${url (check name x.source)}
      '') (flakeFollows sources.${name})}
    '';
    # Rewrites the lock file of the flake in a file or git source in place.
    rewrite = name: /* sh */ ''
      (
        ${overrideArgs name}
        own_lock "$(readlink -f ${quote "${target.path}/${name}"})"
        nix flake lock "$@" "$(flake_url ${quote name})" >&2
      )
    '';
    # Derives what the target path of a flake or flake-input source gets from
    # what got delivered to .populate/derived/<name>/original: a copy, which
    # gets patched and gets its lock file rewritten.  Unless materialized,
    # the copy gets added to the store, and the target path becomes a link to
    # it.  Copies get made again only if what they derive from changes:
    # materialized ones if the delivered store path, the patches, or what
    # inputs get drawn from which sources changes, and others also if the
    # sources they draw inputs from change.
    derive = name: let
      source = sources.${name};
      source' = source.${source.type};
      rewriteLock = source'.rewriteLock && drawing ? ${name};
      targetPath = "${target.path}/${name}";
      dir = "${derivedDir}/${name}";
      spec = toJSON {
        inherit (source') materialize;
        inherit rewriteLock;
        follows = flakeFollows source;
      };
      # Globbing is off, so patches get listed with ls, in order.
      applyPatches = optionalString (source'.patches != []) /* sh */ ''
        ls ${quote "${patchesDir}/${name}"} | while read -r patch; do
          if ! patch -p1 -s --batch --no-backup-if-mismatch \
              -i ${quote "${patchesDir}/${name}"}/"$patch" >&2; then
            >&2 printf 'error: patch %s does not apply to source %s\n' \
                "$(printf %s "$patch" | cut -c6-)" ${quote name}
            exit 1
          fi
        done
      '';
      # Removes the work directory, which an interrupted run may have left
      # behind.
      removeWork = removeTree (quote "${dir}/work");
    in /* sh */ ''
      (
        # Writes the key $1 to a new file, which then replaces the key, so
        # nothing at its place gets written through, e.g. a symlink.
        write_key() {
          key_file=$(mktemp ${quote "${dir}/key"}.XXXXXX)
          printf '%s\n' "$1" > "$key_file"
          mv -f "$key_file" ${quote "${dir}/key"}
        }
        original=$(readlink -f ${quote "${dir}/original"})
        path=$(printf '%s\n' "$original" | cut -d/ -f1-4)
        subdir=''${original#"$path"}
        subdir=''${subdir#/}
        key=$(
          {
            printf '%s\n' "$original" ${quote spec}
            ${optionalString (source'.patches != []) /* sh */ ''
              ls ${quote "${patchesDir}/${name}"} | while read -r patch; do
                sha256sum ${quote "${patchesDir}/${name}"}/"$patch"
              done
            ''}
            ${optionalString (rewriteLock && !source'.materialize) /* sh */ ''
              ${overrideArgs name}
              printf '%s\n' "$@"
              # Sources outside the store can change without changing their
              # path.
              ${concatMapStrings (source: /* sh */ ''
                drawn=$(readlink -f ${quote (
                  if generated ? ${source}
                    then "${flakesDir}/${source}"
                    else "${target.path}/${source}"
                )})
                case $drawn in
                  /nix/store/*) ;;
                  *) nix-hash --type sha256 "$drawn" ;;
                esac
              '') (unique (drawnFrom name))}
            ''}
          } | sha256sum | cut -c-64
        )
        ${removeWork}
        ${if source'.materialize then /* sh */ ''
          if ! test -e ${quote "${dir}/key"} ||
              test "$(cat ${quote "${dir}/key"})" != "$key" ||
              test -L ${quote targetPath} ||
              ! test -d ${quote targetPath}; then
            cp -R "$original" ${quote "${dir}/work"}
            chmod -R u+w ${quote "${dir}/work"}
            (
              cd ${quote "${dir}/work"}
              ${applyPatches}
            )
            ${removeForeignLink targetPath}
            rm -fR ${quote targetPath}
            mv ${quote "${dir}/work"} ${quote targetPath}
            write_key "$key"
          fi
          ${optionalString rewriteLock /* sh */ ''
            ${overrideArgs name}
            own_lock ${quote targetPath}
            nix flake lock "$@" "$(flake_url ${quote name})" >&2
          ''}
        '' else /* sh */ ''
          if test -e ${quote "${dir}/key"} &&
              test "$(cat ${quote "${dir}/key"})" = "$key" &&
              result=$(readlink ${quote "${dir}/result"}) &&
              nix-store --check-validity "$result" 2>/dev/null; then
            :
          else
            # The copy keeps the name of the delivered store path.
            mkdir ${quote "${dir}/work"}
            work=$(readlink -f ${quote "${dir}/work"})/$(basename "$path" | cut -c34-)
            cp -R "$path" "$work"
            chmod -R u+w "$work"
            (
              cd "$work"/"$subdir"
              ${applyPatches}
            )
            ${optionalString rewriteLock /* sh */ ''
              ${overrideArgs name}
              # Not just the path, which Nix takes for the enclosing Git
              # work tree, if any.
              nix flake lock "$@" "path:$(url_path "$work")''${subdir:+?dir=$subdir}" >&2
            ''}
            result=$(nix-store --add-fixed --recursive sha256 "$work")
            ${removeWork}
            nix-store --realise "$result" \
                --add-root ${quote "${dir}/result"} --indirect >/dev/null
            write_key "$key"
          fi
          ${makeRoomForLink targetPath}
          # .populate/derived/<name>/result roots the store path.
          ln -fns "$result''${subdir:+/$subdir}" ${quote targetPath}
        ''}
      )
    '';
    # Generates the flake of a source in .populate/flakes/<name>.
    flake = name: let
      follows = flakeFollows generated.${name};
      drawn = unique (map (x: check name x.source) follows);
      # Nix ignores overrides below an input that follows another input, so
      # an input of an input drawn from a source gets overridden at that
      # source.
      override = x:
        "inputs." +
        concatMapStringsSep ".inputs." toJSON (drawnPath name x.path) +
        ".follows = ${toJSON (inputName x.source)};";
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
          printf '  inputs.%s.url = "%s";\n' ${quote (toJSON (inputName name))} "$url"
          ${concatImapStrings (i: source: /* sh */ ''
            printf '  inputs.%s.url = "%s";\n' ${quote (toJSON (inputName source))} "$url${toString i}"
            ${optionalString (!generated ? ${source}) /* sh */ ''
              if ! test -e "$(readlink -f ${quote "${target.path}/${source}"})"/flake.nix; then
                printf '  inputs.%s.flake = false;\n' ${quote (toJSON (inputName source))}
              fi
            ''}
          '') drawn}
          ${concatMapStrings (x: /* sh */ ''
            printf '  %s\n' ${quote (override x)}
          '') follows}
          printf '  outputs = inputs: inputs.%s;\n' ${quote (toJSON (inputName name))}
          echo '}'
        } > flake.nix
        # Not just ., which Nix takes for the enclosing Git work tree, if any.
        nix flake lock "path:$(url_path "$(pwd -P)")" >&2
      )
    '';
    process = name:
      optionalString (derived ? ${name}) (derive name) +
      (if generated ? ${name} then flake name
       else if drawing ? ${name} && !(derived ? ${name}) then rewrite name
       else "");
    # Removes the entries of the state directory dir that sources named
    # names don't need anymore, and the directory once it's empty.
    removeStale = dir: names: /* sh */ ''
      if test -d ${quote dir}; then
        ${removeOthers { dir = quote dir; inherit names; }}
        if test -z "$(ls -A ${quote dir})"; then
          rmdir ${quote dir}
        fi
      fi
    '';
  in
    if sorted ? cycle then
      throw "krops: sources draw inputs from each other: ${toString sorted.cycle}"
    else runShell target /* sh */ ''
      set -efu
      ${useState sentinel (attrNames sources)}
      ${optionalString (names != []) /* sh */ ''
        ${optionalString (drawing != {})
          (requireFlakes "drawing flake inputs from sources")}

        ${urlPath}

        # Nix rewrites lock files in place, which also changes what else is
        # a hard link to the lock file, e.g. in a backup, or what it is a
        # symlink to.  So the lock file of the flake in the directory $1
        # gets replaced by a copy first.
        # The copy goes to a new file, so nothing that's there already
        # gets written through.
        own_lock() {
          if test -e "$1"/flake.lock; then
            own_lock_copy=$(mktemp "$1"/.flake.lock.XXXXXX)
            cp -p "$1"/flake.lock "$own_lock_copy"
            mv -f "$own_lock_copy" "$1"/flake.lock
          fi
        }

        # Prints the flake URL of the source named $1.
        flake_url() {
          path=$(readlink -f ${quote target.path}/"$1")
          if ! test -d "$path"; then
            >&2 printf 'error: source %s is not a directory\n' "$1"
            exit 1
          fi
          if test -e "$path"/.git; then
            if test -e "$path"/.gitmodules; then
              printf 'git+file:%s?submodules=1' "$(url_path "$path")"
            else
              printf 'git+file:%s' "$(url_path "$path")"
            fi
          else
            printf 'path:%s' "$(url_path "$path")"
          fi
        }

        # Inputs can only be drawn into flakes, so check all sources before
        # changing anything.
        missing=
        ${concatMapStrings (name: /* sh */ ''
          if ! test -e ${quote (
            if derived ? ${name}
              then "${derivedDir}/${name}/original"
              else "${target.path}/${name}"
          )}/flake.nix; then
            missing="$missing "${quote name}
          fi
        '') (attrNames drawing)}
        if test -n "$missing"; then
          >&2 printf 'error: source %s draws flake inputs from other sources, but contains no flake.nix\n' $missing
          exit 1
        fi

        # Nix ignores inputs drawn that the flake doesn't have, with a
        # warning, so a misspelt input name would draw nothing.  Prints the
        # flake URL of the flake in the source named $1 as delivered.
        own_flake_url() {
          case " "${quote (toString (attrNames derived))}" " in
            *" $1 "*)
              printf 'path:%s' "$(url_path "$(readlink -f ${quote derivedDir}/"$1"/original)")"
              ;;
            *)
              flake_url "$1"
              ;;
          esac
        }
        # The lock files of the flakes in the sources, as Nix locks them now,
        # with an empty flake in place of each input drawn from a source,
        # which may not be reachable, as the one the flake's lock file pins.
        locks_dir=$(mktemp -d)
        echo '{ outputs = _: {}; }' > "$locks_dir"/flake.nix
        ${concatMapStrings (name: let
          follows = flakeFollows sources.${name};
        in /* sh */ ''
          set --
          ${concatMapStrings (x: /* sh */ ''
            set -- "$@" --override-input ${quote (concatStringsSep "/" x.path)} "path:$locks_dir"
          '') follows}
          if ! nix flake metadata --json --no-write-lock-file "$@" \
              "$(own_flake_url ${quote name})" > "$locks_dir"/${quote name}.json; then
            >&2 printf 'error: source %s draws inputs from other sources, but its flake can'"'"'t be locked\n' \
                ${quote name}
            exit 1
          fi
        '') (unique (concatMap (name: concatMap (x: map (c: c.name) (inputChecks name x.path)) (flakeFollows sources.${name})) (attrNames drawing)))}
        # Fails, naming the input, unless the flake in the source named $1
        # has an input at the path $2, a JSON list of input names.  $3 is
        # the source that the input $4 of the source $5 gets drawn from.
        require_input() {
          if ! test "$(
            METADATA=$(cat "$locks_dir/$1.json") INPUT=$2 nix eval --impure --raw --expr ${quote ''
              (${lockHasInput})
                (builtins.fromJSON (builtins.getEnv "METADATA")).locks
                (builtins.fromJSON (builtins.getEnv "INPUT"))
            ''}
          )" = 1; then
            if test "$1" = "$5"; then
              >&2 printf 'error: source %s draws input %s from source %s, but its flake has no input %s\n' \
                  "$5" "$4" "$3" "$4"
            else
              >&2 printf 'error: source %s draws input %s from source %s, but the flake of source %s has no input %s\n' \
                  "$5" "$4" "$3" "$1" "$(printf %s "$2" | tr -d '[]"' | tr , /)"
            fi
            exit 1
          fi
        }
        ${concatMapStrings (name: concatMapStrings (x: concatMapStrings (c: /* sh */ ''
          require_input ${quote c.name} ${quote (toJSON c.path)} \
              ${quote x.source} ${quote (concatStringsSep "/" x.path)} ${quote name}
        '') (inputChecks name x.path)) (flakeFollows sources.${name})) (attrNames drawing)}
        rm -R "$locks_dir"

        ${optionalString (generated != {}) /* sh */ ''
          mkdir -p ${quote flakesDir}
        ''}
        ${concatMapStrings process sorted.result}
      ''}
      # Remove roots of flake inputs of sources that are neither flake nor
      # flake-input sources anymore.
      ${concatMapStrings (name: /* sh */ ''
        rm -fR ${quote "${sentinel}/flake-inputs/${name}"}
      '') (attrNames (filterAttrs
        (_: source: !elem source.type [ "flake" "flake-input" ])
        sources))}
      if test -d ${quote "${sentinel}/flake-inputs"} &&
          test -z "$(ls -A ${quote "${sentinel}/flake-inputs"})"; then
        rmdir ${quote "${sentinel}/flake-inputs"}
      fi
      # Remove what sources left behind that don't need it anymore.
      ${removeStale flakesDir (attrNames generated)}
      ${removeStale derivedDir (attrNames derived)}
      ${removeStale patchesDir (attrNames patched)}
    '';

  # Removes entries of the target directory that aren't sources, garbage
  # collector roots of flake inputs of sources that aren't flake or
  # flake-input sources, and uploads left behind by interrupted runs.
  prune' = target: sources: let
    flakeNames = attrNames (filterAttrs
      (_: source: elem source.type [ "flake" "flake-input" ])
      sources);
  in runShell target /* sh */ ''
    set -efu
    ${useState "${target.path}/.populate" []}
    cd ${quote target.path}
    ${removeOthers {
      dir = ".";
      names = attrNames sources ++ [ ".populate" ];
      log = quote (targetName target target.path);
    }}
    roots=.populate/flake-inputs
    if test -d "$roots"; then
      ${removeOthers { dir = ''"$roots"''; names = flakeNames; }}
      if test -z "$(ls -A "$roots")"; then
        rmdir "$roots"
      fi
    fi
    ${removeTree ".populate/flake-uploads"}
  '';

  pop.derivation = target: source: runShell target /* sh */ ''
    ${makeRoomForLink target.path}
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
    inherit (import ./flake-jq.nix)
      metadataSubdir selected selfIsRemote selfLocked;
    nix' = "${nix}/bin/nix --extra-experimental-features ${quote "nix-command flakes"}";
    inputPath = if source.name == null then [] else splitString "/" source.name;
    fetchOnTarget = source.fetchOnTarget or false;
    name = baseNameOf target.path;
    sentinel = "${dirOf target.path}/.populate";
    # A source that gets patched, gets its lock file rewritten, or is
    # materialized gets linked in .populate/derived/<name> instead of at the
    # target path, and the flakes step derives what the target path gets.
    derived = derivesFlake { type = "flake"; flake = source; };
    linkPath =
      if derived then "${sentinel}/derived/${name}/original" else target.path;
    patches = source.patches or [];
    # Uploads the patches to .populate/patches/<name>, numbered in order.
    uploadPatches = optionalString (patches != []) /* sh */ ''
      rm -fR "$PWD"/patches
      mkdir "$PWD"/patches
      ${concatImapStrings (i: patch: /* sh */ ''
        cp ${quote patch} "$PWD"/patches/${quote "${fixedWidthNumber 4 i}-${baseNameOf patch}"}
      '') patches}
      ${runShell target /* sh */ ''
        set -efu
        ${useState sentinel [ name ]}
        mkdir -p ${quote "${sentinel}/patches"}
      ''}
      ${rsync' (target // { path = "${sentinel}/patches/${name}"; })
               (rsyncDefaultConfig // { filterFiles = false; useChecksum = true; })
               /* sh */ ''"$PWD"/patches''}
    '';
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
        printf %s ${quote source.url} |
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
          ${quote source.url} ${quote (toString source.name)}
      exit 1
    '';
    # The inputs of the flake in this source that get drawn from other
    # sources, as paths of input names.
    overridden = map (x: x.path) (flakeFollows { type = "flake"; flake = source; });
    requireInputs = source.requireInputs or true;
    # Shell function printing the store path $1, followed by the inputs its
    # flake in the subdirectory $2 pins in its own lock file, using the
    # commands nix and mktemp.  Without a lock file, locking would change the
    # flake, so there are no such inputs.  Inputs that get drawn from other
    # sources are left out, with all they pin: Nix archives an empty flake
    # in their place, so it doesn't fetch them.
    closure = { nix, mktemp }: /* sh */ ''
      # Prints the store paths in nix flake archive's output $1.
      closure_paths() {
        ARCHIVE=$1 OVERRIDDEN=${quote (toJSON overridden)} \
        ${nix} eval --impure --raw --expr '
          let
            overridden = builtins.fromJSON (builtins.getEnv "OVERRIDDEN");
            # Inputs given by relative paths are part of their parent.
            paths = prefix: node: builtins.concatMap
              (name: let
                input = node.inputs.''${name};
                path = prefix ++ [ name ];
              in
                if builtins.elem path overridden then []
                else
                  (if input ? path then [ input.path ] else []) ++
                  paths path input)
              (builtins.attrNames (node.inputs or {}));
          in
            builtins.concatStringsSep "\n"
              (paths [] (builtins.fromJSON (builtins.getEnv "ARCHIVE")))
        '
        echo
      }
      closure() {
        printf '%s\n' "$1"
        closure_dir=$1''${2:+/$2}
        if test -e "$closure_dir"/flake.nix && test -e "$closure_dir"/flake.lock; then
          closure_flake=path:$1''${2:+?dir=$2}
          set --
          ${optionalString (overridden != []) /* sh */ ''
            closure_empty=$(${mktemp} -d)
            echo '{ outputs = _: {}; }' > "$closure_empty"/flake.nix
            ${concatMapStrings (path: /* sh */ ''
              set -- "$@" --override-input ${quote (concatStringsSep "/" path)} "path:$closure_empty"
            '') overridden}
          ''}
          if closure_archive=$(
            ${nix} flake archive --json --no-update-lock-file "$@" "$closure_flake"
          ); then
            closure_paths "$closure_archive"
          else
            ${if requireInputs then /* sh */ ''
              >&2 printf 'error: source %s: the inputs its own lock file pins can'"'"'t be delivered%s\n' \
                  ${quote name} ${quote (optionalString (source.name != null)
                    ".  Set its requireInputs to false to deliver it anyway.")}
              exit 1
            '' else /* sh */ ''
              # Without --no-update-lock-file, Nix adds what the lock file
              # lacks.
              if closure_archive=$(
                ${nix} flake archive --json --no-write-lock-file "$@" "$closure_flake"
              ); then
                >&2 printf 'warning: source %s: its own lock file needs to be updated; delivering it with the inputs Nix locks now, which evaluating it may not use\n' \
                    ${quote name}
                closure_paths "$closure_archive"
              else
                >&2 printf 'warning: source %s: the inputs its own lock file pins can'"'"'t be delivered; delivering it without them\n' \
                    ${quote name}
              fi
            ''}
          fi
          ${optionalString (overridden != []) /* sh */ ''
            rm -R "$closure_empty"
          ''}
        fi
      }
    '';
    # Directory of garbage collector roots for the input's own inputs.
    inputsRoots = "${sentinel}/flake-inputs/${name}";
    # Directory receiving the flake itself if the target can't fetch it.
    uploads = "${sentinel}/flake-uploads";
    upload = "${uploads}/${name}";
    removeUpload = /* sh */ ''
      ${removeTree (quote upload)}
      # Sources get populated one after another, so no other source uses the
      # directory meanwhile.
      if test -d ${quote uploads} && test -z "$(ls -A ${quote uploads})"; then
        rmdir ${quote uploads}
      fi
    '';
    # Reads the subdirectory containing the flake or input, which may be
    # empty, followed by store paths from stdin.  Links the first store path,
    # or the subdirectory therein, at the link path, and registers it and
    # the remaining ones as garbage collector roots.  Roots get added before
    # obsolete ones get removed, so the inputs stay rooted.
    link = /* sh */ ''
      set -efu
      read -r dir
      read -r path
      ${useState sentinel [ name ]}
      ${optionalString derived /* sh */ ''
        mkdir -p ${quote (dirOf linkPath)}
      ''}
      ${makeRoomForLink linkPath}
      nix-store --realise "$path" --add-root ${quote linkPath} --indirect >/dev/null
      # The garbage collector follows the link into the store path.
      if test -n "$dir"; then
        ln -fns "$path/$dir" ${quote linkPath}
      fi

      # Left behind by an interrupted run, or not needed anymore.
      ${removeUpload}
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
        if test -z "$(ls -A ${quote (dirOf inputsRoots)})"; then
          rmdir ${quote (dirOf inputsRoots)}
        fi
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
      read -r expected
      if test -n "$self" && ! nix-store --check-validity "$self" 2>/dev/null; then
        name=$(basename "$self" | cut -c34-)
        mv ${quote upload}/tree ${quote upload}/"$name"
        added=$(nix-store --add-fixed --recursive sha256 ${quote upload}/"$name")
        ${removeUpload}
        if test "$added" != "$self"; then
          >&2 printf 'error: flake %s arrived as %s instead of %s\n' \
              ${quote source.url} "$added" "$self"
          exit 1
        fi
      fi
      # Fetching contacts where the input comes from even if the store has
      # what the lock file pins.
      if test -n "$expected" && ! nix-store --check-validity "$expected" 2>/dev/null; then
        expected=
      fi
      # The store path and the subdirectory, on separate lines.  Inputs
      # referring to local paths can only be fetched if the target has them
      # as well.
      fetched=$(
        FLAKE=${quote source.url} INPUT=${quote (toString source.name)} \
        SELECTED=$selected SELF=$self EXPECTED=$expected \
        nix eval --impure --raw --expr '
          let
            selected = builtins.fromJSON (builtins.getEnv "SELECTED");
            expected = builtins.getEnv "EXPECTED";
            selectedPath =
              if selected.self || expected != "" then null
              else localPath selected.locked;
            path =
              if selected.self then builtins.getEnv "SELF"
              else if expected != "" then expected
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
            if selectedPath != null && builtins.substring 0 1 selectedPath == "/" && !builtins.pathExists selectedPath then
              throw "flake ''${builtins.getEnv "FLAKE"}: input ''${builtins.getEnv "INPUT"} refers to ''${selectedPath}, which does not exist on the target"
            else if missing != [] then
              throw "flake ''${builtins.getEnv "FLAKE"}: input ''${key} refers to ''${localPath lock.nodes.''${key}.locked}, which does not exist on the target"
            else
              path + "\n" + selected.subdir
        '
      )
      path=$(printf '%s\n' "$fetched" | sed -n 1p)
      subdir=$(printf '%s\n' "$fetched" | sed -n 2p)
      ${closure { nix = "nix"; mktemp = "mktemp"; }}
      # Not in the pipeline, where failing wouldn't fail populate.
      paths=$(closure "$path" "$subdir")
      printf '%s\n%s\n' "$subdir" "$paths" | {
        ${link}
      }
    '';
    # Fetches the flake and its inputs, and links the results.
    archiveAndLink = /* sh */ ''
      set -efu
      ${requireFlakes "fetching flakes on the target"}
      metadata=$(nix flake metadata --json --no-update-lock-file ${quote source.url})
      # The store path and the subdirectory, on separate lines.
      fetched=$(
        METADATA=$metadata nix eval --impure --raw --expr '
          let
            metadata = builtins.fromJSON (builtins.getEnv "METADATA");
          in
            metadata.path + "\n" + (${metadataSubdir}) metadata
        '
      )
      path=$(printf '%s\n' "$fetched" | sed -n 1p)
      subdir=$(printf '%s\n' "$fetched" | sed -n 2p)
      ${closure { nix = "nix"; mktemp = "mktemp"; }}
      paths=$(closure "$path" "$subdir")
      printf '%s\n%s\n' "$subdir" "$paths" | {
        ${link}
      }
    '';
  in
    if !fetchOnTarget && !isLocalTarget target && target.sudo then
      throw "krops: source ${target.path}: copying flakes to targets with sudo is not supported"
    else if fetchOnTarget && source.name == null && isRemoteRef source.url then
      uploadPatches + runShell target archiveAndLink
    else /* sh */ ''
      set -efu
      ${uploadPatches}

      ${cached "metadata" /* sh */ ''
        ${nix'} flake metadata --json --no-update-lock-file ${quote source.url}
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
                  ${useState sentinel [ name ]}
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

      # The store path the lock file pins what's selected to, which is the
      # one of a directory named source with the locked hash.  A store that
      # has it needs no fetching, which contacts where the input comes from
      # even then.
      expected=
      hash=$(printf '%s\n' "$selected" | ${jq}/bin/jq -r '.locked.narHash // empty')
      case $hash in
        sha256-*)
          expected=$(
            ${nix}/bin/nix-store --print-fixed-path --recursive sha256 "$(
              printf %s "''${hash#sha256-}" |
              ${coreutils}/bin/base64 -d |
              ${coreutils}/bin/od -An -v -tx1 |
              ${coreutils}/bin/tr -d ' \n'
            )" source
          )
          ;;
      esac

      ${if fetchOnTarget then /* sh */ ''
        printf '%s\n%s\n%s\n' "$selected" "$self" "$expected" | {
          ${runShell target fetchAndLink}
        }
      '' else /* sh */ ''
        path=$self
        if test -z "$path"; then
          if test -n "$expected" &&
              ${nix}/bin/nix-store --check-validity "$expected" 2>/dev/null; then
            path=$expected
          else
            path=$(
              SELECTED=$selected ${nix'} eval --impure --raw --expr '
                (builtins.fetchTree
                  (builtins.fromJSON (builtins.getEnv "SELECTED")).locked).outPath
              '
            )
          fi
        fi
        subdir=$(printf '%s\n' "$selected" | ${jq}/bin/jq -r .subdir)
        ${closure { nix = nix'; mktemp = "${coreutils}/bin/mktemp"; }}
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
    # Hooks and commands a repository's configuration names run with Git's
    # commands, so populate's Git doesn't run any.  The configuration gets
    # checked as well, but Git also runs a hook it has itself.
    git() {
      command git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
    }
    # Remove target path if it doesn't look like a git worktree.
    # This can happen e.g. when it had a different type earlier.  A work
    # tree that a symlink points to, or whose .git is a symlink or a file
    # naming a repository elsewhere, isn't populate's own: fetching,
    # resetting, and cleaning would change what's elsewhere.
    ${removeLink target.path}
    if test -L ${quote target.path}/.git ||
        ! test -d ${quote target.path}/.git; then
      rm -fR ${quote target.path}
    fi
    # A .git directory can name places elsewhere too, which Git's commands
    # change, or commands, which they run.  Populate only uses a work tree
    # whose .git directory has nothing like that, and else replaces it if
    # reclone is set, or fails, telling why.
    if test -e ${quote target.path}; then
      # Not $((, which would be arithmetic.
      if problems=$( ${gitProblems target.path} ); then :; else
        exit 1
      fi
      if test -n "$problems"; then
        ${if source.reclone then /* sh */ ''
          >&2 printf 'replacing the Git work tree %s, because %s\n' \
              ${quote target.path} "$problems"
          rm -fR ${quote target.path}
        '' else /* sh */ ''
          >&2 printf 'error: populate doesn'"'"'t use the Git work tree %s, because %s.  Fix that, remove the work tree, or set the source'"'"'s reclone to true to replace it by a fresh clone.\n' \
              ${quote target.path} "$problems"
          exit 1
        ''}
      fi
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
    fi
    # Also if HEAD is there already: rewriting a lock file in place, e.g.,
    # changes the work tree, and stages the lock file if Nix created it.
    git reset --hard "$hash" >&2
    git submodule update --init --recursive

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

    # With the fixed modification time, only checksums tell outputs of the
    # same size apart.
    ${rsync' target (rsyncDefaultConfig // { useChecksum = true; }) /* sh */ "$out"}
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
    echo ${quote "populating '${target'.host}:${target'.path}'..."} >&2
    PWD=$TMPDIR/workdirs/${quote name}
    mkdir -p "$PWD"
    cd "$PWD"
    ${pop.${source.type} target' source'}
  '';

  rsync' = target: config: sourcePath: /* sh */ ''
    # rsync writes through a symlink at the target path, e.g. one a symlink or
    # flake source left there, into what it points to.  And rsync fixes the
    # mode and time of a file it takes for unchanged in place, which changes
    # every hard link to it, e.g. one elsewhere, or a backup's.  So each file
    # with other hard links gets replaced by a copy of its own first.
    ${runShell target /* sh */ ''
      ${removeLink target.path}
      if test -d ${quote target.path}; then
        find ${quote target.path} -type f -links +1 -exec sh -c '
          for file; do
            copy=$(mktemp "$file.XXXXXX")
            cp -p "$file" "$copy"
            mv -f "$copy" "$file"
          done
        ' sh {} +
      fi
    ''}
    source_path=${sourcePath}
    if test -d "$source_path"; then
      source_path=$source_path/
    fi
    # Without .rsync-filter files applying, rsync reads none.
    ${if config.filterFiles or true
      then insecureLinks config
      else "insecure_links="}
    # Each item gets logged with what changed about it, and its size, as
    # transferred and in total.
    ${rsync}/bin/rsync \
        ${optionalString config.useChecksum /* sh */ "--checksum"} \
        ${optionalString target.sudo /* sh */ "--rsync-path=\"sudo rsync\""} \
        -e ${quote (ssh' target)} \
        --protect-args \
        $insecure_links \
        --itemize-changes \
        --out-format=${quote "%i %n%L %'''b/%'''l"} \
        --info=backup,del,copy,misc,mount,name,nonreg,remove,skip,symsafe \
        ${rsyncFilterArgs config} \
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
    insecureLinks = null;
  };

  # rsync's arguments for what a source excludes and filters, followed by
  # -F, which applies .rsync-filter files, unless the config turns that off.
  rsyncFilterArgs = config: /* sh */ ''
    ${concatMapStringsSep " "
      (pattern: /* sh */ "--exclude ${quote pattern}")
      config.exclude} \
    ${concatMapStringsSep " "
      (filter: /* sh */ "--${filter.type} ${quote filter.pattern}")
      config.filters} \
    ${optionalString (config.filterFiles or true) "-F"}'';

  # rsync 3.5.0 and later open .rsync-filter files with a stricter walk than
  # the files they transfer, and treat the ones that walk can't open as
  # missing, without saying so.  It fails, e.g., for a directory on the way
  # that the user may enter but not read, like a home directory with mode
  # 711, or a symlink that neither root nor the user owns.  So rsync, when
  # asked, tells which .rsync-filter files it reads for the source in
  # $source_path: the ones therein, and the ones in the directories above
  # it, which apply as well.  If it reports ones as missing that exist and
  # that the user may read, the config's insecureLinks decides: populate
  # fails with an error if it's null, syncs without them if it's false, and
  # makes rsync open them like the files it transfers with --insecure-links
  # if it's true, both with a warning.  Sets insecure_links to rsync's extra
  # argument.
  insecureLinks = config: let
    setting = config.insecureLinks;
  in /* sh */ ''
    insecure_links=
    rsync_version=$(${rsync}/bin/rsync --version | ${coreutils}/bin/head -n 1)
    rsync_version=$(set -- $rsync_version; echo "$3")
    # Whether a .rsync-filter file applies at all.
    filtered=$(${findutils}/bin/find "$source_path" -name .rsync-filter -print -quit)
    above=$(${coreutils}/bin/dirname "$source_path")
    while test -z "$filtered"; do
      if test -e "$above"/.rsync-filter; then
        filtered=$above/.rsync-filter
      elif test "$above" = / || test "$above" = .; then
        break
      fi
      above=$(${coreutils}/bin/dirname "$above")
    done
    if test "$(printf '%s\n' 3.5.0 "$rsync_version" | ${coreutils}/bin/sort -V |
               ${coreutils}/bin/head -n 1)" = 3.5.0 &&
        test -n "$filtered"
    then
      # A dry run of the same transfer, as far as filtering goes.
      ${rsync}/bin/rsync --dry-run --debug=FILTER2 \
          ${rsyncFilterArgs config} \
          -rlptD \
          "$source_path" "$TMPDIR"/rsync-filter-check \
        > "$TMPDIR"/rsync-filter-check.log 2>&1 || :
      # The first .rsync-filter file rsync reports as missing although it
      # exists.  One the user may not read isn't for rsync to read anyway.
      parsed=
      ignored=
      while IFS= read -r line; do
        case $line in
          "[sender] parse_filter_file("*)
            parsed=1
            ;;
        esac
        case $line in
          "[sender] parse_filter_file("*") [not found]")
            file=''${line#*parse_filter_file(}
            file=''${file%,*,*}
            # rsync prints bytes it takes for unprintable, which depends on
            # the locale, as \#ooo.
            escaped=$file
            file=
            while :; do
              case $escaped in
                *'\#'[0-7][0-7][0-7]*)
                  literal=''${escaped%%'\#'[0-7][0-7][0-7]*}
                  escaped=''${escaped#"$literal"'\#'}
                  byte=$(printf "\\$(printf %s "$escaped" | ${coreutils}/bin/cut -c1-3)x")
                  file=$file$literal''${byte%x}
                  escaped=''${escaped#???}
                  ;;
                *)
                  file=$file$escaped
                  break
                  ;;
              esac
            done
            if test -e "$file" && test -r "$file"; then
              ignored=$file
              break
            fi
            ;;
        esac
      done < "$TMPDIR"/rsync-filter-check.log
      ${coreutils}/bin/rm "$TMPDIR"/rsync-filter-check.log
      if test -z "$parsed"; then
        >&2 printf 'warning: rsync %s doesn'"'"'t tell which .rsync-filter files it reads, so it may sync %s without some of them unnoticed.\n' \
            "$rsync_version" "$source_path"
      fi
      if test -n "$ignored"; then
        ${if setting == null then /* sh */ ''
          >&2 printf 'error: rsync %s can'"'"'t read %s, so it would sync %s without it.  This happens, e.g., if a directory on the way isn'"'"'t readable, or if a symlink on the way belongs to neither root nor the user running rsync.  Set the source'"'"'s insecureLinks to true to make rsync read it anyway, or to false to sync without it.\n' \
              "$rsync_version" "$ignored" "$source_path"
          exit 1
        '' else if setting then /* sh */ ''
          >&2 printf 'warning: rsync %s can'"'"'t read %s; it reads it with --insecure-links anyway, because insecureLinks is true.\n' \
              "$rsync_version" "$ignored"
          insecure_links=--insecure-links
        '' else /* sh */ ''
          >&2 printf 'warning: rsync %s can'"'"'t read %s, so it syncs %s without it, because insecureLinks is false.\n' \
              "$rsync_version" "$ignored" "$source_path"
        ''}
      fi
    fi
  '';

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
assert checkTargetPath target.path;
assert all checkSourceName (attrNames source);
writers.writeDash "populate.${target.host}" ''
  set -efu

  # Change to a private temporary directory to prevent collisions.
  TMPDIR=$(${coreutils}/bin/mktemp -dt populate.XXXXXXXX)
  readonly TMPDIR # Ensure the trap will delete the correct thing.
  export TMPDIR # Share it with the jobs and the ssh wrapper.
  # Stops the ssh master, if any source started one, also after failures,
  # before its control socket goes away with $TMPDIR.
  stop_ssh_master() {
    if ${ssh' target} -q -O check ${quote target.host} 2>/dev/null; then
      ${ssh' target} -q -O stop ${quote target.host}
    fi
  }
  trap 'trap "" HUP INT TERM; stop_ssh_master; rm -R "$TMPDIR"' EXIT
  # A signal ends the shell without running the trap above, unless it's
  # trapped itself.  The shell runs these traps once the command it waits
  # for ends, which a signal to the process group, like the one of an
  # interrupt key, ends as well.  Further signals get ignored, so they
  # don't end the trap above halfway.
  trap 'trap "" HUP INT TERM; exit 129' HUP
  trap 'trap "" HUP INT TERM; exit 130' INT
  trap 'trap "" HUP INT TERM; exit 143' TERM

  echo + "$0" >&2
  ${check { inherit force target; }}
  ${optionalString backup (do-backup { inherit target; })}
  ${concatStringsSep "\n" (mapAttrsToList (populate target) source)}
  ${flakes target source}
  ${optionalString prune (prune' target source)}
''
