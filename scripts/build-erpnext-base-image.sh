#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build-erpnext-base-image.sh

Optional environment variables:
  BASE_IMAGE_NAME          Default: skychip/erpnext-base
  BASE_IMAGE_TAG           Default: 16.32.0
  ERPNEXT_REPO             Default: https://github.com/frappe/erpnext.git
  ERPNEXT_REF              Default: v16.32.0
  ERPNEXT_COMMIT           Default: 81a6f97566b83609c3917404a560b673050e907d
  FRAPPE_REPO              Default: https://github.com/frappe/frappe.git
  FRAPPE_REF               Default: v16.32.0
  FRAPPE_COMMIT            Default: 5cba016e86b54b57f34a3864282b92300ef20fb0
  FRAPPE_IMAGE_TAG         Default: version-16
  FRAPPE_IMAGE_PREFIX      Default: frappe
  GITHUB_PROXY_PREFIX      Default: empty (example: https://githubproxy.cc/)
  PLATFORM                 Default: linux/amd64
  PUSH                     Default: 0 (set to 1 to push after building)
EOF
}

BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-skychip/erpnext-base}"
BASE_IMAGE_TAG="${BASE_IMAGE_TAG:-16.32.0}"
ERPNEXT_REPO="${ERPNEXT_REPO:-https://github.com/frappe/erpnext.git}"
ERPNEXT_REF="${ERPNEXT_REF:-v16.32.0}"
ERPNEXT_COMMIT="${ERPNEXT_COMMIT:-81a6f97566b83609c3917404a560b673050e907d}"
FRAPPE_REPO="${FRAPPE_REPO:-https://github.com/frappe/frappe.git}"
FRAPPE_REF="${FRAPPE_REF:-v16.32.0}"
FRAPPE_COMMIT="${FRAPPE_COMMIT:-5cba016e86b54b57f34a3864282b92300ef20fb0}"
FRAPPE_IMAGE_TAG="${FRAPPE_IMAGE_TAG:-version-16}"
FRAPPE_IMAGE_PREFIX="${FRAPPE_IMAGE_PREFIX:-frappe}"
GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-}"
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH="${PUSH:-0}"

for commit in "$ERPNEXT_COMMIT" "$FRAPPE_COMMIT"; do
  if [[ ! "$commit" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "Core commits must be full 40-character SHAs." >&2
    usage >&2
    exit 2
  fi
done

if [[ -z "$BASE_IMAGE_TAG" || "$BASE_IMAGE_TAG" == "latest" ]]; then
  echo "BASE_IMAGE_TAG must be a non-latest version tag." >&2
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

resolve_ref() {
  local repo="$1"
  local ref="$2"
  local commit
  local fetch_repo="$repo"

  if [[ -n "$GITHUB_PROXY_PREFIX" && "$repo" == https://github.com/* ]]; then
    fetch_repo="${GITHUB_PROXY_PREFIX}${repo}"
  fi

  commit="$(git ls-remote "$fetch_repo" "refs/tags/$ref^{}" | awk 'NR == 1 {print $1}')"
  if [[ -z "$commit" ]]; then
    commit="$(git ls-remote "$fetch_repo" "refs/tags/$ref" | awk 'NR == 1 {print $1}')"
  fi
  printf '%s' "$commit"
}

if [[ "$(resolve_ref "$FRAPPE_REPO" "$FRAPPE_REF")" != "$FRAPPE_COMMIT" ]]; then
  echo "Frappe tag $FRAPPE_REF does not resolve to $FRAPPE_COMMIT." >&2
  exit 1
fi

if [[ "$(resolve_ref "$ERPNEXT_REPO" "$ERPNEXT_REF")" != "$ERPNEXT_COMMIT" ]]; then
  echo "ERPNext tag $ERPNEXT_REF does not resolve to $ERPNEXT_COMMIT." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_json="$(mktemp)"
trap 'rm -f "$apps_json"' EXIT

cat >"$apps_json" <<EOF
[
  {
    "url": "$ERPNEXT_REPO",
    "branch": "$ERPNEXT_REF"
  }
]
EOF

image="${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG}"

echo "Building fixed ERPNext base $image"
docker buildx build \
  --progress=plain \
  --platform "$PLATFORM" \
  --build-arg "FRAPPE_IMAGE_TAG=$FRAPPE_IMAGE_TAG" \
  --build-arg "FRAPPE_REF=$FRAPPE_REF" \
  --build-arg "FRAPPE_PATH=$FRAPPE_REPO" \
  --build-arg "FRAPPE_EXPECTED_COMMIT=$FRAPPE_COMMIT" \
  --build-arg "ERPNEXT_REF=$ERPNEXT_REF" \
  --build-arg "ERPNEXT_EXPECTED_COMMIT=$ERPNEXT_COMMIT" \
  --build-arg "FRAPPE_IMAGE_PREFIX=$FRAPPE_IMAGE_PREFIX" \
  --build-arg "GITHUB_PROXY_PREFIX=$GITHUB_PROXY_PREFIX" \
  --secret "id=apps_json,src=$apps_json" \
  --file "$repo_root/images/layered/Containerfile" \
  --tag "$image" \
  --load \
  "$repo_root"

docker run --rm \
  --env "EXPECTED_FRAPPE_BUILD=frappe $FRAPPE_REF $FRAPPE_COMMIT" \
  --env "EXPECTED_ERPNEXT_BUILD=erpnext $ERPNEXT_REF $ERPNEXT_COMMIT" \
  --entrypoint bash \
  "$image" -lc \
  'test -d /home/frappe/frappe-bench/apps/frappe/frappe &&
   test -d /home/frappe/frappe-bench/apps/erpnext/erpnext &&
   grep -Fxq "$EXPECTED_FRAPPE_BUILD" /home/frappe/frappe-bench/.erpnext-base-build &&
   grep -Fxq "$EXPECTED_ERPNEXT_BUILD" /home/frappe/frappe-bench/.erpnext-base-build &&
   test ! -e /home/frappe/frappe-bench/apps/frappe/.git &&
   test ! -e /home/frappe/frappe-bench/apps/erpnext/.git'

if [[ "$PUSH" == "1" ]]; then
  docker push "$image"
fi

echo "Built and verified $image with fixed Frappe and ERPNext commits."