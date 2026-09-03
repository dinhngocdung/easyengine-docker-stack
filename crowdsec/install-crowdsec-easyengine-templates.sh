#!/usr/bin/env bash
# Installer that deploys CrowdSec templates from the repo (or from remote templates)
# Usage: sudo bash install-crowdsec-easyengine-templates.sh --apply [--cf] [--dry-run] [--templates-url URL]

set -Eeuo pipefail
IFS=$'\n\t'

INSTALL_DIR="/opt/crowdsec"
DRY_RUN=0
APPLY=0
INSTALL_CLOUDFLARE=0
TEMPLATES_URL="${TEMPLATES_URL:-https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/crowdsec/templates-installer/crowdsec}"

log()  { printf '[crowdsec] %s\n' "$*"; }
die()  { printf '[crowdsec] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo bash install-crowdsec-easyengine-templates.sh [options]

  --apply                 Make changes (required; otherwise no change is made)
  --dry-run               Show the checks and intended actions without changing the host
  --cf                    Also install the Cloudflare Worker bouncer
  --templates-url URL     Base raw URL where templates are hosted (defaults to this repo's branch)
  -h, --help              Show this help
EOF
}

# Quick arg parsing
while (($#)); do
  case "$1" in
    --apply) DRY_RUN=0; APPLY=1 ;; 
    --dry-run) DRY_RUN=1 ;; 
    --cf) INSTALL_CLOUDFLARE=1 ;; 
    --templates-url) shift; (($#)) || die "--templates-url needs a value"; TEMPLATES_URL=$1 ;; 
    --templates-url=*) TEMPLATES_URL=${1#*=} ;; 
    -h|--help) usage; exit 0 ;; 
    *) die "Unknown option: $1" ;; 
  esac
  shift
done

((APPLY)) || die "No changes made. Re-run with --apply (or use --dry-run to preview)."

