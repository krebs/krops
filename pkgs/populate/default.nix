with import ../../lib;
with shell;

{ coreutils, dash, findutils, git, jq, openssh, pass, rsync, writeDash }:

let
  check = { force, target }: let
    sentinelFile = "${target.path}/.populate";
  in shell' target /* sh */ ''
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
    shell' target /* sh */ ''
      if ! test -d ${quote sentinelFile}; then
        >&2 printf 'error" sentinel file is not a directory: %s\n' ${quote (
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

  pop.derivation = target: source: shell' target /* sh */ ''
    nix-build -E ${quote source.text} -o ${quote target.path} >&2
  '';

  pop.file = target: source: let
    configAttrs = ["useChecksum" "exclude"];
    config = filterAttrs (name: _: elem name configAttrs) source;
  in
    rsync' target config (quote source.path);

  pop.git = target: source: shell' target /* sh */ ''
    set -efu
    if ! test -e ${quote target.path}; then
      git clone --recurse-submodules ${quote source.url} ${quote target.path}
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
        git fetch origin
      '' else /* sh */ ''
        if ! git log -1 "$hash" >/dev/null 2>&1; then
          git fetch origin
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

    if test -e ${quote source.dir}/.git; then
      local_pass_info=${quote source.name}\ $(${git}/bin/git -C ${quote source.dir} log -1 --format=%H ${quote source.name})
      remote_pass_info=$(${shell' target /* sh */ ''
        cat ${quote target.path}/.pass_info || :
      ''})

      if test "$local_pass_info" = "$remote_pass_info"; then
        exit 0
      fi
    fi

    tmp_dir=$(${coreutils}/bin/mktemp -dt populate-pass.XXXXXXXX)
    trap cleanup EXIT
    cleanup() {
      rm -fR "$tmp_dir"
    }

    ${findutils}/bin/find ${quote passPrefix} -type f |
    while read -r gpg_path; do

      rel_name=''${gpg_path#${quote passPrefix}}
      rel_name=''${rel_name%.gpg}

      pass_date=$(
        ${git}/bin/git -C ${quote source.dir} log -1 --format=%aI "$gpg_path"
      )
      pass_name=${quote source.name}/$rel_name
      tmp_path=$tmp_dir/$rel_name

      ${coreutils}/bin/mkdir -p "$(${coreutils}/bin/dirname "$tmp_path")"
      PASSWORD_STORE_DIR=${quote source.dir} ${pass}/bin/pass show "$pass_name" > "$tmp_path"
      ${coreutils}/bin/touch -d "$pass_date" "$tmp_path"
    done

    if test -n "''${local_pass_info-}"; then
      echo "$local_pass_info" > "$tmp_dir"/.pass_info
    fi

    ${rsync' target {} /* sh */ "$tmp_dir"}
  '';

  pop.pipe = target: source: /* sh */ ''
    ${quote source.command} | {
      ${shell' target /* sh */ "cat > ${quote target.path}"}
    }
  '';

  # TODO rm -fR instead of ln -f?
  pop.symlink = target: source: shell' target /* sh */ ''
    ln -fnsT ${quote source.target} ${quote target.path}
  '';

  populate = target: name: source: let
    source' = source.${source.type};
    target' = target // { path = "${target.path}/${name}"; };
  in writeDash "populate.${target'.host}.${name}" ''
    set -efu
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
        -e ${quote (ssh' target)} \
        -vFrlptD \
        --delete-excluded \
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

  shell' = target: script:
    if isLocalTarget target
      then script
      else
        if target.sudo then /* sh */ ''
          ${ssh' target} ${quote target.host} ${quote "sudo bash -c ${quote script}"}
        '' else ''
          ${ssh' target} ${quote target.host} ${quote script}
        '';

  ssh' = target: concatMapStringsSep " " quote (flatten [
    "${openssh}/bin/ssh"
    (optionals (target.user != "") ["-l" target.user])
    "-o" "ControlPersist=no"
    "-p" target.port
    "-T"
  ]);

in

{ backup ? false, force ? false, source, target }:
writeDash "populate.${target.host}" ''
  set -efu
  ${check { inherit force target; }}
  set -x
  ${optionalString backup (do-backup { inherit target; })}
  ${concatStringsSep "\n" (mapAttrsToList (populate target) source)}
''
