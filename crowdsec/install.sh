#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/crowdsec"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL_DEFAULT="https://raw.githubusercontent.com/YOUR_GITHUB_USER/easyengine-crowdsec/main"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Installation failed at line $LINENO. See the command above."' ERR

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"

command -v docker >/dev/null 2>&1 || die "Docker is required. EasyEngine normally installs it."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

command -v iptables >/dev/null 2>&1 || die "iptables is required."
iptables --version | grep -q 'nf_tables' || die "This installer expects iptables-nft. Current: $(iptables --version)"

if ! iptables -S DOCKER-USER >/dev/null 2>&1; then
  warn "DOCKER-USER chain does not exist yet."
  warn "Docker may create it when its bridge networking is initialized."
fi

detect_nginx_log_dir() {
  local candidates=(
    "/opt/easyengine/services/nginx-proxy/logs"
    "/opt/easyengine/services/nginx-proxy/log"
  )

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

[[ -n "$NGINX_PROXY_LOG_DIR" ]] || die \
  "Could not detect EasyEngine nginx-proxy log directory. Set NGINX_PROXY_LOG_DIR=/path/to/logs and rerun."

[[ -d "$NGINX_PROXY_LOG_DIR" ]] || die "Log directory does not exist: $NGINX_PROXY_LOG_DIR"

log "EasyEngine nginx-proxy logs: $NGINX_PROXY_LOG_DIR"

mkdir -p \
  "$APP_DIR/config/acquis.d" \
  "$APP_DIR/config/parsers/s02-enrich" \
  "$APP_DIR/data" \
  "$APP_DIR/data-bouncers" \
  "$APP_DIR/fw-bouncer"

copy_repo_file() {
  local src="$SCRIPT_DIR/$1"
  local dst="$APP_DIR/$1"
  [[ -f "$src" ]] || die "Missing repository file: $1"
  mkdir -p "$(dirname "$dst")"
  install -m "$3" "$src" "$dst"
}

copy_repo_file "docker-compose.yml.template" "$APP_DIR/docker-compose.yml.template" 0644
copy_repo_file "config/acquis.d/nginx-proxy.yaml" "$APP_DIR/config/acquis.d/nginx-proxy.yaml" 0644
copy_repo_file "config/acquis.d/sshd.yaml" "$APP_DIR/config/acquis.d/sshd.yaml" 0644
copy_repo_file "config/parsers/s02-enrich/whitelists.yaml" "$APP_DIR/config/parsers/s02-enrich/whitelists.yaml" 0644
copy_repo_file "fw-bouncer/Dockerfile" "$APP_DIR/fw-bouncer/Dockerfile" 0644

# Render compose with the actual EasyEngine log path.
sed "s|\${NGINX_PROXY_LOG_DIR}|$NGINX_PROXY_LOG_DIR|g" \
  "$APP_DIR/docker-compose.yml.template" > "$APP_DIR/docker-compose.yml"

chmod 0750 "$APP_DIR"
chmod 0700 "$APP_DIR/data-bouncers"

# Initial firewall bouncer config. The API key is inserted after LAPI is up.
cat > "$APP_DIR/data-bouncers/fw-bouncer.yaml" <<'YAML'
mode: iptables
pid_dir: /var/run/
update_frequency: 10s
api_url: http://127.0.0.1:8080/
api_key: CHANGE_ME
log_mode: stdout
log_level: info
iptables_chains:
  - INPUT
  - DOCKER-USER
YAML
chmod 0600 "$APP_DIR/data-bouncers/fw-bouncer.yaml"

log "Starting CrowdSec agent only..."
cd "$APP_DIR"
docker compose up -d crowdsec

log "Waiting for CrowdSec LAPI..."
for _ in {1..30}; do
  if docker exec crowdsec cscli lapi status >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker exec crowdsec cscli lapi status >/dev/null 2>&1 \
  || die "CrowdSec LAPI did not become ready. Check: docker logs crowdsec"

register_bouncer() {
  local name="$1"
  local cfg="$2"

  if docker exec crowdsec cscli bouncers list 2>/dev/null \
      | awk 'NR > 1 {print $1}' | grep -Fxq "$name"; then
    warn "Bouncer '$name' already exists. Reusing it."
    return 0
  fi

  docker exec crowdsec cscli bouncers add "$name" -o raw > "/tmp/crowdsec-${name}.key"
  local key
  key="$(tr -d '\r\n' < "/tmp/crowdsec-${name}.key")"
  [[ -n "$key" ]] || die "Could not create bouncer key for $name"
  rm -f "/tmp/crowdsec-${name}.key"

  case "$name" in
    fw)
      sed -i "s/^api_key: .*/api_key: $key/" "$cfg"
      ;;
    cfworker)
      if [[ -f "$cfg" ]]; then
        sed -i "s/^  lapi_key: .*/  lapi_key: $key/" "$cfg"
      fi
      ;;
  esac

  chmod 0600 "$cfg"
}

