# Caddy with the ACME DNS-01 provider modules that ACME_DNS_PROVIDER supports.
# Caddy has no runtime plugins, so the modules are compiled into the binary here.
# .github/workflows/caddy-image.yml publishes this image; servers pull it by digest.
ARG CADDY_VERSION=2.11.7
FROM caddy:${CADDY_VERSION}-builder AS builder
ARG CADDY_VERSION
RUN xcaddy build "v${CADDY_VERSION}" \
    --with github.com/caddy-dns/loopia@v1.0.1 \
    --with github.com/caddy-dns/namedotcom@v0.1.2 \
    --with github.com/libdns/namedotcom@v0.9.0

FROM caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
