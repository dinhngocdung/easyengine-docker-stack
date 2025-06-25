# Quick start
1. Create folder for borgmatic
    ```bash
    mkdir -p ./borgmatic/data/borgmatic.d/
    ```

2. Download docker-compose.yml and borgmatic config.yaml
    ```bash
    curl -o ./borgmatic/docker-compose.yml https://raw.githubusercontent.com/dinhngocdung/ee-container-stack/refs/heads/main/borgmatic/docker-compose.yml
    curl -o ./borgmatic/data/borgmatic.d/config.yaml https://raw.githubusercontent.com/dinhngocdung/ee-container-stack/refs/heads/main/borgmatic/data/borgmatic.d/config.yaml
    ```

3. Download and edit file .env
    ```bash
    curl -o ./borgmatic/.env https://raw.githubusercontent.com/dinhngocdung/ee-container-stack/refs/heads/main/borgmatic/.env
    vi ./borgmatic/.env
    ```

4. Run borgmatic container (one time)
    ```bash
    cd ./borgmatic && \
    sudo docker compose run --rm --entrypoint bash borgmatic
    ```
