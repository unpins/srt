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

      # A `-version` smoke passes a binary that cannot move data, so the native
      # build transfers for real on loopback: srt-file-transmit sends a file in
      # the clear and AES-encrypted, and srt-tunnel carries a TCP stream over
      # SRT; every copy must arrive byte-identical. The payload comes from awk.
      # Runs wherever the build machine can execute the result.
      withRoundTrip = pkgs: drv: drv.overrideAttrs (old: {
        doInstallCheck = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
        nativeInstallCheckInputs = (old.nativeInstallCheckInputs or [ ])
          ++ [ pkgs.buildPackages.python3 ];
        installCheckPhase = ''
          runHook preInstallCheck
          b=$out/bin
          fail() { echo "installCheck: $*"; exit 1; }
          LC_ALL=C awk 'BEGIN { for (i = 0; i < 400000; i++) printf "%c", (i * 7 + int(i / 997) * 13) % 256 }' > payload.bin
          test "$(wc -c < payload.bin)" -eq 400000 || fail "probe payload has the wrong size"

          for enc in "" "?passphrase=0123456789abcdef&pbkeylen=16"; do
            rm -rf recv && mkdir recv
            port=$((20000 + RANDOM % 20000))
            timeout 60 "$b/srt-file-transmit" "srt://:$port$enc" "file://$PWD/recv/" > rx.log 2>&1 &
            rx=$!
            sleep 1
            timeout 60 "$b/srt-file-transmit" "file://$PWD/payload.bin" "srt://127.0.0.1:$port$enc" > tx.log 2>&1 \
              || { cat tx.log rx.log; fail "srt-file-transmit could not send''${enc:+ encrypted}"; }
            wait "$rx" || true
            cmp -s payload.bin recv/payload.bin || { cat rx.log; fail "file''${enc:+ (encrypted)} arrived different"; }
          done
        '' + pkgs.lib.optionalString (!pkgs.stdenv.hostPlatform.isWindows) ''
          tcp=$((20000 + RANDOM % 10000)); srt=$((30000 + RANDOM % 5000)); lp=$((35000 + RANDOM % 5000))
          python3 - "$tcp" > sink.txt <<'PY' &
        import socket, sys
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); s.settimeout(60)
        c, _ = s.accept(); out = bytearray()
        while True:
            d = c.recv(65536)
            if not d: break
            out += d
        open("tunneled.bin", "wb").write(out)
        PY
          sink=$!
          sleep 1
          timeout 90 "$b/srt-tunnel" "srt://:$srt" "tcp://127.0.0.1:$tcp" > tun-server.log 2>&1 &
          ts=$!
          sleep 1
          timeout 90 "$b/srt-tunnel" "tcp://:$lp" "srt://127.0.0.1:$srt" > tun-client.log 2>&1 &
          tc=$!
          sleep 1
          python3 - "$lp" <<'PY'
        import socket, sys, time
        s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=30)
        s.sendall(open("payload.bin", "rb").read()); s.shutdown(socket.SHUT_WR)
        time.sleep(3); s.close()
        PY
          wait "$sink" || true
          kill "$ts" "$tc" 2>/dev/null || true
          cmp -s payload.bin tunneled.bin || fail "srt-tunnel changed the TCP stream"
        '' + ''
          echo "installCheck: file transfer (clear and AES) and TCP tunnel arrived intact"
          runHook postInstallCheck
        '';
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
          # srt installs no man pages at all.
          { name = "srt-live-transmit"; noMan = true; }
          { name = "srt-file-transmit"; noMan = true; }
          # Upstream's CMake builds no srt-tunnel on mingw, so it must not be
          # announced on the .exe either — an applet the dispatcher can't reach.
          { name = "srt-tunnel"; noMan = true; supportedTarget = p: !(p.isMinGW or false); }
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
        withRoundTrip pkgs (withApps ((ulib.nativeFixes.srt sp).override { stdenv = eng; }));

      # mingw cross. No per-package stdenv swap: multicall.windows = true puts
      # the whole set on the engine adapter already.
      windowsBuild = pkgs:
        withApps (ulib.nativeFixes.srt (ulib.mingwStaticCross pkgs));
    };
}
