#!/bin/bash

set -e

DOMAIN="sample.com"
WWW_DOMAIN="www.${DOMAIN}"

NGINX_CONF_DIR="/var/lib/docker/volumes/global-nginx-proxy_confd/_data"

REDIRECT_FILE="${NGINX_CONF_DIR}/${DOMAIN}-redirect.conf"
DEFAULT_FILE="${NGINX_CONF_DIR}/default.conf"
OUTPUT_FILE="${NGINX_CONF_DIR}/00-${DOMAIN}-override.conf"


# ==========================================================
# LOG
# ==========================================================

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

success() {
    printf '✓ %s\n' "$1"
}

error() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}


# ==========================================================
# EXTRACT SERVER BLOCK
#
# Tìm:
#
#   server {
#       ...
#       listen PORT ...
#       ...
#       server_name DOMAIN;
#       ...
#   }
#
# và trả về NGUYÊN BLOCK.
# ==========================================================

extract_server_block() {

    local file="$1"
    local wanted_name="$2"
    local wanted_port="$3"

    awk \
        -v wanted_name="$wanted_name" \
        -v wanted_port="$wanted_port" '

        function reset_block() {
            buf = ""
            depth = 0
            has_name = 0
            has_listen = 0
            in_server = 0
        }

        BEGIN {
            reset_block()
        }

        /^[[:space:]]*server[[:space:]]*\{/ {
            reset_block()
            in_server = 1
        }

        in_server {

            buf = buf $0 ORS

            if ($0 ~ "^[[:space:]]*server_name[[:space:]]+" wanted_name "[[:space:]]*;") {
                has_name = 1
            }

            if ($0 ~ "^[[:space:]]*listen[[:space:]]+" wanted_port "([[:space:]]|;|ssl)") {
                has_listen = 1
            }

            line = $0

            opens = gsub(/\{/, "", line)
            closes = gsub(/\}/, "", line)

            depth = depth + opens - closes

            if (depth == 0) {

                if (has_name && has_listen) {
                    printf "%s", buf
                    exit
                }

                reset_block()
            }
        }

    ' "$file"
}


# ==========================================================
# CHECK VARIABLES
# ==========================================================

log "Domain: $DOMAIN"
log "WWW:    $WWW_DOMAIN"

printf '\n'

if [[ "$WWW_DOMAIN" != "www.${DOMAIN}" ]]; then
    error "WWW_DOMAIN không hợp lệ: [$WWW_DOMAIN]"
fi

[[ -f "$REDIRECT_FILE" ]] ||
    error "Không tìm thấy: $REDIRECT_FILE"

[[ -f "$DEFAULT_FILE" ]] ||
    error "Không tìm thấy: $DEFAULT_FILE"

success "Đã tìm thấy cả 2 file nguồn."


# ==========================================================
# A. sample.com HTTP
# ==========================================================

log "Extract: $DOMAIN HTTP từ ${DOMAIN}-redirect.conf"

BARE_HTTP="$(
    extract_server_block \
        "$REDIRECT_FILE" \
        "$WWW_DOMAIN" \
        "80"
)"

[[ -n "$BARE_HTTP" ]] ||
    error "Không tìm thấy HTTP redirect block."

BARE_HTTP="$(
    printf '%s\n' "$BARE_HTTP" |
    sed \
        -e "s/server_name[[:space:]]\+${WWW_DOMAIN};/server_name ${DOMAIN};/" \
        -e "s#https://${DOMAIN}#https://${WWW_DOMAIN}#g"
)"

success "Extract $DOMAIN HTTP OK."


# ==========================================================
# B. sample.com HTTPS
# ==========================================================

log "Extract: $DOMAIN HTTPS từ ${DOMAIN}-redirect.conf"

BARE_HTTPS="$(
    extract_server_block \
        "$REDIRECT_FILE" \
        "$WWW_DOMAIN" \
        "443"
)"

[[ -n "$BARE_HTTPS" ]] ||
    error "Không tìm thấy HTTPS redirect block."

BARE_HTTPS="$(
    printf '%s\n' "$BARE_HTTPS" |
    sed \
        -e "s/server_name[[:space:]]\+${WWW_DOMAIN};/server_name ${DOMAIN};/" \
        -e "s#https://${DOMAIN}#https://${WWW_DOMAIN}#g"
)"

success "Extract $DOMAIN HTTPS OK."


# ==========================================================
# C. www.sample.com HTTP
#
# Lấy nguyên block từ default.conf
#
# Sau đó chỉ sửa:
#
#   return 301 https://$host$request_uri;
#
# thành:
#
#   return 301 https://www.sample.com$request_uri;
# ==========================================================

log "Extract: $WWW_DOMAIN HTTP từ default.conf"

WWW_HTTP="$(
    extract_server_block \
        "$DEFAULT_FILE" \
        "$WWW_DOMAIN" \
        "80"
)"

[[ -n "$WWW_HTTP" ]] ||
    error "Không tìm thấy $WWW_DOMAIN HTTP block."

WWW_HTTP="$(
    printf '%s\n' "$WWW_HTTP" |
    sed \
        's#return[[:space:]]\+301[[:space:]]\+https://\$host\$request_uri;#return 301 https://www.sample.com$request_uri;#'
)"

success "Extract $WWW_DOMAIN HTTP OK."


# ==========================================================
# D. www.sample.com HTTPS
#
# GIỮ NGUYÊN 100% từ default.conf
# ==========================================================

log "Extract: $WWW_DOMAIN HTTPS từ default.conf"

WWW_HTTPS="$(
    extract_server_block \
        "$DEFAULT_FILE" \
        "$WWW_DOMAIN" \
        "443"
)"

[[ -n "$WWW_HTTPS" ]] ||
    error "Không tìm thấy $WWW_DOMAIN HTTPS block."

success "Extract $WWW_DOMAIN HTTPS OK."


# ==========================================================
# E. CREATE OUTPUT
# ==========================================================

log "Tạo file override:"
echo "  $OUTPUT_FILE"

{
    printf '%s\n\n' "$BARE_HTTP"
    printf '%s\n\n' "$BARE_HTTPS"
    printf '%s\n\n' "$WWW_HTTP"
    printf '%s\n' "$WWW_HTTPS"
} > "$OUTPUT_FILE"

success "Đã tạo file override."


# ==========================================================
# F. CHECK
# ==========================================================

echo
echo "============================================================"
echo "SERVER / REDIRECT / PROXY"
echo "============================================================"

grep -nE \
    '^[[:space:]]*(listen|server_name|return|proxy_pass)[[:space:]]' \
    "$OUTPUT_FILE"


echo
echo "============================================================"
echo "EXPECTED CANONICAL REDIRECTS"
echo "============================================================"

grep -nF \
    'return 301 https://www.sample.com$request_uri;' \
    "$OUTPUT_FILE" || true


echo
echo "============================================================"
echo "FULL OUTPUT"
echo "============================================================"

cat "$OUTPUT_FILE"


echo
echo "============================================================"
success "TEST HOÀN TẤT"
echo "============================================================"