run() {
  if ((DRY_RUN)); then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

fetch_template() {
  local relpath=$1 tmpfile
  tmpfile=$(mktemp)
  if curl -fsS -o "$tmpfile" "$TEMPLATES_URL/$relpath"; then
    echo "$tmpfile"
    return 0
  fi
  rm -f "$tmpfile"
  return 1
}

copy_template_if_exists() {
  local relpath=$1 target=$2 mode=${3:-0640} tmp
  # If running from within the repo's crowdsec/ dir, prefer local copy
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$script_dir/$relpath" ]]; then
    log "Using local template $script_dir/$relpath -> $target"
    if ((DRY_RUN)); then log "Would create: $target"; return 0; fi
    mkdir -p "$(dirname "$target")"
    envsubst < "$script_dir/$relpath" > "${target}.tmp"
    install -m "$mode" "${target}.tmp" "$target"
    rm -f "${target}.tmp"
    return 0
  fi
  # Try remote
  tmp=$(fetch_template "$relpath") || return 1
  log "Fetched remote template $relpath -> $target"
  if ((DRY_RUN)); then rm -f "$tmp"; log "Would create: $target"; return 0; fi
  mkdir -p "$(dirname "$target")"
  envsubst < "$tmp" > "${target}.tmp"
  install -m "$mode" "${target}.tmp" "$target"
  rm -f "$tmp" "${target}.tmp"
  return 0
}

require_root() {
  ((DRY_RUN)) && return 0
  ((EUID == 0)) || die "Run with sudo/root: sudo bash $0 --apply"
}

require_root

if ((DRY_RUN)); then log "Dry run: templates would be applied to $INSTALL_DIR"; fi

# Create directories and copy templates (or fallback small defaults)
run mkdir -p "$INSTALL_DIR/config/acquis.d" "$INSTALL_DIR/config/parsers/s02-enrich" \
  "$INSTALL_DIR/data" "$INSTALL_DIR/data-bouncers" "$INSTALL_DIR/bin"

# nginx-proxy acquis
if ! copy_template_if_exists "config/acquis.d/nginx-proxy.yaml" "$INSTALL_DIR/config/acquis.d/nginx-proxy.yaml"; then
  cat <<'EOF' | install -D -m 0640 /dev/stdin "$INSTALL_DIR/config/acquis.d/nginx-proxy.yaml"
filenames:
  - /var/log/nginx-proxy/access.log
  - /var/log/nginx-proxy/error.log
labels:
  type: nginx
EOF
  log "Wrote fallback nginx-proxy acquis"
fi

# sshd acquis
if ! copy_template_if_exists "config/acquis.d/sshd.yaml" "$INSTALL_DIR/config/acquis.d/sshd.yaml"; then
  cat <<'EOF' | install -D -m 0640 /dev/stdin "$INSTALL_DIR/config/acquis.d/sshd.yaml"
filenames:
  - /var/log/secure
labels:
  type: syslog
EOF
  log "Wrote fallback sshd acquis"
fi

# whitelists
if ! copy_template_if_exists "parsers/s02-enrich/whitelists.yaml" "$INSTALL_DIR/config/parsers/s02-enrich/whitelists.yaml"; then
  cat <<'EOF' | install -D -m 0640 /dev/stdin "$INSTALL_DIR/config/parsers/s02-enrich/whitelists.yaml"
name: crowdsecurity/whitelists
description: "Internal EasyEngine ranges + trusted sources"
whitelist:
  reason: "internal EasyEngine ranges and explicitly trusted sources"
  cidr:
    - "127.0.0.1/8"
    - "::1/128"
    - "10.0.0.0/20"
    - "10.1.0.0/16"
    - "10.2.0.0/16"
EOF
  log "Wrote fallback whitelists"
fi

# firewall bouncer
if ! copy_template_if_exists "data-bouncers/firewall-bouncer.yaml" "$INSTALL_DIR/data-bouncers/firewall-bouncer.yaml"; then
  cat <<'EOF' | install -D -m 0640 /dev/stdin "$INSTALL_DIR/data-bouncers/firewall-bouncer.yaml"
mode: iptables
pid_dir: /var/run/
update_frequency: 10s
api_url: http://127.0.0.1:8080/
api_key: __CROWDSEC_API_KEY_PENDING__
log_mode: stdout
log_level: info
iptables_chains:
  - INPUT
  - DOCKER-USER
EOF
  log "Wrote fallback firewall bouncer"
fi

# cloudflare bouncer (template only; installer will still run generator if requested)
if ! copy_template_if_exists "data-bouncers/cloudflare-worker-bouncer.yaml" "$INSTALL_DIR/data-bouncers/cloudflare-worker-bouncer.yaml"; then
  cat <<'EOF' | install -D -m 0640 /dev/stdin "$INSTALL_DIR/data-bouncers/cloudflare-worker-bouncer.yaml"
# Cloudflare worker bouncer placeholder. The installer can fetch a generated config when --cf is used.
lapi_key: __CROWDSEC_API_KEY_PENDING__
EOF
  log "Wrote fallback cloudflare bouncer placeholder"
fi

# docker-compose
if ! copy_template_if_exists "docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"; then
  cat <<'EOF' | install -D -m 0640 /dev/stdin "$INSTALL_DIR/docker-compose.yml"
name: crowdsec
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    environment:
      COLLECTIONS: "crowdsecurity/nginx crowdsecurity/sshd crowdsecurity/linux crowdsecurity/wordpress"
      TZ: "${TZ:-Asia/Ho_Chi_Minh}"
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./config:/etc/crowdsec
      - ./data:/var/lib/crowdsec/data
      - /var/log/secure:/var/log/secure:ro
      - ${NGINX_LOG_DIR:-/opt/easyengine/services/nginx-proxy/logs}:/var/log/nginx-proxy:ro
    restart: unless-stopped

  firewall-bouncer:
    image: ghcr.io/shgew/cs-firewall-bouncer-docker:stable
    container_name: crowdsec-firewall-bouncer
    network_mode: host
    cap_add: [NET_ADMIN, NET_RAW]
    security_opt: [no-new-privileges:true]
    depends_on: [crowdsec]
    volumes:
      - ./data-bouncers/firewall-bouncer.yaml:/config/crowdsec-firewall-bouncer.yaml:ro
      - /etc/localtime:/etc/localtime:ro
    restart: unless-stopped

  cloudflare-worker-bouncer:
    profiles: [cloudflare]
    image: crowdsecurity/cloudflare-worker-bouncer:latest
    container_name: crowdsec-cloudflare-worker-bouncer
    depends_on: [crowdsec]
    volumes:
      - ./data-bouncers/cloudflare-worker-bouncer.yaml:/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml:ro
    restart: unless-stopped
EOF
  log "Wrote fallback docker-compose"
fi

# cscli shortcut
if ! copy_template_if_exists "bin/crowdsec-cscli" "/usr/local/bin/crowdsec-cscli" 0755; then
  cat <<'EOF' | install -D -m 0755 /dev/stdin "/usr/local/bin/crowdsec-cscli"
#!/usr/bin/env bash
set -euo pipefail
if docker compose version >/dev/null 2>&1; then
  exec docker compose -f "$INSTALL_DIR/docker-compose.yml" exec crowdsec cscli "$@"
fi
exec docker-compose -f "$INSTALL_DIR/docker-compose.yml" exec crowdsec cscli "$@"
EOF
  log "Installed cscli shortcut"
fi

log "Templates installed to $INSTALL_DIR"
log "If --cf was provided you should run the Cloudflare generator workflow from the original installer to produce the worker config."

