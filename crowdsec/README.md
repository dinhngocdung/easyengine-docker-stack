# CrowdSec Docker for EasyEngine

Thay thế Fail2ban trên **EasyEngine v4 + Docker** bằng CrowdSec với hai lớp remediation:

- **Firewall bouncer**: chặn tại host bằng `iptables` + `DOCKER-USER`.
- **Cloudflare Worker bouncer**: block/captcha tại Cloudflare edge cho các zone chạy proxy.

CrowdSec chạy hoàn toàn trong Docker.

## Quick install

Trên server EasyEngine:

```bash
curl -fsSL https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/main/crowdsec/install.sh -o /tmp/install-crowdsec.sh
sudo bash /tmp/install-crowdsec.sh
```

> Sau khi tạo repository thật, thay `dinhngocdung` bằng GitHub username/org của bạn.

Hoặc:

```bash
wget -qO /tmp/install-crowdsec.sh https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/main/crowdsec/install.sh
sudo bash /tmp/install-crowdsec.sh
```

Installer sẽ:

1. kiểm tra Docker/Compose/iptables;
2. tự phát hiện log `nginx-proxy` của EasyEngine;
3. tạo `/opt/crowdsec`;
4. tạo CrowdSec + firewall bouncer;
5. đăng ký firewall bouncer với LAPI;
6. tùy chọn cấu hình Cloudflare Worker bouncer;
7. build/start stack;
8. chạy health checks;
9. in các lệnh quản trị tiếp theo.

## Kiến trúc

```text
Internet
   |
   +--> Cloudflare Worker bouncer (nếu proxy ON)
   |        block / captcha
   |
   v
EasyEngine global nginx proxy
   |
   v
DOCKER-USER / INPUT
   |
   +--> CrowdSec firewall bouncer
   |
   v
WordPress site containers

CrowdSec agent
   +--> nginx-proxy access/error logs
   +--> /var/log/secure
   +--> scenarios / collections
   |
   +--> LAPI
          +--> firewall bouncer
          +--> Cloudflare Worker bouncer
```

## Yêu cầu

- EasyEngine v4 đã cài Docker + Docker Compose v2.
- Host dùng iptables-nft (`iptables --version` có `nf_tables`).
- `DOCKER-USER` tồn tại nếu muốn chặn traffic vào container.
- Cloudflare Worker bouncer là **tùy chọn**.
- Nếu dùng Cloudflare Worker bouncer, Cloudflare account cần quyền API phù hợp. Với phiên bản bouncer hiện tại, Analytics Engine được dùng cho metrics; token nên có `Account Analytics: Read`. Analytics Engine phải khả dụng nếu muốn metrics đầy đủ.

## Files

```text
.
├── install.sh
├── README.md
├── LICENSE
├── .gitignore
├── docker-compose.yml.template
├── config
│   ├── acquis.d
│   │   ├── nginx-proxy.yaml
│   │   └── sshd.yaml
│   └── parsers
│       └── s02-enrich
│           └── whitelists.yaml
└── fw-bouncer
    └── Dockerfile
```

Runtime data/config được tạo ở:

```text
/opt/crowdsec/
├── docker-compose.yml
├── config/
├── data/
├── data-bouncers/
└── fw-bouncer/
```

## Cloudflare Worker

Installer hỏi:

```text
Configure Cloudflare Worker bouncer? [y/N]
```

Nếu chọn `y`, nhập Cloudflare API token.

Installer dùng chính binary của Cloudflare Worker bouncer để sinh config:

```bash
docker run --rm crowdsecurity/cloudflare-worker-bouncer:latest \
  -g "$CLOUDFLARE_API_TOKEN"
```

Sau đó installer giữ lại config cho các zone mà token nhìn thấy. **Kiểm tra lại zone trước khi bật production**.

Cloudflare Worker chỉ có tác dụng khi DNS record đang proxied qua Cloudflare.

Cloudflare Worker bouncer hiện được CrowdSec duy trì. Bouncer sử dụng Worker/KV và có thể dùng Analytics Engine cho metrics; CrowdSec khuyến nghị chú ý quota/plan khi triển khai, đặc biệt nếu bảo vệ nhiều zone.

