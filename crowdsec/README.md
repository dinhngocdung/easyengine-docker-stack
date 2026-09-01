# CrowdSec installer for EasyEngine v4

`install-crowdsec-easyengine.sh` installs CrowdSec on an AlmaLinux EasyEngine v4 host using Docker Compose and iptables-nft. It creates `/opt/crowdsec` and runs a local firewall bouncer on `INPUT` and `DOCKER-USER`; the latter is essential for traffic forwarded into Docker site containers.

The script never overwrites existing configuration, CrowdSec data, or bouncer keys. Re-running it is safe: it keeps existing files and only creates missing ones. It also accepts CRLF downloads by re-executing a sanitized temporary copy.

Dựa trên nội dung mã nguồn của tệp [install-crowdsec-easyengine.sh](https://github.com/dinhngocdung/easyengine-docker-stack/blob/main/crowdsec/install-crowdsec-easyengine.sh) bạn đang xem và chia sẻ, cấu trúc hệ thống CrowdSec Docker Stack được định nghĩa chính xác với các thành phần kỹ thuật sau:


## Kiến trúc 3 Container (`docker-compose.yml`)

* **`crowdsec` (Security Engine)**
  **Image:** `crowdsecurity/crowdsec:latest`
  **Tác dụng:** Đóng vai trò là trung tâm phân tích nhật ký (Central Security Engine). Kích hoạt sẵn các collections: `crowdsecurity/nginx`, `crowdsecurity/sshd`, `crowdsecurity/linux`, và `crowdsecurity/wordpress`. Đồng thời ánh xạ các thư mục cấu hình, dữ liệu và mount trực tiếp luồng log hệ thống (`/var/log/secure`) cùng thư mục log Nginx Proxy (`${NGINX_LOG_DIR}`).
  
  
* **`firewall-bouncer` (Network Bouncer)**
  **Image:** `ghcr.io/shgew/cs-firewall-bouncer-docker:stable`
  **Tác dụng:** Chạy ở chế độ `network_mode: host` với các quyền kiểm soát mạng cấp kernel (`NET_ADMIN`, `NET_RAW`). Có nhiệm vụ đồng bộ các quyết định từ LAPI của CrowdSec để tự động thiết lập luật chặn trực tiếp trên tường lửa hệ thống (iptables/nftables) ngay khi phát hiện IP độc hại.


* **`cloudflare-worker-bouncer` (Edge Bouncer)**
  **Image:** `crowdsecurity/cloudflare-worker-bouncer:latest`
  **Tác dụng:** Được quản lý theo profile riêng (`cloudflare`). Đảm nhận việc chặn lọc hoặc thách thức các request độc hại ngay từ biên mạng của Cloudflare dựa trên cấu hình tích hợp, ngăn chặn từ xa trước khi request chạm tới máy chủ gốc.


## Cấu hình Theo dõi và Phân tích Nhật ký (Log Parsers / Collections)

Hệ thống cấu hình sẵn các cơ chế bóc tách luồng log thông qua các thành phần (Collections):

* **`crowdsecurity/nginx` & `crowdsecurity/wordpress` (Nginx & WordPress Logs):**
  *Tác dụng:* Phân tích nhật ký truy cập và lỗi từ hệ thống Nginx Proxy/EasyEngine để phát hiện các hành vi quét mã độc, dò mật khẩu ứng dụng WordPress, tấn công chèn mã (SQLi, XSS) hoặc brute-force trang đăng nhập.


* **`crowdsecurity/sshd` & `crowdsecurity/linux` (System & SSH Logs):**
  *Tác dụng:* Giám sát nhật ký bảo mật hệ thống (`/var/log/secure`) để phát hiện kịp thời các cuộc tấn công dò mật khẩu SSH, truy cập trái phép hoặc các dấu hiệu bất thường ở tầng hệ điều hành.

  
## Before running

- Run on the target EasyEngine host as root (via `sudo`). Docker and Docker Compose must already work.
- The host must report `nf_tables` in `iptables --version`. The installer deliberately stops on another backend.
- The nginx-proxy log directory must exist. The usual EasyEngine location is `/opt/easyengine/services/nginx-proxy/logs`; supply `--nginx-log-dir` if yours differs.
- For the optional Cloudflare Worker bouncer, create a scoped API token with rights to edit the required Worker, KV, route, and zone firewall resources. Enable **Workers Analytics Engine** before deployment or Cloudflare can return error `10089`.

## Install

Download the single script and run a non-writing preview first:

```bash
curl -fsSLO https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/main/crowdsec/install-crowdsec-easyengine.sh
sudo bash install-crowdsec-easyengine.sh --dry-run
```

Install CrowdSec and the host firewall bouncer. This is the default and does not install Cloudflare or request confirmation:

```bash
sudo bash install-crowdsec-easyengine.sh --apply
```

To also configure Cloudflare, add `--cf`. If token or domain is omitted, the script asks only for that missing value:

```bash
sudo bash install-crowdsec-easyengine.sh --apply --cf
```

To configure Cloudflare without prompts and retain only the named zones:

```bash
sudo bash install-crowdsec-easyengine.sh --apply --cf \
  --token='NEW_CLOUDFLARE_TOKEN' --domain='example.com,example.net'
```

Use `--domain=all` to retain every zone discovered by the Cloudflare token:

```bash
sudo bash install-crowdsec-easyengine.sh --apply --cf --token='NEW_CLOUDFLARE_TOKEN' --domain=all
```

If a Cloudflare config already exists, the installer keeps it. To deliberately regenerate it, filtering its zones and retaining its existing LAPI key where possible, add `--refresh-cloudflare`. The previous file is preserved with a timestamped `.bak.*` suffix.

For unattended use, pass secrets through protected environment variables rather than shell history. The Cloudflare token still needs to be protected by your CI/server environment.

```bash
sudo CLOUDFLARE_TOKEN='...' TRUSTED_CIDRS='203.0.113.8/32,2001:db8::/48' \
  bash install-crowdsec-easyengine.sh --apply --cf --domain='example.com'
```

## What it creates

```text
/opt/crowdsec/
├── docker-compose.yml
├── config/acquis.d/{nginx-proxy,sshd}.yaml
├── config/parsers/s02-enrich/whitelists.yaml
├── data/                              # CrowdSec state
└── data-bouncers/
    ├── firewall-bouncer.yaml
    └── cloudflare-worker-bouncer.yaml # only after Cloudflare setup
```

The Cloudflare service is in the Compose `cloudflare` profile, so an incomplete Cloudflare setup cannot crash the core CrowdSec/firewall installation. When a token is provided, the script generates the Worker configuration via the official image’s `-g` option, edits that single generated configuration (without adding a second `crowdsec_config`), retains only the requested zones, starts CrowdSec first, registers both bouncers, writes their LAPI keys, and then starts the corresponding services.

It also creates a persistent `cscli` alias in `/etc/profile.d/crowdsec-cscli.sh`. Open a new login shell after installation, then use `cscli metrics` or `cscli alerts list` without typing the Docker command. An existing shortcut is left untouched.

When EasyEngine's `ee` command is available, the installer lists detected hosted domains for review. Check the generated Cloudflare bouncer configuration and remove zones that are not hosted on this server before continuing with a broad token. The exact generated YAML can vary by bouncer release, so the script does not use fragile text parsing that could corrupt its zone configuration.

## Verify safely

After installation:

```bash
cd /opt/crowdsec
docker compose ps
docker compose exec -T crowdsec cscli bouncers list
docker compose exec -T crowdsec cscli metrics
docker compose exec -T crowdsec cscli alerts list
```

To prove the firewall bouncer blocks Docker traffic, add a temporary decision for a test IP **from another network**—never the source address of your current SSH session—test, then delete it:

```bash
docker exec crowdsec cscli decisions add --ip <TEST_IP> --duration 2m -R test
# Visit the site from that test connection.
docker exec crowdsec cscli decisions delete --ip <TEST_IP>
```

For the Cloudflare Worker, confirm the `crowdsec-bouncer` script and routes in the Cloudflare dashboard. Worker protection only applies when the DNS record is Cloudflare-proxied; the local firewall bouncer remains independent of Cloudflare.

If Docker reports that the Cloudflare Worker cannot find a network ID, recreate only that failed optional container:

```bash
cd /opt/crowdsec
docker compose --profile cloudflare rm -sf cloudflare-worker-bouncer
docker compose --profile cloudflare up -d --no-deps --force-recreate cloudflare-worker-bouncer
```

## Recovery and updates

If a bouncer name already exists but its key is no longer available, the installer will not delete it or overwrite a working config. Deliberately remove that bouncer with `cscli bouncers delete <name>`, update the matching config key, and run the installer again. Do not delete `/opt/crowdsec/data` unless you intentionally want to discard CrowdSec state.
