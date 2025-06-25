# Quick Start 
## 1. Download docker-compose.yml, .env, fail and filter:

mkdir -p ./fail2ban/filter.d/
mkdir -p ./fail2ban/jail.d/

curl -o ./fail2ban/docker-compose.yml -L https://raw.githubusercontent.com/dinhngocdung/ee-container-stack/refs/heads/main/fail2ban/docker-compose.yml
curl -o ./fail2ban/.env -L https://raw.githubusercontent.com/dinhngocdung/ee-container-stack/refs/heads/main/fail2ban/.env

curl -o ./fail2ban/filter.d/nginx-req-limit.conf -L https://raw.githubusercontent.com/dinhngocdung/ee-container-stack/refs/heads/main/fail2ban/filter.d/nginx-req-limit.conf
curl -o ./fail2ban/filter.d/wp-login-fail.conf -L https://raw.githubusercontent.com/dinhngocdung/ee-container-stack/refs/heads/main/fail2ban/filter.d/wp-login-fail.conf

curl -o ./fail2ban/jail.d/jail.local -L https://raw.githubusercontent.com/dinhngocdung/ee-container-stack/refs/heads/main/fail2ban/jail.d/jail.local

## 2. Add your sites logs
vi ./fail2ban/docker-compose.yml

## 3. Run
cd ./fail2ban/ && \
sudo docker compose up -d