## Bảo mật secrets

Không commit:

```text
data-bouncers/*.yaml
.env
```

API keys được ghi vào `/opt/crowdsec/data-bouncers/` và file được chmod `600`.

Nếu repository public, tuyệt đối không đưa token Cloudflare hoặc CrowdSec bouncer key vào Git.

## Sau khi cài

Alias được tạo trong root shell:

```bash
alias cscli='docker exec -t crowdsec cscli'
```

Có thể dùng:

```bash
cscli metrics
cscli alerts list
cscli decisions list
cscli bouncers list
cscli lapi status
cscli version
```

### Ban thủ công

```bash
cscli decisions add --ip 1.2.3.4 --duration 24h -R "manual-ban"
```

### Bỏ ban

```bash
cscli decisions delete --ip 1.2.3.4
```

### Test firewall bouncer

Từ một mạng khác với server:

```bash
cscli decisions add --ip YOUR_PUBLIC_IP --duration 2m -R "test"
curl -I https://your-domain.com
cscli decisions delete --ip YOUR_PUBLIC_IP
```

Không test từ chính server vì traffic local không đi theo cùng path.

### Kiểm tra containers

```bash
cd /opt/crowdsec
docker compose ps
docker logs crowdsec --tail 100
docker logs crowdsec-fw-bouncer --tail 100
docker logs crowdsec-cf-worker-bouncer --tail 100
```

## Khi thêm site EasyEngine

### Firewall

Thông thường **không cần đổi gì**.

EasyEngine dùng global nginx proxy, vì vậy site mới tiếp tục ghi log vào cùng log source mà CrowdSec đang đọc. Firewall bouncer chặn theo source IP nên tự bảo vệ site mới.

Nếu site mới có IP/CIDR tin cậy riêng, thêm vào:

```text
/opt/crowdsec/config/parsers/s02-enrich/whitelists.yaml
```

Sau đó:

```bash
cd /opt/crowdsec
docker compose restart crowdsec
```

### Cloudflare

Nếu site mới nằm sau Cloudflare, cần thêm zone vào:

```text
/opt/crowdsec/data-bouncers/cf-worker-bouncer.yaml
```

Sau đó:

```bash
cd /opt/crowdsec
docker compose restart cloudflare-worker-bouncer
```

Kiểm tra:

```bash
docker logs crowdsec-cf-worker-bouncer --tail 100
```

## Fail2ban migration

Không nên gỡ Fail2ban ngay.

Khuyến nghị:

```bash
systemctl stop fail2ban
systemctl disable fail2ban
```

Giữ `/opt/fail2ban` một thời gian để đối chiếu log/config cũ.

## Backup

```bash
tar czf /opt/crowdsec-backup-$(date +%F).tar.gz \
  -C /opt/crowdsec \
  config data data-bouncers docker-compose.yml fw-bouncer
```

## Restore

```bash
cd /opt/crowdsec
docker compose down
# restore config/data/data-bouncers từ backup
docker compose up -d
```

## Troubleshooting

### `exec format error`

Script bị CRLF:

```bash
sed -i 's/\r$//' install.sh
```

### Bouncer đã tồn tại

```bash
cscli bouncers list
cscli bouncers delete NAME
```

### Firewall bouncer không chặn container

Kiểm tra:

```bash
iptables --version
iptables -S DOCKER-USER
cscli bouncers list
docker logs crowdsec-fw-bouncer --tail 100
```

`DOCKER-USER` phải có trong `iptables_chains`.

### Cloudflare Worker lỗi Analytics Engine

Kiểm tra Analytics Engine trong Cloudflare account và xem:

```bash
docker logs crowdsec-cf-worker-bouncer --tail 200
```

### SSH parser không phát hiện đủ

Theo dõi:

```bash
cscli metrics
cscli alerts list
```

Nếu pattern SSH thực tế không được collection mặc định bắt, tạo parser/scenario riêng sau khi có log thực tế. Không nên thêm parser tùy chỉnh chỉ dựa trên giả định.

## License

MIT
