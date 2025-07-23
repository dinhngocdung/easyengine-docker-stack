# Fail2ban for easyengine-docker quick start 
## 1. Download docker-compose.yml, fail2ban.env, jail and filter:
```bash
sudo mkdir -p /opt/fail2ban/data/{jail.d,filter.d,action.d}

sudo curl -o /opt/fail2ban/docker-compose.yml -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/docker-compose.yml
sudo curl -o /opt/fail2ban/fail2ban.env -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/fail2ban.env

sudo curl -o /opt/fail2ban/data/filter.d/sshd.local -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/filter.d/sshd.local
sudo curl -o /opt/fail2ban/data/filter.d/nginx-req-limit.conf -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/filter.d/nginx-req-limit.conf
sudo curl -o /opt/fail2ban/data/filter.d/wp-login-fail.conf -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/filter.d/wp-login-fail.conf

sudo curl -o /opt/fail2ban/data/jail.d/jail.local -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/jail.d/jail.local
```
## 2. Add your sites logs
```bash
vi /opt/fail2ban/docker-compose.yml
```
## 3. Run
```bash
sudo docker compose up -d
```

## 4 More
Use Cloudflare WAF
```bash
sudo curl -o /opt/fail2ban/data/jail.d/jail-cloudflare.local -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/fail2ban/jail.d/jail-cloudflare.local

# And change your cfzone and cftoken
```
