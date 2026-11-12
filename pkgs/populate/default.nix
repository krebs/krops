with import ../../lib;
with shell;

{ coreutils, dash, findutils, git, jq, nix, openssh, pass, passage, rsync, writers }:

let
  # Populate replaces and removes what's at the target paths of sources, so
  # it refuses names that lead out of the target directory, to the directory
  # itself, or to its own state.
  checkSourceName = name:
    if elem name [ "" "." ".." ".populate" ] ||
        builtins.match "[^/[:cntrl:]]+" name == null then
      throw "krops: source name ${toJSON name} can't be used: it must be a file name other than ., .., and .populate, without slashes and control characters"
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
  # instead of followed.
  removeTree = path: /* sh */ ''
    if test -L ${path}; then
      rm ${path}
    elif test -e ${path}; then
      chmod -R u+w ${path}
      rm -fR ${path}
    fi
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
      case $(readlink ${quote path}) in
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

  check = { force, target }: let
    sentinelFile = "${target.path}/.populate";
  in runShell target /* sh */ ''
    # Before anything touches it, which would touch what it points to.
    if test -L ${quote sentinelFile}; then
      >&2 printf 'error: sentinel file is a symlink: %s\n' ${quote (
        optionalString (!isLocalTarget target) "${target.host}:" +
        sentinelFile
      )}
      exit 1
    fi
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
      ${useState sentinelFile []}
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
        then ''"path:$(readlink -f ${quote "${flakesDir}/${name}"})"''
        else ''"$(flake_url ${quote name})"'';
    check = name: source:
      if source == name then
        throw "krops: source ${name} draws inputs from itself"
      else if !(sources ? ${source}) then
        throw "krops: source ${name} draws inputs from missing source ${source}"
      else
        source;
    # Sets the positional parameters to nix flake lock's arguments for
    # drawing the inputs of the flake in source name from other sources.
    overrideArgs = name: /* sh */ ''
      set --
      ${concatMapStrings (x: /* sh */ ''
        set -- "$@" --override-input ${quote (concatStringsSep "/" x.path)} ${url (check name x.source)}
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
              for arg; do
                case $arg in
                  path:/nix/store/*) ;;
                  path:*|git+file:*)
                    arg=''${arg#*:}
                    nix-hash --type sha256 "''${arg%%\?*}"
                    ;;
                esac
              done
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
            printf '%s\n' "$key" > ${quote "${dir}/key"}
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
              nix flake lock "$@" "path:$work''${subdir:+?dir=$subdir}" >&2
            ''}
            result=$(nix-store --add-fixed --recursive sha256 "$work")
            ${removeWork}
            nix-store --realise "$result" \
                --add-root ${quote "${dir}/result"} --indirect >/dev/null
            printf '%s\n' "$key" > ${quote "${dir}/key"}
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
        "inputs.${toJSON (inputName base)}" +
        # A source with a generated flake has itself as input therein.
        optionalString (parent != null && generated ? ${base})
          ".inputs.${toJSON (inputName base)}" +
        concatMapStrings (name: ".inputs.${toJSON name}") rest +
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
        nix flake lock "path:$(pwd -P)" >&2
      )
    '';
    process = name:
      optionalString (derived ? ${name}) (derive name) +
      (if generated ? ${name} then flake name
       else if drawing ? ${name} && !(derived ? ${name}) then rewrite name
       else "");
    # Removes the entries of directory dir that aren't in names.
    removeOthers = dir: names: /* sh */ ''
      if test -d ${quote dir}; then
        ls -A ${quote dir} | while read -r name; do
          case ${quote " ${toString names} "} in
            *" $name "*) ;;
            *)
              ${removeTree ''${quote dir}/"$name"''}
              ;;
          esac
        done
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

        # Nix rewrites lock files in place, which also changes what else is
        # a hard link to the lock file, e.g. in a backup, or what it is a
        # symlink to.  So the lock file of the flake in the directory $1
        # gets replaced by a copy first.
        own_lock() {
          if test -e "$1"/flake.lock; then
            cp -p "$1"/flake.lock "$1"/flake.lock.populate
            mv -f "$1"/flake.lock.populate "$1"/flake.lock
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
              printf 'git+file:%s?submodules=1' "$path"
            else
              printf 'git+file:%s' "$path"
            fi
          else
            printf 'path:%s' "$path"
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
      ${removeOthers flakesDir (attrNames generated)}
      ${removeOthers derivedDir (attrNames derived)}
      ${removeOthers patchesDir (attrNames patched)}
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
    ${useState "${target.path}/.populate" []}
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
    inherit (import ./flake-jq.nix) selected selfIsRemote selfLocked;
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
      # The store path and the subdirectory, on separate lines.  Inputs
      # referring to local paths can only be fetched if the target has them
      # as well.
      fetched=$(
        FLAKE=${quote source.url} SELECTED=$selected SELF=$self \
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
      metadata=$(nix flake metadata --json --no-update-lock-file ${quote source.url})
      archive=$(nix flake archive --json --no-update-lock-file ${quote source.url})
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
    # This can happen e.g. when it had a different type earlier.  A work
    # tree that a symlink points to, or whose .git is a symlink or a file
    # naming a repository elsewhere, isn't populate's own: fetching,
    # resetting, and cleaning would change what's elsewhere.
    ${removeLink target.path}
    if test -L ${quote target.path}/.git ||
        ! test -d ${quote target.path}/.git; then
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
    PWD=$TMPDIR/workdirs/${quote name}
    mkdir -p "$PWD"
    cd "$PWD"
    ${pop.${source.type} target' source'}
  '';

  rsync' = target: config: sourcePath: /* sh */ ''
    # rsync writes through a symlink at the target path, e.g. one a symlink or
    # flake source left there, into what it points to.
    ${runShell target (removeLink target.path)}
    source_path=${sourcePath}
    if test -d "$source_path"; then
      source_path=$source_path/
    fi
    ${insecureLinks config.insecureLinks}
    # Each item gets logged with what changed about it, and its size, as
    # transferred and in total.
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
        $insecure_links \
        --itemize-changes \
        --out-format=${quote "%i %n%L %'''b/%'''l"} \
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
    insecureLinks = null;
  };

  # rsync 3.5.0 and later open .rsync-filter files with a stricter walk than
  # the files they transfer, and treat the ones that walk can't open as
  # missing, without saying so.  It fails, e.g., for a directory on the way
  # that the user may enter but not read, like a home directory with mode
  # 711, or a symlink that neither root nor the user owns.  So rsync, when
  # asked, tells which .rsync-filter files in the source in $source_path it
  # reads.  If it reports existing ones as missing, setting fails with an
  # error if it's null, syncs without them if it's false, and makes rsync
  # open them like the files it transfers with --insecure-links if it's true,
  # both with a warning.  Sets insecure_links to rsync's extra argument.
  insecureLinks = setting: /* sh */ ''
    insecure_links=
    rsync_version=$(${rsync}/bin/rsync --version | ${coreutils}/bin/head -n 1)
    rsync_version=$(set -- $rsync_version; echo "$3")
    if test "$(printf '%s\n' 3.5.0 "$rsync_version" | ${coreutils}/bin/sort -V |
               ${coreutils}/bin/head -n 1)" = 3.5.0 &&
        test -n "$(${findutils}/bin/find "$source_path" -name .rsync-filter -print -quit)"
    then
      # The first existing .rsync-filter file rsync reports as missing.
      ignored=$(
        ${rsync}/bin/rsync --dry-run --debug=FILTER2 -F -rlptD \
            "$source_path" "$TMPDIR"/rsync-filter-check 2>&1 |
        while read -r line; do
          case $line in
            "[sender] parse_filter_file("*") [not found]")
              file=''${line#*parse_filter_file(}
              file=''${file%,*,*}
              if test -e "$file"; then
                printf '%s\n' "$file"
                break
              fi
              ;;
          esac
        done
      )
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
  trap 'stop_ssh_master; rm -R "$TMPDIR"' EXIT

  ${check { inherit force target; }}
  set -x
  ${optionalString backup (do-backup { inherit target; })}
  ${concatStringsSep "\n" (mapAttrsToList (populate target) source)}
  ${flakes target source}
  ${optionalString prune (prune' target source)}

''
