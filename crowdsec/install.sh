#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/crowdsec"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '\033[1;32m[+]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

trap 'die "Installation failed at line $LINENO. See the command above."' ERR


# ---------------------------------------------------------------------------
# 1. Preflight checks
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"

command -v docker >/dev/null 2>&1 \
  || die "Docker is required. EasyEngine normally installs it."

docker compose version >/dev/null 2>&1 \
  || die "Docker Compose v2 is required."

command -v iptables >/dev/null 2>&1 \
  || die "iptables is required."

iptables --version | grep -q 'nf_tables' \
  || die "This installer expects iptables-nft. Current: $(iptables --version)"

if ! iptables -S DOCKER-USER >/dev/null 2>&1; then
  warn "DOCKER-USER chain does not exist yet."
  warn "Docker may create it when its bridge networking is initialized."
fi


# ---------------------------------------------------------------------------
# 2. Detect EasyEngine nginx-proxy log directory
# ---------------------------------------------------------------------------

detect_nginx_log_dir() {
  local candidates=(
    "/opt/easyengine/services/nginx-proxy/logs"
    "/opt/easyengine/services/nginx-proxy/log"
  )

  local d

  for d in "${candidates[@]}"; do
    if [[ -f "$d/access.log" || -f "$d/error.log" ]]; then
      printf '%s' "$d"
      return 0
    fi
  done

  if docker inspect ee-nginx-proxy >/dev/null 2>&1; then
    docker inspect ee-nginx-proxy \
      --format '{{range .Mounts}}{{println .Source "\t" .Destination}}{{end}}' \
      | awk '$2 ~ /log/ {print $1; exit}'
    return 0
  fi

  return 1
}

NGINX_PROXY_LOG_DIR="${NGINX_PROXY_LOG_DIR:-}"

if [[ -z "$NGINX_PROXY_LOG_DIR" ]]; then
  NGINX_PROXY_LOG_DIR="$(detect_nginx_log_dir || true)"
fi

[[ -n "$NGINX_PROXY_LOG_DIR" ]] \
  || die "Could not detect EasyEngine nginx-proxy log directory. Set NGINX_PROXY_LOG_DIR=/path/to/logs and rerun."

[[ -d "$NGINX_PROXY_LOG_DIR" ]] \
  || die "Log directory does not exist: $NGINX_PROXY_LOG_DIR"

log "EasyEngine nginx-proxy logs: $NGINX_PROXY_LOG_DIR"


# ---------------------------------------------------------------------------
# 3. Create application directories
# ---------------------------------------------------------------------------

mkdir -p \
  "$APP_DIR/config/acquis.d" \
  "$APP_DIR/config/parsers/s02-enrich" \
  "$APP_DIR/data" \
  "$APP_DIR/data-bouncers"

chmod 0750 "$APP_DIR"
chmod 0700 "$APP_DIR/data-bouncers"


# ---------------------------------------------------------------------------
# 4. Copy repository files
# ---------------------------------------------------------------------------

copy_repo_file() {
  local src="$SCRIPT_DIR/$1"
  local dst="$APP_DIR/$1"
  local mode="$2"

  [[ -f "$src" ]] || die "Missing repository file: $1"

  mkdir -p "$(dirname "$dst")"
  install -m "$mode" "$src" "$dst"
}

copy_repo_file \
  "docker-compose.yml.template" \
  0644

copy_repo_file \
  "config/acquis.d/nginx-proxy.yaml" \
  0644

copy_repo_file \
  "config/acquis.d/sshd.yaml" \
  0644

copy_repo_file \
  "config/parsers/s02-enrich/whitelists.yaml" \
  0644


# ---------------------------------------------------------------------------
# 5. Render docker-compose.yml
# ---------------------------------------------------------------------------

log "Rendering docker-compose.yml..."

sed \
  "s|__NGINX_PROXY_LOG_DIR__|$NGINX_PROXY_LOG_DIR|g" \
  "$APP_DIR/docker-compose.yml.template" \
  > "$APP_DIR/docker-compose.yml"

chmod 0644 "$APP_DIR/docker-compose.yml"


# ---------------------------------------------------------------------------
# 6. Initial firewall bouncer configuration
# ---------------------------------------------------------------------------

if [[ ! -f "$APP_DIR/data-bouncers/fw-bouncer.yaml" ]]; then

  log "Creating firewall bouncer configuration..."

  cat > "$APP_DIR/data-bouncers/fw-bouncer.yaml" <<'YAML'
