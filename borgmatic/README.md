# Borgmatic for Easyengine-docker quick start 
1. Download docker-compose.yml, .env and borgmatic config.yaml

    ```bash
    sudo mkdir -p /opt/borgmatic/data/{borgmatic.d,repository,.config,.ssh,.cache}

    sudo curl -o /opt/borgmatic/docker-compose.yml https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/borgmatic/docker-compose.yml
    sudo curl -o /opt/borgmatic/data/borgmatic.d/config.yaml https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/borgmatic/data/borgmatic.d/config.yaml
    sudo curl -o /opt/borgmatic/.env https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/borgmatic/.env
    ```

2.  Change your info in .env 
    ```bash
    sudo vi /opt/borgmatic/.env
    ```

3. Run borgmatic container (one time)
    ```bash
    sudo docker compose -f /opt/borgmatic/docker-compose.yml run --rm --entrypoint bash borgmatic
    ```
