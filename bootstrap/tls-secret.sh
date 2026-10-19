#!/usr/bin/env bash
# Creates/updates the TLS Secret used by the gateway Ingress.
# The certificate must contain gateway.lan in its SAN; reissue it with
# /root/coredns/certs/make-certs.sh before running this script.

set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${CERT_DIR:-/root/coredns/certs}"
NAMESPACE="${NAMESPACE:-microservice-lab-apps}"
SECRET_NAME="${SECRET_NAME:-gateway-lan-tls}"
DOMAIN="${DOMAIN:-gateway.lan}"

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not found" >&2; exit 1; }
[ -f "${CERT_DIR}/server.crt" ] || { echo "ERROR: ${CERT_DIR}/server.crt not found" >&2; exit 1; }
[ -f "${CERT_DIR}/server.key" ] || { echo "ERROR: ${CERT_DIR}/server.key not found" >&2; exit 1; }

if ! openssl x509 -in "${CERT_DIR}/server.crt" -noout -checkhost "${DOMAIN}" >/dev/null 2>&1; then
  echo "ERROR: ${CERT_DIR}/server.crt does not cover ${DOMAIN}." >&2
  echo "Add ${DOMAIN} to HOSTS in make-certs.sh, reissue, then rerun this script." >&2
  exit 1
fi

kubectl apply -k "${REPO_ROOT}/infrastructure/namespaces" >/dev/null

kubectl -n "${NAMESPACE}" create secret tls "${SECRET_NAME}" \
  --cert="${CERT_DIR}/server.crt" \
  --key="${CERT_DIR}/server.key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "TLS secret ${NAMESPACE}/${SECRET_NAME} is up to date."
