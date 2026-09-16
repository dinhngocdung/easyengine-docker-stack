#!/bin/bash
###########################################################
# Script: Đổi Main Site từ domain.com -> www.domain.com
# Áp dụng cho WordPress Multisite (blog_id=1 = Main Site)
#
# Usage:
#   ./convert-mainsite-to-www.sh <domain.com>
###########################################################

set -e

# ====== CONFIG ======
EE_BIN="/usr/local/bin/ee"
DOMAIN="${1:-}"
NGINX_CONF_DIR="/var/lib/docker/volumes/global-nginx-proxy_confd/_data"
SITE_ROOT="/opt/easyengine/sites"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
error()   { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }
warning() { echo -e "${YELLOW}[WARNING] $1${NC}" >&2; }

# ====== HELPER: chạy lệnh qua ee shell an toàn với escaping (base64) ======
run_in_site() {
    local site="$1"
    local cmd="$2"
    local enc
    enc=$(echo -n "$cmd" | base64 -w0)
    "$EE_BIN" shell "$site" --command="echo $enc | base64 -d | sh"
}

# ====== HELPER: lấy nguyên server { ... } block ======
extract_server_block() {
    local file="$1"
    local server_name="$2"
    local listen_port="$3"

    awk \
        -v wanted_name="$server_name" \
        -v wanted_port="$listen_port" '
        function reset_block() {
            buf=""
            depth=0
            has_name=0
            has_listen=0
            in_server=0
        }

        BEGIN {
            reset_block()
        }

        /^[[:space:]]*server[[:space:]]*\{/ {
            reset_block()
            in_server=1
        }

        in_server {
            buf = buf $0 ORS

            if ($0 ~ "^[[:space:]]*server_name[[:space:]]+" wanted_name "[[:space:]]*;") {
                has_name=1
            }

            if ($0 ~ "^[[:space:]]*listen[[:space:]]+" wanted_port "([[:space:]]|;|ssl)") {
                has_listen=1
            }

            line=$0
            opens=gsub(/\{/, "", line)
            closes=gsub(/\}/, "", line)

            depth += opens - closes

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

# ====== DOMAIN ======
if [ -z "$DOMAIN" ]; then
    read -p "Nhập domain gốc cần chuyển đổi (ví dụ: sample.com): " DOMAIN
fi

DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)

[[ -z "$DOMAIN" ]] && error "Domain không được để trống."

if ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    error "Domain không hợp lệ: $DOMAIN"
fi

WWW_DOMAIN="www.$DOMAIN"

success "Domain gốc: $DOMAIN  →  Main Site mới: $WWW_DOMAIN"

WP_CONFIG_PATH="$SITE_ROOT/$DOMAIN/app/htdocs/wp-config.php"

if [[ ! -f "$WP_CONFIG_PATH" ]]; then
    error "Không tìm thấy wp-config.php tại: $WP_CONFIG_PATH"
fi

# ====== XÁC NHẬN TRƯỚC KHI CHẠY ======
echo ""
echo "Sẽ thực hiện các bước sau:"
echo "  1. UPDATE wp_site / wp_blogs -> đổi domain Main Site sang $WWW_DOMAIN"
echo "  2. Sửa DOMAIN_CURRENT_SITE trong wp-config.php"
echo "  3. Lấy config từ ${DOMAIN}-redirect.conf + default.conf"
echo "     -> tạo file override Nginx (00-$DOMAIN-override.conf)"
echo "  4. ee site clean $DOMAIN && ee site reload $DOMAIN"
echo ""

read -p "Tiếp tục? [y/N]: " CONFIRM

[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && {
    echo "Đã huỷ."
    exit 0
}

# ====== 1. UPDATE wp_site / wp_blogs ======
log "Cập nhật wp_site.domain và wp_blogs.domain (blog_id=1)..."

SQL1="UPDATE wp_site SET domain = '$WWW_DOMAIN' WHERE domain = '$DOMAIN';"

run_in_site "$DOMAIN" "wp db query \"$SQL1\" --allow-root" \
    || error "Update wp_site thất bại."

SQL2="UPDATE wp_blogs SET domain = '$WWW_DOMAIN' WHERE blog_id = 1;"

run_in_site "$DOMAIN" "wp db query \"$SQL2\" --allow-root" \
    || error "Update wp_blogs thất bại."

success "Đã cập nhật wp_site / wp_blogs."

# ====== 2. SỬA wp-config.php ======
log "Cập nhật DOMAIN_CURRENT_SITE trong wp-config.php..."

if grep -q "DOMAIN_CURRENT_SITE" "$WP_CONFIG_PATH"; then

    sed -i \
        "s|define(\s*'DOMAIN_CURRENT_SITE'\s*,\s*'[^']*'\s*);|define('DOMAIN_CURRENT_SITE', '$WWW_DOMAIN');|" \
        "$WP_CONFIG_PATH"

else

    sed -i \
        "/\/\* That's all, stop editing/i define('DOMAIN_CURRENT_SITE', '$WWW_DOMAIN');" \
        "$WP_CONFIG_PATH"

fi

success "Đã cập nhật wp-config.php"


# ====== 3. TRÍCH XUẤT CONFIG EASYENGINE + TẠO FILE OVERRIDE ======
log "Đọc config EasyEngine..."

REDIRECT_FILE="$NGINX_CONF_DIR/${DOMAIN}-redirect.conf"
DEFAULT_FILE="$NGINX_CONF_DIR/default.conf"
OUTPUT_FILE="$NGINX_CONF_DIR/00-${DOMAIN}-override.conf"
TEMP_OUTPUT="$(mktemp)"

[[ -f "$REDIRECT_FILE" ]] ||
    error "Không tìm thấy: $REDIRECT_FILE"

[[ -f "$DEFAULT_FILE" ]] ||
    error "Không tìm thấy: $DEFAULT_FILE"

success "Đã tìm thấy cả 2 file nguồn."


# ----- A. domain.com HTTP -----
log "Extract: $DOMAIN HTTP từ ${DOMAIN}-redirect.conf"

BARE_HTTP="$(
    extract_server_block \
        "$REDIRECT_FILE" \
        "$WWW_DOMAIN" \
        "80"
)"

[[ -n "$BARE_HTTP" ]] ||
    error "Không tìm thấy HTTP redirect block trong $REDIRECT_FILE"

BARE_HTTP="$(
    printf '%s\n' "$BARE_HTTP" |
    sed \
        -e "s/server_name[[:space:]]\+${WWW_DOMAIN}[[:space:]]*;/server_name ${DOMAIN};/" \
        -e "s#https://${DOMAIN}#https://${WWW_DOMAIN}#g"
)"

success "Extract $DOMAIN HTTP OK."


# ----- B. domain.com HTTPS -----
log "Extract: $DOMAIN HTTPS từ ${DOMAIN}-redirect.conf"

BARE_HTTPS="$(
    extract_server_block \
        "$REDIRECT_FILE" \
        "$WWW_DOMAIN" \
        "443"
)"

