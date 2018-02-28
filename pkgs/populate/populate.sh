#! /bin/sh
set -efu

main() {(
  self=$(readlink -f "$0")
  basename=${0##*/}

  debug=false
  force=false
  origin_host=${HOSTNAME-cat /proc/sys/kernel/hostname}
  origin_user=$LOGNAME
  target_spec=


  abort=false

  error() {
    echo "$basename: error: $1" >&2
    abort=true
  }

  for arg; do
    case $arg in
      --force)
        force=true
        ;;
      -*)
        error "bad argument: $arg"
        ;;
      *)
        if test -n "$target_spec"; then
          error "bad argument: $arg"
        else
          target_spec=$arg
        fi
        ;;
    esac
  done

  if test -z "$target_spec"; then
    error 'no target specified'
  fi

  if test "$abort" = true; then
    exit 11
  fi

  target=$(
    export origin_host
    export origin_user
    echo "$target_spec" | jq -R '
      def default(value; f): if . == null then value else f end;
      def default(value): default(value; .);

      match("^(?:([^@]+)@)?(?:([^:/]+))?(?::([^/]+))?(/.*)?")
      | {
        user: .captures[0].string | default(env.origin_user),
        host: .captures[1].string | default(env.origin_host),
        port: .captures[2].string | default(22;
          if test("^[0-9]+$") then fromjson else
            error(@json "bad target port: \(.)")
          end),
        path: .captures[3].string | default("/var/src"),
      }
    '
  )

  echo $target | jq . >&2

  target_host=$(echo $target | jq -r .host)
  target_path=$(echo $target | jq -r .path)
  target_port=$(echo $target | jq -r .port)
  target_user=$(echo $target | jq -r .user)

  if test "$force" = true; then
    force_target
  else
    check_target
  fi

  jq -c 'to_entries | group_by(.value.type) | flatten[]' |
  while read -r source; do
    key=$(echo "$source" | jq -r .key)
    type=$(echo "$source" | jq -r .value.type)
    conf=$(echo "$source" | jq -r .value.${type})

    printf '\e[1;33m%s\e[m\n' "populate_$type $key $conf" >&2

    populate_"$type" "$key" "$conf"
  done
)}

# Safeguard to prevent clobbering of misspelled targets.
# This function has to be called first.
check_target() {
  {
    echo target_host=$(quote "$target_host")
    echo target_path=$(quote "$target_path")
    echo 'sentinel_file=$target_path/.populate'
    echo 'if ! test -f "$sentinel_file"; then'
    echo '  echo "error: missing sentinel file: $target_host:$sentinel_file" >&2'
    echo '  exit 1'
    echo 'fi'
  } \
    |
  target_shell
}

force_target() {
  {
    echo target_path=$(quote "$target_path")
    echo 'sentinel_file=$target_path/.populate'
    echo 'mkdir -vp "$target_path"'
    echo 'touch "$sentinel_file"'
  } \
    |
  target_shell
}

is_local_target() {
  test "$target_host" = "$origin_host" &&
  test "$target_user" = "$origin_user"
}

populate_file() {(
  file_name=$1
  file_path=$(echo "$2" | jq -r .path)

  if is_local_target; then
    file_target=$target_path/$file_name
  else
    file_target=$target_user@$target_host:$target_path/$file_name
  fi

  rsync \
      -vFrlptD \
      --delete-excluded \
      "$file_path"/ \
      -e "ssh -o ControlPersist=no -p $target_port" \
      "$file_target"
)}

populate_git() {(
  git_name=$1
  git_url=$(echo "$2" | jq -r .url)
  git_ref=$(echo "$2" | jq -r .ref)

  git_work_tree=$target_path/$git_name

  {
    echo set -efu

    echo git_url=$(quote "$git_url")
    echo git_ref=$(quote "$git_ref")

    echo git_work_tree=$(quote "$git_work_tree")

    echo 'if ! test -e "$git_work_tree"; then'
    echo '  git clone "$git_url" "$git_work_tree"'
    echo 'fi'

    echo 'cd $git_work_tree'

    echo 'if ! url=$(git config remote.origin.url); then'
    echo '  git remote add origin "$git_url"'
    echo 'elif test "$url" != "$git_url"; then'
    echo '  git remote set-url origin "$git_url"'
    echo 'fi'

    # TODO resolve git_ref to commit hash
    echo 'hash=$git_ref'

    echo 'if ! test "$(git log --format=%H -1)" = "$hash"; then'
    echo '  if ! git log -1 "$hash" >/dev/null 2>&1; then'
    echo '    git fetch origin'
    echo '  fi'
    echo '  git checkout "$hash" -- "$git_work_tree"'
    echo '  git -c advice.detachedHead=false checkout -f "$hash"'
    echo 'fi'

    echo 'git clean -dfx'

  } \
    |
  target_shell
)}

populate_pass() {(
  pass_target_name=$1
  pass_dir=$(echo "$2" | jq -r .dir)
  pass_name_root=$(echo "$2" | jq -r .name)

  if is_local_target; then
    pass_target=$target_path/$pass_target_name
  else
    pass_target=$target_user@$target_host:$target_path/$pass_target_name
  fi

  umask 0077

  tmp_dir=$(mktemp -dt populate-pass.XXXXXXXX)
  trap cleanup EXIT
  cleanup() {
    rm -fR "$tmp_dir"
  }

  pass_prefix=$pass_dir/$pass_name_root/

  find "$pass_prefix" -type f |
  while read -r pass_gpg_file_path; do

    rel_name=${pass_gpg_file_path:${#pass_prefix}}
    rel_name=${rel_name%.gpg}

    pass_name=$pass_name_root/$rel_name
    tmp_path=$tmp_dir/$rel_name

    mkdir -p "$(dirname "$tmp_path")"
    PASSWORD_STORE_DIR=$pass_dir pass show "$pass_name" > "$tmp_path"
  done

  rsync \
      --checksum \
      -vFrlptD \
      --delete-excluded \
      "$tmp_dir"/ \
      -e "ssh -o ControlPersist=no -p $target_port" \
      "$pass_target"
)}

populate_pipe() {(
  pipe_target_name=$1
  pipe_command=$(echo "$2" | jq -r .command)

  result_path=$target_path/$pipe_target_name

  "$pipe_command" | target_shell -c "cat > $(quote "$result_path")"
)}

populate_symlink() {(
  symlink_name=$1
  symlink_target=$(echo "$2" | jq -r .target)
  link_name=$target_path/$symlink_name

  {
    # TODO rm -fR instead of ln -f?
    echo ln -fns $(quote "$symlink_target" "$link_name")
  } \
    |
  target_shell
)}

quote() {
  printf %s "$1" | sed 's/./\\&/g'
  while test $# -gt 1; do
    printf ' '
    shift
    printf %s "$1" | sed 's/./\\&/g'
  done
  echo
}

target_shell() {
  if is_local_target; then
    /bin/sh "$@"
  else
    ssh "$target_host" \
        -l "$target_user" \
        -o ControlPersist=no \
        -p "$target_port" \
        -T \
        /bin/sh "$@"
  fi
}

main "$@"
