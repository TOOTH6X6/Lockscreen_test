# ClockFont

เปลี่ยนฟอนต์นาฬิกาหน้าล็อกเป็น Apple ADT Numeric (ตัวเลขสูงแคบ) ตามรูปตัวอย่าง
ค่าเริ่มต้น: SF Adaptive Numeric, wght 600, wdth 100, HGHT 200

## Build โดยไม่ใช้ Mac
1. สร้าง repository ใหม่บน github.com แล้วอัปโหลดไฟล์ทั้งหมดในโฟลเดอร์นี้ (ไฟล์ฟอนต์ 3.4 MB อัปโหลดผ่านเว็บได้)
2. ไฟล์ `.github/workflows/build.yml` ต้องอยู่ในพาธนี้พอดี ถ้าโฟลเดอร์ที่ขึ้นต้นด้วยจุดไม่ถูกอัปโหลด ให้ใช้ Add file > Create new file พิมพ์พาธเต็มแล้ววางเนื้อหา
3. เปิดแท็บ Actions รอ build เสร็จ ดาวน์โหลด artifact ชื่อ `deb` แตก zip จะได้ .deb
4. เปิด .deb ด้วย Sileo, Zebra หรือ Filza แล้ว Respring

## ถ้าฟอนต์ไม่เปลี่ยน
ดู log ที่ `/var/mobile/Documents/ClockFont.log` ซึ่งบอกว่า
- โหลดไฟล์ฟอนต์ได้ไหม และมี face อะไรบ้างในไฟล์
- สร้างฟอนต์ทดสอบที่ 80 pt สำเร็จไหม
- label ตัวไหน (ชื่อคลาสและ view แม่) ถูกเปลี่ยนฟอนต์ ถ้าบรรทัด `applied to ...` ไม่ขึ้นเลย แปลว่านาฬิกาไม่ได้อยู่ใน SpringBoard หรือ PosterBoard หรือไม่ได้วาดด้วย UILabel ส่ง log มาให้ผมแก้ต่อได้

## ปรับค่า
แก้ไฟล์ `/var/jb/Library/ClockFont/config.plist` (rootful: `/Library/ClockFont/config.plist`) แล้ว Respring
- `axes`: wght 1-1000 (น้ำหนัก), wdth 60-100 (ความกว้าง), HGHT 100-500 (ความสูง)
- `sizeScale`: คูณขนาดตัวอักษรเดิม
- `face`: ชื่อ PostScript ของฟอนต์ในไฟล์ .ttc เช่น `.SFNumeric-Regular` (แกน wdth 30-150), `.SFRoundedNumeric-Regular`

ฟอนต์ในไฟล์เป็นของ Apple ใช้กับเครื่องตัวเองเท่านั้น ไม่ควรเผยแพร่แพ็กเกจต่อสาธารณะ
