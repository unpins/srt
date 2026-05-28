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
# `OnINT_ForceExit(int)` (live + file define the same signal handler). A
# per-app `objcopy --redefine-sym` (single-form, the only form llvm-objcopy
# honours on Mach-O too) dissolves the set without touching the shared
# objects:
#
#   1. Let CMake build normally — every app .o lands under
#      CMakeFiles/<app>.dir/, the shared set under
#      CMakeFiles/srtsupport_virtual.dir/.
#   2. Rename each app's `main` → `<app>_main` (the one clash known a priori;
#      the dispatcher needs distinct entry points anyway).
#   3. A small dispatcher.c (basename(argv[0]) → <app>_main, with an
#      `srt <applet> [args]` fallback) is compiled and linked in.
#   4. Link iteratively: reuse CMake's resolved link.txt for the first app
#      verbatim (exact compiler, flags, shared objects, libsrt.a and
#      per-target deps — mbedtls, -ldl/-latomic on linux, frameworks on
#      darwin, winpthreads on mingw — in the right order), splice in the other
#      apps' own objects + dispatcher.o, and rename the output. Each failed
#      link names the remaining *strong* duplicates; we rename those per-app
#      and relink. We trust the linker rather than predict clashes from nm:
#      on COFF, nm reports COMDAT defs (typeinfo, vtables, `.refptr` thunks)
#      as strong R/T, indistinguishable from real clashes, while the linker
#      merges them silently. `extraLinkFlags` lets the Windows build force the
#      C++ runtime static (single-binary policy).
{ lib }:
{ pkgs, srt, extraLinkFlags ? "" }:
let
  multicall = srt.overrideAttrs (old: {
    pname = "srt-multi";

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

      # Rename each app's main → <app>_main so the dispatcher can reach them as
      # distinct entry points. main is the one clash known a priori; any others
      # are discovered from the linker in the iterative link below.
      for a in "''${apps[@]}"; do
        san=$(echo "$a" | tr '-' '_')
        $OBJCOPY --redefine-sym "''${up}main=''${up}''${san}_main" \
          "CMakeFiles/$a.dir/apps/$a.cpp.$objext"
      done

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

      # Iterative link. Reuse the first app's resolved link.txt verbatim (exact
      # compiler, flags, shared OBJECT-lib objects, libsrt.a and per-target
      # deps in the right order); splice in the other apps' own objects +
      # dispatcher.o and rename the output (the link.txt output token carries
      # .exe on mingw, so split it off — we always emit multicall/srt).
      #
      # Each failed attempt names the *strong* duplicate symbols ("multiple
      # definition" / "duplicate symbol"); weak/COMDAT defs merge silently. We
      # trust the linker rather than predict from nm because on COFF nm reports
      # COMDAT (typeinfo, vtables, .refptr thunks) as strong R/T, indistinct
      # from real clashes. Rename each reported symbol in every app that
      # defines it, then relink. -Wl,--no-demangle makes GNU ld print mangled
      # names objcopy can consume (ld64 already prints raw symbols). For srt
      # this converges in two passes: OnINT_ForceExit(int), shared by srt-live
      # and srt-file, is the only clash beyond main.
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
      nodemangle=-Wl,--no-demangle
      case "$($CC -dumpmachine)" in *darwin*) nodemangle="" ;; esac

      # Demangler to map the linker's reported clash back to the raw nm symbol
      # objcopy needs. GNU ld prints mangled names (--no-demangle above); ld64
      # always prints demangled and has no flag to stop it, so each clash is
      # matched against both the raw nm symbol and its demangled form. The
      # toolchain ships the demangler next to nm.
      nmdir=$(dirname "$(command -v ''${NM%% *})")
      demangle=cat
      for c in c++filt llvm-cxxfilt; do
        if [ -x "$nmdir/$c" ]; then demangle="$nmdir/$c"; break; fi
        command -v "$c" >/dev/null 2>&1 && { demangle=$c; break; }
      done

      converged=0
      for _ in $(seq 1 30); do
        if eval "$pre $extra multicall/dispatcher.o -o multicall/srt $libs $nodemangle ${extraLinkFlags}" 2>multicall/link.err; then
          converged=1; break
        fi
        cat multicall/link.err >&2
        sed -nE "s/.*multiple definition of [\`']([^']+)'.*/\1/p; s/.*duplicate symbol '([^']+)'.*/\1/p" \
          multicall/link.err | sort -u > multicall/clash.syms
        [ -s multicall/clash.syms ] || { echo "multicall: link failed without a duplicate-symbol diagnostic" >&2; exit 1; }
        while IFS= read -r sym; do
          hit=0
          for a in "''${apps[@]}"; do
            obj="CMakeFiles/$a.dir/apps/$a.cpp.$objext"
            $NM --defined-only "$obj" | awk '{print $3}' > multicall/raw.syms
            # ld64 demangles after stripping the Mach-O leading '_'; mirror that
            # so the demangled column matches its report (a no-op on ELF, where
            # the raw column matches the mangled report instead).
            sed 's/^_//' multicall/raw.syms | $demangle > multicall/dem.syms
            raw=$(paste multicall/raw.syms multicall/dem.syms \
                  | awk -F'\t' -v s="$sym" '$1==s || $2==s {print $1; exit}')
            [ -n "$raw" ] || continue
            san=$(echo "$a" | tr '-' '_')
            $OBJCOPY --redefine-sym "$raw=''${up}''${san}__''${raw#"$up"}" "$obj"
            hit=1
          done
          [ "$hit" = 1 ] || { echo "multicall: clashing symbol '$sym' not defined by any app object" >&2; exit 1; }
        done < multicall/clash.syms
      done
      [ "$converged" = 1 ] || { echo "multicall: link did not converge in 30 passes" >&2; exit 1; }

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
