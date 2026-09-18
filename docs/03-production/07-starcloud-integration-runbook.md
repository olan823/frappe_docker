---
title: Starcloud Integration Production Runbook
---

# Scope

This runbook records the production procedure verified on `sky2` for adding
`starcloud_integration` to the existing ERPNext image without stopping unrelated
Docker containers.

The verified release values are:

```text
ERPNext:              16.32.0
Base image:           skychip/erpnext:16.32.0-starcompany-0.1.10
Starcloud app:        v0.1.0
Starcloud app commit: ae3a20400329cea836765702264b6739bd4dd695
Result image:         skychip/erpnext:16.32.0-starcloud-0.1.0
Compose project:      erpnext-prod
Site:                 erp.skychip.top
Production directory: /home/ubuntu/gitops/erpnext-prod
Production env file:  erpnext.env
Build directory:      /home/ubuntu/build/frappe_docker
```

Do not run `docker compose down`. Do not run production application tests that
create or drop tables.

# Publish Build Tooling

The build host must have these files from the `olan823/frappe_docker` `main`
branch:

```text
images/layered/Containerfile.starcloud
scripts/build-starcloud-image.sh
scripts/deploy-starcloud-image.sh
```

Update the build checkout:

```bash
cd /home/ubuntu/build/frappe_docker
git fetch origin main
git pull --ff-only origin main
```

If untracked copies of either script prevent the pull, preserve them and retry:

```bash
backup_dir="$HOME/build/starcloud-script-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
mv scripts/build-starcloud-image.sh "$backup_dir/"
mv scripts/deploy-starcloud-image.sh "$backup_dir/"
git pull --ff-only origin main
```

Validate the files:

```bash
test -f scripts/build-starcloud-image.sh &&
test -f scripts/deploy-starcloud-image.sh &&
test -f images/layered/Containerfile.starcloud &&
echo "Starcloud build files OK"

bash -n scripts/build-starcloud-image.sh
bash -n scripts/deploy-starcloud-image.sh
```

# Build The Image

Build the Starcloud layer on top of the existing Starcompany image:

```bash
cd /home/ubuntu/build/frappe_docker

APP_VERSION='0.1.0'
APP_COMMIT='ae3a20400329cea836765702264b6739bd4dd695'
APP_REF="v${APP_VERSION}"
BASE_IMAGE='skychip/erpnext:16.32.0-starcompany-0.1.10'
IMAGE_TAG="16.32.0-starcloud-${APP_VERSION}"

sudo env \
  APP_REPO='https://github.com/olan823/starcloud_integration.git' \
  APP_REF="$APP_REF" \
  APP_COMMIT="$APP_COMMIT" \
  BASE_IMAGE="$BASE_IMAGE" \
  IMAGE_TAG="$IMAGE_TAG" \
  GITHUB_PROXY_PREFIX='https://githubproxy.cc/' \
  bash ./scripts/build-starcloud-image.sh
```

This build does not replace or restart running containers. Verify the result:

```bash
sudo docker image inspect \
  skychip/erpnext:16.32.0-starcloud-0.1.0 \
  --format 'ID={{.Id}} Created={{.Created}} Size={{.Size}}'

sudo docker run --rm \
  --entrypoint bash \
  skychip/erpnext:16.32.0-starcloud-0.1.0 \
  -lc '
    test -d /home/frappe/frappe-bench/apps/starcompany_integration &&
    test -d /home/frappe/frappe-bench/apps/starcloud_integration &&
    cat /home/frappe/frappe-bench/.starcloud-build
  '
```

The build marker must be:

```text
v0.1.0 ae3a20400329cea836765702264b6739bd4dd695
```

# Registry Failure Handling

If `registry-1.docker.io:443` times out after the image is built, do not rebuild
the image. The same host can deploy the local image directly. Keep
`PULL_POLICY=never` in the production environment file.

Do not restart the Docker daemon merely to fix registry connectivity because
that can affect production containers. Push the image later when connectivity
returns:

```bash
sudo docker push skychip/erpnext:16.32.0-starcloud-0.1.0
```

# Identify Production Compose Files

Do not assume the build checkout is the production Compose directory. Inspect a
running container first:

```bash
container_id="$(
  sudo docker ps -q \
    --filter label=com.docker.compose.project=erpnext-prod |
  head -n 1
)"

sudo docker inspect "$container_id" \
  --format 'WorkingDir={{index .Config.Labels "com.docker.compose.project.working_dir"}}
ConfigFiles={{index .Config.Labels "com.docker.compose.project.config_files"}}
Project={{index .Config.Labels "com.docker.compose.project"}}'
```

The verified production paths are:

```text
WorkingDir=/home/ubuntu/gitops/erpnext-prod
ConfigFiles=/home/ubuntu/gitops/erpnext-prod/compose.yaml,/home/ubuntu/gitops/erpnext-prod/compose.starcompany.yaml
```

# Select The New Image

Back up the production environment file before changing it:

```bash
cd /home/ubuntu/gitops/erpnext-prod
sudo cp erpnext.env "erpnext.env.backup-$(date +%Y%m%d-%H%M%S)"

sudo sed -i \
  -e 's|^CUSTOM_IMAGE=.*|CUSTOM_IMAGE=skychip/erpnext|' \
  -e 's|^CUSTOM_TAG=.*|CUSTOM_TAG=16.32.0-starcloud-0.1.0|' \
  -e 's|^PULL_POLICY=.*|PULL_POLICY=never|' \
  erpnext.env
```

