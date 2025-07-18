# Borgmatic for Easyengine-docker quick start 
1. Download docker-compose.yml, .env and borgmatic config.yaml

    ```bash
    mkdir -p ./borgmatic/data/{borgmatic.d,repository,.config,.ssh,.cache}

    curl -o ./borgmatic/docker-compose.yml https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/borgmatic/docker-compose.yml
    curl -o ./borgmatic/data/borgmatic.d/config.yaml https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/borgmatic/data/borgmatic.d/config.yaml
    curl -o ./borgmatic/.env https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/refs/heads/main/borgmatic/.env
    ```

2.  Change your info in .env 
    ```bash
    vi ./borgmatic/.env
    ```

3. Run borgmatic container (one time)
    ```bash
    cd ./borgmatic && \
    sudo docker compose run --rm --entrypoint bash borgmatic
    ```
