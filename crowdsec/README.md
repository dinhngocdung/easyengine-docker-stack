# CrowdSec cho EasyEngine — template + script triển khai

Thay thế fail2ban. `install.sh` chỉ lo triển khai — mọi nội dung cấu hình
thật nằm trong `templates/`, sửa ở đó để đổi hành vi, không sửa script.

## Cấu trúc

```
crowdsec/
├── install.sh                              ← chỉ đọc input + triển khai, không sinh YAML
├── README.md
└── templates/
    ├── docker-compose.yml                  ← tĩnh, Compose tự thay ${VAR} từ .env
    ├── acquis-nginx-proxy.yaml             ← tĩnh
    ├── acquis-host-auth.yaml               ← tĩnh
    ├── whitelists.yaml                     ← SỬA TRỰC TIẾP khi cần thêm IP tin cậy
    ├── fw-bouncer.yaml                      ← tĩnh, image tự envsubst lúc chạy
    ├── cf-worker-bouncer-header.yaml.tmpl   ← script render (chứa placeholder)
    ├── cf-worker-bouncer-zones.yaml         ← SỬA TRỰC TIẾP khi thêm/bớt site
    └── cf-worker-bouncer-footer.yaml.tmpl   ← script render (chứa placeholder)
```

## Nguyên tắc: sửa gì ở đâu

| Muốn đổi | Sửa file | Cần chạy lại `install.sh`? |
|---|---|---|
| Thêm site mới (Cloudflare) | `templates/cf-worker-bouncer-zones.yaml` | Có |
| Thêm IP/CIDR tin cậy | `templates/whitelists.yaml` | Không — chỉ cần `docker compose restart crowdsec` |
| Đổi collection CrowdSec | Chạy `install.sh`, nhập lại khi được hỏi | Có |
| Đổi image `fw-bouncer` | Chạy `install.sh`, nhập lại khi được hỏi | Có |
| Đổi cấu trúc file compose | `templates/docker-compose.yml` | Có |

`install.sh` không có logic sinh nội dung YAML nào (trừ 1 bước `envsubst` bắt
buộc cho `cf-worker-bouncer`, vì binary đó không tự đọc biến môi trường được
— xem comment trong `cf-worker-bouncer-header.yaml.tmpl`).

## Cài đặt

```bash
git clone https://github.com/dinhngocdung/easyengine-docker-stack.git
cd easyengine-docker-stack/crowdsec
sudo ./install.sh
```

**Không tách `install.sh` ra khỏi `templates/`** — script tự dò
`templates/` nằm cạnh chính nó (`$(dirname "${BASH_SOURCE[0]}")`), không
hoạt động nếu chỉ tải mỗi `install.sh`.

## Thêm site mới — không cần hỏi script gì cả

```bash
cd easyengine-docker-stack/crowdsec
vi templates/cf-worker-bouncer-zones.yaml    # copy khối ví dụ, đổi zone_id + domain
sudo ./install.sh                             # Enter qua hết các câu hỏi để giữ nguyên giá trị cũ
```

## Secret — không bao giờ nằm trong `templates/`

Toàn bộ giá trị nhạy cảm (API token, key bouncer, đường dẫn log riêng từng
server) chỉ sống trong `/opt/crowdsec/.env` (chmod 600, sinh ra khi chạy
`install.sh`, KHÔNG commit lên git). File `templates/*.tmpl` chỉ chứa cú
pháp `${VAR}`, không bao giờ chứa giá trị thật — an toàn để repo public.

Thêm `.gitignore` ở gốc repo (nếu chưa có):
```
crowdsec/.env
*.env
```

## Cloudflare Worker bouncer — bắt buộc bật Analytics Engine trước

Thủ công 1 lần trên Dashboard trước khi chạy `install.sh` với Cloudflare
bật — script sẽ hỏi xác nhận nhưng không tự kiểm tra được. Thiếu bước này,
`cloudflare-worker-bouncer` crash-loop lỗi `10089`.

## Update

```bash
cd /opt/crowdsec
docker exec -t crowdsec cscli hub update && docker exec -t crowdsec cscli hub upgrade
docker compose pull && docker compose up -d
```
`fw-bouncer` giờ dùng image dựng sẵn (`ghcr.io/shgew/cs-firewall-bouncer-docker`,
tự động rebuild theo mỗi bản CrowdSec mới) — `docker compose pull` là đủ,
không cần `build` nữa.

## Kiểm chứng sau khi cài

```bash
docker exec -t crowdsec cscli bouncers list      # fw (+ cfworker nếu bật) phải "Valid ✔️"
docker exec -t crowdsec cscli decisions add --ip <IP_của_bạn> --duration 2m -R test
curl -I https://<domain>                          # từ mạng khác — phải bị chặn/timeout
docker exec -t crowdsec cscli decisions delete --ip <IP_của_bạn>
```