Add any missing keys, then validate only non-secret image settings:

```bash
sudo grep -q '^CUSTOM_IMAGE=' erpnext.env ||
  echo 'CUSTOM_IMAGE=skychip/erpnext' | sudo tee -a erpnext.env >/dev/null

sudo grep -q '^CUSTOM_TAG=' erpnext.env ||
  echo 'CUSTOM_TAG=16.32.0-starcloud-0.1.0' | sudo tee -a erpnext.env >/dev/null

sudo grep -q '^PULL_POLICY=' erpnext.env ||
  echo 'PULL_POLICY=never' | sudo tee -a erpnext.env >/dev/null

sudo grep -E \
  '^(CUSTOM_IMAGE|CUSTOM_TAG|PULL_POLICY|ERPNEXT_VERSION)=' \
  erpnext.env
```

Validate the resolved Compose configuration before deployment:

```bash
sudo docker compose \
  -p erpnext-prod \
  --env-file erpnext.env \
  -f compose.yaml \
  -f compose.starcompany.yaml \
  config --quiet

sudo docker compose \
  -p erpnext-prod \
  --env-file erpnext.env \
  -f compose.yaml \
  -f compose.starcompany.yaml \
  config --images | sort -u
```

The resolved images must include:

```text
skychip/erpnext:16.32.0-starcloud-0.1.0
```

# Configure The Site

The Starcloud shared secret must be newly generated, must match Starcloud's
`ERPNEXT_PROXY_SHARED_SECRET`, and must not match the Starcompany proxy secret.
Never commit it or paste it into documentation or chat.

Configure the non-secret values:

```bash
cd /home/ubuntu/gitops/erpnext-prod

compose=(sudo docker compose -p erpnext-prod --env-file erpnext.env \
  -f compose.yaml -f compose.starcompany.yaml)

"${compose[@]}" exec -T backend \
  bench --site erp.skychip.top set-config \
  starcloud_api_base_url 'https://cloud.skychip.top'

"${compose[@]}" exec -T backend \
  bench --site erp.skychip.top set-config \
  starcloud_api_timeout_seconds 10

"${compose[@]}" exec -T backend \
  bench --site erp.skychip.top set-config \
  starcloud_health_path '/api/erpnext/health'
```

Read the secret without echoing it or storing it in shell history:

```bash
read -rsp 'New Starcloud proxy secret: ' STAR_SECRET
echo

"${compose[@]}" exec -T backend \
  bench --site erp.skychip.top set-config \
  starcloud_proxy_shared_secret "$STAR_SECRET"

unset STAR_SECRET
```

Before deployment, Starcloud must already use the same rotated secret and its
Laravel migration, route cache rebuild, and Octane reload must be complete.

# Targeted Deployment

Run the deployment script through `bash`, matching the established Starcompany
deployment pattern:

```bash
cd /home/ubuntu/gitops/erpnext-prod

APP_VERSION='0.1.0'
IMAGE_TAG="16.32.0-starcloud-${APP_VERSION}"

sudo env \
  ENV_FILE=erpnext.env \
  COMPOSE_FILES='compose.yaml compose.starcompany.yaml' \
  IMAGE_NAME=skychip/erpnext \
  IMAGE_TAG="$IMAGE_TAG" \
  SITE=erp.skychip.top \
  PROJECT=erpnext-prod \
  bash /home/ubuntu/build/frappe_docker/scripts/deploy-starcloud-image.sh
```

The script only recreates these ERPNext application services:

```text
configurator backend frontend websocket queue-short queue-long scheduler
```

It does not recreate `db`, `redis-cache`, or `redis-queue`. It installs the app
when needed, runs `bench migrate`, clears cache, lists installed apps, and calls
the Starcloud health check.

The success marker is:

```text
Deployment completed without stopping unrelated Compose services.
```

# Post-Deployment Validation

```bash
cd /home/ubuntu/gitops/erpnext-prod

sudo docker compose \
  -p erpnext-prod \
  --env-file erpnext.env \
  -f compose.yaml \
  -f compose.starcompany.yaml \
  ps

sudo docker compose \
  -p erpnext-prod \
  --env-file erpnext.env \
  -f compose.yaml \
  -f compose.starcompany.yaml \
  exec -T backend \
  bench --site erp.skychip.top list-apps
```

All ERPNext application services must use the new Starcloud image. Database and
Redis container creation times must remain unchanged. Installed apps must include:

```text
starcompany_integration
starcloud_integration
```

The verified health response contains:

```json
{"data":{"errorCode":0,"description":"success","data":{"service":"starcloud","status":"ok"}}}
```

Open `https://erp.skychip.top/app/starcloud-applications` with a `System Manager`
account. Assign `Starcloud User` for read-only access or `Starcloud Admin` for
review access, then validate list, detail, approve, reject, idempotency, and the
Starcloud operation audit record.

# Operational Notes

- Do not run `docker compose down`.
- Do not use `sudo chmod 666 /var/run/docker.sock`.
- Do not run `ErpnextApplicationControllerTest` against production.
- Do not delete the local image while it is unavailable from a registry.
- Keep the timestamped `erpnext.env` backup until production validation is complete.
- A failed registry push after a successful build does not invalidate the local image.
- If deployment fails, preserve container logs and do not delete containers or volumes.