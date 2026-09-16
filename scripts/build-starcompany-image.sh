#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  APP_REF=<release-tag> APP_COMMIT=<40-char-sha> IMAGE_TAG=<versioned-tag> ./scripts/build-starcompany-image.sh

Optional environment variables:
  APP_REPO             Default: https://github.com/olan823/starcompany_integration.git
  ERPNEXT_REPO         Default: https://github.com/frappe/erpnext.git
  ERPNEXT_BRANCH       Default: version-16
  FRAPPE_REPO          Default: https://github.com/frappe/frappe.git
  GITHUB_PROXY_PREFIX  Default: empty (example: https://githubproxy.cc/)
  IMAGE_NAME           Default: skychip/erpnext
  FRAPPE_BRANCH        Default: version-16
  FRAPPE_IMAGE_PREFIX  Default: frappe
  PLATFORM             Default: linux/amd64
  PUSH                 Default: 0 (set to 1 to push after building)
EOF
}

APP_REPO="${APP_REPO:-https://github.com/olan823/starcompany_integration.git}"
APP_REF="${APP_REF:-}"
APP_COMMIT="${APP_COMMIT:-}"
ERPNEXT_REPO="${ERPNEXT_REPO:-https://github.com/frappe/erpnext.git}"
ERPNEXT_BRANCH="${ERPNEXT_BRANCH:-version-16}"
FRAPPE_REPO="${FRAPPE_REPO:-https://github.com/frappe/frappe.git}"
GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-}"
IMAGE_NAME="${IMAGE_NAME:-skychip/erpnext}"
IMAGE_TAG="${IMAGE_TAG:-}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-16}"
FRAPPE_IMAGE_PREFIX="${FRAPPE_IMAGE_PREFIX:-frappe}"
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH="${PUSH:-0}"

if [[ ! "$APP_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "APP_REF must be an immutable semantic release tag such as v0.1.1." >&2
  usage >&2
  exit 2
fi

if [[ ! "$APP_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "APP_COMMIT must be the full 40-character commit SHA referenced by APP_REF." >&2
  usage >&2
  exit 2
fi

if [[ -z "$IMAGE_TAG" || "$IMAGE_TAG" == "latest" ]]; then
  echo "IMAGE_TAG must be a non-latest version tag." >&2
  usage >&2
  exit 2
fi

if [[ "$PUSH" != "0" && "$PUSH" != "1" ]]; then
  echo "PUSH must be 0 or 1." >&2
  exit 2
fi

for command_name in docker git; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "$command_name is required." >&2
    exit 1
  }
done

remote_commit="$(git ls-remote "$APP_REPO" "refs/tags/$APP_REF^{}" | awk 'NR == 1 {print $1}')"
if [[ -z "$remote_commit" ]]; then
  remote_commit="$(git ls-remote "$APP_REPO" "refs/tags/$APP_REF" | awk 'NR == 1 {print $1}')"
fi

if [[ "$remote_commit" != "$APP_COMMIT" ]]; then
  echo "Remote tag $APP_REF resolves to ${remote_commit:-nothing}, not $APP_COMMIT." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_json="$(mktemp)"
trap 'rm -f "$apps_json"' EXIT

cat >"$apps_json" <<EOF
[
  {
    "url": "$ERPNEXT_REPO",
    "branch": "$ERPNEXT_BRANCH"
  },
  {
    "url": "$APP_REPO",
    "branch": "$APP_REF"
  }
]
EOF

image="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Building $image with Frappe $FRAPPE_BRANCH, ERPNext $ERPNEXT_BRANCH, and starcompany_integration $APP_REF"
docker buildx build \
  --progress=plain \
  --platform "$PLATFORM" \
  --build-arg "FRAPPE_BRANCH=$FRAPPE_BRANCH" \
  --build-arg "FRAPPE_PATH=$FRAPPE_REPO" \
  --build-arg "FRAPPE_IMAGE_PREFIX=$FRAPPE_IMAGE_PREFIX" \
  --build-arg "GITHUB_PROXY_PREFIX=$GITHUB_PROXY_PREFIX" \
  --build-arg "CACHE_BUST=$APP_COMMIT" \
  --build-arg "STARCOMPANY_EXPECTED_COMMIT=$APP_COMMIT" \
  --secret "id=apps_json,src=$apps_json" \
  --file "$repo_root/images/layered/Containerfile" \
  --tag "$image" \
  --load \
  "$repo_root"

docker run --rm --entrypoint bash "$image" -lc \
  'test -d /home/frappe/frappe-bench/apps/erpnext/erpnext &&
   test -f /home/frappe/frappe-bench/apps/starcompany_integration/starcompany_integration/api/proxy.py &&
   test -f /home/frappe/frappe-bench/apps/starcompany_integration/starcompany_integration/starcompany/page/starcompany_console/starcompany_console.js &&
   grep -q "def update_authorization_pool_threshold" /home/frappe/frappe-bench/apps/starcompany_integration/starcompany_integration/api/proxy.py'

if [[ "$PUSH" == "1" ]]; then
  docker push "$image"
fi

echo "Built and verified $image from starcompany_integration $APP_REF at $APP_COMMIT"