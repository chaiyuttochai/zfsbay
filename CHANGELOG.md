# Changelog

## Unreleased

- New: `bay <N> swap-to-spare [--watch]` — `zpool replace` the bay's drive
  with an AVAIL hot spare, optionally blocking with a refreshing progress
  bar until resilver completes. After resilver the spare is permanently the
  vdev member (no manual `zpool detach` needed) and the bay is safe to
  physically swap.
- New: `--watch` (alias `--wait`) flag on `check sync` for in-place
  refreshing progress display until all resilvers finish.
- Fix: `run_cmd` now executes read-only queries even under `--dry-run`
  (previously, planning a state change was impossible because the perccli
  enclosure autodetect ran with empty output).
- Fix: `cmd_bay_{remove,replace,join,locate}` run `check_deps` before
  `resolve_bay`, so PERCCLI_BIN is set when enclosure autodetect runs.
- Fix: SAS drive matching — register every udev serial-ish field
  (ID_SERIAL, ID_SERIAL_SHORT, ID_SCSI_SERIAL) and the dual-port WWN
  sibling (XOR-1 last hex digit), so SAS SSDs behind PERC populate
  DEVICE/POOL/VDEV columns.
- Fix: pool walker now resolves partition paths back to their whole disk
  (`/dev/sdaN` → `/dev/sda`), so SSDs whose partitions sit in different
  vdevs (rpool's mirror logs/cache) get attributed to the correct bay.
- Fix: guard empty-subscript lookups against `BYID_FOR_DEV` to avoid
  bash "bad array subscript" abort when a PD has no kernel device yet.
- Fix: real perccli JSON layout is `Drive /cN/eM/sK` per drive plus a
  sibling `- Detailed Information` object — merge them so WWN/SN/Media
  Error Count are reachable at the top level.
- Doc: bundled Dell PERCCLI 7.1623 (.deb + .rpm) under `vendor/perccli/`
  for offline install on Proxmox.

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
