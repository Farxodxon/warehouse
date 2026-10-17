# WMS Backend

Eclair zavodi uchun ombor boshqaruv tizimi (WMS) backend servisi.
Dart + Shelf freymvork, lokal PostgreSQL bazasi (Docker orqali).

Barcha ma'lumot shu kompyuterda saqlanadi — bulut xizmatlariga bog'liq
emas.

> **To'liq qo'llanma:** [QULLANMA.md](QULLANMA.md) — o'rnatish,
> foydalanish, rollar, Excel import, API ro'yxati va muammolarni hal qilish.

## Ishga tushirish

1. Bog'liqliklarni o'rnating:

```
dart pub get
```

2. Postgres'ni ishga tushiring:

```
docker compose up -d
```

3. `.env` faylini yarating (namuna uchun `.env.example`ga qarang):

```
cp .env.example .env
```

Lokal Postgres uchun quyidagi qiymat to'g'ri keladi:

```
DATABASE_URL=postgresql://wms:wms_local_dev@localhost:5432/wms
```

4. Migratsiyalarni ishga tushiring:

```
dart run bin/migrate.dart
```

5. Serverni ishga tushiring:

```
dart run bin/server.dart
```

6. Boshqa terminal oynasida /health endpointni tekshiring:

```
curl -s localhost:8080/health
# {"status":"ok","database":"connected"}
```

## Auth (JWT + bcrypt)

### Migratsiyalarni ishga tushirish

`lib/db/migrations/` papkasidagi `.sql` fayllar `bin/migrate.dart` orqali bajariladi
(kuzatuv `schema_migrations` jadvalida yuritiladi, takror bajarilmaydi):

```
dart run bin/migrate.dart
```

### Endpointlar

```
# Dastlabki admin foydalanuvchini yaratish (faqat users bo'sh bo'lganda)
curl -s -X POST localhost:8080/setup \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@eclair.uz","password":"Test1234!","full_name":"Admin"}'

# Login - JWT token oladi
curl -s -X POST localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@eclair.uz","password":"Test1234!"}'

# Joriy foydalanuvchi (auth middleware orqali himoyalangan)
curl -s localhost:8080/me -H "Authorization: Bearer <TOKEN>"
```

`.env`ga `JWT_SECRET` qatorini qo'shing (token imzolash uchun).

## Organization / Warehouses (A3)

Ichki, bitta tashkilot (Eclair) uchun: `organizations` jadvalda bitta yozuv avtomatik
yaratiladi, `wareshouses` esa ko'p bo'lishi mumkin. Har bir omborga foydalanuvchining
ruxsati `user_warehouse_access` jadvalida saqlanadi (role: `super_admin`,
`warehouse_manager`, `operator`, `viewer`).

Endpointlar (barchasi `Authorization: Bearer <TOKEN>` bilan himoyalangan):

```
# Omborlar ro'yxati (super_admin - hammasi, boshqa - faqat biriktirilgan)
curl -s localhost:8080/warehouses -H "Authorization: Bearer <TOKEN>"

# Yangi ombor (faqat super_admin; yaratuvchiga warehouse_manager roli beriladi)
curl -s -X POST localhost:8080/warehouses \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"name":"Tashkent-1","address":"Yunusobod","city":"Tashkent"}'

# Ombor ma'lumoti
curl -s localhost:8080/warehouses/1 -H "Authorization: Bearer <TOKEN>"

# Omborga foydalanuvchi biriktirish (super_admin yoki warehouse_manager)
curl -s -X POST localhost:8080/warehouses/1/users \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"user_id":2,"role":"operator"}'

# Ombor foydalanuvchilari ro'yxati
curl -s localhost:8080/warehouses/1/users -H "Authorization: Bearer <TOKEN>"
```

## Lokal Postgres (Docker orqali)

Bazaning barcha ma'lumoti shu noutbukda saqlanadi. `docker-compose.yml`
Postgres 18 konteynerini 5432-portda ko'taradi va ma'lumotni `wms_pgdata`
volume'ida saqlaydi — konteyner o'chirilsa ham yo'qolmaydi.

```
docker compose up -d      # Postgres'ni ishga tushirish
docker compose ps         # holatni ko'rish
docker compose stop       # to'xtatish (ma'lumot saqlanadi)
docker compose down       # o'chirish (volume saqlanadi)
```

Konektsiya qatori `.env` da:

```
DATABASE_URL=postgresql://wms:wms_local_dev@localhost:5432/wms
```

## Testlar

`test/smoke_test.dart` **ishlab turgan server va haqiqiy bazani** talab qiladi,
shuning uchun avval serverni ishga tushiring:

```
Terminal 1: dart run bin/server.dart
Terminal 2: dart test test/smoke_test.dart
```

Login hisob ma'lumotlarini muhit orqali berish mumkin
(`WMS_TEST_EMAIL` / `WMS_TEST_PASSWORD`).

Eski `test/server_test.dart` — `shelf` scaffold qoldig'i bo'lib, WMS
endpointlarini tekshirmaydi va `dart test` ni har doim qizil qoldiradi.


## Telegram bot sozlash

Chiqim (OUT/FEFO) xabarlari va `/qoldiq` buyrug'i uchun bot **webhook**
rejimida ishlaydi (Render bepul tarifda uxlab qolgani uchun polling emas).
Bot faqat o'qiydi: chiqim/kirim/tuzatish buyruqlari yo'q.

Sozlash qadamlari:

1. [@BotFather](https://t.me/BotFather) dan yangi bot yarating va
   **token**ni oling (`TELEGRAM_BOT_TOKEN` uchun).
2. Botni xabar yuborilmoqchi bo'lgan guruhga qo'shing.
3. Render'da servis sozlamalariga 3 ta muhit o'zgaruvchisini qo'shing
   (qiymatni kiriting, `sync: false`):

   | O'zgaruvchi | Qiymat |
   |---|---|
   | `TELEGRAM_BOT_TOKEN` | BotFather bergan token |
   | `TELEGRAM_WEBHOOK_SECRET` | Tasodifiy uzun matn (masalan: `openssl rand -hex 32`) |
   | `TELEGRAM_CHAT_IDS` | Ruxsatli chat ID'lari, vergul bilan |

4. Deploy'dan keyin guruhga `/id` yozing - bot `Bu chat ID: <raqam>`
   javobini qaytaradi. Bu raqamni `TELEGRAM_CHAT_IDS`ga qo'shing va
   servisni qayta deploy qiling.

Webhook avtomatik ro'yxatdan o'tkaziladi: server ishga tushganda
`RENDER_EXTERNAL_URL` (yoki `PUBLIC_BASE_URL`) asosida
`<ommaviy manzil>/telegram/webhook` manziliga ulanadi.

Tekshirish (guruhda):

```
/yordam          buyruqlar ro'yxati
/id              chat ID raqami
/qoldiq L001/2   mahsulot qoldig'i (SKU yoki nom bo'yicha)
```

Eslatma: token va secret qiymatlari README'ga, loglarga va commit'ga
yozilmaydi. Env bo'sh bo'lsa webhook o'chiq turadi (`404`), server
ishlashda davom etadi.

Birlik testlari (tarmoq va bazasiz):

```
dart test test/telegram_test.dart
```