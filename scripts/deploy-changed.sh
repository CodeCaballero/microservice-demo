#!/usr/bin/env bash
# Deploy only microservices whose source changed (content hash) or whose image
# is not yet in Artifact Registry / the Kubernetes cluster.
#
# Usage:
#   export PROJECT_ID=microservices-demo-python-12w2
#   ./scripts/deploy-changed.sh
#
# Options:
#   --dry-run          Print actions without building or deploying
#   --force SERVICE    Rebuild/deploy one or all services (comma-separated, or "all")
#   --service NAME     Only consider these services (comma-separated)
#
# Environment:
#   PROJECT_ID         GCP project (required)
#   AR_REGION          Artifact Registry location (default: us)
#   AR_REPO            Artifact Registry repository name (default: microservices-demo)
#   KUBE_NAMESPACE     Kubernetes namespace (default: default)
#   PLATFORM           docker build platform (default: linux/amd64)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PROJECT_ID="${PROJECT_ID:-}"
AR_REGION="${AR_REGION:-us}"
AR_REPO="${AR_REPO:-microservices-demo}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-default}"
PLATFORM="${PLATFORM:-linux/amd64}"
REGISTRY="${AR_REGION}-docker.pkg.dev"

DRY_RUN=false
FORCE_SERVICES=""
ONLY_SERVICES=""

usage() {
  sed -n '2,20p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --force)
      shift
      FORCE_SERVICES="${1:-all}"
      ;;
    --service)
      shift
      ONLY_SERVICES="${1:-}"
      ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: set PROJECT_ID (e.g. export PROJECT_ID=my-gcp-project)" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

need_cmd docker
need_cmd kubectl
need_cmd gcloud
need_cmd sha256sum

# name:context:dockerfile:deployment:container
# dockerfile path is relative to context
read -r -d '' SERVICE_DEFS <<'EOF' || true
frontend:src/frontend:Dockerfile:frontend:server
emailservice:src/emailservice:Dockerfile:emailservice:server
productcatalogservice:src/productcatalogservice:Dockerfile:productcatalogservice:server
recommendationservice:src/recommendationservice:Dockerfile:recommendationservice:server
shippingservice:src/shippingservice:Dockerfile:shippingservice:server
checkoutservice:src/checkoutservice:Dockerfile:checkoutservice:server
paymentservice:src/paymentservice:Dockerfile:paymentservice:server
currencyservice:src/currencyservice:Dockerfile:currencyservice:server
cartservice:src/cartservice/src:Dockerfile:cartservice:server
adservice:src/adservice:Dockerfile:adservice:server
loadgenerator:src/loadgenerator:Dockerfile:loadgenerator:main
EOF

should_process_service() {
  local name="$1"
  if [[ -n "${ONLY_SERVICES}" ]]; then
    IFS=',' read -r -a only <<<"${ONLY_SERVICES}"
    for o in "${only[@]}"; do
      [[ "${o}" == "${name}" ]] && return 0
    done
    return 1
  fi
  return 0
}

is_forced() {
  local name="$1"
  [[ -z "${FORCE_SERVICES}" ]] && return 1
  [[ "${FORCE_SERVICES}" == "all" ]] && return 0
  IFS=',' read -r -a forced <<<"${FORCE_SERVICES}"
  for f in "${forced[@]}"; do
    [[ "${f}" == "${name}" ]] && return 0
  done
  return 1
}

compute_context_hash() {
  local context="$1"
  local dockerfile="$2"
  if [[ ! -d "${REPO_ROOT}/${context}" ]]; then
    echo "missing-context" >&2
    return 1
  fi
  (
    cd "${REPO_ROOT}"
    find "${context}" -type f \
      ! -path '*/.git/*' \
      ! -path '*/node_modules/*' \
      ! -path '*/__pycache__/*' \
      ! -path '*/bin/*' \
      ! -path '*/obj/*' \
      2>/dev/null | LC_ALL=C sort | while read -r file; do
        sha256sum "${file}"
      done
    printf '%s\n' "${dockerfile}"
  ) | sha256sum | awk '{print substr($1,1,12)}'
}

remote_image_exists() {
  local image="$1"
  gcloud artifacts docker images describe "${image}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1
}

cluster_image() {
  local deployment="$1"
  local container="$2"
  kubectl get deployment "${deployment}" \
    -n "${KUBE_NAMESPACE}" \
    -o "jsonpath={.spec.template.spec.containers[?(@.name=='${container}')].image}" \
    2>/dev/null || true
}

deployment_exists() {
  local deployment="$1"
  kubectl get deployment "${deployment}" -n "${KUBE_NAMESPACE}" >/dev/null 2>&1
}

run() {
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[dry-run] $*"
  else
  echo "+ $*"
    "$@"
  fi
}

echo "Project:    ${PROJECT_ID}"
echo "Registry:   ${REGISTRY}/${PROJECT_ID}/${AR_REPO}"
echo "Namespace:  ${KUBE_NAMESPACE}"
echo "Platform:   ${PLATFORM}"
echo

DEPLOYED=0
SKIPPED=0

while IFS=':' read -r name context dockerfile deployment container; do
  [[ -z "${name}" ]] && continue
  should_process_service "${name}" || continue

  if ! deployment_exists "${deployment}"; then
    echo "== ${name}: skip (no deployment/${deployment} in namespace ${KUBE_NAMESPACE})"
    ((SKIPPED++)) || true
    continue
  fi

  hash="$(compute_context_hash "${context}" "${dockerfile}")"
  image="${REGISTRY}/${PROJECT_ID}/${AR_REPO}/${name}:${hash}"
  current_cluster="$(cluster_image "${deployment}" "${container}")"

  reason=""
  if is_forced "${name}"; then
    reason="forced"
  elif [[ "${current_cluster}" != "${image}" ]]; then
    reason="cluster image differs"
  elif ! remote_image_exists "${image}"; then
    reason="not in Artifact Registry"
  fi

  if [[ -z "${reason}" ]]; then
    echo "== ${name}: up to date (tag ${hash})"
    ((SKIPPED++)) || true
    continue
  fi

  echo "== ${name}: deploy (${reason})"
  echo "   context: ${context}"
  echo "   image:   ${image}"
  if [[ -n "${current_cluster}" ]]; then
    echo "   cluster: ${current_cluster}"
  fi

  run docker build --platform "${PLATFORM}" -t "${image}" \
    -f "${REPO_ROOT}/${context}/${dockerfile}" \
    "${REPO_ROOT}/${context}"
  run docker push "${image}"
  run kubectl set image "deployment/${deployment}" "${container}=${image}" -n "${KUBE_NAMESPACE}"
  if [[ "${DRY_RUN}" != true ]]; then
    run kubectl rollout status "deployment/${deployment}" -n "${KUBE_NAMESPACE}" --timeout=300s
  fi
  ((DEPLOYED++)) || true
  echo
done <<<"${SERVICE_DEFS}"

echo "Done. deployed=${DEPLOYED} skipped=${SKIPPED}"