[[ -n "$BARE_HTTPS" ]] ||
    error "Không tìm thấy HTTPS redirect block trong $REDIRECT_FILE"

BARE_HTTPS="$(
    printf '%s\n' "$BARE_HTTPS" |
    sed \
        -e "s/server_name[[:space:]]\+${WWW_DOMAIN}[[:space:]]*;/server_name ${DOMAIN};/" \
        -e "s#https://${DOMAIN}#https://${WWW_DOMAIN}#g"
)"

success "Extract $DOMAIN HTTPS OK."


# ----- C. www.domain.com HTTP -----
log "Extract: $WWW_DOMAIN HTTP từ default.conf"

WWW_HTTP="$(
    extract_server_block \
        "$DEFAULT_FILE" \
        "$WWW_DOMAIN" \
        "80"
)"

[[ -n "$WWW_HTTP" ]] ||
    error "Không tìm thấy $WWW_DOMAIN HTTP block trong $DEFAULT_FILE"

# EasyEngine mặc định:
#   return 301 https://$host$request_uri;
#
# Canonical phải luôn là:
#   https://www.domain.com$request_uri
WWW_HTTP="$(
    printf '%s\n' "$WWW_HTTP" |
    sed \
        -e "s#https://\\\$host\\\$request_uri#https://${WWW_DOMAIN}\$request_uri#g"
)"

success "Extract $WWW_DOMAIN HTTP OK."


# ----- D. www.domain.com HTTPS -----
log "Extract: $WWW_DOMAIN HTTPS từ default.conf"

WWW_HTTPS="$(
    extract_server_block \
        "$DEFAULT_FILE" \
        "$WWW_DOMAIN" \
        "443"
)"

[[ -n "$WWW_HTTPS" ]] ||
    error "Không tìm thấy $WWW_DOMAIN HTTPS block trong $DEFAULT_FILE"

success "Extract $WWW_DOMAIN HTTPS OK."


# ----- Ghi file override -----
log "Tạo file override:"
echo " $OUTPUT_FILE"

{
    printf '%s\n\n' "$BARE_HTTP"
    printf '%s\n\n' "$BARE_HTTPS"
    printf '%s\n\n' "$WWW_HTTP"
    printf '%s\n' "$WWW_HTTPS"
} > "$TEMP_OUTPUT"

mv "$TEMP_OUTPUT" "$OUTPUT_FILE"

success "Đã tạo file override."

# ====== 4. CLEAN + RELOAD SITE ======
log "Chạy ee site clean và ee site reload..."

"$EE_BIN" site clean "$DOMAIN" \
    || warning "ee site clean gặp lỗi, kiểm tra thủ công."

"$EE_BIN" site reload "$DOMAIN" \
    || warning "ee site reload gặp lỗi, kiểm tra thủ công."

success "Đã clean + reload site."

log "Reload nginx-proxy để áp dụng file override..."

"$EE_BIN" service reload nginx-proxy \
    || warning "Reload nginx-proxy thất bại, kiểm tra thủ công."


# ====== TỔNG KẾT ======
echo ""
echo "=========================================="
success "Hoàn tất chuyển Main Site: $DOMAIN -> $WWW_DOMAIN"
echo "=========================================="

cat << EOF

${GREEN}Kiểm tra lại:${NC}
  $EE_BIN shell $DOMAIN --command='wp site list --allow-root'
  $EE_BIN shell $DOMAIN --command='wp option get siteurl --allow-root'
  $EE_BIN shell $DOMAIN --command='wp option get home --allow-root'
  curl -IL https://$DOMAIN/
  curl -IL https://$WWW_DOMAIN/

EOF