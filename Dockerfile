# WMS backend — lokal Docker image.
#
# Build va ishga tushirish:
#   docker build -t wms-backend .
#   docker run -p 8080:8080 --env-file .env wms-backend
#
# Eslatma: bu backend lokal Postgres'ga ulanadi. `docker run` paytida
# `--network host` yoki compose'ning bitta tarmog'ini ishlatish kerak,
# aks holda backend konteynerdagi localhost Postgres'ni ko'rmaydi.
# Oddiy ishga tushirish uchun `dart run bin/server.dart` yetarli.

FROM dart:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .
RUN dart compile exe bin/server.dart -o bin/server

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/bin/server /app/server

ENV PORT=8080
EXPOSE 8080

CMD ["/app/server"]
