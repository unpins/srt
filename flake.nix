{
  description = "the SRT (Secure Reliable Transport) CLI apps as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # srt ships three CLI apps (srt-live-transmit / srt-file-transmit /
  # srt-tunnel) folded into one argv[0]-dispatching `srt` binary. Shared
  # `nativeFixes.srt` swaps OpenSSL → mbedtls and turns the apps off (ffmpeg
  # only wants libsrt); here we turn them back on.
  #
  # Native (Linux/darwin): build under the unpin-llvm engine (all objects LLVM
  # bitcode) and let mkStandaloneFlake's bitcode self-fold pack the three apps
  # into one binary. The apps are C++ → requires.cxx makes the fold link
  # libc++/libstdc++ statically (Linux pkgsStatic already does; on darwin it
  # folds static libc++ instead of the forbidden /usr/lib/libc++.1.dylib).
  # Windows (mingw, no engine → native objects) still uses ./multicall.nix's
  # objcopy fold, and drops srt-tunnel (upstream: no C++11 <thread>).
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      mk = pkgs: extra: import ./multicall.nix { lib = pkgs.lib // ulib; } extra;

      # C++, lto + link capture so the self-fold can relink the three apps.
      engStdenv = pkgs:
        let sp = pkgs.pkgsStatic; in
        ulib.unpinAdapterStdenv {
          inherit pkgs;
          target = sp.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = true;
          lto = true;
          captureLinks = true;
        };

      # nativeFixes.srt with the apps re-enabled (ENABLE_APPS=OFF → ON).
      withApps = drv: drv.overrideAttrs (o: {
        cmakeFlags =
          (builtins.filter (f: f != "-DENABLE_APPS=OFF") (o.cmakeFlags or [ ]))
          ++ [ "-DENABLE_APPS=ON" ];
      });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      name = "srt";

      engine = "unpin-llvm";
      multicall = {
        programs = [
          { name = "srt-live-transmit"; }
          { name = "srt-file-transmit"; }
          { name = "srt-tunnel"; }
        ];
        requires.cxx = true;
      };

      build = pkgs:
        let
          eng = engStdenv pkgs;
          isDarwin = pkgs.pkgsStatic.stdenv.hostPlatform.isDarwin;
          # darwin: nixpkgs' mbedtls hardcodes -DCMAKE_C_FLAGS=-fzero-init-
          # padding-bits=unions (a GCC-15 flag). On Linux mbedtls builds under
          # gcc (which has it); on darwin the engine builds it with the unpin
          # clang, which rejects the GCC-only flag → strip it (darwin only, so
          # Linux/cross keep their hash).
          sp = pkgs.pkgsStatic.extend (_: prev: pkgs.lib.optionalAttrs isDarwin {
            mbedtls = prev.mbedtls.overrideAttrs (o: {
              cmakeFlags = builtins.filter
                (f: f != "-DCMAKE_C_FLAGS=-fzero-init-padding-bits=unions")
                (o.cmakeFlags or [ ])
                # mbedtls' demo programs and test suite build with -Werror; on
                # darwin pkgsStatic's inert `-static-libgcc` trips -Wunused-command-
                # line-argument → fatal. We link only the libmbed*.a, never the
                # demos/tests, so skip building them entirely.
                ++ [ "-DENABLE_PROGRAMS=OFF" "-DENABLE_TESTING=OFF" ];
              # nixpkgs' mbedtls postConfigure runs `perl scripts/config.pl set …`
              # to enable threading. Under the darwin engine cmake builds
              # out-of-source (CWD = build/, scripts/ a level up) whereas Linux
              # builds in-source, so the relative path fails. Run it from wherever
              # scripts/config.pl actually is, then return.
              postConfigure = ''
                __d=$PWD
                [ -f scripts/config.pl ] || cd ..
                ${o.postConfigure or ""}
                cd "$__d"
              '';
            });
          });
        in
        withApps ((ulib.nativeFixes.srt sp).override { stdenv = eng; });

      # mingw drops srt-tunnel (upstream: no C++11 <thread>), so Windows ships a
      # 2-applet multicall. The apps are C++ → force the runtime static so the
      # .exe carries no libstdc++-6/libgcc_s/libmcfgthread DLLs. Drive the
      # combined link through lld (-fuse-ld=lld): binutils 2.44 discards the
      # cxx11 COMDAT members in the combined PE link, leaving them undefined;
      # lld's PE/COFF COMDAT handling links them cleanly. Same fix as heif.
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        mk pkgs {
          pkgs = cross;
          srt = ulib.nativeFixes.srt cross;
          extraLinkFlags = "-static -static-libgcc -static-libstdc++ -fuse-ld=lld";
        };
    };
}
