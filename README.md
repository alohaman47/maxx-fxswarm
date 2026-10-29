# MAXX FX SWARM v1.0.0

บอท AI เทรด 25 คู่ FX บน M15 แบบ "AI เลือกทิศ / EA คุมเงิน" + ระบบพิสูจน์ว่า AI มี edge จริงไหม

```
EA (MT5, VPS)  --ทุกแท่ง M15 ปิด-->  server (Railway)  --batch ละ 5 คู่-->  AI ฟรี (Gemini Flash-Lite)
     ^                                    |
     +------ poll ทุก 3 วิ: คำสั่ง OPEN <---+---> virtual books: AI / REVERSE / calibration -> dashboard
```

## สิ่งที่เปลี่ยนจากบอทเดิม

| บอทเดิม | v1 |
|---|---|
| ปิดคู่ละ +$1 (RR กลับหัว) | ตัดทิ้ง ใช้ ATR ล้วน: SL 1 / BE 1 / trail จาก 1.5 (ห่าง 1) / TP 3 / time stop 8 ชม. |
| Reverse mode | ตัดทิ้ง แต่ server จำลอง REVERSE book คู่ขนานไว้เทียบทุกสัญญาณ |
| HOLD = ปิดไม้ | NONE = ไม่เปิดไม้ใหม่ ไม้ที่ถืออยู่ปล่อยให้ ATR จัดการ |
| ถาม AI ทุก 12 วิ ทีละคู่ 5 key | ถามแค่ตอนแท่ง M15 ปิด batch ละ 5 คู่ = 5 call / 15 นาที (key เดียวพอ) |
| conf 80% เชื่อตามที่ AI บอก | log ทุกสัญญาณแยกตาม conf แล้ววัดผลจริง (calibration table) |
| lot ตายตัว | lot จากความเสี่ยง $ ต่อไม้ (ขาดทุนที่ 1 ATR = InpRiskUSD) |
| ไม่มีคุม correlation | สูงสุด 6 ไม้ และสกุลเดียวกันทิศเดียวกันไม่เกิน 2 |
| ไม่มีข่าว | ข่าว high-impact ±15 นาที ไม่เปิดคู่ที่มีสกุลนั้น |
| -$100 / +$200 | คงไว้ (ปิด+ลอย, ตามวัน NY) + ปิดหมดศุกร์ 16:00 NY |

## ติดตั้ง

### 1) GitHub + Railway
1. สร้าง repo ใหม่ `maxx-fxswarm` (Private) อัปโหลดทุกไฟล์ในโฟลเดอร์นี้
2. Railway > New Project > Deploy from GitHub > เลือก repo
3. เพิ่ม Volume mount ที่ `/data`
4. Variables:

| ตัวแปร | ค่า |
|---|---|
| `MAXX_KEY` | รหัสยาวๆ ของเราเอง (ใช้ทั้ง EA และ dashboard) |
| `GEMINI_KEYS` | API key จาก aistudio.google.com/apikey (หลาย key ใส่คั่นด้วย , ได้) |
| `DATA_DIR` | `/data` |

ตัวเลือก (มีค่า default แล้ว): `GEMINI_MODEL` (auto), `MIN_CONF` (80), `VIRT_MIN_CONF` (เท่า MIN_CONF - เกณฑ์ของ virtual books), `BATCH_SIZE` (5), `AI_START_NY`/`AI_END_NY` (0/24), `AI_SKIP_NY` (16-19 = ข้ามช่วงหลัง NY ปิดถึง rollover), `AI_DAILY_LIMIT` (900), `AI_GAP_MS` (5000), `SL_ATR` `BE_ATR` `TRAIL_START_ATR` `TRAIL_DIST_ATR` `TP_ATR` `MAX_HOLD_BARS`, `NEWS_GUARD` (1)

AI ตัวอื่นแทน Gemini ได้: `AI_PROVIDER=openai` + `OPENAI_KEYS` + `OPENAI_BASE_URL` + `OPENAI_MODEL` (Groq / OpenRouter / DeepSeek) หรือ `AI_PROVIDER=anthropic` + `ANTHROPIC_API_KEY` (Haiku) — ไม่ใส่ key เลย = mock mode (dashboard ขึ้นแดง)

5. เปิด `https://<app>/health` ต้องเห็น `aiMode:"live"` และ `keySet:true`

### 2) MT5 (VPS)
1. Tools > Options > Expert Advisors > ติ๊ก Allow WebRequest แล้วใส่ URL Railway
2. คอมไพล์ `mt5/MaxxFxSwarm_v1.mq5` แปะชาร์ตไหนก็ได้ 1 ชาร์ต (EA ดูแลครบ 25 คู่เอง)
3. Inputs ที่ต้องตั้ง: `InpURL` (https://...railway.app), `InpKey` = MAXX_KEY, `InpSuffix` ถ้าโบรกมีท้ายชื่อคู่
4. `InpDryRun=true` ไว้ก่อน — EA จะ log "DRY would BUY..." ไม่ส่งออเดอร์จริง
5. Magic 600200 — เพิ่มใน soldier list ของ Commander

## เกณฑ์ตัดสิน (ห้ามข้าม)
- **Phase 0 DryRun** อย่างน้อย 2-4 สัปดาห์ จน AI book มี 60+ ไม้ (ควร 100+)
- **ผ่าน** = AI book PF > 1.2 **และ** ชนะ REVERSE book **และ** calibration แถว conf สูงได้ avg R ดีกว่าแถวต่ำ
- ผ่านแล้วค่อย `InpDryRun=false` ด้วย `InpRiskUSD` เล็ก
- ไม่ผ่าน = AI ไม่มีตา ไม่ต้องเสียเงินจริงพิสูจน์ซ้ำ

## API
`GET /health` · `POST /api/bar` (EA) · `GET /api/cmd?since=N` (EA) · `POST /api/ack` (EA) · `GET /api/state` · `POST /api/pause|resume|closeall` · `GET /api/log?f=trades|decisions|acks` — ทุกตัวยกเว้น /health ต้องส่ง header `x-maxx-key`

หมายเหตุ: Gemini ฟรีมีโควต้าต่อวัน (เปลี่ยนบ่อย ดูใน AI Studio) ถ้าโดน 429 server จะสลับ key ถัดไปเอง ถ้าหมดทุก key รอบนั้นข้ามไป
