# zfsbay

> CLI สำหรับจัดการ hot-swap ดิสก์ใน ZFS pool บน Dell PowerEdge ที่รัน Proxmox VE
> พร้อม PERC H730P / H750 / H755

## `zfsbay` คืออะไร

`zfsbay` เป็นเครื่องมือ Bash บนเครื่องเดียว (single-host, ไม่มี SSH ไม่มี daemon) ที่ออกแบบ
ให้ทีม ops ขนาดเล็กใช้ตอน "ดิสก์เสียกลางดึก" — เปลี่ยนดิสก์ใน bay ได้อย่างปลอดภัย ตรวจ
สุขภาพ ดู endurance ของ SSD เช็คความคืบหน้า resilver ทั้งหมดผ่านคำสั่งเดียว ไม่ต้องจำ
syntax ของ `perccli64` กับ `zpool` แยกกัน

ตัว tool ทำหน้าที่เป็น "shim" บางๆ บน 3 ชุดคำสั่งหลัก: **`perccli64`** (จัดการ PERC RAID
controller), **`smartctl`** (อ่าน SMART), และ **`zpool`/`zfs`** (จัดการ pool) โดย
จับคู่ bay ทางกายภาพ (เช่น `32:4`) เข้ากับ `/dev/disk/by-id/...` และ vdev ของ pool
อย่างถูกต้อง พร้อมเช็ค redundancy ก่อนทุกครั้งที่จะ offline ดิสก์ — ถ้าการถอดจะทำให้
pool ไม่มี redundancy เหลือ จะปฏิเสธทันที (ใช้ `--force` เพื่อข้าม)

## ความต้องการของระบบ

- Proxmox VE 8.x (หรือ Debian 12 base) บน Dell PowerEdge ที่มี PERC H730P / H730 / H740P / H750 / H755
- Bash 4.4+
- `perccli64` (จาก Dell support — ปกติอยู่ที่ `/opt/MegaRAID/perccli/perccli64`) หรือ `storcli64`
- `smartmontools` ≥ 7.3
- OpenZFS ≥ 2.2
- Tools: `jq`, `awk`, `sed`, `column`, `udevadm`, `lsblk`

ตรวจของให้ครบก่อน:

```bash
apt install -y jq smartmontools bsdmainutils
ls /opt/MegaRAID/perccli/perccli64    # ถ้าไม่มี ดาวน์โหลดจาก dell.com/support
zpool version | head -1
```

## การติดตั้ง

```bash
git clone <repo> zfsbay
cd zfsbay
sudo ./install.sh
```

`install.sh` จะวางไฟล์ตาม path มาตรฐาน:

| ปลายทาง | จาก |
|---|---|
| `/usr/local/sbin/zfsbay`     | `./zfsbay` |
| `/usr/local/lib/zfsbay/*.sh` | `./lib/` |
| `/etc/zfsbay.conf`           | `./etc/zfsbay.conf.example` (ไม่ทับของเดิม) |
| `/etc/bash_completion.d/zfsbay` | `./completions/zfsbay.bash` |
| `/var/log/zfsbay.log`        | สร้างใหม่ (mode 0640) |

หรือรันตรงจาก repo ก็ได้ (สำหรับ dev): `./zfsbay help`

## เริ่มเร็ว — Playbooks สำหรับเคสจริง

ดู [**SOLUTIONS.md**](SOLUTIONS.md) สำหรับ step-by-step ของ 3 เคสที่พบบ่อย — copy-paste ใช้บนหน้างานได้เลย:

