#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  IMAGE_TAG=<versioned-tag> ./scripts/deploy-starcompany-image.sh

Optional environment variables:
  IMAGE_NAME     Default: skychip/erpnext
  SITE           Default: erp.skychip.top
  PROJECT        Must remain erpnext-prod
  ENV_FILE       Default: .env
  COMPOSE_FILES  Default: compose.yaml compose.starcompany.yaml
EOF
}

IMAGE_NAME="${IMAGE_NAME:-skychip/erpnext}"
IMAGE_TAG="${IMAGE_TAG:-}"
SITE="${SITE:-erp.skychip.top}"
PROJECT="${PROJECT:-erpnext-prod}"
ENV_FILE="${ENV_FILE:-.env}"
COMPOSE_FILES="${COMPOSE_FILES:-compose.yaml compose.starcompany.yaml}"

if [[ "$PROJECT" != "erpnext-prod" ]]; then
  echo "Refusing to deploy any Compose project other than erpnext-prod." >&2
  exit 2
fi

if [[ -z "$IMAGE_TAG" || "$IMAGE_TAG" == "latest" ]]; then
  echo "IMAGE_TAG must be a non-latest version tag." >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Environment file not found: $ENV_FILE" >&2
  exit 2
fi

compose_args=(-p "$PROJECT" --env-file "$ENV_FILE")
for compose_file in $COMPOSE_FILES; do
  if [[ ! -f "$compose_file" ]]; then
    echo "Compose file not found: $compose_file" >&2
    exit 2
  fi
  compose_args+=(-f "$compose_file")
done

image="${IMAGE_NAME}:${IMAGE_TAG}"
app_services=(configurator backend frontend websocket queue-short queue-long scheduler)

docker image inspect "$image" >/dev/null
docker run --rm --entrypoint bash "$image" -lc \
  'test -f /home/frappe/frappe-bench/apps/starcompany_integration/starcompany_integration/api/proxy.py &&
   grep -q "def update_authorization_pool_threshold" /home/frappe/frappe-bench/apps/starcompany_integration/starcompany_integration/api/proxy.py'

docker compose "${compose_args[@]}" config --quiet

resolved_images="$({
  docker compose "${compose_args[@]}" config --images
} | sort -u)"

if ! grep -Fxq "$image" <<<"$resolved_images"; then
  echo "The resolved Compose configuration does not use $image." >&2
  echo "Persist CUSTOM_IMAGE=$IMAGE_NAME and CUSTOM_TAG=$IMAGE_TAG in $ENV_FILE before deploying." >&2
  exit 1
fi

echo "Deploying $image to Compose project $PROJECT for site $SITE"
docker compose "${compose_args[@]}" up -d --no-deps --force-recreate "${app_services[@]}"

docker compose "${compose_args[@]}" exec -T backend bench --site "$SITE" migrate
docker compose "${compose_args[@]}" exec -T backend bench --site "$SITE" clear-cache
docker compose "${compose_args[@]}" exec -T backend bench --site "$SITE" list-apps
docker compose "${compose_args[@]}" exec -T backend bench --site "$SITE" execute \
  starcompany_integration.api.proxy.health_check

echo "Deployment completed with persistent image settings from $ENV_FILE."