# Solutions — Step-by-step Playbooks

Task-oriented cheatsheets — ใช้บนหน้างานได้เลย — สำหรับ 3 เคสที่พบบ่อย

| # | Playbook | ใช้เมื่อ |
|---|---|---|
| [1](#1-check-status--วิเคราะห์-ว่าควรเปลี่ยนเมื่อไหร่) | Check status & วิเคราะห์ | ตรวจประจำ — รู้ว่า pool ไหน/bay ไหนต้องสนใจ |
| [2](#2-proactive-replace-โย้กไปใช้-spare-ก่อนดิสก์เสีย) | Proactive replace ผ่าน spare | ดิสก์ ENDUR ต่ำ ยังไม่เสีย แต่ต้องการเปลี่ยน |
| [3](#3-after-spare-takeover-เติม-spare-ใหม่-แทน-disk-ที่เพิ่งใช้) | เติม spare ใหม่หลัง takeover | หลัง spare ทำงาน (auto หรือ manual) — ต้องเปลี่ยนดิสก์จริง + เติม spare |

---

## 1. Check status & วิเคราะห์ ("ควรเปลี่ยนเมื่อไหร่")

### 🎯 เป้าหมาย

- รู้ว่า pool ทุกตัว healthy
- รู้ว่า bay ไหน wear ใกล้หมด
- รู้ว่า safety net ครบ (spare + autoreplace + zed)

### 1.1 คำสั่งหลัก

```bash
# ภาพรวม pool (HEALTH + FRAG + CAP)
zfsbay pool status

# ภาพรวม bay (ENDUR + HEALTH + POOL/VDEV)
zfsbay bay status

# Bay เดียว — รายละเอียด
zfsbay bay <N> status
```

### 1.2 ดูค่าไหนเพื่อตัดสินใจ — เรียงตามความสำคัญ

| ลำดับ | ค่า | เกณฑ์ | ความหมาย |
|---|---|---|---|
| 1 | **ENDUR%** | <50 = วางแผน, <30 = เร่ง, <15 = ฉุกเฉิน | budget การเขียนของ SSD ที่เหลือ |
| 2 | **POOL state** | ONLINE = ดี, DEGRADED = มีดิสก์เสีย | ตรวจจาก `zfsbay pool status` |
| 3 | **CAP%** | <80 = ปลอดภัย, >80 = ระวัง, >90 = วิกฤต | พื้นที่ pool เต็มแค่ไหน |
| 4 | **HEALTH%** | <80 = ดูเพิ่ม | heuristic จาก SMART + PERC error counters |
| 5 | **FRAG%** | <50 = ปกติ, >70 = ช้า | fragmentation ของ free space |
| 6 | **PERC STATE** | Onln/JBOD = ดี, UBad/Failed/Frgn = แย่ | สถานะ raw จาก PERC |

### 1.3 Trigger — เมื่อไหร่ต้องลงมือ

```
ENDUR < 30%       → เริ่ม swap-to-spare (Playbook 2)
POOL DEGRADED     → resilver กำลังทำ หรือ ดิสก์เสีย — ตรวจ zpool status
CAP > 80%         → วางแผนขยาย pool / ลบ snapshot
PERC = UBad       → ดิสก์เสียจริง — ทำ Playbook 3 (replace + เติม spare)
PERC = Frgn       → foreign config ค้าง — clear ก่อนใช้
PERC = Failed     → ดิสก์ตาย — Playbook 3
```

### 1.4 ตรวจ Safety Net (autoreplace + spare + zed)

ถ้า `autoreplace=on` + มี spare AVAIL + zed รัน → **ดิสก์เสียกลางดึก ZFS จะ activate spare เอง**

```bash
# ตรวจ autoreplace ของทุก pool
zpool get autoreplace
# ผล: VALUE=on ทุก pool

# ตรวจว่ามี spare AVAIL
zpool status | grep -A 2 spares
# ผล: state ของ spare เป็น AVAIL

# ตรวจ zed daemon
systemctl is-active zfs-zed
# ผล: active
```

### 1.5 One-liner — รวมทุกอย่างใน command เดียว

```bash
echo "=== $(hostname) ==="
zfsbay --json bay status | jq -r '
  .bays[]
  | select(.endurance_pct != null)
  | "\(.bay)  ENDUR=\(.endurance_pct)  POOL=\(.pool // "-")  STATE=\(.perc_state)"
' | sort -k2 -t= -n
echo
echo "Pools:"
zpool list -o name,health,cap,frag,autoreplace
echo
echo "Spares:"
for p in $(zpool list -H -o name); do
    sp=$(zpool status "$p" | awk '/^[[:space:]]*spares$/{getline;print $1,$2}')
    printf "  %-12s %s\n" "$p" "${sp:-(none)}"
done
echo
echo "ZED: $(systemctl is-active zfs-zed)"
```

### 1.6 Multi-host check (จาก management host)

```bash
HOSTS="pve-r22 pve-r24 pve-r25 pve-r26 pve-r27 pve-r29 pve-r30 pve-r31"

for h in $HOSTS; do
    echo "═══ $h ═══"
    ssh "$h" 'zfsbay --json bay status' \
        | jq -r '.bays[] | select(.endurance_pct != null and .endurance_pct < 60)
                 | "  \(.bay)  ENDUR=\(.endurance_pct)  \(.serial)  pool=\(.pool // "-")"'
done
```

### ✅ Checklist ประจำ (ทำทุก 3 เดือน)

- [ ] ทุก pool HEALTH=ONLINE
- [ ] ทุก pool CAP < 80%
- [ ] ทุก pool ที่ raidz/mirror มี autoreplace=on
- [ ] ทุก pool ที่สำคัญ มี spare AVAIL
- [ ] zfs-zed รันบนทุก host
- [ ] ดิสก์ที่ ENDUR < 30% มีแผนเปลี่ยน
- [ ] db-zfs / single-disk pool มี backup off-pool

---

## 2. Proactive replace (โย้กไปใช้ spare ก่อนดิสก์เสีย)

### 🎯 เป้าหมาย

- ดิสก์ที่ยังไม่เสีย แต่ ENDUR ใกล้หมด → ย้ายข้อมูลไป spare ผ่าน resilver
- ระหว่างทำ pool ยัง full redundancy ไม่ผ่านสถานะ DEGRADED
- หลัง resilver เสร็จ → bay เก่า "ว่าง" จาก ZFS — พร้อมถอดดิสก์

### 2.1 Pre-check — ก่อนเริ่ม

```bash
# 1. ระบุ bay ที่จะเปลี่ยน — ดู ENDUR
zfsbay bay status

# 2. ตรวจว่า pool มี spare AVAIL
zpool status <pool> | grep -A 2 spares
#   ต้องเห็น state = AVAIL

# 3. ตรวจ pool ไม่กำลัง resilver อยู่
zfsbay check sync
#   ต้องเห็น "no resilver in progress on any pool"

# 4. ตรวจว่ามี monitoring/alert พร้อม (เพราะ resilver ใช้ I/O ของ pool)
```

### 2.2 Workflow — ทำตาม 3 ขั้น

```bash
# ตั้ง variable ลด typo
HOST=pve-r29     # เครื่อง
BAY=1            # bay number ที่จะ swap

# --- Step 1: dry-run ดูคำสั่งจริงก่อน ---
ssh "$HOST" "zfsbay --dry-run bay $BAY swap-to-spare"
# ตอบ y ที่ confirm prompt — ไม่ทำจริง แค่ print plan

# --- Step 2: รันจริง + ติดตามจนเสร็จ ---
ssh "$HOST" "zfsbay bay $BAY swap-to-spare --watch"
# ตอบ y ที่ confirm
# จะ block อยู่จนกว่า resilver จะเสร็จ (~1-3 ชั่วโมง สำหรับ 1.7TB SSD)
# กด Ctrl+C ออกได้ตอนเห็น "✔ resilver เสร็จแล้ว"
```

### 2.3 Verify — หลัง resilver เสร็จ

```bash
# ตรวจ pool ONLINE ไม่ DEGRADED
ssh "$HOST" "zpool status <pool>"
# spare ตอนนี้กลายเป็นสมาชิก vdev ถาวร — ดิสก์เก่าออกไปจากพูลแล้ว

# bay ที่ swap จะไม่อยู่ใน vdev อีกต่อไป
ssh "$HOST" "zfsbay bay status"
# bay <N> POOL=- VDEV=- (ปกติ — รอถอดดิสก์)
```

### 2.4 Physical swap (Playbook 3)

หลัง resilver เสร็จ → **ไปต่อที่ Playbook 3** เพื่อถอดดิสก์เก่าและเติม spare ใหม่

### 📋 Cheat sheet (print ติดข้าง rack)

```
┌──────────────────────────────────────────────┐
│  PROACTIVE SWAP — ENDUR ใกล้หมด              │
│                                              │
│  1. zfsbay bay status                        │
│     → ระบุ bay ที่ ENDUR < 30%               │
│                                              │
│  2. zpool status <pool> | grep -A 2 spares   │
│     → ตรวจมี spare AVAIL                     │
│                                              │
│  3. zfsbay --dry-run bay <N> swap-to-spare   │
│     → review plan                            │
│                                              │
│  4. zfsbay bay <N> swap-to-spare --watch     │
│     → รันจริง รอ resilver เสร็จ              │
│                                              │
│  5. zpool status <pool>                      │
│     → ตรวจ ONLINE (ไม่ DEGRADED)             │
│                                              │
│  6. → ไปต่อ Playbook 3 เพื่อเปลี่ยนดิสก์จริง │
└──────────────────────────────────────────────┘
```

### ⚠️ ข้อควรระวัง

- **ใช้ I/O ของ pool** — ทำใน window ที่ load น้อย
- **อย่าเริ่มหลายเครื่องพร้อมกัน** — แต่ละเครื่องใช้เวลา 1-3 ชั่วโมง
- **อย่าทำ proactive swap แบบ batch** ถ้า ENDUR ยังเกิน 50% — เปลือง spare เปล่าๆ

---

## 3. After spare takeover — เติม spare ใหม่ + แทน disk ที่เพิ่งใช้

### 🎯 เป้าหมาย

หลังจาก spare ถูก activate (กรณี A หรือ B):
- **A.** ZFS auto-replace (autoreplace=on, ดิสก์เสียกลางดึก)
- **B.** Manual `swap-to-spare` (Playbook 2)

ทั้ง 2 กรณีจบที่สถานะเดียวกัน:
- spare เดิม → กลายเป็น data vdev member ถาวร
- ดิสก์เก่า (FAULTED หรือใกล้เสีย) → ถูกปลดจาก pool
- pool ตอนนี้ **ไม่มี spare** ในบางช่วง

ต้อง:
1. ถอดดิสก์เก่าออก
2. ใส่ดิสก์ใหม่
3. add ดิสก์ใหม่กลับเป็น spare → pool กลับมามี safety net

### 3.1 Before — ตรวจสถานะปัจจุบัน

```bash
HOST=pve-r29
BAY=1   # bay ที่ดิสก์เก่ายังเสียบอยู่ (รอถอด)

# 1. resilver เสร็จแน่ (ถ้ายัง อย่าถอดดิสก์)
ssh "$HOST" "zfsbay check sync"
#   ต้อง: "no resilver in progress on any pool"

# 2. ตรวจว่า bay ปัจจุบันไม่อยู่ใน vdev แล้ว (ปลอดภัยถอด)
ssh "$HOST" "zfsbay bay $BAY status"
#   ต้อง: POOL=- VDEV=- (หรือ POOL ไม่มี = ดิสก์ไม่ใช่ส่วนของ pool)

# 3. ตรวจว่า pool ONLINE
ssh "$HOST" "zpool status <pool> | grep state:"
#   ต้อง: state: ONLINE
```

### 3.2 Step-by-step — เปลี่ยนดิสก์ + เติม spare

```bash
# === Step 1: เตรียมถอด — LED + spindown ===
ssh "$HOST" "zfsbay bay $BAY remove"
# ➜ "✔ ไฟ LED ติดที่ bay <BAY> แล้ว ปลอดภัยที่จะถอดดิสก์ออก"

# === Step 2: ไปหน้า rack ===
# - หา bay ที่ไฟ LED ติดอยู่
# - ถอดดิสก์เก่าออก
# - เสียบดิสก์ใหม่ที่ bay เดิม
# - LED ยังติดต่อจนกว่า replace จะรัน

# === Step 3: ตั้งค่า PERC + ตรวจ kernel เห็นดิสก์ใหม่ ===
ssh "$HOST" "zfsbay bay $BAY replace"
# จะทำ: clear foreign (ถ้ามี) → set good → set jbod → wait for kernel device
# ➜ ถ้าไม่มีตำแหน่ง FAULTED ใน pool ให้ replace → จบที่ "set jbod" เฉยๆ
#   (ไม่ใช่ error — เป็นปกติเพราะดิสก์ใหม่นี้ยังไม่ใช่ส่วนของ pool ใด)

# === Step 4: เติม spare ใหม่ ===
ssh "$HOST" "zfsbay bay $BAY join pool <pool> as spare"
# ➜ "✔ bay <BAY> เพิ่มเข้า pool <pool> แล้ว"
```

### 3.3 After — verify pool กลับมาเต็มสภาพ

```bash
# 1. ตรวจตาราง bay
ssh "$HOST" "zfsbay bay status"
# bay <BAY> ต้องขึ้น: POOL=<pool> VDEV=spare-N (หรือ spares)
#                    STATE=Onln  ENDUR=100 (ดิสก์ใหม่เอี่ยม)

# 2. ตรวจ pool layout
ssh "$HOST" "zpool status <pool>"
# ต้องเห็น section "spares" พร้อมดิสก์ใหม่ + state AVAIL

# 3. ตรวจ autoreplace ยังเปิด
ssh "$HOST" "zpool get autoreplace <pool>"
# VALUE=on
```

### 3.4 ตัวอย่าง — Full workflow บน pve-r29 bay 32:1

```bash
# === ก่อน ทุกอย่างพร้อม ===
HOST=pve-r29
BAY=1

ssh $HOST "zfsbay check sync"                    # no resilver
ssh $HOST "zfsbay bay $BAY status"               # POOL=- VDEV=- ✓

# === Step 1 ===
ssh $HOST "zfsbay bay $BAY remove"
# Output: "✔ ไฟ LED ติดที่ bay 32:1 แล้ว ปลอดภัยที่จะถอดดิสก์ออก"

# === Step 2 — ไป rack ถอด/เสียบดิสก์ใหม่ ===

# === Step 3 ===
ssh $HOST "zfsbay bay $BAY replace"
# Output: 
#   clear foreign config
#   set good force
#   set jbod
#   ดิสก์ใหม่: /dev/sdc (zfs path: /dev/disk/by-id/wwn-0x...)
#   ไม่พบ pool ที่มี vdev ในสถานะ OFFLINE/UNAVAIL — ข้าม zpool replace
#   ✔ bay 32:1 เปลี่ยนดิสก์เสร็จ

# === Step 4 ===
ssh $HOST "zfsbay bay $BAY join pool rpool as spare"
# Output: "✔ bay 32:1 เพิ่มเข้า pool rpool แล้ว"

# === Verify ===
ssh $HOST "zfsbay bay status"
# bay 32:1: STATE=Onln ENDUR=100 POOL=rpool VDEV=spares ✓
```

### 📋 Cheat sheet (print ติดข้าง rack)

```
┌──────────────────────────────────────────────┐
│  AFTER SPARE TAKEOVER — เปลี่ยนดิสก์จริง     │
│                                              │
│  PRE-CHECK                                   │
│  □ zfsbay check sync                         │
│    → ต้อง "no resilver"                      │
│  □ zfsbay bay <N> status                     │
│    → POOL=- (ปลอดภัยถอด)                     │
│                                              │
│  STEPS                                       │
│  1. zfsbay bay <N> remove                    │
│     → ไฟ LED ติด                             │
│                                              │
│  2. (ถอดดิสก์เก่า เสียบดิสก์ใหม่)            │
│                                              │
│  3. zfsbay bay <N> replace                   │
│     → set jbod + ตรวจ kernel เห็น           │
│                                              │
│  4. zfsbay bay <N> join pool <pool> as spare │
│     → เติม spare ใหม่                         │
│                                              │
│  POST-CHECK                                  │
│  □ zfsbay bay status                         │
│    → bay <N> POOL=<pool> VDEV=spares ✓       │
│  □ zpool status <pool>                       │
│    → spares: <new disk> AVAIL ✓              │
└──────────────────────────────────────────────┘
```

### ⚠️ ข้อควรระวัง

- **อย่าถอดดิสก์ตอน resilver ยังไม่เสร็จ** → pool DEGRADED ทันที (อาจ data loss)
- **ถ้า rpool/boot disk** → หลัง replace ต้องทำ `proxmox-boot-tool format/init` ด้วย
  - ใช้ `zfsbay bay <N> remove --force-boot` เพื่อ allow ทำกับ rpool
  - อ่านรายละเอียดใน [MANUAL.md § 4.4](MANUAL.md)
- **ดิสก์ใหม่ขนาดต้อง ≥ ดิสก์เก่า** ไม่งั้น ZFS ไม่ยอมรับเป็น spare

---

## ภาพรวม Decision Tree

```
ดิสก์มีปัญหา?
│
├─ ENDUR < 30% (ยังไม่เสีย แต่ใกล้หมด)
│   └─ Playbook 2: Proactive swap-to-spare
│       └─ เสร็จแล้ว → Playbook 3: เปลี่ยนดิสก์จริง + เติม spare
│
├─ ดิสก์ FAULTED จริง (autoreplace=on + spare AVAIL)
│   └─ ZFS auto-activate spare แล้ว — ทำเฉพาะ Playbook 3
│
├─ ดิสก์ FAULTED + ไม่มี spare
│   └─ pool DEGRADED — ต้องเปลี่ยนดิสก์ทันที
│       1. zfsbay bay <N> remove (ถ้าระบบยังเข้าถึงได้)
│       2. (เปลี่ยนดิสก์)
│       3. zfsbay bay <N> replace (auto find faulted slot → zpool replace)
│
└─ ทุกอย่าง healthy
    └─ Playbook 1: monitor ทุก 3 เดือน
```

---

**ดูเพิ่มเติม**:
- [MANUAL.md](MANUAL.md) — คู่มือฉบับ ops engineer (รายละเอียดทุก subcommand)
- [README.md](README.md) — intro + ติดตั้ง
- [CHANGELOG.md](CHANGELOG.md) — version history
