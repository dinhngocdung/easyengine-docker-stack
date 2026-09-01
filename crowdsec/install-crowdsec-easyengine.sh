#!/usr/bin/env bash
# CrowdSec installer for EasyEngine v4 on AlmaLinux / Docker / iptables-nft.
# Run: sudo bash install-crowdsec-easyengine.sh --apply

set -Eeuo pipefail
IFS=$'\n\t'

INSTALL_DIR="/opt/crowdsec"
DRY_RUN=0
INSTALL_CLOUDFLARE=0
ENABLE_CLOUDFLARE=0
CF_TOKEN="${CLOUDFLARE_TOKEN:-}"
TRUSTED_CIDRS="${TRUSTED_CIDRS:-}"
NGINX_LOG_DIR="${NGINX_LOG_DIR:-}"
CF_DOMAINS="${CLOUDFLARE_DOMAINS:-}"
REFRESH_CLOUDFLARE=0

readonly DEFAULT_CIDRS=$'127.0.0.1/8\n::1/128\n10.0.0.0/20\n10.1.0.0/16\n10.2.0.0/16'
readonly FIREWALL_NAME="firewallbouncer"
readonly CLOUDFLARE_NAME="cloudflarebouncer"

log()  { printf '[crowdsec] %s\n' "$*"; }
warn() { printf '[crowdsec] WARNING: %s\n' "$*" >&2; }
die()  { printf '[crowdsec] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo bash install-crowdsec-easyengine.sh [options]

  --apply                 Make changes (required; otherwise no change is made)
  --dry-run               Show the checks and intended actions without changing the host
  --cf                    Also install the Cloudflare Worker bouncer
  --token=TOKEN, --cloudflare-token TOKEN
                          Non-interactive Cloudflare API token (prefer prompt or env var)
  --domain=DOMAIN[,DOMAIN...|all]
                          Cloudflare zones to retain; "all" retains every generated zone
  --refresh-cloudflare    Regenerate Cloudflare config; saves a timestamped backup first
  --trusted-cidrs LIST    Extra trusted CIDRs, separated by commas or whitespace
  --nginx-log-dir PATH    EasyEngine nginx-proxy log directory
  --install-dir PATH      Installation directory (default: /opt/crowdsec)
  -h, --help              Show this help

Environment alternatives: CLOUDFLARE_TOKEN, TRUSTED_CIDRS, NGINX_LOG_DIR.
Cloudflare Analytics Engine must already be enabled in the Cloudflare account.
EOF
}

# A CRLF script is a frequent source of an opaque "exec format error". Re-exec a
# sanitized temporary copy so it remains usable even when downloaded on Windows.
# This must happen before option parsing so all original arguments are preserved.
if LC_ALL=C grep -q $'\r' "$0" 2>/dev/null; then
  fixed_script=$(mktemp /tmp/crowdsec-installer.XXXXXX)
  tr -d '\r' < "$0" > "$fixed_script"
  if bash "$fixed_script" "$@"; then fixed_status=0; else fixed_status=$?; fi
  rm -f "$fixed_script"
  exit "$fixed_status"
fi

