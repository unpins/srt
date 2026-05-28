# srt

Standalone build of the [SRT](https://github.com/Haivision/srt) (Secure Reliable Transport) command-line apps.

[![Build](https://github.com/unpins/srt/actions/workflows/srt.yml/badge.svg)](https://github.com/unpins/srt/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

Low-latency, reliable transport of live streams over UDP. Ships as one multicall binary that dispatches to the upstream apps:

- `srt-live-transmit` — bridge a live stream between SRT and UDP/file/stdout.
- `srt-file-transmit` — transfer files over SRT.
- `srt-tunnel` — tunnel a TCP connection over SRT (Linux / macOS only).

Run an applet by name or via the dispatcher:

```bash
srt-live-transmit udp://:1234 srt://example:4201   # by name
srt live-transmit  udp://:1234 srt://example:4201   # via the srt dispatcher
```

## Installation

Install with [unpin](https://github.com/unpins/unpin):

```bash
unpin srt
```

Or run without installing:

```bash
unpin run srt -- srt-live-transmit --help
```

## Build locally

```bash
nix build github:unpins/srt
./result/bin/srt
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/srt/releases) page has standalone binaries for manual download.

## Build notes

- **Single multicall binary** — the three apps are post-linked into one `srt`; applet names are recreated as `argv[0]` shims on install.
- **mbedtls, not OpenSSL** — smaller crypto closure; AES-encrypted streams work unchanged.
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs. Ships 2 applets — upstream excludes `srt-tunnel` (no C++11 `<thread>`).

Platform fixes live in [`nix-lib/native-overlay/srt.nix`](https://github.com/unpins/nix-lib/blob/main/native-overlay/srt.nix); the multicall link recipe is in [`multicall.nix`](./multicall.nix).
