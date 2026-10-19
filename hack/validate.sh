#!/usr/bin/env bash
# Local validation for the microservice-lab GitOps repository.
# Runs only local rendering/builds; it never talks to the cluster or deploys anything.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

fail=0

kustomize_build() {
  local dir="$1"
  echo "==> kubectl kustomize ${dir}"
  if ! kubectl kustomize "${dir}" >/dev/null; then
    echo "FAILED: kubectl kustomize ${dir}" >&2
    fail=1
  fi
}

render_chart() {
  local label="$1"
  shift
  echo "==> helm template ${label}"
  if ! helm template "$@" >/dev/null; then
    echo "FAILED: helm template ${label}" >&2
    fail=1
  fi
}

echo "== Kustomize builds =="
kustomize_build bootstrap
kustomize_build argocd/applications
kustomize_build infrastructure/namespaces
kustomize_build infrastructure/storage
kustomize_build platform/nacos
kustomize_build apps/user-service
kustomize_build apps/gateway

echo
echo "== Helm repositories =="
helm repo add groundhog2k https://groundhog2k.github.io/helm-charts/ --force-update >/dev/null
helm repo add cloudpirates https://cloudpirates-io.github.io/helm-charts/ --force-update >/dev/null
helm repo update >/dev/null

echo
echo "== Helm renders =="
for svc in auth order tenant user nacos; do
  render_chart "mysql-${svc}" \
    "mysql-${svc}" groundhog2k/mysql \
    --version 3.1.4 -f "platform/mysql-${svc}/values.yaml"
done
render_chart redis redis cloudpirates/redis --version 0.37.2 -f platform/redis/values.yaml
render_chart rabbitmq rabbitmq cloudpirates/rabbitmq --version 0.21.31 -f platform/rabbitmq/values.yaml

echo
echo "== Application policy checks =="
for f in argocd/applications/*.yaml bootstrap/root-application.yaml; do
  if [ "$(basename "${f}")" = "kustomization.yaml" ]; then
    continue
  fi
  if ! grep -q 'ServerSideApply=true' "${f}"; then
    echo "MISSING ServerSideApply=true: ${f}" >&2
    fail=1
  fi
  if grep -q 'resources-finalizer' "${f}"; then
    echo "UNEXPECTED resources-finalizer: ${f}" >&2
    fail=1
  fi
done

echo
if [ "${fail}" -ne 0 ]; then
  echo "Validation FAILED" >&2
  exit 1
fi
echo "Validation OK"