mode: iptables

update_frequency: 10s

log_mode: stdout
log_level: info

api_url: http://127.0.0.1:8080/
api_key: CHANGE_ME

insecure_skip_verify: false

disable_ipv6: false

deny_action: DROP
deny_log: false

supported_decisions_types:
  - ban

iptables_chains:
  - INPUT
  - DOCKER-USER
YAML

  chmod 0600 "$APP_DIR/data-bouncers/fw-bouncer.yaml"

else

  log "Existing firewall bouncer configuration found; keeping it."

fi


# ---------------------------------------------------------------------------
# 7. Start CrowdSec agent only
# ---------------------------------------------------------------------------

log "Starting CrowdSec agent only..."

cd "$APP_DIR"

docker compose up -d crowdsec


# ---------------------------------------------------------------------------
# 8. Wait for CrowdSec LAPI
# ---------------------------------------------------------------------------

log "Waiting for CrowdSec LAPI..."

lapi_ready=false

for _ in {1..30}; do

  if docker exec crowdsec cscli lapi status >/dev/null 2>&1; then
    lapi_ready=true
    break
  fi

  sleep 2

done

[[ "$lapi_ready" == true ]] \
  || die "CrowdSec LAPI did not become ready. Check: docker logs crowdsec"


# ---------------------------------------------------------------------------
# 9. Register firewall bouncer
# ---------------------------------------------------------------------------

register_firewall_bouncer() {

  local name="fw"
  local cfg="$APP_DIR/data-bouncers/fw-bouncer.yaml"

  local existing_key=""
  local key=""

  # Check whether the configuration already contains a real API key.
  existing_key="$(
    awk -F': ' '/^api_key:/ {print $2; exit}' "$cfg" \
      | tr -d '[:space:]'
  )"

  if [[ -n "$existing_key" && "$existing_key" != "CHANGE_ME" ]]; then
    log "Firewall bouncer configuration already contains an API key."
    return 0
  fi

  log "Registering firewall bouncer in CrowdSec..."

  if docker exec crowdsec cscli bouncers list 2>/dev/null \
      | awk 'NR > 1 {print $1}' \
      | grep -Fxq "$name"; then

    die "Bouncer '$name' already exists in CrowdSec but its local config has no API key.

Remove the old bouncer and rerun:

  docker exec crowdsec cscli bouncers delete $name

Then rerun install.sh."

  fi

  key="$(
    docker exec crowdsec cscli bouncers add "$name" -o raw
  )"

  key="$(printf '%s' "$key" | tr -d '\r\n')"

  [[ -n "$key" ]] \
    || die "Could not create bouncer key for $name"

  sed -i \
    "s|^api_key:.*|api_key: $key|" \
    "$cfg"

  chmod 0600 "$cfg"

  log "Firewall bouncer registered successfully."
}

register_firewall_bouncer


# ---------------------------------------------------------------------------
# 10. Cloudflare Worker bouncer
# ---------------------------------------------------------------------------

configure_cloudflare() {

  local answer
  local token
  local generated
  local tmp

  read -r -p "Configure Cloudflare Worker bouncer? [y/N]: " answer

  [[ "${answer,,}" == "y" ]] || return 0

  read -r -s -p "Cloudflare API token: " token
  echo

  [[ -n "$token" ]] \
    || die "Cloudflare token is empty."

  log "Generating Cloudflare Worker configuration..."

  tmp="$(mktemp)"

  trap 'rm -f "$tmp"' RETURN

  docker run --rm \
    crowdsecurity/cloudflare-worker-bouncer:latest \
    -g "$token" \
    > "$tmp"

  [[ -s "$tmp" ]] \
    || die "Cloudflare bouncer returned an empty config."

  cat > "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml" <<'YAML'
crowdsec_config:
  lapi_url: http://crowdsec:8080/
  lapi_key: CHANGE_ME
  update_frequency: 10s
YAML

  cat "$tmp" >> "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  rm -f "$tmp"

  # Cloudflare Worker settings.
  if grep -qE '^[[:space:]]*script_name:' \
      "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"; then

    sed -i \
      's|^[[:space:]]*script_name:.*|script_name: "crowdsec-bouncer"|' \
      "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  else

    printf '\nscript_name: "crowdsec-bouncer"\n' \
      >> "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  fi

  if grep -qE '^[[:space:]]*compatibility_date:' \
      "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"; then

    sed -i \
      's|^[[:space:]]*compatibility_date:.*|compatibility_date: "2026-01-01"|' \
      "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  else

    printf 'compatibility_date: "2026-01-01"\n' \
      >> "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  fi

  chmod 0600 \
    "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  # Register Cloudflare bouncer.
  local cf_key

  cf_key="$(
    docker exec crowdsec cscli bouncers add cfworker -o raw
  )"

  cf_key="$(printf '%s' "$cf_key" | tr -d '\r\n')"

  [[ -n "$cf_key" ]] \
    || die "Could not create Cloudflare bouncer key."

  sed -i \
    "s|^[[:space:]]*lapi_key:.*|  lapi_key: $cf_key|" \
    "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  chmod 0600 \
    "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  warn "Review $APP_DIR/data-bouncers/cf-worker-bouncer.yaml before production."
  warn "Keep only Cloudflare zones actually hosted by this EasyEngine server."
  warn "Make sure Analytics Engine is enabled for the Cloudflare account."

  log "Cloudflare Worker bouncer configured."
}

