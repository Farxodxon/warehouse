# WMS backend - Render Docker image.
#
# Render builds and runs this image. Runtime configuration comes from
# environment variables in the Render dashboard.
#
# DATABASE_URL must point to Neon PostgreSQL and include sslmode=require.

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
