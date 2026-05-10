# คู่มือใช้งาน zfsbay

> คู่มือฉบับ ops engineer สำหรับ `zfsbay` v0.1.0
> เป้าหมาย: เปิดอ่านครั้งเดียวแล้วใช้งานได้ทุกเคส รวมทั้งตอนตี 3

---

## สารบัญ

1. [แนวคิดและคำศัพท์](#1-แนวคิดและคำศัพท์)
2. [ติดตั้งและคอนฟิก](#2-ติดตั้งและคอนฟิก)
3. [คำสั่งทุกตัวพร้อมตัวอย่าง](#3-คำสั่งทุกตัวพร้อมตัวอย่าง)
4. [Runbooks (เคสจริง)](#4-runbooks-เคสจริง)
5. [Safety Guards: เคสที่ tool จะปฏิเสธ](#5-safety-guards-เคสที่-tool-จะปฏิเสธ)
6. [Troubleshooting](#6-troubleshooting)
7. [JSON output schema](#7-json-output-schema)
8. [Internals (สำหรับ debug ลึก)](#8-internals-สำหรับ-debug-ลึก)
9. [Cheat Sheet](#9-cheat-sheet)

---

## 1. แนวคิดและคำศัพท์

### `zfsbay` ทำอะไร

`zfsbay` คือ wrapper ที่ผูก 3 layer เข้าด้วยกัน:

```
PERC controller    →   Linux kernel       →   ZFS pool
(perccli64)            (/dev/disk/by-id)      (zpool)
   ↑ bay 32:4              ↑ /dev/sdc            ↑ tank/raidz1-0
   └─────────────── จับคู่ผ่าน WWN / Serial ─────────┘
```

ปกติคุณต้องจำ syntax 3 ชุดและรันคำสั่ง 5–8 บรรทัดต่อการเปลี่ยนดิสก์ 1 ลูก
`zfsbay` ย่อให้เหลือ `zfsbay bay 4 remove` → ถอด → `zfsbay bay 4 replace`

### คำศัพท์ที่ต้องเข้าใจ

| คำ | หมายความ |
|---|---|
| **Bay** | ช่องเสียบดิสก์ทางกายภาพบน chassis เช่น "bay 4" หมายถึง slot 4 บน enclosure (backplane) |
| **EID:Slt** | Enclosure ID + Slot — ตำแหน่งที่ PERC รายงาน เช่น `32:4` = enclosure 32 slot 4 |
| **DID** | Device ID ภายในของ PERC ใช้สำหรับ `smartctl -d megaraid,<DID>` |
| **WWN** | World Wide Name — id เฉพาะของดิสก์ (16 hex chars) ใช้จับคู่ระหว่าง PERC กับ kernel |
| **VD** | Virtual Drive — ของ PERC mode RAID (single-disk RAID0 หรือ RAID1/5/6/10) |
| **JBOD** | "Just a Bunch of Disks" — PERC ให้ kernel เห็นดิสก์ตรงๆ ไม่ผ่าน VD |
| **vdev** | vdev ของ ZFS เช่น `mirror-0`, `raidz1-0`, `replacing-2` |
| **resilver** | กระบวนการ rebuild ของ ZFS หลัง replace |
| **rpool** | pool ที่บูตเครื่อง (ปกติชื่อ `rpool` บน Proxmox) |

### โหมดของ PERC controller

PERC แต่ละรุ่นรันได้ 2 โหมด — `zfsbay` ตรวจอัตโนมัติและเลือก path ที่ถูกต้อง:

- **HBA / eHBA / non-RAID mode**: PERC ให้ kernel เห็น disk ตรงๆ → ใช้ `set jbod` ตอน replace
- **RAID mode**: ทุกดิสก์ต้องอยู่ใน VD → `zfsbay` สร้าง single-disk RAID0 VD ให้ตอน replace

---

## 2. ติดตั้งและคอนฟิก

### 2.1 Prerequisite

```bash
# Tools พื้นฐาน
apt install -y jq smartmontools bsdmainutils

# perccli64 — ถ้ายังไม่มี ดาวน์โหลดจาก dell.com/support
ls /opt/MegaRAID/perccli/perccli64

# ZFS (Proxmox มาให้แล้ว)
zpool version
```

### 2.2 ติดตั้ง

```bash
git clone <repo> /opt/zfsbay   # หรือ scp มา
cd /opt/zfsbay
sudo ./install.sh
```

ตรวจ:
```bash
zfsbay version          # → zfsbay 0.1.0
zfsbay help             # ดู subcommand ทั้งหมด
```

### 2.3 Config: `/etc/zfsbay.conf`

ค่า default ทำงานได้ทันทีโดยไม่ต้องแก้ ปรับได้ถ้าต้องการ:

```bash
PERCCLI="/opt/MegaRAID/perccli/perccli64"  # path ของ perccli
DEFAULT_CONTROLLER=0                        # PERC ตัวที่ 0
DEFAULT_ENCLOSURE=                          # blank = autodetect
LOG_FILE="/var/log/zfsbay.log"

# threshold สี (% — ต่ำกว่านี้สีเหลือง, ต่ำกว่ายิ่งน้อยสีแดง)
COLOR_HEALTH_GREEN_MIN=80
COLOR_HEALTH_YELLOW_MIN=50
COLOR_ENDURANCE_GREEN_MIN=80
COLOR_ENDURANCE_YELLOW_MIN=50

# รูปแบบของ /dev/disk/by-id ที่จะใช้ตอนเพิ่มดิสก์เข้า pool
# auto = ตามที่ pool ใช้อยู่ / wwn / by-id-ata / by-id-scsi
PREFER_ZFS_PATH_FORM="auto"

# ถ้าตั้ง 1 → ทุกคำสั่ง state-changing default = dry-run
DRY_RUN_DEFAULT=0
```

### 2.4 Bash completion

ติดตั้งแล้ว autocompletion ใช้งานได้ทันที (เปิด shell ใหม่):
```bash
zfsbay <TAB>             # → bay check locate pool version help
zfsbay bay <TAB>         # → status 0 1 2 3 ...
zfsbay bay 4 <TAB>       # → remove replace join
```

---

## 3. คำสั่งทุกตัวพร้อมตัวอย่าง

### 3.1 `zfsbay bay status`

ดูตารางทุก bay:

```
$ zfsbay bay status
BAY   SERIAL          DEVICE                                ID    STATE  HEALTH%  ENDUR%  USED/TOTAL    POOL    VDEV
32:0  S4YUNX0M123456  /dev/disk/by-id/wwn-0x55cd2e404b9...   sda  Onln   98       97      -/447G        rpool   mirror-0
32:1  ZA1234ABC       /dev/disk/by-id/wwn-0x5002538b00...   sdb  Onln   100      88      -/447G        rpool   mirror-0
32:2  -               -                                      -    UGood  N/A      N/A     -/447G        -       -
32:3  Z1Z9999         -                                      -    UBad   10       N/A     -/4.0T        -       -
32:4  Z1Z1234         /dev/disk/by-id/wwn-0x5000c5006b1...   sdc  Onln   100      N/A     -/4.0T        tank    raidz2-0
```

ดู bay เดียว (รายละเอียดทั้งหมด):
```bash
zfsbay bay 4 status         # หรือ zfsbay bay status 32:4
```

**สี:**
- HEALTH%/ENDUR%: เขียว ≥80, เหลือง 50–79, แดง <50, dim สำหรับ N/A
- STATE: เขียว=Onln, แดง=UBad/Failed, เหลือง=Rbld/Frgn, dim=UGood

### 3.2 `zfsbay pool status [<pool>]`

```bash
zfsbay pool status                    # ทุก pool
zfsbay pool status rpool              # pool เดียว verbose (`zpool status -P -v`)
```

### 3.3 `zfsbay bay <N> remove`

ขั้นตอนที่ทำให้:
1. ตรวจ redundancy ของ vdev ที่ bay นั้นอยู่ — ถ้าจะเสียทั้งหมด → ปฏิเสธ
2. ตรวจ resilver — ถ้ากำลัง resilver อยู่ → ปฏิเสธ
3. ตรวจ rpool — ถ้าใช่ ต้องใส่ `--force-boot`
4. `zpool offline <pool> <device>`
5. ยืนยันสถานะเป็น OFFLINE
6. `perccli64 /cN/eM/sK start locate` (เปิดไฟ)
7. (ถ้าใส่ `--delete-vd`) ลบ single-disk RAID0 VD
8. `perccli64 /cN/eM/sK spindown`

```bash
# ปกติ
zfsbay bay 4 remove

# Pool ของ boot (rpool)
zfsbay bay 0 remove --force-boot

# ดิสก์ตายแล้ว pool degraded แต่ยังต้องการถอด (ข้าม redundancy guard)
zfsbay bay 3 remove --force

# ลบ VD ด้วย (สำหรับ controller mode RAID)
zfsbay bay 4 remove --delete-vd

# ทดสอบก่อน
zfsbay --dry-run bay 4 remove
```

### 3.4 `zfsbay bay <N> replace`

หลังเสียบดิสก์ใหม่ลง bay เดิม:
1. ตรวจ foreign config — ถ้ามี → ถาม (หรือใช้ `--clear-foreign`)
2. ตรวจ peer ใน pool ใช้ JBOD หรือ R0 VD → ทำตาม
   - JBOD: `set good force` → `set jbod`
   - RAID: `set good force` → `add vd r0 drives=M:K`
3. รอให้ kernel เห็นดิสก์ใหม่ (timeout 60 วิ)
4. หา device path ที่ถูกฟอร์ม (wwn-* / ata-* / scsi-*)
5. ตรวจ ashift compatibility
6. `zpool replace <pool> <old> <new>`
7. ปิดไฟ locate

```bash
zfsbay bay 4 replace                    # ปกติ
zfsbay bay 4 replace --clear-foreign    # auto-clear foreign config
zfsbay bay 4 replace --force            # ข้าม ashift mismatch
zfsbay --dry-run bay 4 replace          # ดูคำสั่งที่จะรัน
```

### 3.5 `zfsbay bay <N> join pool <pool> [as <mode>]`

เพิ่มดิสก์ใหม่ที่ยังไม่อยู่ใน pool ใดๆ:

```bash
# spare (default)
zfsbay bay 2 join pool tank
zfsbay bay 2 join pool tank as spare

# mirror กับดิสก์เดิม
zfsbay bay 2 join pool tank as mirror=/dev/disk/by-id/wwn-0x5000c5006b1a4fb8

# replace ดิสก์ที่ FAULTED อยู่ (กรณีดิสก์ใหม่อยู่คนละ bay กับเก่า)
zfsbay bay 2 join pool tank as replace=/dev/disk/by-id/wwn-0x5000c5006b1afff8/old
```

### 3.6 `zfsbay check sync [bay <N>]`

```bash
$ zfsbay check sync
tank: [######........................] 19.55% — unknown to go — 900G / 2.34T
rpool: no resilver

$ zfsbay check sync bay 4
tank: [######........................] 19.55% — 03:14:15 to go — 900G / 2.34T
```

ใช้ดู progress ของ resilver ของ ZFS รวมทั้ง rebuild ของ PERC (กรณี VD)

### 3.7 `zfsbay locate <N> [on|off]`

```bash
zfsbay locate 4              # = on
zfsbay locate 4 on
zfsbay locate 4 off
```

ใช้ "หา bay" ก่อนถอดดิสก์ — ไม่จำเป็นใน workflow `remove` (เปิดให้อัตโนมัติ)

### 3.8 Global flags

| Flag | ใช้เมื่อ |
|---|---|
| `--json` | ส่ง output ให้ monitoring / script |
| `-y, --yes` | ตอบ y กับ prompt ทุกอัน (ใช้ในสคริปต์) |
| `--dry-run` | ทดสอบก่อนรันจริง — ไม่เปลี่ยน state ใดๆ |
| `--no-color` | ปิดสี (auto-disabled ตอน output ไม่ใช่ TTY) |
| `-v, --verbose` | echo คำสั่ง external ที่กำลังรัน |
| `-q, --quiet` | แสดงเฉพาะ error |
| `--controller N` | PERC ตัวที่ N (default 0) |
| `--enclosure M` | enclosure id (default: autodetect) |
| `--refresh` | bypass in-memory cache, query perccli ใหม่ |
| `--config <path>` | ใช้ config อื่น |
| `--force` | ข้าม redundancy guard / ashift / capacity check |
| `--force-boot` | ทำงานกับ rpool ได้ |
| `--clear-foreign` | auto-clear foreign config |
| `--delete-vd` | ตอน remove ลบ R0 VD ด้วย |

---

## 4. Runbooks (เคสจริง)

### 4.1 ✅ ตรวจสุขภาพดิสก์ประจำเช้า

```bash
# 1. ดูภาพรวม
zfsbay bay status

# 2. หา outlier
zfsbay --json bay status \
  | jq '.bays[] | select(.endurance_pct != null and .endurance_pct < 30)'

# 3. ดู pool health
zfsbay pool status
```

### 4.2 🔧 Proactive replace — ดิสก์ endurance เหลือน้อย

ดิสก์ bay 4 endurance เหลือ 12% ต้องเปลี่ยนก่อนตาย:

```bash
# 1. ยืนยัน pool ยังแข็งแรง (ไม่มี vdev อื่นเสียร่วม)
zfsbay bay status
zfsbay pool status

# 2. (แนะนำ) dry-run ดูคำสั่งที่จะรัน
zfsbay --dry-run bay 4 remove

# 3. remove จริง
zfsbay bay 4 remove
# Output: "✔ ไฟ LED ติดที่ bay 32:4 แล้ว ปลอดภัยที่จะถอดดิสก์ออก"

# 4. ไปหน้า rack ถอดดิสก์เก่า เสียบใหม่ที่ bay เดิม
#    LED ที่ bay 4 จะติดอยู่

# 5. replace
zfsbay bay 4 replace
# Output: "✔ bay 32:4 เปลี่ยนดิสก์เสร็จ"

# 6. ดู resilver
zfsbay check sync bay 4
```

### 4.3 🚨 ดิสก์ตายกลางดึก — pool DEGRADED

เครื่องส่ง alert pool DEGRADED:

```bash
# 1. ดูสถานะ
zfsbay pool status                    # ยืนยัน DEGRADED
zfsbay bay status                     # หา bay ที่ STATE = UBad / Failed

# สมมติ bay 3 เสีย และไม่ใช่ rpool
# 2. remove
zfsbay bay 3 remove                   # zpool offline + locate + spindown
# (ถ้าดิสก์เสียจน spindown ไม่สำเร็จ — ignore warning)

# 3. ถอดเก่า เสียบใหม่

# 4. replace
zfsbay bay 3 replace

# 5. monitor
zfsbay check sync bay 3
watch -n 30 'zfsbay check sync bay 3'   # update ทุก 30 วินาที
```

### 4.4 🚨 Boot pool (rpool) ดิสก์เสีย

**ก่อนเริ่ม**: ต้องเตรียม `proxmox-boot-tool` มาด้วย

```bash
# 1. ตรวจ
zfsbay pool status rpool
zfsbay bay status                     # bay 0 = rpool ใน mirror-0

# 2. remove (ต้อง --force-boot)
zfsbay bay 0 remove --force-boot

# 3. ถอดเก่า เสียบใหม่

# 4. replace
zfsbay bay 0 replace

# 5. ⚠️ เตรียม ESP บน partition ใหม่
fdisk -l /dev/sdX                     # หา part ESP (partition 2)
proxmox-boot-tool format /dev/sdX2 --force
proxmox-boot-tool init /dev/sdX2
proxmox-boot-tool refresh

# 6. ยืนยัน
proxmox-boot-tool status
zfsbay check sync bay 0
```

### 4.5 ➕ เพิ่มดิสก์ใหม่เป็น hot spare

```bash
# 1. เสียบดิสก์ใหม่ที่ bay 5 (ก่อนหน้านี้ว่าง)
zfsbay bay status                     # ยืนยันมี PD ใหม่แล้ว state=UGood

# 2. join เป็น spare
zfsbay bay 5 join pool tank as spare

# 3. ตรวจ
zpool status tank | grep spare
```

### 4.6 🔁 ขยาย pool: เพิ่มดิสก์เข้า mirror

```bash
# pool tank เป็น single-disk vdev อยากทำให้เป็น mirror
zfsbay bay 5 join pool tank as mirror=/dev/disk/by-id/wwn-0x5000c5006b1a4fb8

# ZFS จะเริ่ม resilver อัตโนมัติ
zfsbay check sync bay 5
```

### 4.7 🤖 Cron / n8n monitoring

ส่ง alert เมื่อมีดิสก์ endurance < 20% หรือ pool DEGRADED:

```bash
#!/bin/bash
# /etc/cron.daily/zfsbay-alert
out=$(zfsbay --json bay status)

# ดิสก์ endurance ต่ำ
low_endur=$(echo "$out" | jq '[.bays[] | select(.endurance_pct != null and .endurance_pct < 20)] | length')

# pool ไม่ healthy
bad_pool=$(zfsbay --json pool status \
  | jq '[.pools[] | select(.health != "ONLINE")] | length')

if (( low_endur > 0 || bad_pool > 0 )); then
    curl -X POST "$N8N_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --argjson b "$out" --argjson le "$low_endur" --argjson bp "$bad_pool" \
              '{host: env.HOSTNAME, low_endurance: $le, degraded_pools: $bp, bays: $b.bays}')"
fi
```

---

## 5. Safety Guards: เคสที่ tool จะปฏิเสธ

`zfsbay` มี safety guard 7 ชั้น — ทุกอันข้ามได้ด้วย flag ตามนี้:

| Guard | เคสที่ปฏิเสธ | flag ที่ข้ามได้ |
|---|---|---|
| **Loss-of-redundancy** | offline แล้ว vdev เหลือ 0 redundancy (เช่น mirror ที่ peer FAULTED อยู่) | `--force` |
| **Active-resilver lockout** | resilver กำลังรันใน pool เดียวกัน | `--force` |
| **Foreign config** | มีหลาย foreign config ค้าง | `--clear-foreign` |
| **rpool detection** | bay อยู่บน rpool/ESP | `--force-boot` (+ ทำ `proxmox-boot-tool` เอง) |
| **ashift mismatch** | ดิสก์ใหม่ phy-sec ไม่ตรง pool ashift | `--force` |
| **Capacity check** | ดิสก์ใหม่เล็กกว่าเก่า | `--force` |
| **Multiple controllers/enclosures** | autodetect ไม่ได้ | `--controller N --enclosure M` |

⚠️ **ห้ามใช้ `--force` แบบไม่คิด** — guard เหล่านี้ออกแบบมาเพื่อกันไม่ให้คุณทำ pool พังตอนตี 3

---

## 6. Troubleshooting

### 6.1 "ไม่พบ perccli64 / storcli64"

```bash
# 1. ตรวจ path
ls -la /opt/MegaRAID/perccli/perccli64
ls -la /usr/sbin/perccli64

# 2. ถ้าไม่มี ดาวน์โหลดจาก dell.com/support → search "perccli linux"
# ติดตั้ง:
dpkg -i perccli_*.deb

# 3. หรือชี้ env var
PERCCLI=/path/to/perccli64 zfsbay bay status

# 4. หรือแก้ใน /etc/zfsbay.conf
```

### 6.2 "ตรวจไม่พบ enclosure อัตโนมัติ"

มีหลาย enclosure (เช่น เครื่อง R740xd2 มี 24+2 bays = 2 enclosures) หรือมีหลาย controller:

```bash
# ดูว่ามีอะไรอยู่
perccli64 show
perccli64 /c0/eall show all | grep "EID"

# ระบุ explicit
zfsbay --controller 0 --enclosure 32 bay status
```

### 6.3 "ห้ามถอด: vdev ... จะเหลือ healthy=N (ขั้นต่ำ M)"

vdev ปลายทางจะเสีย redundancy ทั้งหมด เช่น mirror ที่ peer FAULTED อยู่แล้ว:

```bash
# 1. ดูสถานะจริง
zpool status <pool>

# 2. ถ้าเข้าใจความเสี่ยงแล้ว
zfsbay bay X remove --force
```

### 6.4 "Foreign config detected"

ดิสก์เคยอยู่ใน controller อื่น/server อื่น:

```bash
# 1. ดูว่ามีอะไร
perccli64 /c0/fall show all

# 2. ถ้าไม่ต้องการ data เก่า
zfsbay bay X replace --clear-foreign

# 3. ถ้าต้องการ import ของเก่า (ไม่ผ่าน zfsbay)
perccli64 /c0/fall import preview
perccli64 /c0/fall import
```

### 6.5 "ashift mismatch"

```bash
# ดู ashift ของ pool
zpool get ashift <pool>

# ดู phy-sec ของดิสก์ใหม่
lsblk -dno PHY-SEC /dev/sdX

# ถ้า pool ashift=12 (4K) แต่ดิสก์ใหม่ 512 → จะเสียประสิทธิภาพ
# ถ้ายอมรับ:
zfsbay bay X replace --force
```

### 6.6 Resilver ไม่ขึ้นใน `check sync`

```bash
# 1. ตรวจตรงๆ
zpool status <pool>

# 2. ถ้า zpool รายงาน resilver แต่ zfsbay ไม่เห็น
# ส่ง output ของคำสั่งนี้มาให้ developer:
zpool status -P -v <pool> > /tmp/zpool-status.txt
```

### 6.7 Pool ใช้ /dev/sdX ไม่ใช่ by-id (legacy)

`zfsbay` ทำงานได้แต่จะเตือน — แนะนำ migrate:

```bash
zpool export <pool>
zpool import -d /dev/disk/by-id <pool>
```

### 6.8 `zfsbay bay status` ช้า

ครั้งแรกอ่าน SMART หลายดิสก์อาจช้า 5–10 วินาที เพราะ spin-up + scrape ทุก attribute

```bash
# Cache ใน memory แล้ว — ครั้งถัดไปเร็ว
# ถ้าต้องการ refresh
zfsbay --refresh bay status
```

### 6.9 Log file

```bash
tail -f /var/log/zfsbay.log

# log มีทุกการกระทำ:
# 2026-05-10T03:42:15Z INFO  เริ่ม bay 32:4 remove (pool=tank, vdev=raidz2-0)
# 2026-05-10T03:42:15Z CMD   /opt/MegaRAID/perccli/perccli64 /c0/e32/s4 start locate
# 2026-05-10T03:42:18Z INFO  bay 32:4 remove เสร็จเรียบร้อย
```

---

## 7. JSON output schema

ทุก subcommand รองรับ `--json`. Schema:

### `bay status --json`

```json
{
  "controller": 0,
  "enclosure": 32,
  "bays": [
    {
      "bay": "32:0",
      "slot": 0,
      "did": 7,
      "wwn": "55cd2e404b9a1234",
      "serial": "BTWA000A1234567A",
      "model": "INTEL SSDSC2BB480H4",
      "size_bytes": 479559477657,
      "interface": "SATA",
      "media": "SSD",
      "perc_state": "Onln",
      "perc_jbod": false,
      "perc_vd": 0,
      "kernel_device": "/dev/sda",
      "by_id": "/dev/disk/by-id/wwn-0x55cd2e404b9a1234",
      "smart_overall": "PASSED",
      "health_pct": 98,
      "endurance_pct": 85,
      "used_bytes": null,
      "total_bytes": 479559477657,
      "pool": "rpool",
      "vdev": "mirror-0",
      "vdev_state": "ONLINE"
    }
  ]
}
```

### `pool status --json`

```json
{
  "pools": [
    {
      "name": "tank",
      "size": "16T", "alloc": "8.5T", "free": "7.5T",
      "health": "ONLINE", "frag": "12%", "cap": "53%",
      "resilver": {
        "in_progress": false,
        "percent": null,
        "eta_seconds": null,
        "scanned_bytes": null,
        "total_bytes": null,
        "rate_bps": null
      }
    }
  ]
}
```

### `check sync --json`

```json
{
  "pools": [
    {
      "name": "tank",
      "state": "DEGRADED",
      "resilver": {
        "in_progress": true,
        "percent": 12.34,
        "eta_seconds": 11655,
        "scanned_bytes": 1352914599116,
        "total_bytes": 2572857208995,
        "rate_bps": 93323264
      }
    }
  ]
}
```

### `version --json`

```json
{ "name": "zfsbay", "version": "0.1.0" }
```

---

## 8. Internals (สำหรับ debug ลึก)

### 8.1 โครงสร้างโค้ด

```
/usr/local/sbin/zfsbay        # arg parser + dispatcher (~226 บรรทัด)
/usr/local/lib/zfsbay/
├── common.sh                 # logging, color, run_cmd, dep+root check
├── ui.sh                     # table renderer, progress bar, colors
├── perccli.sh                # wrapper + JSON parser ของ perccli64
├── smartctl.sh               # SMART parsing per vendor + endurance dispatcher
├── zfs.sh                    # zpool wrappers + resilver parser
├── mapping.sh                # bay↔DID↔WWN↔/dev/sdX↔by-id↔vdev resolver (cached)
└── workflows.sh              # subcommand orchestration
```

### 8.2 Bay-to-device resolution chain

```
PERC PD (EID:Slt = "32:4")
    ↓ JSON: perccli64 /c0/eall/sall show all J
DID = 11
WWN = "5000c5006b1a4fb8"
    ↓ udevadm info / scan /dev/disk/by-id
/dev/disk/by-id/wwn-0x5000c5006b1a4fb8
    ↓ readlink -f
/dev/sdc
    ↓ scan zpool status -P -v
pool = "tank", vdev = "raidz2-0", state = "ONLINE"
```

จับคู่ด้วย **WWN ก่อน, fallback เป็น Serial Number** (สำหรับ SSD เก่าที่ WWN = 0)

### 8.3 Cache

ทุกการเรียก subcommand จะ query perccli + scan /dev/disk/by-id ครั้งเดียว แล้ว cache ใน memory (associative arrays). ใช้ `--refresh` เพื่อ bypass

### 8.4 Endurance attribute mapping

| ID | Name | Vendor |
|---|---|---|
| 231 | SSD_Life_Left | Intel, SK Hynix |
| 233 | Media_Wearout_Indicator | Intel, Crucial/Micron |
| 202 | Percent_Lifetime_Remain | Micron, Crucial |
| 177 | Wear_Leveling_Count | Samsung |
| 173 | MWI / Avg_Write/Erase_Count | SanDisk, Kingston (≤100 only) |
| 169 | Remaining_Lifetime_Perc | Apple, Toshiba |

ดิสก์ตัวเดียวกันอาจ match หลาย ID — `zfsbay` ใช้ตัวแรกที่เจอตามลำดับนี้

SAS SSD: parse `smartctl -l ssd` หา `Percentage used endurance indicator: N%` → endurance left = `100 - N`

NVMe: `Percentage Used: N%` (smartctl `-a`) หรือ `percentage_used: N` (`nvme smart-log`) → `100 - N`

HDD: ไม่ใช้ → รายงาน `N/A`

### 8.5 Health % heuristic

```
score = 100
- 20 ถ้า reallocated_sectors > 0
- 30 ถ้า pending_sectors > 0
- 10 ถ้า CRC errors > 100
- 50 ถ้า predictive failure
- 10 ถ้า PERC media_error > 0
- 10 ถ้า PERC other_error > 10
- 50 ถ้า PERC predictive_failure > 0
- 20 ถ้า SAS grown defect list > 0
- 10 ถ้า อุณหภูมิ > 60°C
floor at 0
```

`smart_overall = FAILED` → score = 0 ทันที

### 8.6 Resilver progress parsing

รองรับ 3 phrasings ของ OpenZFS:

- **0.8.x**: `1.23T scanned out of 2.34T at 234M/s, 03:14:15 to go`
- **2.0/2.1**: `1.23T scanned at 234M/s, 567G issued at 89M/s, 2.34T total` + `45.6G resilvered, 12.34% done, 03:14:15 to go`
- **2.2**: `900G / 2.34T scanned, 458G / 2.34T issued at 89M/s` + `78.4G resilvered, 19.55% done, no estimated completion time`

### 8.7 Exit codes

| Code | ความหมาย |
|---|---|
| 0 | สำเร็จ |
| 1 | error ทั่วไป |
| 2 | usage error |
| 3 | dependency หาย |
| 4 | ไม่ใช่ root |
| 5 | hardware/perccli error |
| 6 | zfs error |
| 7 | ผู้ใช้ยกเลิก (confirm = no) |

---

## 9. Cheat Sheet

### Daily ops

```bash
zfsbay bay status                              # ดูทุก bay
zfsbay pool status                             # ดูทุก pool
zfsbay check sync                              # ดู resilver
zfsbay --json bay status | jq                  # JSON สำหรับ script
```

### เปลี่ยนดิสก์ (workflow มาตรฐาน)

```bash
zfsbay bay <N> remove                          # 1) เตรียมถอด
# (ถอด เสียบใหม่)
zfsbay bay <N> replace                         # 2) zpool replace
zfsbay check sync bay <N>                      # 3) ดู progress
```

### Flag ที่ใช้บ่อย

```bash
--dry-run              # ทดสอบก่อนรันจริง
-y                     # ข้าม confirm
-v                     # ดูคำสั่ง external
--force                # ข้าม redundancy/ashift guard
--force-boot           # rpool ops
--clear-foreign        # auto-clear foreign config
```

### Path สำคัญ

```
/usr/local/sbin/zfsbay         # entrypoint
/usr/local/lib/zfsbay/         # libraries
/etc/zfsbay.conf               # config
/var/log/zfsbay.log            # audit log
/opt/MegaRAID/perccli/perccli64
```

### เมื่อมีปัญหา

```bash
zfsbay -v <command>            # verbose
zfsbay --dry-run <command>     # ดูคำสั่งจริง
tail -f /var/log/zfsbay.log    # log file
zfsbay --refresh bay status    # bypass cache
```

---

**Issues / feedback**: เปิด issue ใน repo
**Updates**: ดู `CHANGELOG.md`
**License**: MIT
