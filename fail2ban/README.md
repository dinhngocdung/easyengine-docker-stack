# Quick Start 
## 1. Download docker-compose.yml, fail2ban.env, jail and filter:
```bash
mkdir -p ./fail2ban/data/{jail.d,filter.d,action.d} && cd fail2ban

curl -o ./docker-compose.yml -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/docker-compose.yml
curl -o ./fail2ban.env -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/fail2ban.env

curl -o ./data/filter.d/sshd.local -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/filter.d/sshd.local
curl -o ./data/filter.d/nginx-req-limit.conf -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/filter.d/nginx-req-limit.conf
curl -o ./data/filter.d/wp-login-fail.conf -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/filter.d/wp-login-fail.conf

curl -o ./data/jail.d/jail.local -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/jail.d/jail.local
```
## 2. Add your sites logs
```bash
vi ./docker-compose.yml
```
## 3. Run
```bash
sudo docker compose up -d
```

## 4 More
Use Cloudflare WAF
```bash
curl -o ./data/jail.d/jail-cloudflare.local -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/jail.d/jail-cloudflare.local

# And change your cfzone and cftoken
```
