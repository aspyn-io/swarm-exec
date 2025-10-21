#!/bin/bash

set -euo pipefail

log() { echo "::notice::[$(date +%H:%M:%S)] $*"; }

# --- inputs (env) expected ---
: "${SERVICE:?missing SERVICE}"
: "${CMD:?missing CMD}"
: "${SSH_USER:=opsadmin}"
: "${SLEEP_BEFORE:=0}"
: "${TIMEOUT:=120}"
: "${INTERVAL:=5}"
: "${USE_HEALTHZ:=true}"
: "${HEALTHZ_URL:=http://127.0.0.1/healthz}"

get_task_running() {
  docker service ps --filter 'desired-state=running' --no-trunc -q "$SERVICE" | head -n1
}
get_cid() { docker inspect -f '{{.Status.ContainerStatus.ContainerID}}' "$1"; }
get_nid() { docker inspect -f '{{.NodeID}}' "$1"; }

wait_for_task() {
  local start elapsed
  start="$(date +%s)"
  while :; do
    local t
    t="$(docker service ps --no-trunc --format '{{.ID}} {{.CurrentState}}' "$SERVICE" \
        | awk '/Running|Starting|Preparing|Assigned/ {print $1; exit}')"
    if [ -n "${t:-}" ]; then
      echo "$t"; return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    log "Waiting for a task to appear for service '$SERVICE' (elapsed ${elapsed}s)..."
    [ "$elapsed" -ge "$TIMEOUT" ] && { echo "::error::No task appeared for $SERVICE within timeout (${TIMEOUT}s)"; return 1; }
    sleep "$INTERVAL"
  done
}

wait_for_cid() {
  local task_id="$1" start elapsed c
  start="$(date +%s)"
  while :; do
    c="$(get_cid "$task_id" 2>/dev/null || true)"
    if [ -n "${c:-}" ]; then
      echo "$c"; return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    log "Task $task_id has no container yet; waiting (elapsed ${elapsed}s)..."
    [ "$elapsed" -ge "$TIMEOUT" ] && { echo "::error::Task $task_id never produced a container within timeout (${TIMEOUT}s)"; return 1; }
    sleep "$INTERVAL"
  done
}

local_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running-no-health{{end}}' "$1"
}
remote_health() {
  ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$1" \
    "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running-no-health{{end}}' $2"
}

http_ok_local() {
  local cid="$1" url="$2"
  docker exec -i "$cid" /bin/sh -lc "
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -o /dev/null --max-time 2 \"$url\"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- --timeout=2 \"$url\" >/dev/null
    else
      exit 2
    fi
  " >/dev/null 2>&1
}
http_ok_remote() {
  local ip="$1" cid="$2" url="$3"
  ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$ip" "
    docker exec -i $cid /bin/sh -lc '
      if command -v curl >/dev/null 2>&1; then
        curl -fsS -o /dev/null --max-time 2 \"$url\"
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=2 \"$url\" >/dev/null
      else
        exit 2
      fi
    '
  " >/dev/null 2>&1
}

node_ip() {
  local nid="$1" ip
  ip="$(docker node inspect -f '{{.Status.Addr}}' "$nid" 2>/dev/null || true)"
  if [ -z "$ip" ] || [ "$ip" = "0.0.0.0" ]; then
    ip="$(docker node inspect -f '{{.ManagerStatus.Addr}}' "$nid" 2>/dev/null | cut -d: -f1)"
  fi
  echo "$ip"
}

