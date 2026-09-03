# crowdsec templates

These files are templates for the CrowdSec installer. They mirror the layout expected at runtime under /opt/crowdsec. The installer script
crowdsec/install-crowdsec-easyengine-templates.sh will copy these files into the host's INSTALL_DIR and perform lightweight templating
via envsubst.

Placeholders supported (envsubst):
- ${TZ}
- ${NGINX_LOG_DIR}
- ${INSTALL_DIR}

If you want the installer to fetch templates remotely, it defaults to the branch crowdsec/templates-installer in this repo.
