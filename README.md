# srt

The [SRT](https://github.com/Haivision/srt) (Secure Reliable Transport) command-line apps, as a single self-contained binary built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/srt/actions/workflows/srt.yml/badge.svg)](https://github.com/unpins/srt/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install srt`.

Low-latency, reliable transport of live streams over UDP. Ships as one binary providing the upstream apps:

- `srt-live-transmit` — bridge a live stream between SRT and UDP/file/stdout.
- `srt-file-transmit` — transfer files over SRT.
- `srt-tunnel` — tunnel a TCP connection over SRT (Linux / macOS only).

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin srt --unpin-program=srt-live-transmit udp://:1234 srt://example.com:4201
unpin srt --unpin-program=srt-file-transmit file:///path/to/video.ts srt://example.com:4201
```

Or install them and call each by name, which is usually what you want:

```bash
unpin install srt
srt-live-transmit udp://:1234 srt://example.com:4201
```

`unpin install srt` creates the `srt-live-transmit`, `srt-file-transmit` and `srt-tunnel` commands (`srt-tunnel` on Linux and macOS only).

## Build locally

```bash
nix build github:unpins/srt
./result/bin/srt --unpin-program=srt-live-transmit -version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/srt/releases) page has standalone binaries for manual download.

## Build notes

- **One binary, `srt`,** holds the programs; `unpin install` creates a command for each.
- **Encryption uses mbedtls** instead of OpenSSL; AES-encrypted streams (`passphrase=`) work unchanged.
- **Windows:** a single `.exe`, no companion DLLs, with `srt-live-transmit` and `srt-file-transmit` — upstream doesn't build `srt-tunnel` for Windows.
- **No man pages** — SRT ships none; run a program with `-help`.