configure_cloudflare


# ---------------------------------------------------------------------------
# 11. Start stack
# ---------------------------------------------------------------------------

log "Pulling required images..."

docker compose pull crowdsec fw-bouncer

if [[ -f "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml" ]]; then
  docker compose pull cloudflare-worker-bouncer
fi


log "Starting CrowdSec stack..."

docker compose up -d


# ---------------------------------------------------------------------------
# 12. Wait for containers
# ---------------------------------------------------------------------------

sleep 8

log "Checking containers..."

docker compose ps


# CrowdSec
docker inspect crowdsec \
  --format '{{.State.Status}}' \
  | grep -q '^running$' \
  || die "crowdsec is not running."


# Firewall bouncer
docker inspect crowdsec-fw-bouncer \
  --format '{{.State.Status}}' \
  | grep -q '^running$' \
  || die "crowdsec-fw-bouncer is not running. Check:

docker logs crowdsec-fw-bouncer --tail 100"


# Cloudflare bouncer, if configured
if [[ -f "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml" ]]; then

  docker inspect crowdsec-cf-worker-bouncer \
    --format '{{.State.Status}}' \
    | grep -q '^running$' \
    || die "Cloudflare worker bouncer is not running. Check:

docker logs crowdsec-cf-worker-bouncer --tail 100"

fi


# ---------------------------------------------------------------------------
# 13. Check registered bouncers
# ---------------------------------------------------------------------------

log "Checking registered bouncers..."

docker exec crowdsec cscli bouncers list || true


# ---------------------------------------------------------------------------
# 14. Install convenient cscli alias
# ---------------------------------------------------------------------------

BASHRC="/root/.bashrc"

if ! grep -qF "alias cscli='docker exec -t crowdsec cscli'" "$BASHRC" 2>/dev/null; then

  printf "\n# CrowdSec\nalias cscli='docker exec -t crowdsec cscli'\n" \
    >> "$BASHRC"

fi


# ---------------------------------------------------------------------------
# 15. Write installation status
# ---------------------------------------------------------------------------

cat > "$APP_DIR/STATUS.md" <<EOF
# CrowdSec installation

Installed: $(date -Is)

EasyEngine nginx-proxy logs:

$NGINX_PROXY_LOG_DIR

## Services

- crowdsec
- crowdsec-fw-bouncer
$(if [[ -f "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml" ]]; then
  echo "- crowdsec-cf-worker-bouncer"
fi)

## Commands

\`\`\`bash
cd $APP_DIR

docker compose ps

docker exec -t crowdsec cscli metrics

docker exec -t crowdsec cscli alerts list

docker exec -t crowdsec cscli decisions list

docker exec -t crowdsec cscli bouncers list

docker logs crowdsec --tail 100

docker logs crowdsec-fw-bouncer --tail 100
\`\`\`

## Important

Test a temporary CrowdSec decision from another network before disabling Fail2ban.
EOF


# ---------------------------------------------------------------------------
# 16. Finish
# ---------------------------------------------------------------------------

log "Installation complete."

echo
echo "Next:"
echo "  cd $APP_DIR"
echo "  docker compose ps"
echo "  docker exec -t crowdsec cscli bouncers list"
echo "  docker exec -t crowdsec cscli metrics"
echo
echo "IMPORTANT:"
echo "Test a temporary decision from another network before disabling Fail2ban."