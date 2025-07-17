# Logrotate for Easyengine-Docker
**My system:**
- Host OS: RHEL 10
- [Easyengine-Docker](https://easyengine.pages.dev/notes/easyengine-docker/)


**Download** config logrotate for Nginx-proxy logs and All site logs:
```bash
# Logrotate nginx-proxy logs
sudo curl -o /etc/logrotate.d/ee-nginx-proxy-log -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/logrotate/logrotate.d/ee-nginx-proxy-log

# Logrotate all site's logs
sudo curl -o /etc/logrotate.d/ee-sites-log -L https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/logrotate/logrotate.d/ee-sites-log
```

**Check** command : kiểm tra cấu hình (không thực sự tực hiện)
```bash
sudo logrotate -d /etc/logrotate.d/ee-nginx-proxy-log
sudo logrotate -d /etc/logrotate.d/ee-sites-log
```
