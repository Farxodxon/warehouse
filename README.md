# WMS Backend

Eclair zavodi uchun ombor boshqaruv tizimi (WMS) backend servisi.
Dart + Shelf freymvork, Neon.tech PostgreSQL bazasi.

## Ishga tushirish

1. Bog'liqliklarni o'rnating:

```
dart pub get
```

2. `.env` faylini yarating (namuna uchun `.env.example`ga qarang):

```
cp .env.example .env
```

Keyin `.env` ichidagi `DATABASE_URL`ga Neon.tech'dagi haqiqiy
PostgreSQL connection stringni qo'ying (masalan:
`postgresql://user:password@host/dbname?sslmode=require`).

3. Serverni ishga tushiring:

```
dart run bin/server.dart
```

4. Boshqa terminal oynasida /health endpointni tekshiring:

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

## Render.com'da deploy (A5)

Repository: `wms_backend/` (git repo `warehouse`). `render.yaml` va `Dockerfile`
repo tub papkasida tayyor.

### Qadamlari (Dashboard orqali)

1. Render.com'da "New +" -> "Blueprint" yoki "Web Service".
2. GitHub reposini ulang (`Farxodxon/warehouse`).
3. Agar **Web Service** tanlansa:
   - Runtime: **Docker**
   - Root directory: `wms_backend` (agar repo ichida boshqa papka bo'lsa)
   - Health check path: `/health`
   - Plan: Free
4. Environment variables kiritish (Render Dashboard "Environment" bo'limida):
   - `DATABASE_URL` - Neon.tech PostgreSQL ulanish qatori (masalan
     `postgresql://user:password@host/dbname?sslmode=require`)
   - `JWT_SECRET` - uzun tasodifiy qator (token imzolash uchun)
   - `PORT` - `8080` (agar Render berilmasa, default 8080)

   E'tibor: `render.yaml`da `DATABASE_URL` va `JWT_SECRET` uchun faqat `sync: false`
   ko'rsatilgan - haqiqiy qiymatlar **Render Dashboard'da qo'lda** kiritiladi,
   repo'da saqlanmaydi.

5. `Deploy` tugmasini bosing. Render GitHub'ga push qilingan har bir yangi
   commitni avtomatik deploy qiladi.

### `render.yaml` (avtomatik Blueprint uchun)

```yaml
services:
  - type: web
    name: eclair-wms-backend
    runtime: docker
    dockerfilePath: ./Dockerfile
    dockerContext: .
    plan: free
    healthCheckPath: /health
    envVars:
      - key: DATABASE_URL
        sync: false
      - key: JWT_SECRET
        sync: false
      - key: PORT
        value: 8080
```

### Mahalliy Docker sinovi

```sh
docker build -t wms-backend-test .
docker run -p 8080:8080 \
  -e DATABASE_URL="$DATABASE_URL" \
  -e JWT_SECRET="$JWT_SECRET" \
  wms-backend-test
curl -s localhost:8080/health
# {"status":"ok","database":"connected"}
```

`.env` fayli Docker image ichiga kirmaydi (`.dockerignore`da chiqarib tashlangan) -
muhit o'zgaruvchilari faqat `-e` yoki Render orqali beriladi.