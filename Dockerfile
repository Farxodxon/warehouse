# Resolve app dependencies first for layer caching, then AOT-compile.
FROM dart:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .
RUN dart compile exe bin/server.dart -o bin/server

# Minimal runtime image: Debian slim + the AOT-compiled binary.
# ca-certificates is required for TLS (sslmode=require in DATABASE_URL).
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/bin/server /app/bin/server

ENV PORT=8080
EXPOSE 8080

CMD ["/app/bin/server"]