register_bouncer "fw" "$APP_DIR/data-bouncers/fw-bouncer.yaml"

configure_cloudflare() {
  local answer token generated tmp
  read -r -p "Configure Cloudflare Worker bouncer? [y/N]: " answer
  [[ "${answer,,}" == "y" ]] || return 0

  read -r -s -p "Cloudflare API token: " token
  echo
  [[ -n "$token" ]] || die "Cloudflare token is empty."

  log "Generating Cloudflare Worker configuration from upstream binary..."
  tmp="$(mktemp)"

  docker run --rm crowdsecurity/cloudflare-worker-bouncer:latest \
    -g "$token" > "$tmp"

  [[ -s "$tmp" ]] || die "Cloudflare bouncer returned an empty config."

  cat > "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml" <<'YAML'
crowdsec_config:
  lapi_url: http://crowdsec:8080/
  lapi_key: CHANGE_ME
  update_frequency: 10s
YAML

  # Generated config is appended exactly as produced by the upstream binary.
  cat "$tmp" >> "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"
  rm -f "$tmp"

  # Set stable worker options recommended for this deployment.
  sed -i 's/^[[:space:]]*script_name: .*/        script_name: "crowdsec-bouncer"/' \
    "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"
  sed -i 's/^[[:space:]]*compatibility_date: .*/        compatibility_date: "2026-01-01"/' \
    "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  chmod 0600 "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  register_bouncer "cfworker" "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml"

  warn "Review $APP_DIR/data-bouncers/cf-worker-bouncer.yaml before production."
  warn "Keep only the Cloudflare zones actually hosted by this EasyEngine server."
  warn "If the generated config contains duplicate top-level keys, remove/merge them before starting the service."

  rm -f "$APP_DIR/.cf-token"
}

configure_cloudflare

# If CF was not configured, don't start a service whose config does not exist.
if [[ ! -f "$APP_DIR/data-bouncers/cf-worker-bouncer.yaml" ]]; then
  sed -i '/^  cloudflare-worker-bouncer:/,/^    restart: unless-stopped$/d' \
    "$APP_DIR/docker-compose.yml"
fi

log "Building firewall bouncer..."
docker compose build fw-bouncer

log "Starting stack..."
docker compose up -d

sleep 8

log "Checking containers..."
docker compose ps

docker inspect crowdsec --format '{{.State.Status}}' | grep -q '^running$' \
  || die "crowdsec is not running"

docker inspect crowdsec-fw-bouncer --format '{{.State.Status}}' | grep -q '^running$' \
  || die "crowdsec-fw-bouncer is not running"

if docker ps -a --format '{{.Names}}' | grep -qx crowdsec-cf-worker-bouncer; then
  docker inspect crowdsec-cf-worker-bouncer --format '{{.State.Status}}' \
    | grep -q '^running$' \
    || die "Cloudflare worker bouncer exists but is not running. Check its logs."
fi

log "Checking registered bouncers..."
docker exec crowdsec cscli bouncers list || true

# Install a convenient alias for root.
BASHRC="/root/.bashrc"
if ! grep -qF "alias cscli='docker exec -t crowdsec cscli'" "$BASHRC" 2>/dev/null; then
  printf "\nalias cscli='docker exec -t crowdsec cscli'\n" >> "$BASHRC"
fi

cat > "$APP_DIR/STATUS.md" <<EOF
# CrowdSec installation

Installed: $(date -Is)
EasyEngine nginx-proxy logs: $NGINX_PROXY_LOG_DIR

## Commands

cd $APP_DIR
docker compose ps
docker exec -t crowdsec cscli metrics
docker exec -t crowdsec cscli alerts list
docker exec -t crowdsec cscli decisions list
docker exec -t crowdsec cscli bouncers list
docker logs crowdsec --tail 100
docker logs crowdsec-fw-bouncer --tail 100
EOF

log "Installation complete."
echo
echo "Next:"
echo "  cd $APP_DIR"
echo "  docker compose ps"
echo "  docker exec -t crowdsec cscli bouncers list"
echo "  docker exec -t crowdsec cscli metrics"
echo
echo "IMPORTANT: test a temporary decision from another network before disabling Fail2ban."
