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

  # Delivers the flake itself, as its input named null.  Only inputs can be
  # fetched on the target, so fetchOnTarget is always false here.
  pop.flake = target: source:
    pop.flake-input target (source // { name = null; fetchOnTarget = false; });

  pop.flake-input = target: source: let
    nix' = "${nix}/bin/nix --extra-experimental-features ${quote "nix-command flakes"}";
    inputPath = if source.name == null then [] else splitString "/" source.name;
    fetchOnTarget = source.fetchOnTarget or false;
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
    # jq filter selecting the flake or input in nix flake archive's output.
    node =
      if source.name == null then "."
      else concatMapStrings (name: ".inputs[${toJSON name}]") inputPath;
    # jq filter selecting the locked input and its own inputs in nix flake
    # metadata's output, as fetchTree arguments, the input first.
    locked = /* jq */ ''
      .locks as $l
      | def ref($path):
          reduce $path[] as $name ($l.root;
            $l.nodes[.].inputs[$name] // error("no input \($name)")
            | if type == "array" then ref(.) else . end);
        def deps($key):
          $key, ($l.nodes[$key].inputs // {} | .[]
            | if type == "array" then ref(.) else . end
            | deps(.));
        ref($input) as $key
        | [$key] + ([deps($key)] | unique - [$key])
        | map($l.nodes[.].locked)
    '';
    sentinel = "${dirOf target.path}/.populate";
    # Directory of garbage collector roots for the input's own inputs.
    inputsRoots = "${sentinel}/flake-inputs/${baseNameOf target.path}";
    # Reads store paths from stdin, links the first one at the target path, and
    # registers it and the remaining ones as garbage collector roots.  Roots
    # get added before obsolete ones get removed, so the inputs stay rooted.
    link = /* sh */ ''
      set -efu
      read -r path
      if test -e ${quote target.path} && ! test -L ${quote target.path}; then
        rm -fR ${quote target.path}
      fi
      nix-store --realise "$path" --add-root ${quote target.path} --indirect >/dev/null

      ${sentinelDirectory sentinel}
      mkdir -p ${quote inputsRoots}
      roots=
      while read -r path; do
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
    # Reads fetchTree arguments as JSON array from stdin, fetches them, and
    # links the results.
    fetchAndLink = /* sh */ ''
      set -efu
      ${requireFlakes "fetching flake inputs on the target"}
      read -r locked
      paths=$(LOCKED=$locked nix eval --impure --raw --expr '
        builtins.concatStringsSep "\n"
          (map (locked: (builtins.fetchTree locked).outPath)
            (builtins.fromJSON (builtins.getEnv "LOCKED")))
      ')
      printf '%s\n' "$paths" | {
        ${link}
      }
    '';
  in
    if !fetchOnTarget && !isLocalTarget target && target.sudo then
      throw "krops: source ${target.path}: copying flakes to targets with sudo is not supported"
    else if fetchOnTarget then /* sh */ ''
      set -efu

      ${cached "metadata" /* sh */ ''
        ${nix'} flake metadata --json --no-update-lock-file ${quote source.flake}
      ''}

      if ! locked=$(
        ${jq}/bin/jq -ce --argjson input ${quote (toJSON inputPath)} ${quote locked} \
          "$cache" 2>/dev/null
      ); then
        ${noInput}
      fi

      printf '%s\n' "$locked" | {
        ${runShell target fetchAndLink}
      }
    '' else /* sh */ ''
      set -efu

      ${cached "archive" /* sh */ ''
        ${nix'} flake archive --json --no-update-lock-file ${quote source.flake}
      ''}

      if ! ${jq}/bin/jq -e ${quote "${node} | .path"} "$cache" >/dev/null; then
        ${noInput}
      fi

      # The input followed by its own inputs, which flakes evaluated on the
      # target need as well.
      paths=$(${jq}/bin/jq -r ${quote "${node} | .. | .path? | strings"} "$cache")

      ${optionalString (!isLocalTarget target) /* sh */ ''
        mkdir -p "$PWD"/bin
        ln -fns ${sshNix' target} "$PWD"/bin/ssh
        PATH=$PWD/bin:$PATH \
        ${nix'} copy --to ${quote "ssh://${target.host}"} $paths >&2
      ''}

      printf '%s\n' "$paths" | {
        ${runShell target link}
      }
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
        -FrlptD \
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

{ backup ? false, force ? false, source, target }:
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

  ${ssh' target} -q -O stop ${quote target.host}
''
