{
  description = "the SRT (Secure Reliable Transport) CLI apps as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # srt ships three CLI apps (srt-live-transmit / srt-file-transmit /
  # srt-tunnel). Shared `nativeFixes.srt` swaps OpenSSL → mbedtls and turns
  # the apps off (ffmpeg only wants libsrt); here we turn them back on and
  # post-link the three into a single multicall `srt` binary — see
  # ./multicall.nix for the link mechanics.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      mk = pkgs: extra: import ./multicall.nix { lib = pkgs.lib // ulib; } extra;
    in
    ulib.mkStandaloneFlake {
      inherit self;
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      name = "srt";

      # The apps are C++. On darwin clang++ links /usr/lib/libc++.1.dylib
      # dynamically (the action-build portability allowlist forbids it), so
      # static-link libc++ into the final multicall link — same single-binary
      # policy as x265's darwin branch. Linux pkgsStatic already links the
      # musl libstdc++ statically, so it needs no extra flags.
      build = pkgs:
        let sp = pkgs.pkgsStatic; in
        mk pkgs ({
          pkgs = sp;
          srt = ulib.nativeFixes.srt sp;
        } // pkgs.lib.optionalAttrs sp.stdenv.hostPlatform.isDarwin {
          extraLinkFlags = "-nostdlib++ ${sp.libcxx}/lib/libc++.a ${sp.libcxx}/lib/libc++abi.a";
        });

      # mingw drops srt-tunnel (upstream: no C++11 <thread>), so Windows
      # ships a 2-applet multicall. The apps are C++ → force the runtime
      # static so the .exe carries no libstdc++-6/libgcc_s/libmcfgthread
      # DLLs (same single-binary policy as x265). Drive the combined link
      # through lld (-fuse-ld=lld): binutils 2.44 discards the cxx11 COMDAT
      # members (basic_string::_M_dispose, std::ctype::do_widen, the exception
      # typeinfos) in the combined PE link, leaving them undefined; lld's
      # PE/COFF COMDAT handling links them cleanly. Same fix as heif.
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        mk pkgs {
          pkgs = cross;
          srt = ulib.nativeFixes.srt cross;
          extraLinkFlags = "-static -static-libgcc -static-libstdc++ -fuse-ld=lld";
        };
    };
}
