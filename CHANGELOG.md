# Changelog

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
