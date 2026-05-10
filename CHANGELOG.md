# Changelog

## 0.2.0 — 2026-05-10

Significant field-validated release. After running 0.1.0 against eight live
Proxmox hosts (pve-r22/24/25/26/27/29/30/31), the parser/matcher gaps and the
missing proactive-replace workflow surfaced — this release closes them and
adds the on-site documentation the team actually needed.

### Features

- **`bay <N> swap-to-spare [--watch]`** — `zpool replace` the bay's drive
  with an AVAIL hot spare, optionally blocking with a refreshing progress
  bar until resilver completes. After resilver the spare permanently
  becomes the vdev member (no manual `zpool detach` needed) and the bay
  is safe to physically swap. Use this for proactive replacement of a
  still-healthy disk before its endurance hits the floor.
- **`check sync --watch`** — in-place refreshing progress display until
  all resilvers finish. Same redraw used by swap-to-spare.
- **`--fast`** — skip per-bay SMART probing in `bay status` so the static
  columns (BAY/SERIAL/DEVICE/STATE/POOL/VDEV) render instantly even on
  hosts where smartctl stalls behind PERC.
- **`install.sh` now auto-installs bundled vendor/perccli/*.deb** on
  Debian-based hosts when perccli64 isn't already present, and adds the
  `PERCCLI=` line to `/etc/zfsbay.conf` only when not already set.
  Skip with `--skip-perccli`.
- **Bundled Dell PERCCLI 7.1623** (.deb + .rpm) under `vendor/perccli/`
  so a fresh `git clone` is enough — no separate download from Dell.

### Fixes

- **Real perccli JSON layout** — the on-disk schema is `Drive /cN/eM/sK`
  per drive plus a sibling `- Detailed Information` object, not the
  `Drive Information` array our 0.1.0 fixture assumed. The new parser
  merges them so WWN / SN / Media Error Count are reachable at the top
  level. Falls back to the old layout when present.
- **SAS drive matching** — register every udev serial-ish field
  (ID_SERIAL, ID_SERIAL_SHORT, ID_SCSI_SERIAL) into DEV_BY_SERIAL, plus
  the dual-port WWN sibling (last hex digit XOR 1). SAS SSDs behind PERC
  now populate DEVICE/POOL/VDEV — they used to show `-` because PERC's
  WWN port differed from the kernel's by one digit, and udev's
  ID_SERIAL_SHORT was a WWN suffix rather than the product serial.
- **Partition → whole-disk match in the pool walker** — pools that put
  different partitions of one SSD into different vdevs (e.g. rpool with
  `-part1` in mirror logs, `-part2` in cache, `-part3` in raidz) now
  attribute the bay to its primary pool/vdev instead of leaving it blank.
- **`run_cmd` executes read-only queries under `--dry-run`** — previously
  it skipped, which made `--dry-run` itself unusable (perccli enclosure
  autodetect returned empty so resolve_bay refused).
- **`cmd_bay_{remove,replace,join,locate}` call `check_deps` before
  `resolve_bay`** so PERCCLI_BIN is set when enclosure autodetect runs.
- **smartctl wall-clock cap** — every smartctl call wrapped in
  `timeout 8s` (configurable via `ZFSBAY_SMART_TIMEOUT`). Drives that
  stall don't block the whole `bay status` table.
- **`--clear-foreign` no longer blocks on confirm prompt** during dry-run.
- **`BYID_FOR_DEV` lookups guarded against empty subscript** — bash was
  aborting `bay status` with "bad array subscript" when a PD had no
  matching kernel device yet (foreign-config or freshly-inserted disk).

### Docs

- **`SOLUTIONS.md`** — three on-site playbooks: check-status & analyze
  (which value to look at, when to act), proactive swap-to-spare, and
  the after-takeover flow that physically replaces the freed drive and
  refills the spare slot. Each playbook ends with a printable rack
  cheat-sheet, and the doc closes with a decision tree that routes from
  "ดิสก์มีปัญหา?" to the right playbook.
- **`MANUAL.md` 3.6 swap-to-spare** + 3.7 `check sync --watch`, runbook
  4.2.1 covering the proactive-via-hot-spare path.
- **`MANUAL.md` 2.1.1**: three install paths for PERCCLI/StorCLI —
  bundled Dell .deb (Proxmox 7), hwraid bookworm repo (Proxmox 8),
  Broadcom StorCLI (non-Dell).
- **README.md** points at SOLUTIONS.md as the primary on-site reference.

## 0.1.0 — 2026-05-10

Initial release.

- Single-host CLI for managing ZFS drives behind Dell PERC controllers on Proxmox VE 8.
- Subcommands: `bay status`, `bay <N> remove|replace|join`, `pool status`, `check sync`, `locate`.
- Resolves bay → DID → WWN → /dev/sdX → /dev/disk/by-id → ZFS vdev with in-memory caching.
- Endurance % parsing for Intel/Samsung/Micron/Kingston SATA SSDs, SAS SSDs (`-l ssd`), and NVMe.
- Heuristic health % from SMART overall + reallocated/pending/CRC counts and PERC PD error counters.
- Resilver progress parser tested against OpenZFS 0.8, 2.x, and 2.2 phrasings.
- Safety guards: redundancy floor check, active-resilver lockout, rpool detection via `proxmox-boot-tool`,
  ashift compatibility, capacity check, foreign-config detection.
- `--json` mode on every subcommand for n8n / monitoring integration.
- `--dry-run` mode prints state-changing commands without executing them.
- Bash 4.4+ only; pure Bash + standard Unix tools (jq, awk, sed, udevadm, lsblk, smartctl, perccli64).
