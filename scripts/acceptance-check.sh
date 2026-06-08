#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-r-devops-magistracy-project-2sem-1003690211}"
RELEASE="${RELEASE:-sausage-store}"
INGRESS_HOST="${INGRESS_HOST:-front-norammoranos.2sem.students-projects.ru}"
TIMEOUT="${TIMEOUT:-300s}"
CREATE_TEST_ORDER="${CREATE_TEST_ORDER:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_CONFIG="${ROOT_CONFIG:-${REPO_DIR}/../config}"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Post-deploy acceptance checks for the Sausage Store final project.

Environment:
  NAMESPACE          Kubernetes namespace. Default: ${NAMESPACE}
  RELEASE            Helm release name. Default: ${RELEASE}
  INGRESS_HOST       Ingress host. Default: ${INGRESS_HOST}
  KUBECONFIG_FILE    Optional kubeconfig path. If omitted, ../config is filtered from apiVersion.
  ROOT_CONFIG        Trainer config path used when KUBECONFIG_FILE is omitted. Default: ${ROOT_CONFIG}
  TIMEOUT            kubectl rollout/wait timeout. Default: ${TIMEOUT}
  CREATE_TEST_ORDER  Set to 0 to skip POST /api/orders. Default: ${CREATE_TEST_ORDER}

The script does not print kubeconfig secrets. It creates one test order unless
CREATE_TEST_ORDER=0 is set.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

log() {
  printf '\n==> %s\n' "$*"
}

