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