1. **[Check status & วิเคราะห์](SOLUTIONS.md#1-check-status--วิเคราะห์-ว่าควรเปลี่ยนเมื่อไหร่)** — รู้ว่า pool ไหน/bay ไหนต้องสนใจ + เกณฑ์ตัดสินใจ
2. **[Proactive replace ผ่าน spare](SOLUTIONS.md#2-proactive-replace-โย้กไปใช้-spare-ก่อนดิสก์เสีย)** — ดิสก์ ENDUR ต่ำ ยังไม่เสีย แต่อยากเปลี่ยน
3. **[After spare takeover — เติม spare ใหม่](SOLUTIONS.md#3-after-spare-takeover-เติม-spare-ใหม่--แทน-disk-ที่เพิ่งใช้)** — หลัง spare ถูกใช้ → เปลี่ยนดิสก์เก่า + restore spare

ดู [MANUAL.md](MANUAL.md) สำหรับ reference ฉบับเต็ม

## คำสั่งย่อทั้งหมด

| คำสั่ง | หน้าที่ |
|---|---|
| `zfsbay pool status [<name>]`         | ดู ZFS pool ทั้งหมดหรือรายการเดียว |
| `zfsbay bay status [<N>]`             | ตารางทุก bay (BAY/SERIAL/DEVICE/STATE/HEALTH/ENDUR/POOL/VDEV) หรือรายละเอียด bay เดียว |
| `zfsbay bay <N> remove`               | offline จาก pool + เปิดไฟ locate + spindown ปลอดภัยที่จะถอด |
| `zfsbay bay <N> replace`              | หลังเสียบดิสก์ใหม่: ตรวจ foreign config, set good/jbod หรือสร้าง R0 VD, รัน `zpool replace` |
| `zfsbay bay <N> join pool <p> [as <m>]` | เพิ่มดิสก์ใหม่เข้า pool (`spare` / `mirror=<dev>` / `replace=<old>`) |
| `zfsbay check sync [bay <N>]`         | progress bar resilver — ทุก pool หรือ pool ที่ครอบ bay นั้น |
| `zfsbay locate <N> [on\|off]`         | เปิด/ปิดไฟ LED ที่ bay |
| `zfsbay version`                      | พิมพ์เวอร์ชัน |
| `zfsbay help [<sub>]`                 | ช่วยเหลือ |

### Global flags

| Flag | ความหมาย |
|---|---|
| `--json`              | output เป็น JSON (สำหรับ n8n / monitoring) |
| `-y`, `--yes`         | ตอบ y กับ confirm prompts ทั้งหมด |
| `--dry-run`           | พิมพ์คำสั่งที่จะรัน แต่ไม่รันจริง |
| `--no-color`          | ปิดสี ANSI |
| `-v`, `--verbose`     | echo คำสั่ง external ที่กำลังรัน |
| `-q`, `--quiet`       | แสดงเฉพาะ error |
| `--controller N`      | PERC controller index (default 0) |
| `--enclosure N`       | enclosure id (default: autodetect) |
| `--refresh`           | bypass in-memory cache |
| `--config <path>`     | ใช้ config file อื่น |
| `--force`             | ข้ามด่าน safety guard (ใช้ระวังๆ) |
| `--force-boot`        | อนุญาตให้ทำงานกับ rpool/ESP |
| `--clear-foreign`     | auto-clear PERC foreign config |
| `--delete-vd`         | ตอน remove ให้ลบ single-disk RAID0 VD ด้วย |

## ตัวอย่างการใช้งานจริง

### 1) ตรวจสุขภาพดิสก์ทุก bay ประจำเช้า

```bash
zfsbay bay status
```

ดูคอลัมน์ HEALTH% และ ENDUR% — สีแดงคือต่ำกว่าเกณฑ์ (default <50%) ค่าเริ่มต้นเตือน
เหลือง 50–79 และเขียว ≥80 (ปรับใน `/etc/zfsbay.conf`)

### 2) เปลี่ยนดิสก์ที่กำลังจะเสีย (proactive replace)

ดิสก์ bay 4 endurance เหลือ 12% ต้องการเปลี่ยนก่อนตาย:

```bash
zfsbay bay 4 remove                       # offline + locate LED + spindown
# (ถอดดิสก์เก่า เสียบใหม่)
zfsbay bay 4 replace                      # set jbod/r0 + zpool replace
zfsbay check sync bay 4                   # ดูความคืบหน้า resilver
```

### 3) กู้สถานการณ์เมื่อดิสก์ตายกลางดึก

ZFS แจ้ง pool DEGRADED เพราะดิสก์ FAULTED แล้ว:

```bash
zfsbay pool status                                # ยืนยันว่า pool DEGRADED จริง
zfsbay bay status                                 # หา bay ที่ STATE = UBad/Failed
zfsbay bay 3 remove --force-boot                  # ถ้าเป็น rpool ต้องใส่ flag นี้
# (ถอดเก่า เสียบใหม่)
zfsbay bay 3 replace
zfsbay check sync                                 # progress bar
```

### 4) เพิ่มดิสก์ใหม่เป็น hot spare

มี bay ว่างอยู่ที่ 2 ต้องการใส่ดิสก์เพิ่มเป็น spare ของ pool `tank`:

```bash
# เสียบดิสก์ที่ bay 2
zfsbay bay 2 join pool tank as spare
```

ต้องการแบบ mirror กับดิสก์เดิม:

```bash
zfsbay bay 2 join pool tank as mirror=/dev/disk/by-id/wwn-0x5000c5006b1a4fb8
```

### 5) เช็คความคืบหน้าหลัง resilver

```bash
zfsbay check sync
# tank: [############..................] 38.7% — 02:14:33 to go — 580G / 1.5T
```

หรือเฉพาะ pool ที่ครอบ bay 4:

```bash
zfsbay check sync bay 4
```

## JSON output สำหรับ n8n / monitoring

ทุก subcommand รองรับ `--json`:

```bash
zfsbay --json bay status | jq '.bays[] | select(.endurance_pct != null and .endurance_pct < 30)'
```

ส่ง `--json check sync` เข้า n8n cron 5 นาทีเพื่อ alert เมื่อมี resilver:

```bash
zfsbay --json check sync \
  | jq -e '.pools[] | select(.resilver.in_progress)' >/dev/null \
  && curl -X POST $N8N_WEBHOOK -d "$(zfsbay --json check sync)"
```

Schema ของ `bay status`:

```json
{
  "controller": 0, "enclosure": 32,
  "bays": [
    {
      "bay": "32:0", "slot": 0, "did": 7, "wwn": "...", "serial": "...",
      "model": "...", "size_bytes": 480103981056,
      "interface": "SATA", "media": "SSD",
      "perc_state": "Onln", "perc_jbod": false, "perc_vd": 0,
      "kernel_device": "/dev/sdb", "by_id": "/dev/disk/by-id/wwn-...",
      "smart_overall": "PASSED", "health_pct": 98, "endurance_pct": 97,
      "used_bytes": null, "total_bytes": 480103981056,
      "pool": "rpool", "vdev": "mirror-0", "vdev_state": "ONLINE"
    }
  ]
}
```

## Troubleshooting

| อาการ | สาเหตุที่พบบ่อย / วิธีแก้ |
|---|---|
| `ไม่พบ perccli64 / storcli64` | ดาวน์โหลดจาก dell.com/support → ติดตั้งใน `/opt/MegaRAID/perccli/` หรือชี้ env `PERCCLI=/path/to/perccli64` |
| `ตรวจไม่พบ enclosure อัตโนมัติ` | มีหลาย enclosure / multiple controllers — ระบุ `--controller 0 --enclosure 32` |
| `ห้ามถอด: vdev ... จะเหลือ healthy=N` | กำลังจะเสีย redundancy — รอ resilver ของ peer ที่กำลัง degraded ให้เสร็จก่อน หรือใช้ `--force` ถ้ามั่นใจ |
| `Foreign config detected` | ดิสก์เคยอยู่บน controller อื่น — ตอบ `y` หรือรันด้วย `--clear-foreign` |
| `ashift mismatch` | ดิสก์ใหม่ phy-sec 512 vs pool ashift=12 (4K) — ใช้ `--force` ถ้ายอมรับการเสียประสิทธิภาพ |
| Resilver ไม่ขึ้นใน `check sync` | ตรวจเวอร์ชัน OpenZFS (รองรับ 0.8 / 2.0 / 2.2). ถ้าใหม่กว่านั้น ส่ง issue พร้อม output ของ `zpool status -P -v` |
| Drive visible ที่ kernel แต่ pool ใช้ /dev/sdX (ไม่ใช่ by-id) | export pool แล้ว `zpool import -d /dev/disk/by-id <pool>` |
| `zfsbay bay status` ช้า | ครั้งแรกอ่าน SMART หลายดิสก์อาจช้า 5–10 วินาที — `--refresh` จะ bypass cache |

## คำเตือนเรื่อง rpool / boot pool

`zfsbay` ตรวจ rpool / ESP จาก `proxmox-boot-tool status`. ถ้า bay ที่จะถอดอยู่บน
rpool **เครื่องมือจะปฏิเสธ** จนกว่าจะใส่ `--force-boot`.

หลัง `bay <N> replace` บนดิสก์ rpool **ต้องเตรียม ESP ด้วยตนเอง**:

```bash
proxmox-boot-tool format /dev/disk/by-id/<new>-part2 --force
proxmox-boot-tool init   /dev/disk/by-id/<new>-part2
proxmox-boot-tool refresh
```

`zfsbay` จะไม่ทำขั้นตอนนี้ให้ — เพราะมีโอกาสพังเครื่องสูงถ้าจัดการอัตโนมัติ

---

License: MIT  ·  Issues: เปิดใน repo  ·  Logs: `/var/log/zfsbay.log`
