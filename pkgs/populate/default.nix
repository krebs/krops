{ coreutils, findutils, git, gnused, jq, openssh, pass, rsync, runCommand, stdenv }:

let
  PATH = stdenv.lib.makeBinPath [
    coreutils
    findutils
    git
    gnused
    jq
    openssh
    pass
    rsync
  ];
in

runCommand "populate-2.2.0" {} ''
  mkdir -p $out/bin
  cp ${./populate.sh} $out/bin/populate
  sed -i '1s,.*,&\nPATH=${PATH},' $out/bin/populate
''
