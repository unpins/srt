# Changelog

## [Unreleased]

## [1.5.4-2] - 2026-09-26

### Added

- On Linux, hostnames now resolve on a machine whose DNS resolver is missing or
  unreachable — Android, or a container with no `/etc/resolv.conf` — once you
  point unpins at a name server. Before, every lookup failed there and the
  stream never left the machine.

### Changed

- A program inside the binary is selected with `--unpin-program=<name>`:
  `srt --unpin-program=srt-live-transmit udp://:1234 srt://example.com:4201`.
  The positional form (`srt srt-live-transmit …`) is gone. The installed
  `srt-live-transmit`, `srt-file-transmit` and `srt-tunnel` commands are
  unaffected.

- The build moves data before the binary ships: a file goes through
  `srt-file-transmit` in the clear and AES-encrypted, and a TCP stream through
  `srt-tunnel`, and each copy must arrive byte-identical. It runs on every
  target the build host can execute. The check before this only ran `-version`.

- Built by the same compiler as the rest of the catalog. The Linux x86_64
  binary grew from 2.2 MB to 2.4 MB; behaviour is unchanged.
