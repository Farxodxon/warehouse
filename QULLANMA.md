# Eclair WMS — To'liq qo'llanma

Ombor boshqaruv tizimi (WMS) uchun to'liq qo'llanma: o'rnatish, foydalanish,
texnik arxitektura va muammolarni hal qilish.

---

## Mundarija

1. [Tizim haqida](#1-tizim-haqida)
2. [Tuzilma](#2-tuzilma)
3. [O'rnatish](#3-ornatish)
4. [Ishga tushirish](#4-ishga-tushirish)
5. [Foydalanish — amaliy qo'llanma](#5-foydalanish--amaliy-qollanma)
6. [Excel orqali mahsulot importi](#6-excel-orqali-mahsulot-importi)
7. [Rollar va ruxsatlar](#7-rollar-va-ruxsatlar)
8. [Texnik arxitektura](#8-texnik-arxitektura)
9. [Ma'lumotlar bazasi](#9-malumotlar-bazasi)
10. [API ro'yxati](#10-api-royxati)
11. [Testlar](#11-testlar)
12. [Muammolar va yechimlar](#12-muammolar-va-yechimlar)
13. [Keyingi bosqichlar](#13-keyingi-bosqichlar)

---

## 1. Tizim haqida

Eclair zavodi uchun mo'ljallangan ombor boshqaruv tizimi. Mahsulot, partiya,
konteyner va joylashuvlarni boshqaradi; kim chiqim qilganini, qayerdan
qayeriga ko'chirilganini va sifat tekshiruvini qayd etadi.

**Asosiy imkoniyatlar:**

| Imkoniyat | Tavsif |
|---|---|
| Omborlar va zonalar | Ko'p ombor, har birida zonalar (sovuq/&quruq/karantin) va joylashuv kodi |
| Dinamik mahsulotlar | Kategoriya orqali har bir mahsulot turiga o'z atributlarini berish |
| Partiya (lot) | Ishlab chiqarilgan/muddati, sifat holati, tekshiruv tarixi |
| Konteyner | Har bir fizik konteyner = shtrix-kod + qoldiq + joylashuv |
| FEFO | Eng muddati yaqin partiyadan birinchi chiqarish |
| Sifat nazorati | Tekshiruvda → Tasdiqlangan / Karantin / Rad etilgan |
| Ogohlantirish | 7 va 30 kunlik muddat ogohlantirishlari |
| Hisobotlar | Qoldiq va harakatlar hisoboti (.xlsx) |
| Skaner | Kameradan shtrix-kod o'qish |
| Yorliqlar | QR kodli yorliqlar PDF chiqarish (A4, 67×37 mm) |

**Ma'lumotlar qayerda saqlanadi:** butun ma'lumot shu kompyuterda, Docker
konteyneridagi PostgreSQL 18 da. Bulut xizmatlariga bog'liq emas — internet
uzilsa ham ishlaydi. Ma'lumot `wms_pgdata` Docker volume'ida turadi.

---

## 2. Tuzilma

Ikki alohida repositoriya bor:

```
Default Project/
├── warehouse/          ← Backend (Dart + Shelf + PostgreSQL)
│   ├── bin/
│   │   ├── server.dart     ← HTTP server, 42 ta endpoint
│   │   └── migrate.dart    ← migratsiyalarni ishga tushirish
│   ├── lib/
│   │   ├── auth/           ← JWT, bcrypt, ruxsatlar
│   │   ├── db/
│   │   │   ├── connection.dart   ← PostgreSQL ulanishi
│   │   │   └── migrations/       ← 13 ta .sql fayl
│   │   ├── inventory/      ← FEFO, ogohlantirish, sifat
│   │   ├── products/       ← atributlar, validatsiya, joylashuv kodi
│   │   └── reports/        ← Excel hisobotlar
│   ├── test/
│   ├── docker-compose.yml ← lokal Postgres
│   └── .env               ← ulanish sozlamalari (git ga kirmaydi)
│
└── eclair-wms-app/     ← Frontend (Flutter)
    └── lib/
        ├── core/           ← API klient, konfiguratsiya
        └── features/
            ├── auth/       ← login
            ├── warehouses/ ← omborlar, zonalar, joylashuvlar
            ├── products/   ← mahsulot, partiya, konteyner, import
            ├── scanner/    ← kamera skaneri
            ├── quality/    ← sifat nazorati
            ├── alerts/     ← muddat ogohlantirishlari
            ├── labels/     ← QR yorliqlar
            └── reports/    ← hisobotlar
```

Backend stateless — u hech narsani diskka yozmaydi. Har bir so'rovda
PostgreSQL'ga ulanadi. Ma'lumot faqat bazada.

---

## 3. O'rnatish

### Talablar

| Dastur | Versiya | Izoh |
|---|---|---|
| Docker Desktop | 29+ | Postgres konteyneri uchun |
| Dart SDK | 3.2.6+ | 3.12.2 sinab ko'rilgan |
| Flutter | 3.10+ | 3.44.6 sinab ko'rilgan |

Tekshirish:

```powershell
dart --version
flutter --version
docker --version
```

### Backend

```powershell
cd warehouse
dart pub get
```

### `.env` fayli

`.env.example` dan nusxa oling:

```powershell
Copy-Item .env.example .env
```

Lokal Postgres uchun quyidagi qiymatlar to'g'ri keladi:

```ini
DATABASE_URL=postgresql://wms:wms_local_dev@localhost:5432/wms
JWT_SECRET=uzun-tasodifiy-qator
PORT=8080
```

`JWT_SECRET` — token imzolash kaliti. Hech qachon real qiymatni
`git commit` qilmang, `.env` `.gitignore`da bor.

### Frontend

```powershell
cd eclair-wms-app
flutter pub get
```

Frontend va backend aloqasi `API_BASE_URL` orqali sozlanadi
(`lib/core/config.dart`). Default `http://localhost:8080`, ya'ni o'zgartirish
shart emas.

---

## 4. Ishga tushirish

Har bir ishga tushirishda **ikki alohida terminal** kerak.

### Terminal 1 — ma'lumotlar bazasi

```powershell
cd warehouse
docker compose up -d
```

Tekshirish:

```powershell
docker compose ps
# STATUS: Up ... (healthy)
```

### Terminal 2 — backend server

```powershell
cd warehouse
dart run bin/migrate.dart      # faqat birinchi marta
dart run bin/server.dart
```

`Server running on http://localhost:8080` chiqishi kerak.

### Tekshirish

```powershell
curl -s localhost:8080/health
# {"status":"ok","database":"connected"}
```

### Terminal 3 — ilova

```powershell
cd eclair-wms-app
flutter run -d windows
```

Yoki oldindan build qilib ishga tushirish:

```powershell
flutter build windows --debug
.\build\windows\x64\runner\Debug\wms_app.exe
```

### To'xtatish

```powershell
docker compose stop            # ma'lumot saqlanadi
Ctrl+C                        # server terminalda
```

### Boshqa qurilmadan ulanish

Tarmoq orqali (telefon, boshqa kompyuter):

```powershell
ipconfig | Select-String "IPv4"
curl -s http://172.20.10.12:8080/health
```

8080-port ochiq bo'lishi kerak (bir marta admin sifatida):

```powershell
New-NetFirewallRule -DisplayName "WMS Backend 8080" `
  -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow
```

---

## 5. Foydalanish — amaliy qo'llanma

### 5.1 Kirish

`Tizimga kirish` ekranida email va parol. Muvaffaqiyatli kirishdan keyin
**Omborlar** ro'yxati ochiladi.

Birinchi admin foydalanuvchisini yaratish (faqat `users` jadvali bo'sh
bo'lsa):

```powershell
curl -s -X POST localhost:8080/setup `
  -H "Content-Type: application/json" `
  -d '{"email":"admin@eclair.uz","password":"Test1234!","full_name":"Admin"}'
```

> Muhim: hozir bazada 2 ta foydalanuvchi bor, shuning uchun `/setup` 403
> qaytaradi (`already_initialized`).

### 5.2 Bosh menyu

Omborlar ekranining yuqori panelida barcha bo'limlar:

| Tugma | Vazifasi |
|---|---|
| Skaner | Kameradan shtrix-kod o'qish |
| Yorliqlar | QR yorliqlar PDF chiqarish |
| Mahsulotlar | Mahsulotlar ro'yxati, qo'shish, Excel import |
| Hisobotlar | Excel hisobot yuklab olish (boshqaruvchilar uchun) |
| 🔔 | Muddat ogohlantirishlari (raqam bilan) |
| ✅ | Sifat tekshiruv navbati (raqam bilan) |
| ↪ | Chiqish |

### 5.3 Omborlar va joylashuvlar

**Omborlar** ro'yxatidan birini tanlang. Unda ikki tab bor:

**Zonalar** — omborning mantiqiy qismlari. `Zona qo'shish` bilan qo'shiladi:

- Nomi (majburiy)
- Turi: sovuq saqlash / quruq saqlash / karantin / boshqa

**Joylashuvlar** — aniq saqlash o'rni. `Joylashuv qo'shish` orqali:

| Maydon | Misol | Majburiy |
|---|---|---|
| Zona | (tanlanadi) | yo'q |
| Aisle | `A` | ha |
| Rack | `03` | ha |
| Shelf | `02` | ha |
| Bin | `01` | ha |
| Sig'imi | `500` | yo'q |

Kod avtomatik yig'iladi: `A-03-02-01`. Har bir omborda kod takrorlanmaydi.

### 5.4 Mahsulotlar

`Mahsulotlar` → qo'shish tugmasi. Quyidagilar kiritiladi:

- Kategoriya (majburiy)
- SKU (majburiy, tashkilot ichida takrorlanmaydi)
- Nomi (majburiy)
- Birlik: `kg`, `dona`, `litr` (majburiy)
- Shtrix-kod (ixtiyoriy)
- Min / Max zaxira (ixtiyoriy)

**Kategoriya atributlari:** kategoriya tanlanganida uning atributlar shakllari
avtomatik paydo bo'ladi. Masalan "Xom ashyo" kategoriyasi `saqlash harorati`
(`text`), `ishlatish maqsadi` (`text`) atributlarini talab qilishi mumkin.
Turlar: matn, son, ha/yo'q, sana.

**Qayerda?** — mahsulot qaysi joylashuvda qancha turganini ko'rsatadi
(ombor, zona, kod, lot, miqdor).

### 5.5 Partiya va konteyner

**Partiya (lot)** — bir marta kelgan mahsulot partiyasi. Lot raqami, ishlab
chiqarilgan sana, muddati va sifat holati bilan.

**Konteyner** — fizik idish (palet, quti). Har biriga shtrix-kod beriladi va
u ma'lum joylashuvga qo'yiladi. Asosiy ish amaliyoti shu yerda:

| Amal | Vazifasi |
|---|---|
| Chiqarish (OUT) | Omibordan chiqarish. Qolgan miqdor ko'rsatiladi |
| Ko'chirish (TRANSFER) | Boshqa joylashuvga ko'chirish |
| Tuzatish (ADJUSTMENT) | Qoldiqni to'g'rilash. **Izoh majburiy** |

Har bir amal `inventory_transactions` jadvaliga yoziladi: kim, qachon, qayerdan,
qayeriga, qancha. Bu **audit izi** — hech qanday o'zgarish yashirilmaydi.

### 5.6 Sifat nazorati

Partiya `Tekshiruvda` holatidan chiqishi kerak:

```
Tekshiruvda → Tasdiqlangan | Karantin | Rad etilgan
Karantin   → Tasdiqlangan | Rad etilgan
Tasdiqlangan → Karantin | Rad etilgan
Rad etilgan → (yakuniy, qaytib bo'lmaydi)
```

Har bir o'zgarishga **izoh majburiy** va kim o'zgartirgani saqlanadi.
Faqat `Tasdiqlangan` partiyalar FEFO va ogohlantirishlarda hisobga olinadi.

### 5.7 Ogohlantirishlar

🔔 tugmasi muddati yaqinlashgan partiyalarni ko'rsatadi. 7 kun yoki 30
kunlik filtr. Ranglar:

| Rang | Holat |
|---|---|
| Qizil | Muddati o'tgan |
| Sariq/oranj | 7 kundan kam qoldi |
| Sariq | Ko'proq qoldi |

Bitta qator bir nechta joylashuvda bo'lsa, hammasi ko'rsatiladi.

### 5.8 Hisobotlar

**Qoldiq hisoboti** — joriy qoldiq: mahsulot, SKU, kategoriya, lot, muddat,
konteyner, miqdor, ombor, zona, joylashuv kodi. 7 kundan kam qolgan
qatorlar qizilga bo'yaladi.

**Harakatlar hisoboti** — sana oralig'ida bo'lgan barcha OUT / TRANSFER /
ADJUSTMENT. Qator rangi turga bog'liq: OUT qizil, TRANSFER ko'k, ADJUSTMENT
sariq.

Ikkalasida ombor filtri ixtiyoriy. Fayl `Downloads` papkasiga saqlanadi.

---

## 6. Excel orqali mahsulot importi

Ko'p mahsulotni bir vaqtda kiritish uchun.

`Mahsulotlar` ekranida Excel ikonkasi → `.xlsx` faylni tanlang →
varaqni tanlang → ustunlarni tekshiring → kategoriya tanlang →
**Yuborish**.

### Ustunlarni avtomatik aniqlash

Ilova birinchi qatorni sarlavha deb oladi (agar `Sarlavha qatori` belgilangan
bo'lsa) va har bir ustunni o'zi nomi bo'yicha tanib oladi:

| Sarlavhada qidiriladi | Vazifasi |
|---|---|
| `код`, `sku`, `code` | SKU |
| `ном`, `назв`, `name` | Nomi |
| `муддат`, `ярокл`, `яроқл`, `срок`, `shelf` | Yaroqlilik muddati |
| `№`, `no`, `n` | Tartib raqami (SKU generatsiya uchun) |
| Kategoriya atributlari `label` yoki `key` bo'yicha | Atribut |

Birinchi topilgan ustun **nomi** bo'ladi. SKU ustuni topilmasa va SKU
belgilanmagan bo'lsa, SKU avtomatik yaratiladi: `PLK-<tartib raqami>`.
Prefix o'zgartirilishi mumkin.

Har bir ustun uchun ro'yxatdan **qo'lda** tanlash mumkin: *E'tiborsiz
qoldirish / SKU (kod) / Nomi / Yaroqlilik muddati / Tartib raqam /
atributlar...*

### Yaroqlilik muddati

`Oylarda` belgilangan bo'lsa, qiymat **30 kunlik** ko'paytiriladi.
Masalan 24 oy → 720 kun. Aks holda qiymat kun sifatida o'qiladi.

### Qatorlar nima uchun o'tkazilmaydi

| Sabab | Tushuntirish |
|---|---|
| Nomi yo'q | Nomi ustuni bo'sh |
| SKU yo'q | SKU belgilangan, lekin qator bo'sh |
| Faylda takrorlangan SKU | Bir faylda SKU ikki marta |
| Bazada allaqachon bor | Bu SKU bazada mavjud |

O'tkazilmagan qatorlar sababi bilan ko'rsatiladi. Biror qator xato
bo'lsa, qolganlari to'xtamaydi — import `5` tadan iborat guruhlarda
ketma-ket yuboriladi.

### Namuna jadval

```
| SKU    | Nomi              | Yaroqlilik (oy) | Saqlash harorati | Ishlatish     |
|--------|-------------------|----------------|------------------|---------------|
| PLK-001| Sodium laureth    | 24             | 15-25            | Yuvish        |
| PLK-002| Plyonka 60 mk     | 36             | 5-25             | Qadovlash     |
```

Shu jadval `.xlsx` ko'rinishida bo'lsa, barcha ustunlar avtomatik
aniqlanadi.

---

## 7. Rollar va ruxsatlar

Bitta foydalanuvchi bir nechta omborda turli rol bilan ishlashi mumkin
(`user_warehouse_access` jadvali). Rol `users.role` da **global**, ombor roli
**mahalliy**.

| Rol | Qayerda | Nimaga qodir |
|---|---|---|
| `super_admin` | global | Hammasi. Barcha omborlar, barcha hisobotlar |
| `warehouse_manager` | ombor | Mahsulot yaratish, zona/joylashuv, sifat, hisobot, ro'l berish |
| `operator` | ombor | Chiqarish, ko'chirish, tarix ko'rish |
| `viewer` | ombor | Faqat ko'rish |

### Amallar bo'yicha

| Amal | super_admin | warehouse_manager | operator | viewer |
|---|---|---|---|---|
| Mahsulot ro'yxati (o'z ombori) | ✅ | ✅ | ✅ | ✅ |
| Mahsulot qo'shish/tahrirlash | ✅ | ✅ | ❌ | ❌ |
| Kategoriya yaratish | ✅ | ❌ | ❌ | ❌ |
| Zona / joylashuv qo'shish | ✅ | ✅ | ❌ | ❌ |
| Partiya / konteyner qo'shish | ✅ | ✅ | ✅ | ❌ |
| OUT / TRANSFER | ✅ | ✅ | ✅ | ❌ |
| ADJUSTMENT | ✅ | ✅ | ❌ | ❌ |
| Sifat holatini o'zgartirish | ✅ | ✅ | ❌ | ❌ |
| Hisobotlar | ✅ | ✅ | ❌ | ❌ |
| Omborga foydalanuvchi biriktirish | ✅ | ✅ (o'z ombori) | ❌ | ❌ |
| Yangi ombor yaratish | ✅ | ❌ | ❌ | ❌ |
| Yangi kategoriya yaratish | ✅ | ❌ | ❌ | ❌ |

> Kategoriya yaratish faqat `super_admin` ga ochiq
> (`_createProductCategoryHandler`, `bin/server.dart:641` yaqinida).
> `warehouse_manager` mahsulot yarata oladi, lekin uning kategoriyasi
> bo'lishi kerak — ya'ni kategoriya `super_admin` tomonidan oldindan
> yaratilishi lozim. Bu ongli cheklov: katalogni kuzatish markazda qoladi.

> `operator` global roli `users.role` da bo'lsa, `_canOperateInventory` uni
> inventory amallariga yo'ladi — bu eski moslik mexanizmi. Oddiy foydalanish
> ombor roli orqali.

### Foydalanuvchi berish

```powershell
curl -s -X POST localhost:8080/warehouses/1/users `
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" `
  -d '{"user_id":2,"role":"operator"}'
```

---

## 8. Texnik arxitektura

### Texnologiyalar

| Qatlam | Texnologiya |
|---|---|
| Backend | Dart 3, Shelf, shelf_router |
| Ma'lumotlar bazasi | PostgreSQL 18 (Docker) |
| Autentifikatsiya | JWT (7 kun), bcrypt |
| Frontend | Flutter 3, Riverpod, Dio |
| Kamera | mobile_scanner (faqat mobil) |
| QR/PDF | pdf, barcode, printing |
| Excel | excel (o'qish va yozish) |

### So'rov oqimi

```
Flutter ilova
    │  Dio HTTP + "Authorization: Bearer <token>"
    ▼
Shelf server (0.0.0.0:8080)
    │  authMiddleware → JWT tekshiruvi
    ▼
Ruxsat tekshiruvi (_canManageProducts / _canOperateInventory / _checkWarehouseAccess)
    ▼
openConnection() → PostgreSQL (localhost:5432)
    ▼
javob (JSON yoki .xlsx)
```

### Autentifikatsiya

Login `JWT` qaytaradi, 7 kun amal qiladi. Keyingi so'rovlarda
`Authorization: Bearer <token>` yuboriladi.

**Token saqlanmaydi** — ilova yopilganda kirish yo'qoladi, qayta kirish
kerak. Bu ataylab qilingan (avval saqlangan bo'lsa, o'g'irlangan tayyor
holatda kirish mumkin bo'lardi).

### Ruxsat tekshiruvi

`super_admin` barcha omborlarni ko'radi. Boshqalar faqat
`user_warehouse_access` da biriktirilgan omborlar. Bu **backend**da
 tekshiriladi — frontend faqat tugmalarni yashiradi.

> Muhim: frontend'da yashirilgan tugma backend'da tekshiriladi, lekin
> backend'da tekshirilmaydigan joy bo'lsa, API orqali atlab o'tish mumkin.
> Shu sababli barcha tekshiruvlar serverda bajarilgan.

### Ma'lumotlar bazasi ulanishi

`lib/db/connection.dart` `.env` faylini `DotEnv(includePlatformEnvironment: true)`
bilan o'qiydi — ya'ni muhit o'zgaruvchilari ham ko'riladi.

`sslmode=require` bo'lsa TLS yoqiladi. Lokal Postgres uchun kerak emas
(localhost).

---

## 9. Ma'lumotlar bazasi

13 ta jadval. Barchasi `organizations` orqali bitta tashkilotga bog'langan
(Eclair).

### Asosiy jadvallar

```
organizations (1)
    └── warehouses
            ├── zones
            │       └── storage_locations
            ├── user_warehouse_access ──→ users
            └── batch_containers ──→ batches ──→ products ──→ product_categories
                    └── storage_locations
            └── inventory_transactions ──→ users
quality_status_history ──→ batches, users
```

### `users` — foydalanuvchilar

| Ustun | Turi | Izoh |
|---|---|---|
| id | SERIAL | PK |
| email | TEXT UNIQUE | login |
| password_hash | TEXT | bcrypt |
| full_name | TEXT | |
| role | TEXT | `super_admin` (global) |
| organization_id | INTEGER FK | |

### `warehouses` — omborlar

`organization_id` FK, `name`, `address`, `city`.

### `user_warehouse_access` — ombor rollari

`user_id` + `warehouse_id` (UNIQUE juftligi), `role`
(`super_admin` / `warehouse_manager` / `operator` / `viewer`).

### `product_categories` — kategoriyalar

`name`, `product_type`, `attribute_schema` (JSONB, default `[]`).

**Atribut shakli:** `{"key": "harorat", "label": "Saqlash harorati",
"type": "text"}`. Ruxsat etilgan turlar: `text`, `number`, `bool`, `date`.

### `products` — mahsulotlar

`category_id` FK, `sku` (tashkilot ichida UNIQUE), `barcode` (indekslangan),
`name`, `unit`, `min_stock`, `max_stock`, `default_shelf_life_days`,
`attributes` (JSONB).

### `batches` — partiyalar

`product_id` FK, `lot_number`, `manufacture_date`, `expiry_date`,
`received_date`, `quality_status`
(`pending_inspection` / `approved` / `quarantine` / `rejected`).

### `batch_containers` — konteynerlar

`batch_id` FK, `container_barcode` (global UNIQUE), `quantity`, `location_id` FK,
`status` (`active` / `reserved` / `expired` / `damaged`).

### `inventory_transactions` — audit izi

`type` (`OUT` / `TRANSFER` / `ADJUSTMENT`), `batch_container_id` FK,
`from_location_id`, `to_location_id`, `quantity`, `performed_by` FK, `note`.

### `storage_locations`

`zone_id` FK, `aisle`, `rack`, `shelf`, `bin`, `code` (ombor ichida UNIQUE),
`capacity_units`, `current_units`.

### `quality_status_history`

`batch_id` FK, `from_status`, `to_status`, `note`, `changed_by` FK,
`changed_at`.

### Migratsiyalar

`bin/migrate.dart` `lib/db/migrations/*.sql` fayllarini **nom bo'yicha
tartiblab** bajaradi. Bajarilgan fayllar `schema_migrations` jadvalida
kuzatiladi va qayta bajarilmaydi.

```
SKIP: 001_create_users.sql (allaqachon bajarilgan)
Migratsiya tugadi: 0 qo'llandi, 13 o'tkazildi
```

Har bir migratsiya **tranzaksiya ichida** bajariladi — xato bo'lsa butun
migratsiya orqaga qaytariladi.

> Yangi migratsiya qo'shish: `lib/db/migrations/014_....sql` nomi bilan
> yarating. Nomi `015`, `016` dan kichik bo'lmasligi kerak.

---

## 10. API ro'yxati

Barcha endpoint'lar `/` dan boshlanadi. `🔒` — token talab qiladi.

### Tizim

| Metod | Yo'l | Vazifasi |
|---|---|---|
| GET | `/health` | Bazaning holati |
| POST | `/setup` | Birinchi admin (faqat bo'sz bazada) |
| POST | `/login` | JWT olish |

### Autentifikatsiya

| Metod | Yo'l | Vazifasi |
|---|---|---|
| 🔒 GET | `/me` | Joriy foydalanuvchi |

### Omborlar

| Metod | Yo'l | Vazifasi | Rol |
|---|---|---|---|
| 🔒 GET | `/warehouses` | Ro'yxat (o'z omborlari) | |
| 🔒 POST | `/warehouses` | Yangi ombor | super_admin |
| 🔒 GET | `/warehouses/{id}` | Ombor ma'lumoti | |
| 🔒 GET | `/warehouses/{id}/users` | Foydalanuvchilar | |
| 🔒 POST | `/warehouses/{id}/users` | Rol berish | manager |

### Kategoriyalar va mahsulotlar

| Metod | Yo'l | Vazifasi | Rol |
|---|---|---|---|
| 🔒 GET | `/product-categories` | Ro'yxat | |
| 🔒 POST | `/product-categories` | Yangi kategoriya | super_admin |
| 🔒 GET | `/product-categories/{id}` | Bitta kategoriya | |
| 🔒 GET | `/products` | Ro'yxat (`?search=`, `?category_id=`) | |
| 🔒 POST | `/products` | Yangi mahsulot | manager |
| 🔒 PUT | `/products/{id}` | Tahrirlash | manager |
| 🔒 GET | `/products/{id}` | Mahsulot | |
| 🔒 GET | `/products/barcode/{code}` | Shtrix-koddan | |

### Zonalar va joylashuvlar

| Metod | Yo'l | Vazifasi | Rol |
|---|---|---|---|
| 🔒 GET | `/warehouses/{id}/zones` | Zonalar | |
| 🔒 POST | `/warehouses/{id}/zones` | Yangi zona | manager |
| 🔒 GET | `/warehouses/{id}/storage-locations` | Joylashuvlar | |
| 🔒 POST | `/warehouses/{id}/storage-locations` | Yangi joylashuv | manager |
| 🔒 GET | `/storage-locations/{id}` | Bitta joylashuv | |
| 🔒 GET | `/storage-locations/code/{code}` | Koddan topish | |

### Partiyalar va konteynerlar

| Metod | Yo'l | Vazifasi | Rol |
|---|---|---|---|
| 🔒 GET | `/products/{id}/batches` | Partiyalar | |
| 🔒 POST | `/products/{id}/batches` | Yangi partiya | manager |
| 🔒 GET | `/products/{id}/locations` | Mahsulot qayerda | |
| 🔒 GET | `/batches/{id}/containers` | Konteynerlar | |
| 🔒 POST | `/batches/{id}/containers` | Yangi konteyner | manager |
| 🔒 GET | `/containers/barcode/{code}` | Shtrix-koddan | |

### Inventory

| Metod | Yo'l | Vazifasi | Rol |
|---|---|---|---|
| 🔒 POST | `/inventory/out` | Chiqarish | operator |
| 🔒 POST | `/inventory/transfer` | Ko'chirish | operator |
| 🔒 POST | `/inventory/adjustment` | Tuzatish | manager |
| 🔒 GET | `/inventory/transactions` | Tarix (`?batch_container_id=`) | |

### FEFO

| Metod | Yo'l | Vazifasi | Rol |
|---|---|---|---|
| 🔒 GET | `/products/{id}/fefo-plan?quantity=` | Reja | |
| 🔒 POST | `/products/{id}/fefo-out` | Reja bo'yicha chiqarish | operator |

**FEFO qanday ishlaydi:** `expiry_date` bo'yicha o'sish tartibida
(`NULL` oxirda), keyin partiya va konteyner id'si. Faqat `approved` va
`active` konteynerlar hisobga olinadi. Yetarli miqdor yo'q bo'lsa —
`insufficient_quantity` xatosi.

### Sifat

| Metod | Yo'l | Vazifasi | Rol |
|---|---|---|---|
| 🔒 GET | `/quality/pending` | Tekshiruv navbati | |
| 🔒 POST | `/batches/{id}/quality-status` | Holatni o'zgartirish | manager |
| 🔒 GET | `/batches/{id}/quality-history` | Tarix | |

### Ogohlantirishlar va hisobotlar

| Metod | Yo'l | Vazifasi | Rol |
|---|---|---|---|
| 🔒 GET | `/alerts/expiring-batches?days=` | Ogohlantirishlar | |
| 🔒 GET | `/alerts/summary` | Badge uchun sonlar | |
| 🔒 GET | `/reports/stock.xlsx` | Qoldiq hisoboti | manager |
| 🔒 GET | `/reports/transactions.xlsx?from=&to=` | Harakatlar | manager |

### Xatolar

| Kod | Ma'no |
|---|---|
| `unauthorized` | Token yo'q yoki muddati tugagan |
| `forbidden` | Ruxsat yo'q |
| `invalid_request` | So'rov noto'g'ri |
| `sku_already_exists` | SKU band |
| `barcode_already_exists` | Shtrix-kod band |
| `location_already_exists` | Joylashuv kodi band |
| `insufficient_quantity` | Qoldiq yetarli emas |
| `note_required` | Izoh majburiy |
| `invalid_attributes` | Atribut turi mos emas |
| `invalid_transition` | Sifat holati o'tkazib bo'lmaydi |

---

## 11. Testlar

### Smoke test — haqiqiy server bilan

```powershell
# Terminal 1
dart run bin/server.dart

# Terminal 2
dart test test/smoke_test.dart
```

Tekshiradi: bazaning ulanishi, noto'g'ri parol 401 berishi, `/me` token
bilan va tokensiz, omborlar ro'yxati, noma'lum yo'l 404.

Login ma'lumotlarini o'zgartirish:

```powershell
$env:WMS_TEST_EMAIL="boshqa@eclair.uz"
$env:WMS_TEST_PASSWORD="Parol123!"
dart test test/smoke_test.dart
```

> `test/server_test.dart` — `shelf` paketidan qolgan scaffold qoldig'i. U
> `/` va `/echo/hello` endpointlarini tekshiradi, WMS da bunday
> endpointlar **yo'q**. Shu sababli `dart test` har doim qizil chiqadi va
> o'z serverini 8080-portga ulashga urilib, ishlab turgan serverni
> buzadi. Uni ishlatmang yoki o'chiring.

### Tekshiruv

```powershell
cd warehouse; dart analyze
cd eclair-wms-app; flutter analyze
```

### Frontend testlari

```powershell
cd eclair-wms-app; flutter test
```

> `test/features/products/import_planner_test.dart` MacBook'dagi aniq fayl
> yo'lini (`/Downloads/...xlsx`) talab qiladi. Boshqa kompyuterda bu test
> o'tmaydi — `WMS_TEST_XLSX` muhit o'zgaruvchisi bilan to'g'ri yo'l
> bering yoki o'zgartiring.

---

## 12. Muammolar va yechimlar

### Server ishlamayapti / `SocketException`

Sabab: 8080-port band. Boshqa server yoki eski jarayon ishlab turibdi.

```powershell
Get-NetTCPConnection -LocalPort 8080 -State Listen
Stop-Process -Id <PID> -Force
```

### `relation "users" does not exist`

Migratsiyalar bajarilmagan yoki boshqa bazaga ulangan:

```powershell
dart run bin/migrate.dart
```

`.env` dagi `DATABASE_URL` to'g'rimi (`localhost:5432/wms`)?

### Docker: ma'lumot yo'qoldi, jadvallar topilmadi

Bu eng ko'p uchraydigan muammo. Sabab — `docker compose` volume nomiga
o'z prefiksi qo'shadi (`warehouse_wms_pgdata`), shuning uchun avval
qo'lda yaratilgan `wms_pgdata` ga ulanmaydi.

`docker-compose.yml` da volume nomi aniq belgilanishi kerak:

```yaml
volumes:
  wms_pgdata:
    name: wms_pgdata
```

Tekshirish:

```powershell
docker volume ls | Select-String wms
docker exec wms-postgres psql -U wms -d wms -c "\dt"
```

### Postgres konteyneri to'xtagan

```powershell
docker compose up -d
docker compose ps        # (healthy) bo'lishi kerak
```

`docker compose ps` da `Exited` ko'rinsa, `docker logs wms-postgres` bilan
sababni ko'ring.

### Flutter: build xatosi

```powershell
cd eclair-wms-app
flutter clean
flutter pub get
flutter build windows --debug
```

### Skaner Windows'da ishlamaydi

`mobile_scanner` faqat Android, iOS, macOS va Web'ni qo'llab-quvvatlaydi —
**Windows'ni qo'llamaydi**. Windows'da skaner funksiyasi ishlamaydi.
Yechim: telefonda yoki `flutter run -d chrome` orqali.

### Hisobot yuklanmayapti

Rol yetarli emas (`warehouse_manager` yoki `super_admin` kerak). Yoki server
ishlamayapti.

### Import: qatorlar o'tkazilmaydi

Sabablar `Nomi yo'q`, `SKU yo'q`, `Faylda takrorlangan SKU`,
`Bazada allaqachon bor`. Ekran sabablarni ko'rsatadi.

### Server kompyuterni qayta ishga tushirgandan keyin to'xtaydi

Server qo'lda ishga tushirilgan jarayon — u ham kompyuter bilan birga
to'xtaydi. `docker compose up -d` dan keyin `dart run bin/server.dart`
yana kerak.

### Ma'lumotni zaxiralash

> **Muhim:** PowerShell'da `>` yoki `| pg_restore` **ishlatmang**.
> PowerShell `>` operatori faylni UTF-16 matn sifatida yozadi va zaxira
> fayl buziladi. Boshlanishi `fffe` bo'lgan fayl — bu buzilgan zaxira.

To'g'ri usul — konteyner ichida yozib, `docker cp` bilan olish:

```powershell
New-Item -ItemType Directory -Force -Path .\zaxira
docker exec wms-postgres pg_dump -U wms -d wms -Fc -f /tmp/wms.dump
docker cp wms-postgres:/tmp/wms.dump .\zaxira\wms-2026-10-03.dump
docker exec wms-postgres rm -f /tmp/wms.dump
```

Tekshirish (fayl to'g'riligi):

```powershell
docker run --rm -v "${PWD}\zaxira:/in:ro" postgres:18-alpine `
  pg_restore -l /in/wms-2026-10-03.dump
```

Fayl to'g'ri bo'lsa ro'yxat chiqadi va birinchi bayt `PGDMP` bo'ladi.

### Ma'lumotni tiklash

```powershell
docker exec wms-postgres mkdir -p /tmp/restore
docker cp .\zaxira\wms-2026-10-03.dump wms-postgres:/tmp/restore/wms.dump
docker exec wms-postgres pg_restore -U wms -d wms --no-owner --no-acl --clean --if-exists /tmp/restore/wms.dump
docker exec wms-postgres rm -rf /tmp/restore
```

> Faqat `wms_pgdata` volume'ini zaxiralash ham yetarli — butun bazadagi
> barcha ma'lumot shu volume'da. Lekin `pg_dump` yondashuvi ixcham va
> boshqa kompyuterga ko'chirish oson.

---

## 13. Keyingi bosqichlar

Hozirgi holat: A → B → C va E bosqichlari bajarilgan. **D bosqichi
bajarilmagan.**

### Hozirgi ma'lumotlar holati

Bazada 2 ta ombor (Tashkent-1, Samarkand-1), 3 ta kategoriya, 370 ta
mahsulot, 15 ta partiya va 10 ta konteyner bor.

> **E'tibor:** birinchi sinov partiyalarining muddati o'tgan
> (`2026-09-01`, `2026-09-25`, `2026-09-29` — joriy sana 2026-10-03 dan
> oldin). Shuning uchun 🔔 ogohlantirishlar qizil rangda to'lgan bo'lishi
> normal. Bu ma'lumotlar MacBook'dagi sinovdan qolgan. Tozalash uchun
> o'sha partiyalarni `rejected` holatga o'tkazing — ular hisobotlardan chiqadi.

Yo'q bo'lgan imkoniyatlar:

**D1 — Chiqish buyurtmalari va picking.** Hozir FEFO faqat bitta mahsulot
bo'yicha ishlaydi. Haqiqiy buyurtma oqimi (buyurtma → ajratish → picking
listi → tasdiqlash) mavjud emas.

**D2 — Kirish/qabul (Receiving).** Ta'minotchi, kirim hujjati, partiyani
joylashuvga qabul qilish.

**D3 — Inventarizatsiya.** Count sessiyasi, ko'rsatilgan va haqiqiy
qoldiq, farqni avtomatik ADJUSTMENTga aylantirish.

**D4 — Dashboard.** Umumiy ko'rsatkichlar: qoldiq, aylanma, muddati yaqin,
kunlik harakatlar.

**D5 — Foydalanuvchilar ekrani.** Backendda bor, frontendda yo'q:
foydalanuvchi yaratish, omborga biriktirish, rol boshqaruv.

### Texnik qarz

- **Token saqlanmaydi** — ilova yopilganda kirish yo'qoladi.
- **`test/server_test.dart`** ishlatilmaydi, `dart test` ni buzadi.
- **`mobile_scanner`** Windows'da ishlamaydi.
- **Frontendda rol tekshiruvi** faqat tugmalarni yashiradi; haqiqiy nazorat
  backendda (bu to'g'ri, lekin frontendda ikki marta takrorlanadi).
- **Ochqiq test muhiti** — `admin@eclair.uz` / `Test1234!` ishlatiladi.

---

## Tez havolalar

```powershell
# Ishga tushirish
cd warehouse; docker compose up -d; dart run bin/server.dart

# Tekshirish
curl -s localhost:8080/health

# Testlar
cd warehouse; dart test test/smoke_test.dart
cd eclair-wms-app; flutter test

# Ilova
cd eclair-wms-app; flutter run -d windows

# Ma'lumotlar
docker compose ps
docker exec wms-postgres psql -U wms -d wms -c "\dt"

# To'xtatish
docker compose stop
```