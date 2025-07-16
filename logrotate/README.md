```bash
# Logrotate nginx-proxy logs
curl -o /etc/logrotate.d/ee-nginx-proxy-log -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/logrotate/logrotate.d/ee-nginx-proxy-log

# Logrotate all site's logs
curl -o /etc/logrotate.d/ee-sites-log -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/logrotate/logrotate.d/ee-sites-log
```
