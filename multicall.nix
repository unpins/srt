# Upstream srt builds three separate app binaries — srt-live-transmit,
# srt-file-transmit and srt-tunnel (the latter dropped on MinGW: upstream
# CMakeLists excludes it for lack of C++11 <thread> headers). To honour the
# unpins one-pkg-one-bin rule we post-link them into a single multicall
# binary at $out/bin/srt; `lib.withAliases` then embeds the applet names as
# an UNPIN_META block so unpin's installer can recreate the argv[0] shims.
#
# Why a post-link route (no source patch): the shared app helpers (apputil,
# uriparser, socketoptions, logsupport, statswriter, transmitmedia, verbose)
# are already an `add_library(... OBJECT)` virtual library that CMake
# compiles ONCE and reuses for every app — so they DON'T collide. Each app's
# own translation unit only clashes on `main` (all apps) plus
# `OnINT_ForceExit(int)` (live + file define the same signal handler):
#
#   1. Let CMake build normally — every app .o lands under
#      CMakeFiles/<app>.dir/, the shared set under
#      CMakeFiles/srtsupport_virtual.dir/.
#   2. Rename each app's `main` → `<app>_main` (the dispatcher needs distinct
#      entry points), then localize the strong globals defined by ≥2 app
#      objects — the genuine duplicates (`OnINT_ForceExit`). This reads mangled
#      nm names directly, so it is robust for C++: the linker's clash report
#      uses demangled names (`OnINT_ForceExit(int)`) that don't round-trip to
#      the mangled symbol objcopy needs, and ld64's demangler isn't always on
#      PATH — that was the darwin link failure. Same approach as heif.
#   3. A small dispatcher.c (basename(argv[0]) → <app>_main, with an
#      `srt <applet> [args]` fallback) is compiled and linked in.
#   4. ONE link: reuse CMake's resolved link.txt for the first app verbatim
#      (exact compiler, flags, shared objects, libsrt.a and per-target deps —
#      mbedtls, -ldl/-latomic on linux, frameworks on darwin, winpthreads on
#      mingw — in the right order), splice in the other apps' objects +
#      dispatcher.o, retarget the output. No iterative pass — localize removed
#      the duplicates. `extraLinkFlags` folds the C++ runtime static on
#      windows/darwin (single-binary policy); the windows combined link runs
#      through lld (binutils 2.44 drops cxx11 COMDAT members in a PE link), and
#      darwin also hides the libc++ surface so dyld can't swap in the system
#      copy (TMO crash). Both are the same fixes heif uses.
{ lib }:
{ pkgs, srt, extraLinkFlags ? "" }:
let
  # mingw: the combined multicall link is driven through lld (-fuse-ld=lld, set
  # in windowsBuild) to dodge binutils 2.44's PE-COMDAT discard bug. The cross
  # gcc driver invokes `ld.lld` from PATH; only this combined link uses it
  # (CMake's per-app links keep binutils ld).
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  multicall = srt.overrideAttrs (old: {
    pname = "srt-multi";

    nativeBuildInputs = (old.nativeBuildInputs or [ ])
      ++ lib.optional isMinGW pkgs.buildPackages.lld;

    # Re-enable the apps the library overlay turns off, and collapse to a
    # single output (we ship only the multicall binary, no lib/headers/.pc).
    cmakeFlags =
      (builtins.filter (f: f != "-DENABLE_APPS=OFF") (old.cmakeFlags or [ ]))
      ++ [ "-DENABLE_APPS=ON" ];
    outputs = [ "out" ];
    # Drop the overlay's srt.pc sed (no .pc shipped). withAliases re-appends
    # its own postInstall on top of this empty one.
    postInstall = "";

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall

      # CMake emits .o on unix, .obj on mingw.
      objext=o
      [ -f "CMakeFiles/srt-live-transmit.dir/apps/srt-live-transmit.cpp.obj" ] && objext=obj

      # Present apps (existence gates MinGW's missing srt-tunnel).
      apps=()
      for a in srt-live-transmit srt-file-transmit srt-tunnel; do
        [ -f "CMakeFiles/$a.dir/apps/$a.cpp.$objext" ] && apps+=("$a")
      done
      [ ''${#apps[@]} -ge 1 ] || { echo "multicall: no srt apps built" >&2; exit 1; }
      printf '%s\n' "''${apps[@]}" > multicall/apps.list

      # Platform symbol prefix (Mach-O leads C symbols with '_'), read once
      # from the first app's main.
      obj0="CMakeFiles/''${apps[0]}.dir/apps/''${apps[0]}.cpp.$objext"
      if $NM --defined-only "$obj0" | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Each app's main .cpp defines file-scope strong globals under shared
      # names — `main` (all apps) and `OnINT_ForceExit` (live + file share the
      # same signal handler) — so linking the mains together clashes on more
      # than `main`. Rather than parse the linker's clash report (it prints
      # demangled C++ names like `OnINT_ForceExit(int)` that don't round-trip
      # back to the mangled nm symbol objcopy needs, and ld64's demangler isn't
      # always on PATH — that was the darwin failure), rename each main →
      # <app>_main, then localize ONLY the globals a tool object shares with
      # another (the genuine duplicates). Each app keeps a private copy; unique
      # globals and the weak/COMDAT C++ runtime symbols stay global so normal
      # resolution is untouched. Same approach as heif/multicall.nix.
      : > multicall/all.syms
      for a in "''${apps[@]}"; do
        san=$(echo "$a" | tr '-' '_')
        obj="CMakeFiles/$a.dir/apps/$a.cpp.$objext"
        entry="''${up}''${san}_main"
        $OBJCOPY --redefine-sym "''${up}main=$entry" "$obj"
        # Strong defs only: uppercase nm type, minus weak/COMDAT (W/V), the
        # entry point, and compiler helpers (a '.' in the name — never present
        # in a C/C++ program or mangled _Z… symbol).
        $NM --defined-only "$obj" \
          | awk -v keep="$entry" '$2 ~ /^[A-Z]$/ && $2 != "W" && $2 != "V" && $3 != keep && index($3,".")==0 {print $3}' \
          | sort -u >> multicall/all.syms
      done
      # Symbols defined by ≥2 apps are the real clashes; localize just those.
      sort multicall/all.syms | uniq -d > multicall/clash.syms
      if [ -s multicall/clash.syms ]; then
        for a in "''${apps[@]}"; do
          $OBJCOPY --localize-symbols=multicall/clash.syms \
            "CMakeFiles/$a.dir/apps/$a.cpp.$objext"
        done
      fi

      # Dispatcher: basename(argv[0]) → <app>_main, '.exe' stripped, plus an
      # `srt <applet> [args]` form so the bare binary stays callable.
      {
        echo '#include <string.h>'
        echo '#include <stdio.h>'
        for a in "''${apps[@]}"; do
          san=$(echo "$a" | tr '-' '_')
          echo "int ''${san}_main(int, char **);"
        done
        echo 'struct applet { const char *name; int (*fn)(int, char **); };'
        echo 'static const struct applet applets[] = {'
        for a in "''${apps[@]}"; do
          san=$(echo "$a" | tr '-' '_')
          echo "    {\"$a\", ''${san}_main},"
        done
        cat <<'CBODY'
    {0, 0}
};
static void copy_basename(char *dst, size_t cap, const char *src) {
    const char *p = src, *s;
    s = strrchr(p, '/'); if (s) p = s + 1;
#ifdef _WIN32
    s = strrchr(p, '\\'); if (s) p = s + 1;
#endif
    size_t n = strlen(p); if (n >= cap) n = cap - 1;
    memcpy(dst, p, n); dst[n] = 0;
    if (n > 4 && strcmp(dst + n - 4, ".exe") == 0) dst[n - 4] = 0;
}
static int usage(const char *a0) {
    fprintf(stderr, "srt: multicall binary; usage: %s <applet> [args]\n", a0);
    fprintf(stderr, "applets:");
    for (const struct applet *a = applets; a->name; a++)
        fprintf(stderr, " %s", a->name);
    fprintf(stderr, "\n");
    return 1;
}
int main(int argc, char **argv) {
    char base[64];
    const char *a0 = (argc > 0 && argv[0]) ? argv[0] : "srt";
    copy_basename(base, sizeof base, a0);
    if (strcmp(base, "srt") == 0) {
        if (argc < 2) return usage(a0);
        copy_basename(base, sizeof base, argv[1]);
        argv++; argc--;
    }
    for (const struct applet *a = applets; a->name; a++)
        if (strcmp(base, a->name) == 0) return a->fn(argc, argv);
    fprintf(stderr, "srt: unknown applet '%s'\n", base);
    return usage(a0);
}
CBODY
      } > multicall/dispatcher.c
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Reuse the first app's resolved link.txt verbatim (exact compiler, flags,
      # shared OBJECT-lib objects, libsrt.a and per-target deps in the right
      # order); splice in the other apps' own objects + dispatcher.o and rename
      # the output (the link.txt output token carries .exe on mingw, so split it
      # off — we always emit multicall/srt). The localize pass above made every
      # app object export only its <app>_main, so a SINGLE link suffices — no
      # iterative redefine, no demangling.
      template="''${apps[0]}"
      line=$(cat "CMakeFiles/$template.dir/link.txt")
      pre="''${line% -o *}"
      post="''${line#* -o }"
      oldname="''${post%% *}"
      libs="''${post#"$oldname"}"
      extra=""
      for a in "''${apps[@]:1}"; do
        extra="$extra CMakeFiles/$a.dir/apps/$a.cpp.$objext"
      done

      # darwin: we fold static libc++/libc++abi in via extraLinkFlags, but libc++
      # emits its symbols weak-external; at load dyld would coalesce them with the
      # macOS 15 system libc++ (which uses typed-memory-operations) and run system
      # code whose TMO static initializer never ran in our binary → abort. Hide the
      # whole libc++/libc++abi surface (-unexported_symbols_list) so dyld keeps OUR
      # static defs. An executable exports nothing, so this is safe. Same fix as
      # heif/multicall.nix; patterns cover the Itanium mangling of std:: / __cxxabiv1
      # / operators new+delete and their vtables/type_info.
      darwin_link_extra=""
      case "$($CC -dumpmachine)" in *darwin*)
        cat > multicall/unexport.syms <<'EOF'
        __Znw*
        __Zna*
        __Zdl*
        __Zda*
        __ZNSt*
        __ZNKSt*
        __ZNVSt*
        __ZSt*
        __ZTVSt*
        __ZTVNSt*
        __ZTISt*
        __ZTINSt*
        __ZTSSt*
        __ZTSNSt*
        __ZN10__cxxabiv1*
        __ZNK10__cxxabiv1*
        __ZTVN10__cxxabiv1*
        __ZTIN10__cxxabiv1*
        __ZTSN10__cxxabiv1*
EOF
        sed -i 's/^[[:space:]]*//' multicall/unexport.syms
        darwin_link_extra="-Wl,-unexported_symbols_list,$PWD/multicall/unexport.syms"
      ;; esac

      eval "$pre $extra multicall/dispatcher.o -o multicall/srt $libs $darwin_link_extra ${extraLinkFlags}" 2>multicall/link.err || {
        cat multicall/link.err >&2
        echo "multicall: combined link failed (unexpected strong duplicate left after localize?)" >&2
        exit 1
      }

      # mingw g++ auto-appends .exe to the link output; normalize to the
      # suffixless name installPhase and withAliases expect (the Windows
      # postFixup re-adds .exe after the UNPIN_META embed).
      [ -f multicall/srt ] || mv multicall/srt.exe multicall/srt
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 multicall/srt "$out/bin/srt"
      while IFS= read -r a; do
        [ -n "$a" ] && ln -s srt "$out/bin/$a"
      done < multicall/apps.list
      runHook postInstall
    '';
  });
  # withAliases harvests the applet symlinks, embeds them as UNPIN_META and
  # objcopies into `$out/bin/srt` (its `primary`). On mingw the shipped file
  # must be `srt.exe`; rename after the embed (symlinks are already gone by
  # then, so nothing dangles).
  aliased = lib.withAliases pkgs
    {
      primary = "srt";
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if pkgs.stdenv.hostPlatform.isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/srt" ] && mv "$out/bin/srt" "$out/bin/srt.exe"
  '';
})
else aliased
