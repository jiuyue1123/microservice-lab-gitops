#!/usr/bin/env bash
# Start/stop port-forwards for the microservice-lab development services.
#
# Usage:
#   ./hack/port-forward.sh start
#   ./hack/port-forward.sh status
#   ./hack/port-forward.sh stop
#   ./hack/port-forward.sh restart
#
# By default forwards bind to 127.0.0.1. When running on the k3s node and
# exposing ports to other LAN machines, use:
#   BIND_ADDRESS=0.0.0.0 ./hack/port-forward.sh start
#
# The gateway port will be added once the gateway application exists.

set -euo pipefail

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found" >&2; exit 1; }

BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
RUN_DIR="${RUN_DIR:-/tmp/microservice-lab-port-forward}"

NACOS_PORT="${NACOS_PORT:-8081}"
NACOS_CLIENT_PORT="${NACOS_CLIENT_PORT:-8848}"
NACOS_GRPC_PORT="${NACOS_GRPC_PORT:-9848}"
NACOS_GRPC_SERVER_PORT="${NACOS_GRPC_SERVER_PORT:-9849}"
MYSQL_AUTH_PORT="${MYSQL_AUTH_PORT:-3307}"
MYSQL_ORDER_PORT="${MYSQL_ORDER_PORT:-3308}"
MYSQL_TENANT_PORT="${MYSQL_TENANT_PORT:-3309}"
MYSQL_USER_PORT="${MYSQL_USER_PORT:-3310}"
MYSQL_NACOS_PORT="${MYSQL_NACOS_PORT:-3311}"
REDIS_PORT="${REDIS_PORT:-6379}"
RABBITMQ_AMQP_PORT="${RABBITMQ_AMQP_PORT:-5672}"
RABBITMQ_PORT="${RABBITMQ_PORT:-15672}"

# name|namespace|target|local port|remote port
FORWARDS=(
  "nacos|microservice-lab-platform|svc/nacos|${NACOS_PORT}|8080"
  "nacos-client|microservice-lab-platform|svc/nacos|${NACOS_CLIENT_PORT}|8848"
  "nacos-grpc|microservice-lab-platform|svc/nacos|${NACOS_GRPC_PORT}|9848"
  "nacos-grpc-server|microservice-lab-platform|svc/nacos|${NACOS_GRPC_SERVER_PORT}|9849"
  "mysql-auth|microservice-lab-platform|svc/mysql-auth|${MYSQL_AUTH_PORT}|3306"
  "mysql-order|microservice-lab-platform|svc/mysql-order|${MYSQL_ORDER_PORT}|3306"
  "mysql-tenant|microservice-lab-platform|svc/mysql-tenant|${MYSQL_TENANT_PORT}|3306"
  "mysql-user|microservice-lab-platform|svc/mysql-user|${MYSQL_USER_PORT}|3306"
  "mysql-nacos|microservice-lab-platform|svc/mysql-nacos|${MYSQL_NACOS_PORT}|3306"
  "redis|microservice-lab-platform|svc/redis|${REDIS_PORT}|6379"
  "rabbitmq-amqp|microservice-lab-platform|svc/rabbitmq|${RABBITMQ_AMQP_PORT}|5672"
  "rabbitmq|microservice-lab-platform|svc/rabbitmq|${RABBITMQ_PORT}|15672"
)

mkdir -p "${RUN_DIR}"

port_in_use() {
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

pid_alive() {
  [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

start_one() {
  local name="$1" ns="$2" target="$3" local_port="$4" remote_port="$5"
  local pidfile="${RUN_DIR}/${name}.pid" logfile="${RUN_DIR}/${name}.log"

  if pid_alive "${pidfile}"; then
    echo "already running: ${name} (pid $(cat "${pidfile}"))"
    return 0
  fi
  if port_in_use "${local_port}"; then
    echo "port ${local_port} already in use; skipping ${name}" >&2
    return 1
  fi

  nohup kubectl -n "${ns}" port-forward "${target}" "${local_port}:${remote_port}" \
    --address "${BIND_ADDRESS}" >"${logfile}" 2>&1 &
  local pid=$!
  echo "${pid}" >"${pidfile}"
  sleep 1

  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "failed to start ${name}; log:" >&2
    tail -n 20 "${logfile}" >&2
    rm -f "${pidfile}"
    return 1
  fi
  echo "started: ${name} -> ${BIND_ADDRESS}:${local_port} (pid ${pid})"
}

stop_one() {
  local name="$1" pidfile="${RUN_DIR}/${name}.pid"
  if pid_alive "${pidfile}"; then
    kill "$(cat "${pidfile}")" 2>/dev/null || true
    echo "stopped: ${name}"
  fi
  rm -f "${pidfile}"
}

status_one() {
  local name="$1" local_port="$2" pidfile="${RUN_DIR}/${name}.pid"
  if pid_alive "${pidfile}"; then
    echo "running: ${name} -> ${BIND_ADDRESS}:${local_port} (pid $(cat "${pidfile}"))"
  else
    echo "stopped: ${name}"
  fi
}

cmd="${1:-start}"
case "${cmd}" in
  start)
    echo "kubectl context: $(kubectl config current-context)"
    echo "bind address: ${BIND_ADDRESS}"
    for entry in "${FORWARDS[@]}"; do
      IFS='|' read -r name ns target local_port remote_port <<< "${entry}"
      start_one "${name}" "${ns}" "${target}" "${local_port}" "${remote_port}" || true
    done
    ;;
  stop)
    for entry in "${FORWARDS[@]}"; do
      IFS='|' read -r name _ _ _ _ <<< "${entry}"
      stop_one "${name}"
    done
    ;;
  status)
    for entry in "${FORWARDS[@]}"; do
      IFS='|' read -r name _ _ local_port _ <<< "${entry}"
      status_one "${name}" "${local_port}"
    done
    ;;
  restart)
    "${BASH_SOURCE[0]}" stop
    "${BASH_SOURCE[0]}" start
    ;;
  *)
    echo "usage: $0 {start|stop|status|restart}" >&2
    exit 1
    ;;
esac
