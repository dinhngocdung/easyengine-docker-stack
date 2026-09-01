#!/usr/bin/env bash
# install.sh — Triển khai CrowdSec (thay fail2ban) từ các template trong ./templates
#
# Script CHỈ đóng vai trò triển khai — mọi nội dung cấu hình thật nằm trong
# ./templates/**, cấu trúc mirror đúng cây thư mục đích trên host. Thêm 1 file
# vào templates/ (đúng nhánh tương ứng) là tự động được deploy, không cần sửa
# file này.
#
# Dùng (tương tác — hỏi input):
#   git clone https://github.com/dinhngocdung/easyengine-docker-stack.git
#   cd easyengine-docker-stack/crowdsec && sudo ./install.sh
#
# Dùng (không tương tác — cho Ansible/CI):
#   Export toàn bộ biến bắt buộc trước (xem REQUIRED_VARS), rồi:
#   CROWDSEC_NONINTERACTIVE=1 sudo -E ./install.sh
#   Script sẽ KHÔNG hỏi gì, fail ngay nếu thiếu biến bắt buộc.

set -euo pipefail

C_BLUE='\033[1;34m'; C_GREEN='\033[1;32m'; C_RED='\033[1;31m'; C_YELLOW='\033[1;33m'; C_RESET='\033[0m'
info()  { echo -e "${C_BLUE}[i]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[✓]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
fail()  { echo -e "${C_RED}[✗]${C_RESET} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Cần chạy bằng root (sudo ./install.sh)."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
[ -d "$TEMPLATES_DIR" ] || fail "Không tìm thấy $TEMPLATES_DIR — chạy script từ đúng thư mục đã clone/giải nén, đừng tách install.sh khỏi templates/."

BASE_DIR="${CROWDSEC_BASE_DIR:-/opt/crowdsec}"
ENV_FILE="$BASE_DIR/.env"
NONINTERACTIVE="${CROWDSEC_NONINTERACTIVE:-0}"
mkdir -p "$BASE_DIR"

if [ -f "$ENV_FILE" ]; then
  info "Tìm thấy $ENV_FILE — nạp làm giá trị mặc định."
  set -a; # shellcheck disable=SC1090
  source "$ENV_FILE"; set +a
fi

# ---------- Input helpers: hỏi tương tác, hoặc bắt buộc đã có sẵn nếu non-interactive ----------

REQUIRED_VARS=(CROWDSEC_SSHD_LOG_PATH CROWDSEC_NGINX_PROXY_LOG_DIR)

ask() {
  local prompt="$1" varname="$2" default="${!2:-}" input
  if [ "$NONINTERACTIVE" = "1" ]; then
    [ -n "$default" ] || { REQUIRED_VARS+=("$varname"); return; }
    return
  fi
  if [ -n "$default" ]; then read -rp "$prompt [$default]: " input
  else read -rp "$prompt: " input; fi
  if [ -n "$input" ]; then printf -v "$varname" '%s' "$input"
  elif [ -n "$default" ]; then printf -v "$varname" '%s' "$default"
  fi
}
ask_yn() {
  local prompt="$1" default="${2:-y}" ans
  [ "$NONINTERACTIVE" = "1" ] && { [ "$default" = y ]; return; }
  read -rp "$prompt [$([ "$default" = y ] && echo 'Y/n' || echo 'y/N')]: " ans
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ---------- 1. Preflight ----------

command -v docker >/dev/null 2>&1 || fail "Không tìm thấy Docker."
docker compose version >/dev/null 2>&1 || fail "Không tìm thấy Docker Compose v2."
if ! command -v jq >/dev/null 2>&1; then
  info "Cài jq..."
  if command -v dnf >/dev/null 2>&1; then dnf install -y jq
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y jq
  else fail "Không tự cài được jq — cài thủ công rồi chạy lại."
  fi
fi

# ---------- 2. Giá trị per-server ----------

echo; info "== Đường dẫn log =="

CROWDSEC_SSHD_LOG_PATH="${CROWDSEC_SSHD_LOG_PATH:-}"
if [ -z "$CROWDSEC_SSHD_LOG_PATH" ]; then
  for c in /var/log/secure /var/log/auth.log; do [ -f "$c" ] && CROWDSEC_SSHD_LOG_PATH="$c" && break; done
fi
ask "Đường dẫn log SSH trên host" CROWDSEC_SSHD_LOG_PATH

CROWDSEC_NGINX_PROXY_LOG_DIR="${CROWDSEC_NGINX_PROXY_LOG_DIR:-}"
if [ -z "$CROWDSEC_NGINX_PROXY_LOG_DIR" ]; then
  PC=$(docker ps --format '{{.Names}}' | grep -i 'nginx-proxy' | head -n1 || true)
  [ -n "$PC" ] && CROWDSEC_NGINX_PROXY_LOG_DIR=$(docker inspect "$PC" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/log/nginx"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
  [ -z "$CROWDSEC_NGINX_PROXY_LOG_DIR" ] && CROWDSEC_NGINX_PROXY_LOG_DIR="/opt/easyengine/services/nginx-proxy/logs"
fi
ask "Đường dẫn log nginx-proxy trên host" CROWDSEC_NGINX_PROXY_LOG_DIR

echo
CROWDSEC_COLLECTIONS="${CROWDSEC_COLLECTIONS:-crowdsecurity/nginx crowdsecurity/sshd crowdsecurity/linux crowdsecurity/wordpress}"
ask "Collections" CROWDSEC_COLLECTIONS
CROWDSEC_TZ="${CROWDSEC_TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || echo Asia/Ho_Chi_Minh)}"
ask "Timezone" CROWDSEC_TZ
FW_BOUNCER_IMAGE="${FW_BOUNCER_IMAGE:-ghcr.io/shgew/cs-firewall-bouncer-docker:stable}"
ask "Image cho fw-bouncer" FW_BOUNCER_IMAGE
CROWDSEC_FW_API_URL="${CROWDSEC_FW_API_URL:-http://127.0.0.1:8080/}"

echo
CF_ENABLED="${CROWDSEC_CF_ENABLED:-no}"
if [ "$NONINTERACTIVE" != "1" ]; then
  ask_yn "Bật Cloudflare Worker bouncer?" "$([ "$CF_ENABLED" = yes ] && echo y || echo n)" && CF_ENABLED="yes" || CF_ENABLED="no"
fi

if [ "$CF_ENABLED" = "yes" ]; then
  if [ "$NONINTERACTIVE" != "1" ]; then
    warn "Trước khi tiếp tục: bật Analytics Engine tại dash.cloudflare.com/<account_id>/workers/analytics-engine"
    ask_yn "Đã bật rồi, tiếp tục?" y || fail "Bật Analytics Engine rồi chạy lại."
  fi
  ask "Cloudflare Account ID" CLOUDFLARE_ACCOUNT_ID
  ask "Cloudflare Account email" CLOUDFLARE_ACCOUNT_NAME
  ask "Cloudflare API Token" CLOUDFLARE_API_TOKEN
  REQUIRED_VARS+=(CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ACCOUNT_NAME CLOUDFLARE_API_TOKEN)
  if [ "$NONINTERACTIVE" != "1" ]; then
    warn "Danh sách zone lấy từ templates/data-bouncers/crowdsec-cloudflare-worker-bouncer-zones.yaml — sửa TRƯỚC khi chạy nếu cần đổi."
    ask_yn "Đã kiểm tra file zones đúng danh sách muốn deploy chưa?" y || fail "Sửa file zones rồi chạy lại."
  fi
fi

# ---------- 3. Fail sớm nếu non-interactive mà thiếu biến ----------

if [ "$NONINTERACTIVE" = "1" ]; then
  MISSING=()
  for v in "${REQUIRED_VARS[@]}"; do [ -n "${!v:-}" ] || MISSING+=("$v"); done
  [ "${#MISSING[@]}" -eq 0 ] || fail "Thiếu biến bắt buộc (chế độ non-interactive): ${MISSING[*]}"
fi

# ---------- 4. Key bouncer — tự sinh nếu chưa có ----------

if [ -z "${CROWDSEC_FW_BOUNCER_KEY:-}" ]; then
  CROWDSEC_FW_BOUNCER_KEY=$(openssl rand -hex 32); info "Đã tự sinh key cho fw-bouncer."
fi
if [ "$CF_ENABLED" = "yes" ] && [ -z "${CROWDSEC_CF_BOUNCER_KEY:-}" ]; then
  CROWDSEC_CF_BOUNCER_KEY=$(openssl rand -hex 32); info "Đã tự sinh key cho cloudflare-worker-bouncer."
fi

# ---------- 5. Ghi .env ----------

{
  echo "CROWDSEC_SSHD_LOG_PATH=$CROWDSEC_SSHD_LOG_PATH"
  echo "CROWDSEC_NGINX_PROXY_LOG_DIR=$CROWDSEC_NGINX_PROXY_LOG_DIR"
  echo "CROWDSEC_COLLECTIONS=$CROWDSEC_COLLECTIONS"
  echo "CROWDSEC_TZ=$CROWDSEC_TZ"
  echo "FW_BOUNCER_IMAGE=$FW_BOUNCER_IMAGE"
  echo "CROWDSEC_FW_API_URL=$CROWDSEC_FW_API_URL"
  echo "CROWDSEC_FW_BOUNCER_KEY=$CROWDSEC_FW_BOUNCER_KEY"
  echo "CROWDSEC_CF_ENABLED=$CF_ENABLED"
  if [ "$CF_ENABLED" = "yes" ]; then
    echo "CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID"
    echo "CLOUDFLARE_ACCOUNT_NAME=$CLOUDFLARE_ACCOUNT_NAME"
    echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN"
    echo "CROWDSEC_CF_BOUNCER_KEY=$CROWDSEC_CF_BOUNCER_KEY"
  fi
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok "Đã ghi $ENV_FILE"

# ---------- 6. Copy toàn bộ template tĩnh — mirror nguyên cây thư mục ----------

mkdir -p "$BASE_DIR"/data
cp -r "$TEMPLATES_DIR/config"          "$BASE_DIR/"
cp -r "$TEMPLATES_DIR/data-bouncers"   "$BASE_DIR/"
cp    "$TEMPLATES_DIR/docker-compose.yml" "$BASE_DIR/docker-compose.yml"
# 3 file *.tmpl / zones trong data-bouncers sẽ được xử lý riêng ở bước 7,
# xoá bản .tmpl thô đã copy nhầm (chưa render) để tránh nhầm với bản đã render
rm -f "$BASE_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer-header.yaml.tmpl" \
      "$BASE_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer-footer.yaml.tmpl"
ok "Đã copy template tĩnh vào $BASE_DIR"

# ---------- 7. Render đúng 1 file cần thật sự render ----------

if [ "$CF_ENABLED" = "yes" ]; then
  export CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_NAME CROWDSEC_CF_BOUNCER_KEY
  {
    envsubst '${CLOUDFLARE_ACCOUNT_ID}' < "$TEMPLATES_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer-header.yaml.tmpl"
    cat "$BASE_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer-zones.yaml"
    envsubst '${CLOUDFLARE_API_TOKEN} ${CLOUDFLARE_ACCOUNT_NAME} ${CROWDSEC_CF_BOUNCER_KEY}' \
      < "$TEMPLATES_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer-footer.yaml.tmpl"
  } > "$BASE_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
  chmod 600 "$BASE_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
  if grep -q "REPLACE_WITH_REAL_ZONE_ID" "$BASE_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer.yaml"; then
    fail "crowdsec-cloudflare-worker-bouncer-zones.yaml vẫn còn placeholder mẫu — sửa trước khi deploy thật."
  fi
  ok "Đã render crowdsec-cloudflare-worker-bouncer.yaml"
else
  rm -f "$BASE_DIR/data-bouncers/crowdsec-cloudflare-worker-bouncer-zones.yaml"
fi

# ---------- 8. Wrapper CLI tiện dùng — cùng quy ước với fail2ban-client-wrapper ----------

cat > /usr/local/bin/cscli <<'WRAP'
#!/usr/bin/env bash
exec docker exec -t crowdsec cscli "$@"
WRAP
chmod +x /usr/local/bin/cscli
ok "Đã tạo wrapper: /usr/local/bin/cscli (gọi thẳng cscli không cần docker exec)"

# ---------- 9. Deploy ----------

cd "$BASE_DIR"

info "Khởi động agent crowdsec..."
docker compose up -d crowdsec

info "Chờ LAPI sẵn sàng..."
for i in $(seq 1 15); do
  docker exec crowdsec cscli lapi status >/dev/null 2>&1 && break
  [ "$i" -eq 15 ] && fail "LAPI không sẵn sàng — kiểm tra: docker logs crowdsec"
  sleep 2
done

info "Đăng ký bouncer (bỏ qua nếu đã có)..."
EXISTING=$(docker exec crowdsec cscli bouncers list -o json | jq -r '.[].name')
echo "$EXISTING" | grep -qx "firewall-bouncer" || { docker exec crowdsec cscli bouncers add firewall-bouncer -k "$CROWDSEC_FW_BOUNCER_KEY"; ok "Đăng ký firewall-bouncer"; }
if [ "$CF_ENABLED" = "yes" ]; then
  echo "$EXISTING" | grep -qx "cloudflare-worker-bouncer" || { docker exec crowdsec cscli bouncers add cloudflare-worker-bouncer -k "$CROWDSEC_CF_BOUNCER_KEY"; ok "Đăng ký cloudflare-worker-bouncer"; }
fi

info "Pull image fw-bouncer ($FW_BOUNCER_IMAGE)... (service: crowdsec-firewall-bouncer)"
docker compose pull crowdsec-firewall-bouncer

SERVICES="crowdsec crowdsec-firewall-bouncer"
[ "$CF_ENABLED" = "yes" ] && SERVICES="$SERVICES crowdsec-cloudflare-worker-bouncer"
info "Khởi động: $SERVICES"
# shellcheck disable=SC2086
docker compose up -d $SERVICES

sleep 8
RUNNING=$(docker compose ps --status running --services)
STATUS_OK=1
for svc in $SERVICES; do
  if echo "$RUNNING" | grep -qx "$svc"; then ok "Service '$svc' đang chạy"
  else warn "Service '$svc' KHÔNG chạy — kiểm tra: docker logs $svc"; STATUS_OK=0; fi
done

echo; ok "Hoàn tất."; docker compose ps
[ "$STATUS_OK" -eq 1 ] || exit 1
