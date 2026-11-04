# ---- web UI (arch-independent, built on the build host) ----
FROM --platform=$BUILDPLATFORM node:22-alpine AS web
WORKDIR /src
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# ---- server (cross-compiled on the build host) ----
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS server
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w" -o /murmur .

# ---- runtime ----
FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata && adduser -D -H -u 10001 app
COPY --from=server /murmur /usr/local/bin/murmur
COPY --from=web /src/dist /app/static
ENV STATIC_DIR=/app/static PORT=8080
EXPOSE 8080
USER 10001
ENTRYPOINT ["murmur"]
CMD ["serve"]
