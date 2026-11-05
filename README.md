# WMS Backend

Eclair zavodi uchun ombor boshqaruv tizimi (WMS) backend servisi.
Dart + Shelf. Faqat bulutda ishlaydi:

- **Backend:** Render (`https://eclair-wms-app.onrender.com`)
- **Ma'lumotlar bazasi:** Neon PostgreSQL
- **Lokal backend, lokal PostgreSQL va Docker Compose ishlatilmaydi.**

> **To'liq qo'llanma:** [QULLANMA.md](QULLANMA.md) — Render/Neon sozlash,
> foydalanish, rollar, Excel import, API ro'yxati va muammolarni hal qilish.

## Production

```text
Health:  https://eclair-wms-app.onrender.com/health
API:     https://eclair-wms-app.onrender.com
Render:  eclair-wms-app (Frankfurt, Docker)
DB:      Neon PostgreSQL
```

Render bepul tarifda servis uxlab qolishi mumkin. Birinchi so'rov 30-60
soniya kutishi mumkin, keyingi so'rovlar tez javob beradi.

## Muhit o'zgaruvchilari

Barcha qiymatlar **Render dashboard** orqali beriladi. Repo ichida `.env`
fayli yo'q va real qiymatlar commit qilinmaydi.

| O'zgaruvchi | Vazifasi |
|---|---|
| `DATABASE_URL` | Neon PostgreSQL, `sslmode=require` bilan |
| `JWT_SECRET` | Token imzolash uchun uzun tasodifiy qator |
| `PORT` | `8080` |
| `TELEGRAM_BOT_TOKEN` | Telegram bot tokeni (ixtiyoriy) |
| `TELEGRAM_WEBHOOK_SECRET` | Webhook secret (ixtiyoriy) |
| `TELEGRAM_CHAT_IDS` | Ruxsatli chat ID'lari (ixtiyoriy) |

`.env.example` faqat nomlar va Neon namunasi uchun. Uni Render'ga yuklamang.

## Deploy

1. O'zgarishlarni `main` branch'ga qo'shing.
2. Render `autoDeploy: true` orqali yangi versiyani o'zi chiqaradi.
3. Deploy tugagach health check:

```bash
curl -s https://eclair-wms-app.onrender.com/health
# {"status":"ok","database":"connected"}
```

Migratsiyalar Neon bazasiga bir marta qo'llaniladi. Yangi migratsiya
qo'shilganda uni Render Shell yoki ishonchli admin muhitida `DATABASE_URL`
bilan ishga tushiring:

```bash
dart run bin/migrate.dart
```

## Auth (JWT + bcrypt)

```bash
# Dastlabki admin (faqat users bo'sh bo'lganda)
curl -s -X POST https://eclair-wms-app.onrender.com/setup \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@eclair.uz","password":"<PAROL>","full_name":"Admin"}'

# Login
curl -s -X POST https://eclair-wms-app.onrender.com/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@eclair.uz","password":"<PAROL>"}'

# Joriy foydalanuvchi
curl -s https://eclair-wms-app.onrender.com/me \
  -H "Authorization: Bearer <TOKEN>"
```

## Organization / Warehouses

Bitta tashkilot (Eclair). Har bir omborga foydalanuvchi ruxsati
`user_warehouse_access` jadvalida saqlanadi (`super_admin`,
`warehouse_manager`, `operator`, `viewer`).

```bash
# Omborlar
curl -s https://eclair-wms-app.onrender.com/warehouses \
  -H "Authorization: Bearer <TOKEN>"

# Yangi ombor (super_admin)
curl -s -X POST https://eclair-wms-app.onrender.com/warehouses \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"name":"Tashkent-1","address":"Yunusobod","city":"Tashkent"}'

# Foydalanuvchi biriktirish
curl -s -X POST https://eclair-wms-app.onrender.com/warehouses/1/users \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"user_id":2,"role":"operator"}'
```

## Boshlang'ich qoldiq importi

Excel (`Qoldiq` varag'i) orqali mahsulot, partiya va konteynerlarni bir
vaqtda yaratish:

```bash
curl -s -X POST \
  'https://eclair-wms-app.onrender.com/inventory/opening-stock?dry_run=true' \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  --data-binary @opening-stock.json
```

`dry_run=true` hech narsa yozmaydi va xatolarni qaytaradi. Tekshiruvdan
so'ng `dry_run`ni olib tashlang. Batafsil: [QULLANMA.md](QULLANMA.md).

## Testlar

Birlik testlari tarmoq va bazasiz ishlaydi:

```bash
dart analyze
dart test
```

Live smoke test faqat aniq test backend'ga qarshi ishlaydi. Production'ga
tasodifan urilmasligi uchun muhit o'zgaruvchilari majburiy:

```bash
WMS_TEST_BASE_URL=https://<test-backend> \
WMS_TEST_EMAIL=<test-email> \
WMS_TEST_PASSWORD=<test-password> \
dart test test/smoke_test.dart
```

`test/smoke_test.dart` muhit o'zgaruvchilari berilmasa o'tkazib yuboriladi.
Haqiqiy foydalanuvchi parolini repo'ga yoki test fayliga yozmang.

## Telegram bot

Chiqim (OUT/FEFO) xabarlari va `/qoldiq` buyrug'i webhook rejimida ishlaydi
(Render bepul tarifda polling ishlamaydi). Bot faqat o'qiydi.

Render dashboard'ga qo'shing:

| O'zgaruvchi | Qiymat |
|---|---|
| `TELEGRAM_BOT_TOKEN` | BotFather bergan token |
| `TELEGRAM_WEBHOOK_SECRET` | Tasodifiy uzun matn |
| `TELEGRAM_CHAT_IDS` | Ruxsatli chat ID'lari, vergul bilan |

Webhook `RENDER_EXTERNAL_URL` (yoki `PUBLIC_BASE_URL`) asosida avtomatik
ro'yxatdan o'tadi. Tekshirish: guruhda `/id` va `/qoldiq L001/2`.

Token va secret qiymatlari README'ga, loglarga va commit'ga yozilmaydi.
Env bo'sh bo'lsa webhook o'chiq turadi (`404`), server ishlashda davom etadi.