need_docker_if_missing() {
  local tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    echo "Neither ${tool} nor docker is available" >&2
    exit 1
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [[ -n "${KUBECONFIG_FILE:-}" ]]; then
  KUBECONFIG_PATH="${KUBECONFIG_FILE}"
else
  KUBECONFIG_PATH="${TMP_DIR}/kubeconfig"
  awk 'found || /^apiVersion:/{found=1; print}' "${ROOT_CONFIG}" > "${KUBECONFIG_PATH}"
  test -s "${KUBECONFIG_PATH}"
  chmod 600 "${KUBECONFIG_PATH}"
fi

kubectl_cmd() {
  if command -v kubectl >/dev/null 2>&1; then
    kubectl --kubeconfig "${KUBECONFIG_PATH}" "$@"
  else
    docker run --rm --user 0 \
      -v "${KUBECONFIG_PATH}:/kubeconfig:ro" \
      bitnami/kubectl:latest \
      --kubeconfig /kubeconfig "$@"
  fi
}

helm_cmd() {
  if command -v helm >/dev/null 2>&1; then
    helm --kubeconfig "${KUBECONFIG_PATH}" "$@"
  else
    docker run --rm --user 0 \
      -v "${KUBECONFIG_PATH}:/kubeconfig:ro" \
      alpine/helm:3.14.4 \
      --kubeconfig /kubeconfig "$@"
  fi
}

need_docker_if_missing kubectl
need_docker_if_missing helm

log "Helm release status"
helm_cmd status "${RELEASE}" --namespace "${NAMESPACE}" | tee "${TMP_DIR}/helm-status.txt"
grep -q 'STATUS: deployed' "${TMP_DIR}/helm-status.txt"

log "Kubernetes resources"
kubectl_cmd -n "${NAMESPACE}" get pods,deployments,statefulsets,services,ingress,hpa,vpa,jobs

log "Pods required by assignment"
kubectl_cmd -n "${NAMESPACE}" get po

log "Ingress required by assignment"
kubectl_cmd -n "${NAMESPACE}" get ing
ingress_host_actual="$(kubectl_cmd -n "${NAMESPACE}" get ing "${RELEASE}-frontend-ingress" \
  -o 'jsonpath={.spec.rules[0].host}')"
printf 'Ingress host=%s\n' "${ingress_host_actual}"
[[ "${ingress_host_actual}" == "${INGRESS_HOST}" ]]

log "Workload rollout status"
kubectl_cmd -n "${NAMESPACE}" rollout status "statefulset/mongodb" --timeout="${TIMEOUT}"
kubectl_cmd -n "${NAMESPACE}" rollout status "statefulset/postgresql" --timeout="${TIMEOUT}"
kubectl_cmd -n "${NAMESPACE}" rollout status "deployment/${RELEASE}-backend" --timeout="${TIMEOUT}"
kubectl_cmd -n "${NAMESPACE}" rollout status "deployment/${RELEASE}-backend-report" --timeout="${TIMEOUT}"
kubectl_cmd -n "${NAMESPACE}" rollout status "deployment/${RELEASE}-frontend" --timeout="${TIMEOUT}"

log "MongoDB init job completion"
kubectl_cmd -n "${NAMESPACE}" wait --for=condition=complete "job/mongodb-init" --timeout="${TIMEOUT}"
mongodb_init_succeeded="$(kubectl_cmd -n "${NAMESPACE}" get job mongodb-init \
  -o 'jsonpath={.status.succeeded}')"
mongodb_init_pods="$(kubectl_cmd -n "${NAMESPACE}" get pods -l job-name=mongodb-init \
  -o 'jsonpath={range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}')"
printf 'mongodb-init job succeeded=%s\n' "${mongodb_init_succeeded}"
printf '%s\n' "${mongodb_init_pods}"
[[ "${mongodb_init_succeeded}" == "1" ]]
grep -q '=Succeeded' <<< "${mongodb_init_pods}"

log "VPA and HPA conditions"
kubectl_cmd -n "${NAMESPACE}" wait \
  --for='jsonpath={.status.conditions[?(@.type=="RecommendationProvided")].status}=True' \
  "vpa/${RELEASE}-backend-vpa" \
  --timeout="${TIMEOUT}"
kubectl_cmd -n "${NAMESPACE}" wait \
  --for='jsonpath={.status.conditions[?(@.type=="ScalingActive")].status}=True' \
  "hpa/${RELEASE}-backend-report-hpa" \
  --timeout="${TIMEOUT}"
kubectl_cmd -n "${NAMESPACE}" describe vpa "${RELEASE}-backend-vpa"
kubectl_cmd -n "${NAMESPACE}" describe hpa "${RELEASE}-backend-report-hpa"
vpa_status="$(kubectl_cmd -n "${NAMESPACE}" get vpa "${RELEASE}-backend-vpa" \
  -o 'jsonpath={.status.conditions[?(@.type=="RecommendationProvided")].status}')"
hpa_status="$(kubectl_cmd -n "${NAMESPACE}" get hpa "${RELEASE}-backend-report-hpa" \
  -o 'jsonpath={.status.conditions[?(@.type=="ScalingActive")].status}')"
hpa_min_replicas="$(kubectl_cmd -n "${NAMESPACE}" get hpa "${RELEASE}-backend-report-hpa" \
  -o 'jsonpath={.spec.minReplicas}')"
hpa_max_replicas="$(kubectl_cmd -n "${NAMESPACE}" get hpa "${RELEASE}-backend-report-hpa" \
  -o 'jsonpath={.spec.maxReplicas}')"
hpa_cpu_target="$(kubectl_cmd -n "${NAMESPACE}" get hpa "${RELEASE}-backend-report-hpa" \
  -o 'jsonpath={.spec.metrics[?(@.resource.name=="cpu")].resource.target.averageUtilization}')"
printf 'VPA RecommendationProvided=%s\n' "${vpa_status}"
printf 'HPA ScalingActive=%s\n' "${hpa_status}"
printf 'HPA minReplicas=%s maxReplicas=%s cpuTarget=%s\n' \
  "${hpa_min_replicas}" "${hpa_max_replicas}" "${hpa_cpu_target}"
[[ "${vpa_status}" == "True" ]]
[[ "${hpa_status}" == "True" ]]
[[ "${hpa_min_replicas}" == "1" ]]
[[ "${hpa_max_replicas}" == "5" ]]
[[ "${hpa_cpu_target}" == "75" ]]

log "Recent application logs"
for deployment in backend backend-report frontend; do
  kubectl_cmd -n "${NAMESPACE}" logs "deployment/${RELEASE}-${deployment}" --tail=200 > "${TMP_DIR}/${deployment}.log"
  if grep -Ei '(fatal|panic|exception|error)' "${TMP_DIR}/${deployment}.log"; then
    echo "Potential critical log entries found in ${deployment}" >&2
    exit 1
  fi
  printf '%s logs: no fatal/panic/exception/error entries in last 200 lines\n' "${deployment}"
done

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for Ingress checks" >&2
  exit 1
fi

log "Ingress frontend and API checks"
base_url="https://${INGRESS_HOST}"
if ! curl -fsSk --max-time 20 "${base_url}/" >/dev/null; then
  base_url="http://${INGRESS_HOST}"
  curl -fsS --max-time 20 "${base_url}/" >/dev/null
fi

curl -fsSk --max-time 20 "${base_url}/api/products" | tee "${TMP_DIR}/products.json" >/dev/null
grep -q '"id":1' "${TMP_DIR}/products.json"

if [[ "${CREATE_TEST_ORDER}" == "1" ]]; then
  curl -fsSk --max-time 20 \
    -H 'Content-Type: application/json' \
    -d '{"productOrders":[{"product":{"id":1},"quantity":1}]}' \
    "${base_url}/api/orders" | tee "${TMP_DIR}/order.json" >/dev/null
  grep -q '"status":"PAID"' "${TMP_DIR}/order.json"
else
  echo "Skipping test order creation because CREATE_TEST_ORDER=${CREATE_TEST_ORDER}"
fi

log "backend-report health"
curl_pod_name="${RELEASE}-acceptance-curl"
curl_pod_overrides="$(
  cat <<JSON
{
  "spec": {
    "containers": [
      {
        "name": "${curl_pod_name}",
        "image": "curlimages/curl:8.8.0",
        "command": [
          "curl"
        ],
        "args": [
          "-fsS",
          "http://${RELEASE}-backend-report-service:8080/api/v1/health"
        ],
        "resources": {
          "requests": {
            "cpu": "25m",
            "memory": "32Mi"
          },
          "limits": {
            "cpu": "50m",
            "memory": "64Mi"
          }
        }
      }
    ]
  }
}
JSON
)"
kubectl_cmd -n "${NAMESPACE}" run "${RELEASE}-acceptance-curl" \
  --rm -i --restart=Never \
  --image=curlimages/curl:8.8.0 \
  --overrides="${curl_pod_overrides}"

log "Acceptance checks passed"
