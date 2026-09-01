# CrowdSec cho EasyEngine — template + script triển khai

Thay thế fail2ban. `install.sh` chỉ lo triển khai — mọi nội dung cấu hình
thật nằm trong `templates/`, sửa ở đó để đổi hành vi, không sửa script.

## Cấu trúc

```
crowdsec/
├── install.sh                              ← chỉ đọc input + triển khai, không sinh YAML
├── README.md
└── templates/
    ├── docker-compose.yml                                    ← tĩnh, Compose tự thay ${VAR} từ .env
    ├── config/
    │   ├── acquis.d/{nginx-proxy.yaml, host-auth.yaml}       ← tĩnh
    │   └── parsers/s02-enrich/whitelists.yaml                ← SỬA TRỰC TIẾP khi cần thêm IP tin cậy
    └── data-bouncers/
        ├── crowdsec-firewall-bouncer.yaml                     ← tĩnh, image tự envsubst lúc chạy
        ├── crowdsec-cloudflare-worker-bouncer-header.yaml.tmpl ← script render (chứa placeholder)
        ├── crowdsec-cloudflare-worker-bouncer-zones.yaml       ← SỬA TRỰC TIẾP khi thêm/bớt site
        └── crowdsec-cloudflare-worker-bouncer-footer.yaml.tmpl ← script render (chứa placeholder)
```

Tên file trong `data-bouncers/` đặt trùng tên bouncer thật (`crowdsec-firewall-bouncer`,
`crowdsec-cloudflare-worker-bouncer`) — mở thư mục là biết ngay file nào ứng
với container/bouncer nào, không cần đối chiếu `docker-compose.yml`.

## Nguyên tắc: sửa gì ở đâu

| Muốn đổi | Sửa file | Cần chạy lại `install.sh`? |
|---|---|---|
| Thêm site mới (Cloudflare) | `templates/data-bouncers/crowdsec-cloudflare-worker-bouncer-zones.yaml` | Có |
| Thêm IP/CIDR tin cậy | `templates/config/parsers/s02-enrich/whitelists.yaml` | Không — chỉ cần `docker compose restart crowdsec` |
| Đổi collection CrowdSec | Chạy `install.sh`, nhập lại khi được hỏi | Có |
| Đổi image `crowdsec-firewall-bouncer` | Chạy `install.sh`, nhập lại khi được hỏi | Có |
| Đổi cấu trúc file compose | `templates/docker-compose.yml` | Có |

`install.sh` không có logic sinh nội dung YAML nào (trừ 1 bước `envsubst`
bắt buộc cho `crowdsec-cloudflare-worker-bouncer`, vì binary đó không tự đọc
biến môi trường được).

## Tên container / service / bouncer — quy ước dùng xuyên suốt

| Vai trò | Container | Service (compose) | Tên đăng ký `cscli` |
|---|---|---|---|
| Agent | `crowdsec` | `crowdsec` | — |
| Firewall (host) | `crowdsec-firewall-bouncer` | `crowdsec-firewall-bouncer` | `firewall-bouncer` |
| Cloudflare Worker | `crowdsec-cloudflare-worker-bouncer` | `crowdsec-cloudflare-worker-bouncer` | `cloudflare-worker-bouncer` |

## Cài đặt

```bash
curl -fsSL -o crowdsec.tar.gz \
  https://github.com/dinhngocdung/easyengine-docker-stack/releases/latest/download/crowdsec.tar.gz
mkdir crowdsec && tar xzf crowdsec.tar.gz -C crowdsec
cd crowdsec && sudo ./install.sh
```

Script sẽ hỏi lần lượt:
- Đường dẫn log SSH / nginx-proxy (tự dò trước, bạn chỉ cần Enter nếu đúng)
- Danh sách collection CrowdSec, timezone, image cho `crowdsec-firewall-bouncer`
- Có dùng Cloudflare Worker bouncer (captcha/block tại edge) không — **tuỳ
  chọn**, bỏ qua nếu VPS không dùng Cloudflare
- Nếu có: Account ID / API Token / Account email

Cuối cùng tự động: copy template vào `/opt/crowdsec`, pull image
`crowdsec-firewall-bouncer`, đăng ký bouncer, khởi động toàn bộ stack, tạo
wrapper `/usr/local/bin/cscli`.

## Chạy lại (update cấu hình / thêm site mới)

```bash
sudo /opt/crowdsec-release/install.sh    # hoặc tải bản mới nhất rồi chạy lại như trên
```
Idempotent — giá trị cũ (`.env`) được nạp lại làm mặc định, key bouncer
không bị sinh lại nếu đã có, bouncer không bị đăng ký trùng.

## Thêm site mới — không cần hỏi script gì cả

```bash
vi templates/data-bouncers/crowdsec-cloudflare-worker-bouncer-zones.yaml
# copy khối ví dụ, đổi zone_id + domain
sudo ./install.sh   # Enter qua hết câu hỏi để giữ nguyên giá trị cũ
```

## Chế độ non-interactive (Ansible/CI)

```bash
CROWDSEC_NONINTERACTIVE=1 sudo -E ./install.sh
```
Bắt buộc export sẵn toàn bộ biến cần thiết trước — script sẽ fail rõ ràng
nếu thiếu, không tự hỏi. Xem role Ansible tham khảo tại repo hạ tầng riêng
(`roles/12_crowdsec/`).

## Secret — không bao giờ nằm trong `templates/`

Toàn bộ giá trị nhạy cảm chỉ sống trong `/opt/crowdsec/.env` (chmod 600,
sinh ra khi chạy `install.sh`, KHÔNG commit lên git). File `templates/*.tmpl`
chỉ chứa cú pháp `${VAR}`, không bao giờ chứa giá trị thật — an toàn để repo
public.

Thêm `.gitignore` ở gốc repo (nếu chưa có):
```
crowdsec/.env
*.env
```

## Cloudflare Worker bouncer — bắt buộc bật Analytics Engine trước

Thủ công 1 lần trên Dashboard trước khi chạy `install.sh` với Cloudflare
bật — script sẽ hỏi xác nhận nhưng không tự kiểm tra được. Thiếu bước này,
`crowdsec-cloudflare-worker-bouncer` crash-loop lỗi `10089`.

## Update

```bash
cd /opt/crowdsec
docker exec -t crowdsec cscli hub update && docker exec -t crowdsec cscli hub upgrade
docker compose pull && docker compose up -d
```
`crowdsec-firewall-bouncer` dùng image dựng sẵn
(`ghcr.io/shgew/cs-firewall-bouncer-docker`, tự động rebuild theo mỗi bản
CrowdSec mới) — `docker compose pull` là đủ, không cần build.

## Kiểm chứng sau khi cài

```bash
cscli bouncers list      # firewall-bouncer (+ cloudflare-worker-bouncer nếu bật) phải "Valid ✔️"
cscli decisions add --ip <IP_của_bạn> --duration 2m -R test
curl -I https://<domain>  # từ mạng khác — phải bị chặn/timeout
cscli decisions delete --ip <IP_của_bạn>
```
(`cscli` ở đây là wrapper `/usr/local/bin/cscli` install.sh đã tạo sẵn —
gọi thẳng không cần `docker exec`.)
