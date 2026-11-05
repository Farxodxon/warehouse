# Eclair WMS - To'liq qo'llanma

Ombor boshqaruv tizimi (WMS) uchun qo'llanma: bulut arxitekturasi,
Render/Neon sozlash, foydalanish, API va muammolarni hal qilish.

**Production muhiti faqat bulutda:**

- Backend: Render - `https://eclair-wms-app.onrender.com`
- Ma'lumotlar bazasi: Neon PostgreSQL
- Ilova: Flutter (macOS/Windows/mobil), bulut backend'ga ulanadi

---

## Mundarija

1. [Tizim haqida](#1-tizim-haqida)
2. [Bulut arxitekturasi](#2-bulut-arxitekturasi)
3. [Render va Neon](#3-render-va-neon)
4. [Ilovani ishga tushirish](#4-ilovani-ishga-tushirish)
5. [Foydalanish](#5-foydalanish)
6. [Excel importi](#6-excel-importi)
7. [Rollar va ruxsatlar](#7-rollar-va-ruxsatlar)
8. [Texnik arxitektura](#8-texnik-arxitektura)
9. [Ma'lumotlar bazasi](#9-malumotlar-bazasi)
10. [API ro'yxati](#10-api-royxati)
11. [Testlar](#11-testlar)
12. [Muammolar va yechimlar](#12-muammolar-va-yechimlar)
13. [Xavfsizlik](#13-xavfsizlik)

---

## 1. Tizim haqida

Eclair zavodi uchun ombor boshqaruv tizimi. Mahsulot, partiya, konteyner
va joylashuvlarni boshqaradi; chiqim, ko'chirish, sifat tekshiruvi va
qoldiq tarixini yuritadi.

| Imkoniyat | Tavsif |
|---|---|
| Omborlar va zonalar | Ko'p ombor, sovuq/quruq/karantin zonalari, joylashuv kodi |
| Dinamik mahsulotlar | Kategoriya bo'yicha atributlar (matn, son, ha/yo'q, sana) |
| Partiya (lot) | Yaroqlilik muddati, sifat holati, tekshiruv tarixi |
| Konteyner | Har bir fizik idish = shtrix-kod + qoldiq + joylashuv |
| FEFO | Eng yaqin muddatli partiyadan birinchi chiqarish |
| Sifat nazorati | Tekshiruvda, tasdiqlangan, karantin, rad etilgan |
| Ogohlantirishlar | 7 va 30 kunlik muddat ogohlantirishlari |
| Hisobotlar | Qoldiq va harakatlar `.xlsx` hisobotlari |
| Skaner | Shtrix-kodni kameradan o'qish |
| Yorliqlar | QR kodli PDF yorliqlar (67x37 mm) |
| Boshlang'ich qoldiq | Excel orqali mahsulot + partiya + konteyner importi |

---

## 2. Bulut arxitekturasi

```text
Flutter ilova (macOS / Windows / mobil)
        |
        | HTTPS + JWT
        v
Render: eclair-wms-app (Frankfurt, Docker)
        |
        | DATABASE_URL (sslmode=require)
        v
Neon PostgreSQL
```

- Backend stateless: ma'lumot faqat Neon bazasida saqlanadi.
- Render bepul tarifda servis uxlab qolishi mumkin. Birinchi so'rov
  30-60 soniya davom etishi mumkin.
- Backend va baza bitta joyda - Render va Neon. Boshqa backend ishlatilmaydi.

---

## 3. Render va Neon

### Render servisi

`render.yaml` quyidagi servisni tavsiflaydi:

```yaml
services:
  - type: web
    name: eclair-wms-app
    runtime: docker
    region: frankfurt
    autoDeploy: true
    healthCheckPath: /health
```

Render dashboard'da muhit o'zgaruvchilari:

| O'zgaruvchi | Vazifasi |
|---|---|
| `DATABASE_URL` | Neon PostgreSQL ulanish qatori (`sslmode=require`) |
| `JWT_SECRET` | Token imzolash uchun uzun tasodifiy qator |
| `PORT` | `8080` |
| `TELEGRAM_BOT_TOKEN` | BotFather tokeni (ixtiyoriy) |
| `TELEGRAM_WEBHOOK_SECRET` | Webhook secret (ixtiyoriy) |
| `TELEGRAM_CHAT_IDS` | Ruxsatli chat ID'lari (ixtiyoriy) |

Real qiymatlar faqat Render dashboard'da saqlanadi. Repo'ga, README'ga
yoki commit'ga yozilmaydi.

### Neon bazasi

Neon dashboard'dan connection string olinadi va Render'ning
`DATABASE_URL` qiymatiga qo'yiladi. Namunasi:

```text
postgresql://USER:PASSWORD@HOST.neon.tech/DBNAME?sslmode=require
```

`sslmode=require` majburiy - Neon TLS talab qiladi.

### Deploy va migratsiyalar

1. O'zgarishlarni `main` branch'ga qo'shing.
2. Render `autoDeploy: true` orqali yangi versiyani chiqaradi.
3. Health check:

```bash
curl -s https://eclair-wms-app.onrender.com/health
# {"status":"ok","database":"connected"}
```

Yangi SQL migratsiya qo'shilsa, uni Neon bazasiga bir marta qo'llang:

```bash
dart run bin/migrate.dart
```

Buyruq `DATABASE_URL`ni Render'dagi Neon qiymati bilan olishi kerak.
Migratsiyalar `schema_migrations` jadvalida kuzatiladi va takror
bajarilmaydi.

---

## 4. Ilovani ishga tushirish

Ilova default holatda Render backend'ga ulanadi:

```bash
cd eclair-wms-app
flutter pub get
flutter run -d macos
```

Windows:

```bash
flutter run -d windows
```

Manzil `lib/core/config.dart` da:

```dart
const String _defaultServerUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://eclair-wms-app.onrender.com',
);
```

Boshqa bulut muhiti kerak bo'lsa, faqat HTTPS manzil bering:

```bash
flutter run -d macos \
  --dart-define=API_BASE_URL=https://<bulut-backend>
```

Production ilova uchun `https://eclair-wms-app.onrender.com` ishlatiladi.

---

## 5. Foydalanish

### 5.1 Kirish

Email va parol bilan kiriladi. Muvaffaqiyatli kirishdan keyin omborlar
ro'yxati ochiladi. Token 7 kun amal qiladi va ilova yopilganda saqlanmaydi.

### 5.2 Bosh menyu

| Tugma | Vazifasi |
|---|---|
| Skaner | Shtrix-kodni o'qish |
| Yorliqlar | QR yorliqlarni PDF chiqarish |
| Mahsulotlar | Mahsulotlar, partiyalar, Excel import |
| Hisobotlar | Qoldiq va harakatlar hisoboti |
| Ogohlantirishlar | Muddati yaqin partiyalar |
| Sifat | Tekshiruv navbati |
| Yuklash | Boshlang'ich qoldiq importi |
| Chiqish | Tizimdan chiqish |

### 5.3 Omborlar, zonalar, joylashuvlar

Ombor tanlangach ikki tab ochiladi:

- **Zonalar** - sovuq saqlash, quruq saqlash, karantin, boshqa.
- **Joylashuvlar** - aisle, rack, shelf, bin. Kod avtomatik yig'iladi,
  masalan `A-03-02-01`. Har bir omborda kod takrorlanmaydi.

### 5.4 Mahsulotlar

Mahsulot uchun kategoriya, SKU, nomi, birlik (`kg`, `dona`, `litr`),
shtrix-kod va min/max zaxira kiritiladi. Kategoriya tanlanganda uning
atributlari avtomatik chiqadi.

### 5.5 Partiya va konteyner

Partiya - bir kelgan mahsulot to'plami: lot raqami, muddat, sifat holati.
Konteyner - fizik idish: shtrix-kod, miqdor va joylashuv.

Asosiy amallar:

| Amal | Vazifasi |
|---|---|
| Chiqarish (OUT) | Ombordan chiqarish |
| Ko'chirish (TRANSFER) | Boshqa joylashuvga ko'chirish |
| Tuzatish (ADJUSTMENT) | Qoldiqni to'g'rilash; izoh majburiy |

Har bir amal `inventory_transactions` jadvaliga yoziladi: kim, qachon,
qayerdan, qayeriga, qancha.

### 5.6 Sifat nazorati

```text
Tekshiruvda -> Tasdiqlangan | Karantin | Rad etilgan
Karantin    -> Tasdiqlangan | Rad etilgan
Tasdiqlangan -> Karantin | Rad etilgan
Rad etilgan -> yakuniy
```

Har bir o'zgarishga izoh majburiy. Faqat `approved` partiyalar FEFO va
ogohlantirishlarda hisobga olinadi.

### 5.7 Ogohlantirishlar va hisobotlar

Ogohlantirishlar 7 yoki 30 kunlik filtr bilan ko'rsatiladi. Qoldiq
hisobotida mahsulot, SKU, lot, muddat, konteyner, miqdor, ombor va
joylashuv bo'ladi. Harakatlar hisoboti sana oralig'idagi OUT, TRANSFER va
ADJUSTMENT amallarini ko'rsatadi.

---

## 6. Excel importi

### 6.1 Boshlang'ich qoldiq importi

`Yuklash` tugmasi orqali `.xlsx` fayl tanlanadi. Ilova `Qoldiq` varag'ini
oladi (bo'lmasa birinchi varaq).

Majburiy ustunlar:

| Ustun | Vazifasi |
|---|---|
| `Kod` yoki `SKU` | Mahsulot SKU'si |
| `Idish soni` | Fizik idishlar soni |

Qo'shimcha ustunlar:

| Ustun | Vazifasi |
|---|---|
| `Nomi` | Mahsulot nomi (yangi mahsulot uchun) |
| `Kategoriya` | Kategoriya nomi |
| `Idish turi` | Masalan `qop`, `baraban` |
| `1 idish, kg` | Bitta idish og'irligi |
| `Lot raqami` | Partiya raqami; bo'sh bo'lsa `BQ-YYMMDD` |
| `Yaroqlilik muddati` | `YYYY-MM-DD`, `DD.MM.YYYY` yoki Excel sana |
| `Joylashuv kodi` | Ombor tanlangan bo'lsa, masalan `A-01-2-3` |
| `Yaroqlilik (oy)` | Yangi mahsulot uchun saqlash muddati (oy) |

Ish tartibi:

1. Faylni tanlang.
2. Ombor va standart kategoriyani tanlang.
3. **Tekshirish** - `dry_run`, hech narsa yozmaydi, xatolarni ko'rsatadi.
4. Xatolar bo'lmasa **Import qilish** - bitta tranzaksiyada yoziladi.
5. Natijadagi konteynerlar uchun QR yorliqlarni chop eting.

Xatolar qator raqami bilan qaytariladi. Xato bo'lsa import to'liq
to'xtaydi va hech narsa yozilmaydi.

Muhim:

- SKU'dagi kirill homogliflari avtomatik lotinga almashtiriladi.
- Shtrix-kod: `<SKU>-YYMMDD-NN`, masalan `L-001-2-261105-01`.
- Bir xil mahsulot va lot mavjud bo'lsa, yangi partiya yaratilmaydi.
- `Idish soni = 0` bo'lsa, faqat mahsulot kartasi yaratiladi (nom bo'lsa).
- Qayta import qilinsa qoldiq ikki baravar bo'ladi.

### 6.2 Mahsulotlarni ommaviy import qilish

`Mahsulotlar` ekranidagi Excel tugmasi orqali ko'p mahsulot kartasini
yaratish mumkin. Ilova sarlavhalarni avtomatik aniqlaydi yoki ustunlarni
qo'lda moslashtirish imkonini beradi.

---

## 7. Rollar va ruxsatlar

| Rol | Qayerda | Huquqlar |
|---|---|---|
| `super_admin` | global | Hammasi, barcha omborlar |
| `warehouse_manager` | ombor | Mahsulot, zona/joylashuv, sifat, hisobot |
| `operator` | ombor | OUT, TRANSFER, tarix |
| `viewer` | ombor | Faqat ko'rish |

| Amal | super_admin | warehouse_manager | operator | viewer |
|---|---|---|---|---|
| Mahsulot ko'rish | ha | ha | ha | ha |
| Mahsulot qo'shish/tahrirlash | ha | ha | yo'q | yo'q |
| Kategoriya yaratish | ha | yo'q | yo'q | yo'q |
| Zona/joylashuv qo'shish | ha | ha | yo'q | yo'q |
| Partiya/konteyner qo'shish | ha | ha | ha | yo'q |
| OUT / TRANSFER | ha | ha | ha | yo'q |
| ADJUSTMENT | ha | ha | yo'q | yo'q |
| Sifat holati | ha | ha | yo'q | yo'q |
| Hisobotlar | ha | ha | yo'q | yo'q |
| Foydalanuvchi biriktirish | ha | o'z ombori | yo'q | yo'q |

Barcha ruxsatlar backend'da tekshiriladi. Frontend faqat tugmalarni
yashiradi.

---

## 8. Texnik arxitektura

| Qatlam | Texnologiya |
|---|---|
| Backend | Dart 3, Shelf, shelf_router |
| Ma'lumotlar bazasi | Neon PostgreSQL |
| Hosting | Render (Docker, Frankfurt) |
| Autentifikatsiya | JWT (7 kun), bcrypt |
| Frontend | Flutter 3, Riverpod, Dio |
| QR/PDF | pdf, barcode, printing |
| Excel | excel |

So'rov oqimi:

```text
Flutter -> HTTPS -> Render (Shelf + auth + ruxsat) -> Neon PostgreSQL
```

`lib/db/connection.dart` `DATABASE_URL`ni muhitdan oladi. Neon uchun
`sslmode=require` TLS'ni yoqadi.

---

## 9. Ma'lumotlar bazasi

Asosiy jadvallar:

```text
organizations
  -> warehouses -> zones -> storage_locations
  -> user_warehouse_access -> users
  -> batch_containers -> batches -> products -> product_categories
       -> storage_locations
  -> inventory_transactions -> users
quality_status_history -> batches, users
```

Muhim jadvallar:

- `users` - email, bcrypt parol, global rol, organization.
- `warehouses`, `zones`, `storage_locations` - ombor tuzilmasi.
- `product_categories`, `products` - katalog va atributlar.
- `batches`, `batch_containers` - partiya va fizik idishlar.
- `inventory_transactions` - OUT/TRANSFER/ADJUSTMENT audit izi.
- `quality_status_history` - sifat holati tarixi.

Migratsiyalar `lib/db/migrations/*.sql` da, tartib bilan bajariladi.
Bajarilganlari `schema_migrations` jadvalida kuzatiladi.

---

## 10. API ro'yxati

Bazaviy manzil: `https://eclair-wms-app.onrender.com`

`lock` belgisi token talab qiladi: `Authorization: Bearer <TOKEN>`.

### Tizim

| Metod | Yo'l | Vazifasi |
|---|---|---|
| GET | `/health` | Server va baza holati |
| POST | `/setup` | Birinchi admin (baza bo'sh bo'lsa) |
| POST | `/login` | JWT olish |

### Autentifikatsiya

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock GET | `/me` | Joriy foydalanuvchi |

### Omborlar

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock GET | `/warehouses` | Ro'yxat |
| lock POST | `/warehouses` | Yangi ombor (super_admin) |
| lock GET | `/warehouses/{id}` | Ombor ma'lumoti |
| lock GET | `/warehouses/{id}/users` | Foydalanuvchilar |
| lock POST | `/warehouses/{id}/users` | Rol berish |

### Kategoriyalar va mahsulotlar

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock GET | `/product-categories` | Ro'yxat |
| lock POST | `/product-categories` | Yangi kategoriya |
| lock GET | `/product-categories/{id}` | Bitta kategoriya |
| lock GET | `/products` | Ro'yxat (`?search=`, `?category_id=`) |
| lock POST | `/products` | Yangi mahsulot |
| lock PUT | `/products/{id}` | Tahrirlash |
| lock GET | `/products/{id}` | Mahsulot |
| lock GET | `/products/barcode/{code}` | Shtrix-koddan |

### Zonalar va joylashuvlar

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock GET | `/warehouses/{id}/zones` | Zonalar |
| lock POST | `/warehouses/{id}/zones` | Yangi zona |
| lock GET | `/warehouses/{id}/storage-locations` | Joylashuvlar |
| lock POST | `/warehouses/{id}/storage-locations` | Yangi joylashuv |
| lock GET | `/storage-locations/{id}` | Bitta joylashuv |
| lock GET | `/storage-locations/code/{code}` | Koddan topish |

### Partiyalar va konteynerlar

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock GET | `/products/{id}/batches` | Partiyalar |
| lock POST | `/products/{id}/batches` | Yangi partiya |
| lock GET | `/products/{id}/locations` | Mahsulot qayerda |
| lock GET | `/batches/{id}/containers` | Konteynerlar |
| lock POST | `/batches/{id}/containers` | Yangi konteyner |
| lock GET | `/containers/barcode/{code}` | Shtrix-koddan |

### Inventory

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock POST | `/inventory/out` | Chiqarish |
| lock POST | `/inventory/transfer` | Ko'chirish |
| lock POST | `/inventory/adjustment` | Tuzatish |
| lock GET | `/inventory/transactions` | Tarix |
| lock POST | `/inventory/opening-stock` | Excel boshlang'ich qoldiq (`?dry_run=true`) |

### FEFO

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock GET | `/products/{id}/fefo-plan?quantity=` | Reja |
| lock POST | `/products/{id}/fefo-out` | Reja bo'yicha chiqarish |

FEFO `expiry_date` bo'yicha o'sadi (`NULL` oxirda), keyin partiya va
konteyner id'si. Faqat `approved` va `active` konteynerlar hisoblanadi.

### Sifat

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock GET | `/quality/pending` | Tekshiruv navbati |
| lock POST | `/batches/{id}/quality-status` | Holatni o'zgartirish |
| lock GET | `/batches/{id}/quality-history` | Tarix |

### Ogohlantirishlar va hisobotlar

| Metod | Yo'l | Vazifasi |
|---|---|---|
| lock GET | `/alerts/expiring-batches?days=` | Ogohlantirishlar |
| lock GET | `/alerts/summary` | Badge uchun sonlar |
| lock GET | `/reports/stock.xlsx` | Qoldiq hisoboti |
| lock GET | `/reports/transactions.xlsx?from=&to=` | Harakatlar |

### Xatolar

| Kod | Ma'no |
|---|---|
| `unauthorized` | Token yo'q yoki muddati tugagan |
| `forbidden` | Ruxsat yo'q |
| `invalid_request` | So'rov noto'g'ri |
| `validation_failed` | Import qatorlarida xatolar |
| `sku_already_exists` | SKU band |
| `barcode_already_exists` | Shtrix-kod band |
| `insufficient_quantity` | Qoldiq yetarli emas |
| `invalid_transition` | Sifat holati o'tkazib bo'lmaydi |

---

## 11. Testlar

### Birlik testlari

Tarmoq va bazasiz:

```bash
cd warehouse
dart analyze
dart test
```

```bash
cd eclair-wms-app
flutter test
```

### Live smoke test

Faqat alohida test backend'ga qarshi ishlaydi. Production'ga tasodifan
urilmasligi uchun uchta muhit o'zgaruvchisi majburiy:

```bash
WMS_TEST_BASE_URL=https://<test-backend> \
WMS_TEST_EMAIL=<test-email> \
WMS_TEST_PASSWORD=<test-password> \
dart test test/smoke_test.dart
```

Muhit o'zgaruvchilari berilmasa test o'tkazib yuboriladi.

### Frontend live testi

Skaner live testi ham faqat aniq test backend'da ishlaydi:

```bash
WMS_LIVE_TEST=1 \
WMS_TEST_BASE_URL=https://<test-backend> \
WMS_TEST_EMAIL=<test-email> \
WMS_TEST_PASSWORD=<test-password> \
flutter test test/features/scanner/scan_result_test.dart
```

---

## 12. Muammolar va yechimlar

### `health` sekin javob beradi

Render bepul tarifda servis uxlab qoladi. Birinchi so'rov 30-60 soniya
kutishi mumkin. Keyingi so'rovlar tez.

### `502` yoki `Application failed to respond`

Render dashboard -> Logs bo'limini tekshiring. Ko'p sabab: `DATABASE_URL`
noto'g'ri, Neon uxlab qolgan yoki migratsiya bajarilmagan.

### `{"error":"database_unavailable"}` yoki ulanish xatosi

- `DATABASE_URL` Neon qiymati ekanini tekshiring.
- `sslmode=require` borligini tekshiring.
- Neon loyihasi pauza bo'lmaganini tekshiring.

### `relation "users" does not exist`

Migratsiyalar Neon bazasiga qo'llanmagan:

```bash
DATABASE_URL=<neon-url> dart run bin/migrate.dart
```

### `401 unauthorized`

Token yo'q yoki muddati tugagan. Qayta login qiling.

### `403 forbidden`

Foydalanuvchining ombor roli yetarli emas. `warehouse_manager` yoki
`super_admin` kerak.

### `404 Route not found`

Endpoint hali Render'ga deploy qilinmagan yoki yo'l noto'g'ri. So'nggi
deploy holatini Render dashboard'da tekshiring.

### Excel import xatolari

`Tekshirish` (`dry_run`) qator raqami va sababni qaytaradi. Ko'p uchraydigan
sabablar: SKU bo'sh, idish soni son emas, yaroqlilik sanasi noto'g'ri,
ombor tanlanmagan, joylashuv kodi topilmadi.

### QR yorliq chiqmaydi

Konteyner barcode'i mavjudligini va printer ulanganini tekshiring. Ko'p
yorliq 300 tadan bo'lib chiqariladi.

---

## 13. Xavfsizlik

- `DATABASE_URL`, `JWT_SECRET` va Telegram qiymatlari faqat Render
  dashboard'da saqlanadi.
- Real parollar, tokenlar va connection string'lar repo'ga yozilmaydi.
- Login tokeni 7 kun amal qiladi va ilova yopilganda saqlanmaydi.
- Barcha ruxsatlar backend'da tekshiriladi; frontend faqat UI yashiradi.
- Neon ulanishida `sslmode=require` majburiy.

---

## Tezkor havolalar

```bash
# Health
curl -s https://eclair-wms-app.onrender.com/health

# Ilova
cd eclair-wms-app && flutter run -d macos

# Backend tekshiruv
cd warehouse && dart analyze && dart test

# Ilova tekshiruv
cd eclair-wms-app && flutter analyze && flutter test

# Migratsiya (Neon)
DATABASE_URL=<neon-url> dart run bin/migrate.dart
```