wait_ready_local() {
  local cid_ref="$1" start elapsed status
  start="$(date +%s)"
  while :; do
    # container replaced?
    if ! docker inspect "$cid_ref" >/dev/null 2>&1; then
      local t
      t="$(get_task_running || true)"
      local c=""; [ -n "$t" ] && c="$(get_cid "$t" 2>/dev/null || true)"
      if [ -n "$c" ] && [ "$c" != "$cid_ref" ]; then
        log "Container changed during wait -> $cid_ref -> $c"
        cid_ref="$c"
      fi
    fi

    status="$(local_health "$cid_ref" 2>/dev/null || true)"
    if [ "$status" = "healthy" ]; then
      log "Container $cid_ref is healthy"
      return 0
    fi
    if [ "${USE_HEALTHZ,,}" = "true" ]; then
      if http_ok_local "$cid_ref" "$HEALTHZ_URL"; then
        log "Container $cid_ref returned 200 from $HEALTHZ_URL"
        return 0
      else
        # graceful fallback if no curl/wget inside
        if ! docker exec -i "$cid_ref" sh -lc 'command -v curl >/dev/null || command -v wget >/dev/null' >/dev/null 2>&1; then
          log "No curl/wget in container; skipping healthz probe and relying on Docker health."
          USE_HEALTHZ="false"
        fi
      fi
    fi
    if [ "$status" = "running-no-health" ] && [ "${USE_HEALTHZ,,}" != "true" ]; then
      log "Container $cid_ref has no Docker healthcheck; accepting running state"
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    log "Waiting for readiness (status:${status:-unknown}, elapsed ${elapsed}s)..."
    [ "$elapsed" -ge "$TIMEOUT" ] && { echo "::error::Timeout waiting for readiness (status:${status:-unknown})"; return 1; }
    sleep "$INTERVAL"
  done
}

wait_ready_remote() {
  local ip="$1" cid_ref="$2" start elapsed status
  start="$(date +%s)"
  while :; do
    if ! ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$ip" "docker inspect $cid_ref >/dev/null 2>&1"; then
      local t
      t="$(get_task_running || true)"
      local c=""; [ -n "$t" ] && c="$(get_cid "$t" 2>/dev/null || true)"
      if [ -n "$c" ] && [ "$c" != "$cid_ref" ]; then
        log "Remote container changed during wait -> $cid_ref -> $c"
        cid_ref="$c"
      fi
    fi

    status="$(remote_health "$ip" "$cid_ref" 2>/dev/null || true)"
    if [ "$status" = "healthy" ]; then
      log "Remote container $cid_ref@$ip is healthy"
      return 0
    fi
    if [ "${USE_HEALTHZ,,}" = "true" ] && http_ok_remote "$ip" "$cid_ref" "$HEALTHZ_URL"; then
      log "Remote container $cid_ref@$ip returned 200 from $HEALTHZ_URL"
      return 0
    fi
    if [ "$status" = "running-no-health" ] && [ "${USE_HEALTHZ,,}" != "true" ]; then
      log "Remote container $cid_ref@$ip has no Docker healthcheck; accepting running state"
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    log "Waiting for remote readiness (status:${status:-unknown}, elapsed ${elapsed}s)..."
    [ "$elapsed" -ge "$TIMEOUT" ] && { echo "::error::Timeout waiting for remote readiness (status:${status:-unknown})"; return 1; }
    sleep "$INTERVAL"
  done
}

sleep_before() {
  if [ "$SLEEP_BEFORE" -gt 0 ]; then
    log "Sleeping for $SLEEP_BEFORE seconds before proceeding..."
    sleep "$SLEEP_BEFORE"
  fi
}

main() {
  log "Service: $SERVICE"
  task="$(wait_for_task)"
  cid="$(wait_for_cid "$task")"
  nid="$(get_nid "$task")"
  self="$(docker info -f '{{.Swarm.NodeID}}')"

  log "Selected Task: $task"
  log "Container ID:  $cid"
  log "Node ID:       $nid"

  sleep_before

  if [ "$nid" = "$self" ]; then
    log "Container $cid is on this node"
    until wait_ready_local "$cid"; do :; done
    docker exec -i "$cid" /bin/sh -lc "$CMD"
  else
    ip="$(node_ip "$nid")"
    [ -z "$ip" ] && { echo "::error::Unable to resolve IP for node $nid"; exit 1; }
    log "Container $cid is on remote node $ip"
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    : > ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts
    until wait_ready_remote "$ip" "$cid"; do :; done
    ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$ip" "docker exec -i $cid /bin/sh -lc '$CMD'"
  fi

  log "Command completed successfully"
}

# allow sourcing for tests
if [ "${1-}" != "sourced" ]; then
  main
fi