while (($#)); do
  case "$1" in
    --apply) DRY_RUN=0; APPLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) : ;; # Backward compatible: installation no longer asks for confirmation.
    --no-cloudflare) warn "--no-cloudflare is unnecessary; Cloudflare is off unless --cf is provided." ;;
    --cf) INSTALL_CLOUDFLARE=1 ;;
    --cloudflare-token) shift; (($#)) || die "--cloudflare-token needs a value"; CF_TOKEN=$1 ;;
    --cloudflare-token=*) CF_TOKEN=${1#*=} ;;
    --token) shift; (($#)) || die "--token needs a value"; CF_TOKEN=$1 ;;
    --token=*) CF_TOKEN=${1#*=} ;;
    --domain) shift; (($#)) || die "--domain needs a value"; CF_DOMAINS=$1 ;;
    --domain=*) CF_DOMAINS=${1#*=} ;;
    --refresh-cloudflare) REFRESH_CLOUDFLARE=1 ;;
    --trusted-cidrs) shift; (($#)) || die "--trusted-cidrs needs a value"; TRUSTED_CIDRS=$1 ;;
    --nginx-log-dir) shift; (($#)) || die "--nginx-log-dir needs a value"; NGINX_LOG_DIR=$1 ;;
    --install-dir) shift; (($#)) || die "--install-dir needs a value"; INSTALL_DIR=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

APPLY=${APPLY:-0}

run() {
  if ((DRY_RUN)); then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

require_apply() {
  ((DRY_RUN || APPLY)) || die "No changes made. Re-run with --apply (or use --dry-run to preview)."
}

require_root() {
  ((DRY_RUN)) && return 0
  ((EUID == 0)) || die "Run with sudo/root: sudo bash $0 --apply"
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
    warn "docker-compose v1 was found. Docker Compose v2 is recommended."
  else
    die "Docker Compose was not found. Install Docker Compose v2 first."
  fi
}

compose() { "${COMPOSE[@]}" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }

detect_nginx_logs() {
  if [[ -n $NGINX_LOG_DIR ]]; then
    [[ -d $NGINX_LOG_DIR ]] || die "NGINX_LOG_DIR does not exist: $NGINX_LOG_DIR"
    return
  fi
  local candidate
  for candidate in \
    /opt/easyengine/services/nginx-proxy/logs \
    /opt/easyengine/services/global-nginx-proxy/logs; do
    if [[ -d $candidate ]]; then NGINX_LOG_DIR=$candidate; return; fi
  done

  # EasyEngine normally uses this directory. Inspecting containers is a fallback
  # only; a guessed mount is never silently used.
  local container mounts
  while IFS= read -r container; do
    mounts=$(docker inspect "$container" --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}' 2>/dev/null || true)
    candidate=$(awk '$2 ~ /nginx/ && $1 ~ /log/ {print $1; exit}' <<<"$mounts")
    if [[ -n $candidate && -d $candidate ]]; then
      NGINX_LOG_DIR=$candidate
      log "Detected nginx-proxy logs from $container: $NGINX_LOG_DIR"
      return
    fi
  done < <(docker ps --format '{{.Names}}' | awk '/nginx.*proxy|proxy.*nginx/')
  die "Could not find EasyEngine nginx-proxy logs. Re-run with --nginx-log-dir PATH."
}

write_if_missing() {
  local target=$1
  if [[ -e $target ]]; then
    log "Keeping existing file: $target"
    # Consume piped template content; otherwise pipefail treats the producer's
    # broken pipe as an error when an idempotent run keeps this file.
    cat >/dev/null
    return
  fi
  if ((DRY_RUN)); then log "Would create: $target"; cat >/dev/null; return; fi
  install -D -m 0640 /dev/stdin "$target"
  log "Created: $target"
}

write_executable_if_missing() {
  local target=$1
  if [[ -e $target ]]; then
    log "Keeping existing file: $target"
    cat >/dev/null
    return
  fi
  if ((DRY_RUN)); then log "Would create: $target"; cat >/dev/null; return; fi
  install -D -m 0755 /dev/stdin "$target"
  log "Created: $target"
}

write_world_readable_if_missing() {
  local target=$1
  if [[ -e $target ]]; then
    log "Keeping existing file: $target"
    cat >/dev/null
    return
  fi
  if ((DRY_RUN)); then log "Would create: $target"; cat >/dev/null; return; fi
  install -D -m 0644 /dev/stdin "$target"
  log "Created: $target"
}

valid_cidr() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ || $1 =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]]
}

render_whitelist() {
  local cidr
  {
    cat <<'EOF'
name: crowdsecurity/whitelists
description: "Internal EasyEngine ranges + trusted sources"
whitelist:
  reason: "internal EasyEngine ranges and explicitly trusted sources"
  cidr:
EOF
    while IFS= read -r cidr; do printf '    - "%s"\n' "$cidr"; done <<<"$DEFAULT_CIDRS"
    for cidr in ${TRUSTED_CIDRS//,/ }; do
      valid_cidr "$cidr" || die "Invalid trusted CIDR: $cidr"
      printf '    - "%s"\n' "$cidr"
    done
  } | write_if_missing "$INSTALL_DIR/config/parsers/s02-enrich/whitelists.yaml"
}

create_base_files() {
  run mkdir -p "$INSTALL_DIR/config/acquis.d" "$INSTALL_DIR/config/parsers/s02-enrich" \
    "$INSTALL_DIR/data" "$INSTALL_DIR/data-bouncers"

  cat <<EOF | write_if_missing "$INSTALL_DIR/config/acquis.d/nginx-proxy.yaml"
filenames:
  - /var/log/nginx-proxy/access.log
  - /var/log/nginx-proxy/error.log
labels:
  type: nginx
EOF
  cat <<'EOF' | write_if_missing "$INSTALL_DIR/config/acquis.d/sshd.yaml"
filenames:
  - /var/log/secure
labels:
  type: syslog
EOF
  render_whitelist
  cat <<'EOF' | write_if_missing "$INSTALL_DIR/data-bouncers/firewall-bouncer.yaml"
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
  cat <<EOF | write_if_missing "$INSTALL_DIR/docker-compose.yml"
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
      - ${NGINX_LOG_DIR}:/var/log/nginx-proxy:ro
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
}

create_cscli_shortcut() {
  cat <<EOF | write_executable_if_missing /usr/local/bin/crowdsec-cscli
#!/usr/bin/env bash
set -euo pipefail
if docker compose version >/dev/null 2>&1; then
  exec docker compose -f "$INSTALL_DIR/docker-compose.yml" exec crowdsec cscli "\$@"
fi
exec docker-compose -f "$INSTALL_DIR/docker-compose.yml" exec crowdsec cscli "\$@"
EOF
  cat <<'EOF' | write_world_readable_if_missing /etc/profile.d/crowdsec-cscli.sh
# Added by install-crowdsec-easyengine.sh. Open a new login shell after install.
alias cscli='/usr/local/bin/crowdsec-cscli'
EOF
}

hosted_sites() {
  command -v ee >/dev/null 2>&1 || return 0
  ee site list 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' || true
}

normalise_domains() {
  local domain cleaned=() item
  for item in ${1//,/ }; do
    domain=${item,,}
    [[ $domain == \*.* ]] && domain=${domain:2}
    [[ $domain =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "Invalid domain: $item"
    cleaned+=("$domain")
  done
  (IFS=,; printf '%s' "${cleaned[*]}")
}

ask_for_domains() {
  if [[ ${CF_DOMAINS,,} == all ]]; then
    CF_DOMAINS=all
    return
  fi
  [[ -n $CF_DOMAINS ]] && { CF_DOMAINS=$(normalise_domains "$CF_DOMAINS"); return; }
  local detected answer
  detected=$(hosted_sites || true)
  if [[ -n $detected ]]; then
    printf 'EasyEngine domains detected:\n%s\n' "$detected"
    printf 'Domains to protect (comma-separated; Enter uses all detected domains): '
  else
    printf 'Domains to protect (comma-separated, for example a.com,b.com): '
  fi
  read -r answer
  [[ -n $answer ]] || answer=$(paste -sd, <<<"$detected")
  [[ -n $answer ]] || die "At least one --domain is required for the Cloudflare bouncer."
  CF_DOMAINS=$(normalise_domains "$answer")
}

existing_cloudflare_lapi_key() {
  awk '
    /^[[:space:]]*crowdsec_config:[[:space:]]*$/ { in_lapi=1; next }
    in_lapi && /^[^[:space:]]/ { in_lapi=0 }
    in_lapi && /^[[:space:]]*lapi_key:/ {
      sub(/^[[:space:]]*lapi_key:[[:space:]]*/, "")
      if ($0 !~ /^\$\{/ && $0 !~ /__CROWDSEC_API_KEY_PENDING__/) { print; exit }
    }
  ' "$1"
}

rewrite_cloudflare_config() {
  # The official generator already contains exactly one crowdsec_config. Edit
  # that block instead of prepending a second one, and keep only selected zones.
  local source=$1 destination=$2 lapi_key=$3
  awk -v domains="$CF_DOMAINS" -v lapi_key="$lapi_key" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function indentation(s) { match(s, /^[[:space:]]*/); return RLENGTH }
    function flush_zone(    i) {
      if (!in_zone) return
      if (keep_zone) { for (i=1; i<=zone_lines; i++) print zone[i]; kept++ }
      delete zone; zone_lines=0; in_zone=0
    }
    function begin_zone(s,    p, zone_name) {
      in_zone=1; zone_indent=indentation(s); zone_lines=1; zone[1]=s; seen++
      p=index(s, "#"); zone_name=(p ? trim(substr(s, p+1)) : "")
      keep_zone=(keep_all || tolower(zone_name) in wanted)
    }
    BEGIN {
      keep_all=(tolower(domains) == "all")
      if (!keep_all) {
        split(domains, entries, ",")
        for (i in entries) wanted[tolower(entries[i])]=1
      }
    }
    {
      line=$0; indent=indentation(line)
      if (in_zone) {
        if (line ~ /^[[:space:]]*-[[:space:]]+zone_id:/ && indent == zone_indent) {
          flush_zone(); begin_zone(line); next
        }
        if (indent >= zone_indent || line ~ /^[[:space:]]*$/) { zone[++zone_lines]=line; next }
        flush_zone()
      }
      if (line ~ /^[[:space:]]*-[[:space:]]+zone_id:/) { begin_zone(line); next }

      if (line ~ /^[[:space:]]*crowdsec_config:[[:space:]]*$/) { section="lapi"; print; next }
      if (line ~ /^[^[:space:]]/) section=""
      if (section == "lapi" && line ~ /^[[:space:]]*lapi_url:/) { sub(/:.*/, ": http://crowdsec:8080/"); print; next }
      if (section == "lapi" && line ~ /^[[:space:]]*lapi_key:/) { sub(/:.*/, ": " lapi_key); print; next }
      if (section == "lapi" && line ~ /^[[:space:]]*only_include_decisions_from:/) { sub(/:.*/, ": [\"cscli\", \"crowdsec\"]"); print; next }
      if (line ~ /^[[:space:]]*script_name:/) { sub(/:.*/, ": \"crowdsec-bouncer\""); print; next }
      if (line ~ /^[[:space:]]*compatibility_date:/) { sub(/:.*/, ": \"2026-01-01\""); print; next }
      print
    }
    END {
      flush_zone()
      if (seen == 0) { print "No zones were found in Cloudflare generator output." > "/dev/stderr"; exit 41 }
      if (kept == 0) { print "None of the requested domains matched a generated Cloudflare zone." > "/dev/stderr"; exit 42 }
    }
  ' "$source" >"$destination"
}

configure_cloudflare() {
  ((INSTALL_CLOUDFLARE)) || { log "Cloudflare Worker bouncer skipped (use --cf to install it)."; return; }
  if [[ -z $CF_TOKEN && -t 0 ]]; then
    printf 'Cloudflare API token (input is hidden): '
    read -r -s CF_TOKEN; printf '\n'
  fi
  [[ -n $CF_TOKEN ]] || { log "Cloudflare Worker bouncer skipped (no token supplied)."; return; }
  ask_for_domains
  ENABLE_CLOUDFLARE=1
  local target="$INSTALL_DIR/data-bouncers/cloudflare-worker-bouncer.yaml" temporary filtered lapi_key backup
  if [[ -e $target && ! $REFRESH_CLOUDFLARE -eq 1 ]]; then
    log "Keeping existing Cloudflare bouncer config: $target (use --refresh-cloudflare to regenerate it)"
    return
  fi
  if ((DRY_RUN)); then
    log "Would generate one Cloudflare config, keeping zones only for: $CF_DOMAINS"
    return
  fi
  lapi_key="__CROWDSEC_API_KEY_PENDING__"
  if [[ -e $target ]]; then
    local prior_key
    prior_key=$(existing_cloudflare_lapi_key "$target" || true)
    [[ -n $prior_key ]] && lapi_key=$prior_key
  fi
  temporary=$(mktemp "$INSTALL_DIR/data-bouncers/.cloudflare.generated.XXXXXX")
  filtered=$(mktemp "$INSTALL_DIR/data-bouncers/.cloudflare.filtered.XXXXXX")
  if ! docker run --rm crowdsecurity/cloudflare-worker-bouncer:latest -g "$CF_TOKEN" >"$temporary"; then
    rm -f "$temporary" "$filtered"
    die "Cloudflare config generation failed. Check the token permissions and Analytics Engine."
  fi
  if ! rewrite_cloudflare_config "$temporary" "$filtered" "$lapi_key"; then
    rm -f "$temporary" "$filtered"
    die "Cloudflare config was not changed because the selected domains did not match the generated zones."
  fi
  if [[ -e $target ]]; then
    backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$target" "$backup"
    log "Backed up prior Cloudflare config: $backup"
  fi
  install -m 0640 "$filtered" "$target"
  rm -f "$temporary" "$filtered"
  log "Generated one Cloudflare bouncer config, filtered to: $CF_DOMAINS"
}

has_pending_key() {
  [[ ! -f $1 ]] || grep -q '__CROWDSEC_API_KEY_PENDING__' "$1"
}

replace_pending_key() {
  local target=$1 key=$2 temporary
  temporary=$(mktemp "${target}.XXXXXX")
  awk -v key="$key" '{sub(/__CROWDSEC_API_KEY_PENDING__/, key)}1' "$target" >"$temporary"
  chmod 0640 "$temporary"
  mv "$temporary" "$target"
}

register_bouncer() {
  local name=$1 target=$2 key
  has_pending_key "$target" || { log "Keeping existing API key in $target"; return; }
  key=$(compose exec -T crowdsec cscli bouncers add "$name" -o raw 2>&1) || {
    warn "Could not register $name. It may already exist; its existing key cannot be read back safely. Keeping the config unchanged."
    warn "Use 'docker compose exec crowdsec cscli bouncers delete $name' only if you intentionally want to replace it, then re-run."
    return 1
  }
  [[ -n $key ]] || die "CrowdSec returned an empty key for $name"
  replace_pending_key "$target" "$key"
  log "Registered $name and stored its API key with mode 0640."
}

wait_for_lapi() {
  local attempt
  for attempt in {1..30}; do
    if compose exec -T crowdsec cscli version >/dev/null 2>&1; then return; fi
    sleep 2
  done
  compose logs --tail=80 crowdsec >&2 || true
  die "CrowdSec LAPI did not become ready within 60 seconds."
}

start_cloudflare_worker() {
  # A previously failed Compose endpoint can retain a deleted Docker network ID.
  # Retry only this optional container; CrowdSec state and firewall rules stay up.
  if compose --profile cloudflare up -d --no-deps cloudflare-worker-bouncer; then
    return
  fi
  warn "Cloudflare Worker could not attach to Docker networking; removing only its failed container and retrying once."
  compose --profile cloudflare rm -sf cloudflare-worker-bouncer || true
  compose --profile cloudflare up -d --no-deps --force-recreate cloudflare-worker-bouncer || \
    die "Cloudflare Worker still cannot start. Run 'docker network inspect crowdsec_default' and inspect its container logs."
}

verify() {
  log "Container status:"
  compose ps || true
  log "Bouncer status (may take a few seconds to become Valid):"
  compose exec -T crowdsec cscli bouncers list || true
  log "Metrics:"
  compose exec -T crowdsec cscli metrics || true
  cat <<'EOF'

Manual safety test (use an IP from a different network, never your active SSH IP):
  docker exec crowdsec cscli decisions add --ip <TEST_IP> --duration 2m -R test
  # test the hosted domain from a separate 4G/VPN connection
  docker exec crowdsec cscli decisions delete --ip <TEST_IP>
EOF
}

main() {
  require_apply
  require_root
  command -v docker >/dev/null 2>&1 || die "Docker was not found. Install EasyEngine/Docker first."
  detect_compose
  command -v iptables >/dev/null 2>&1 || die "iptables was not found. This installer requires iptables-nft."
  local iptables_version
  iptables_version=$(iptables --version 2>&1 || true)
  [[ $iptables_version == *nf_tables* ]] || die "iptables-nft was not detected ($iptables_version). Stop: do not use this iptables-mode installer on a different firewall backend."
  log "Confirmed firewall backend: $iptables_version"
  detect_nginx_logs
  log "Using nginx-proxy logs: $NGINX_LOG_DIR"

  if ((DRY_RUN)); then
    log "Dry run complete. Re-run with --apply to install."
    return
  fi
  create_base_files
  create_cscli_shortcut
  configure_cloudflare
  compose config -q || die "Generated/existing docker-compose.yml is invalid; no containers were started."
  compose up -d crowdsec
  wait_for_lapi
  register_bouncer "$FIREWALL_NAME" "$INSTALL_DIR/data-bouncers/firewall-bouncer.yaml" || true
  if has_pending_key "$INSTALL_DIR/data-bouncers/firewall-bouncer.yaml"; then
    die "Firewall bouncer has no usable key, so it was not started. Resolve the existing bouncer key issue shown above, then re-run."
  fi
  if ((ENABLE_CLOUDFLARE)); then
    register_bouncer "$CLOUDFLARE_NAME" "$INSTALL_DIR/data-bouncers/cloudflare-worker-bouncer.yaml" || true
    if has_pending_key "$INSTALL_DIR/data-bouncers/cloudflare-worker-bouncer.yaml"; then
      warn "Cloudflare bouncer has no usable key; it will not be started. CrowdSec and the firewall bouncer will still start."
      ENABLE_CLOUDFLARE=0
    fi
  fi
  compose up -d
  ((ENABLE_CLOUDFLARE)) && start_cloudflare_worker
  verify
  log "Installation completed. Existing config and data were never overwritten."
}

main "$@"
