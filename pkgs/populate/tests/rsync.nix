# rsync versions whose behaviour around .rsync-filter files differs: 3.4.1
# reads them like the files it transfers, and 3.5.0 opens them more
# strictly.  The tests run the scenarios depending on that with each,
# whatever version nixpkgs has.  rsync's own test suite doesn't run: these
# builds only need to behave like the releases.
{ lib, stdenv, fetchurl, fetchpatch, perl, updateAutotoolsGnuConfigScriptsHook
, acl, libiconv, popt, zlib
}:

let
  rsync = { version, hash, patches ? [] }: stdenv.mkDerivation {
    pname = "rsync";
    inherit version patches;
    src = fetchurl {
      # signed with key 9FEF 112D CE19 A0DC 7E88  2CB8 1BB2 4997 A853 5F6F
      url = "mirror://samba/rsync/src/rsync-${version}.tar.gz";
      inherit hash;
    };
    nativeBuildInputs = [ perl updateAutotoolsGnuConfigScriptsHook ];
    # With ACLs and extended attributes, which backups use (rsync -aAX).
    buildInputs = [ acl libiconv popt zlib ];
    configureFlags = [
      "--disable-lz4"
      "--disable-openssl"
      "--disable-xxhash"
      "--disable-zstd"
      "--enable-ipv6"
      "--with-included-zlib=no"
      "--with-nobody-group=nogroup"
    ];
    enableParallelBuilding = true;
    meta.mainProgram = "rsync";
  };
in {
  "3.4.1" = rsync {
    version = "3.4.1";
    hash = "sha256-KSS8s6Hti1UfwQH3QLnw/gogKxFQJ2R89phQ1l/YjFI=";
    patches = [
      # Compilation with GCC 15.
      (fetchpatch {
        url = "https://github.com/RsyncProject/rsync/commit/a4b926dcdce96b0f2cc0dc7744e95747b233500a.patch";
        hash = "sha256-UiEQJ+p2gtIDYNJqnxx4qKgItKIZzCpkHnvsgoxBmSE=";
      })
    ];
  };
  "3.5.0" = rsync {
    version = "3.5.0";
    hash = "sha256-x//R72U+mVQPZh5HywC3+crR7muXI5mxb5PWcmVuDTM=";
  };
}
