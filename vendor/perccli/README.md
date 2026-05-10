# Dell PERCCLI 7.1623.00 (A11)

ไบนารี **PERCCLI** ของ Dell EMC สำหรับใช้กับ PERC RAID controllers (H730/H740/H750/H755 ฯลฯ)
ดาวน์โหลดมาจาก Dell support เพื่อให้ติดตั้งได้แบบ offline จาก git pull

## ที่มา

- **Vendor**: Dell EMC
- **Product**: Dell EMC PowerEdge RAID Controller (PERC) Command Line Interface
- **Version**: 7.1623.00, Revision A11 (May 2021)
- **Download**: https://www.dell.com/support/home/ → Service Tag → Drivers → SAS RAID
- **License**: Dell EULA (ดู `ThirdPartyLicenseNotice.pdf`)

## ไฟล์ในโฟลเดอร์

| File | ใช้กับ | ขนาด |
|---|---|---|
| `perccli_007.1623.0000.0000_all.deb` | Debian / Ubuntu / Proxmox | 1.9 MB |
| `perccli-007.1623.0000.0000-1.noarch.rpm` | RHEL / CentOS / Rocky / SUSE | 2.1 MB |
| `pubKey.asc` | Dell GPG signing key (verify ของแท้) | 1.7 KB |
| `splitpackage.sh` | helper script ของ Dell (ไม่จำเป็นต้องใช้) | 4 KB |
| `ThirdPartyLicenseNotice.pdf` | license notice | 576 KB |

## วิธีติดตั้ง (Proxmox / Debian)

```bash
cd /path/to/zfsbay
sudo dpkg -i vendor/perccli/perccli_007.1623.0000.0000_all.deb

# ตรวจ binary
ls /opt/MegaRAID/perccli/perccli64
/opt/MegaRAID/perccli/perccli64 show

# ผูกกับ zfsbay
echo 'PERCCLI="/opt/MegaRAID/perccli/perccli64"' | sudo tee -a /etc/zfsbay.conf
zfsbay bay status
```

## วิธีติดตั้ง (RHEL / SUSE)

```bash
sudo rpm -ivh vendor/perccli/perccli-007.1623.0000.0000-1.noarch.rpm
```

## Verify GPG signature (ทางเลือก)

```bash
gpg --import vendor/perccli/pubKey.asc
# ตรวจ deb signature ด้วย dpkg-sig (ถ้าติดตั้งไว้)
dpkg-sig --verify vendor/perccli/perccli_007.1623.0000.0000_all.deb
```

## หมายเหตุ

- เวอร์ชัน 7.1623 รองรับ PERC H730 / H730P / H740 / H740P / H750 / H755 ครบทุกรุ่น
- ถ้ามี controller รุ่นใหม่กว่า (H965 / H975 ขึ้นไป) อาจต้อง download เวอร์ชันใหม่จาก Dell
- ถ้าใช้ controller ที่ไม่ใช่ Dell (LSI / Broadcom MegaRAID ตรงๆ) ใช้ `storcli64` จาก Broadcom แทน
