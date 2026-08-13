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
  # Every target builds under the unpin-llvm engine (all objects LLVM bitcode)
  # and lets mkStandaloneFlake's bitcode self-fold pack the apps into one
  # binary. The apps are C++ → requires.cxx makes the fold link libc++/libstdc++
  # statically (Linux pkgsStatic already does; on darwin it folds static libc++
  # instead of the forbidden /usr/lib/libc++.1.dylib). Windows ships two applets:
  # upstream's CMake skips srt-tunnel on mingw (no C++11 <thread> there).
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

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
      smoke = [ "--unpin-program=srt-live-transmit" "-version" ];
      smokePattern = "SRT Library version: [0-9]+\\.[0-9]+";

      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [
          { name = "srt-live-transmit"; }
          { name = "srt-file-transmit"; }
          # Upstream's CMake builds no srt-tunnel on mingw, so it must not be
          # announced on the .exe either — an applet the dispatcher can't reach.
          { name = "srt-tunnel"; supportedTarget = p: !(p.isMinGW or false); }
        ];
        requires.cxx = true;
      };

      build = pkgs:
        let
          eng = engStdenv pkgs;
          # mbedtls' darwin fixes (the GCC-only -fzero-init-padding-bits flag and
          # the out-of-source `scripts/config.pl` path) live in nix-lib's
          # native-overlay, which autoWires into this very pkgsStatic — a copy
          # here nests on top of it.
          sp = pkgs.pkgsStatic;
        in
        withApps ((ulib.nativeFixes.srt sp).override { stdenv = eng; });

      # mingw cross. No per-package stdenv swap: multicall.windows = true puts
      # the whole set on the engine adapter already.
      windowsBuild = pkgs:
        withApps (ulib.nativeFixes.srt (ulib.mingwStaticCross pkgs));
    };
}
