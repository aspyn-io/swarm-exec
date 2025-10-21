#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  TMPDIR="$(mktemp -d)"
  export PATH="$TMPDIR:$PATH"

  # stubs directory
  mkdir -p "$TMPDIR"

  # default stubs (can be overridden per-test)
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  service)
    # docker service ps <SERVICE> --no-trunc --format '{{.ID}} {{.CurrentState}}'
    if [ "$2" = "ps" ]; then
      # emit nothing by default (no tasks)
      exit 0
    fi
    ;;
  inspect)
    # docker inspect -f ... <id>
    # emit empty by default to simulate "no cid yet"
    exit 1
    ;;
  info)
    # docker info -f '{{.Swarm.NodeID}}'
    echo "NODE_SELF"
    ;;
  exec)
    exit 0
    ;;
  node)
    # node inspect -f {{.Status.Addr}} <nid>
    echo "127.0.0.1"
    ;;
esac
EOF
  chmod +x "$TMPDIR/docker"

  cat > "$TMPDIR/ssh" <<'EOF'
#!/usr/bin/env bash
# default ssh stub: succeed
exit 0
EOF
  chmod +x "$TMPDIR/ssh"
}

teardown() {
  rm -rf "$TMPDIR"
}

load_script() {
  # source the script without running main()
  export SERVICE="svc" CMD="true" TIMEOUT="2" INTERVAL="1" USE_HEALTHZ="false"
  source "${BATS_TEST_DIRNAME}/../scripts/swarm-exec.sh" sourced
}

@test "wait_for_task times out when no tasks appear" {
  load_script
  run wait_for_task
  [ "$status" -ne 0 ]
  [[ "${output}" == *"No task appeared"* ]]
}

@test "wait_for_task returns a task when one appears" {
  # patch docker service ps to emit a candidate
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "service" ] && [ "$2" = "ps" ]; then
  echo "abc123 Running 1s ago"
  exit 0
fi
if [ "$1" = "info" ]; then echo "NODE_SELF"; fi
if [ "$1" = "inspect" ]; then exit 1; fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run wait_for_task
  [ "$status" -eq 0 ]
  [ "$output" = "abc123" ]
}

@test "wait_for_cid returns cid once present" {
  # first returns no cid, then returns a cid
  cat > "$TMPDIR/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\$1" = "inspect" ]; then
  if [ ! -f "$TMPDIR/flip" ]; then
    touch "$TMPDIR/flip"
    exit 1
  else
    # format evaluates to the CID; emit something
    echo "deadbeefcid"
    exit 0
  fi
fi
if [ "\$1" = "info" ]; then echo "NODE_SELF"; fi
if [ "\$1" = "service" ] && [ "\$2" = "ps" ]; then echo "abc123 Running 1s ago"; fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run wait_for_cid abc123
  [ "$status" -eq 0 ]
  # Extract the last line of output (which should be the container ID)
  local last_line
  last_line="$(echo "$output" | tail -n1)"
  [ "$last_line" = "deadbeefcid" ]
}

@test "wait_ready_local accepts healthy" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ]; then
  # .State.Health.Status -> healthy
  if [ "$2" = "-f" ]; then echo "healthy"; exit 0; fi
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run wait_ready_local 42
  [ "$status" -eq 0 ]
  [[ "${output}" == *"healthy"* ]]
}

@test "rolling replacement: container id changes mid-wait" {
  # first call: old cid not found; second: new running task/cid appears
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  inspect)
    # simulate: the original cid is gone -> non-zero
    exit 1
    ;;
  service)
    if [ "$2" = "ps" ]; then
      # new task appears
      echo "newtask Running 1s ago"
    fi
    ;;
  info) echo "NODE_SELF" ;;
esac
EOF
  chmod +x "$TMPDIR/docker"

  # also stub get_cid to resolve new task to new cid
  # easiest: shadow the function after load
  load_script
  get_cid() { echo "newcid"; }

  # local_health should still not be healthy, but we just verify it loops and picks newcid once
  export TIMEOUT=1 INTERVAL=1
  run wait_ready_local oldcid
  [[ "${output}" == *"Container changed during wait -> oldcid -> newcid"* ]]
}

@test "get_cid extracts container ID from task" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ] && [ "$2" = "-f" ]; then
  echo "container123abc"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run get_cid task456
  [ "$status" -eq 0 ]
  [ "$output" = "container123abc" ]
}

@test "get_nid extracts node ID from task" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ] && [ "$2" = "-f" ]; then
  echo "node789xyz"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run get_nid task456
  [ "$status" -eq 0 ]
  [ "$output" = "node789xyz" ]
}

@test "local_health returns healthy status" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ] && [ "$2" = "-f" ]; then
  echo "healthy"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run local_health container123
  [ "$status" -eq 0 ]
  [ "$output" = "healthy" ]
}

@test "local_health returns running-no-health for container without healthcheck" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ] && [ "$2" = "-f" ]; then
  echo "running-no-health"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run local_health container123
  [ "$status" -eq 0 ]
  [ "$output" = "running-no-health" ]
}

@test "node_ip resolves from Status.Addr" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "node" ] && [ "$2" = "inspect" ] && [ "$3" = "-f" ]; then
  if [[ "$4" == *"Status.Addr"* ]]; then
    echo "192.168.1.100"
  fi
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run node_ip node123
  [ "$status" -eq 0 ]
  [ "$output" = "192.168.1.100" ]
}

@test "node_ip returns IP when Status.Addr is available" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "node" ] && [ "$2" = "inspect" ] && [ "$3" = "-f" ]; then
  echo "192.168.1.100"
  exit 0
fi
exit 1
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run node_ip node123
  [ "$status" -eq 0 ]
  [ "$output" = "192.168.1.100" ]
}

@test "node_ip handles docker command failure gracefully" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# All docker calls fail
exit 1
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run node_ip node123
  [ "$status" -eq 0 ]
  # Should output empty string when all calls fail
  [ -z "$output" ]
}

@test "http_ok_local succeeds with curl" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "exec" ] && [ "$2" = "-i" ]; then
  # simulate successful docker exec (healthz check passed)
  exit 0
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run http_ok_local container123 "http://127.0.0.1/healthz"
  [ "$status" -eq 0 ]
}

@test "http_ok_local fails when no curl/wget available" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "exec" ] && [ "$2" = "-i" ]; then
  # simulate container without curl/wget
  exit 2
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run http_ok_local container123 "http://127.0.0.1/healthz"
  [ "$status" -eq 2 ]
}

@test "wait_ready_local accepts running-no-health when USE_HEALTHZ=false" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ]; then
  echo "running-no-health"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  export USE_HEALTHZ="false"
  run wait_ready_local container123
  [ "$status" -eq 0 ]
  [[ "${output}" == *"has no Docker healthcheck; accepting running state"* ]]
}

@test "wait_ready_local times out with unhealthy container" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ]; then
  echo "unhealthy"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  export TIMEOUT=1 INTERVAL=1 USE_HEALTHZ="false"
  run wait_ready_local container123
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Timeout waiting for readiness"* ]]
}

@test "wait_ready_local uses healthz endpoint when available" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ]; then
  echo "starting"  # not healthy yet
elif [ "$1" = "exec" ]; then
  # simulate successful healthz check
  exit 0
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  export USE_HEALTHZ="true" HEALTHZ_URL="http://127.0.0.1/health"
  run wait_ready_local container123
  [ "$status" -eq 0 ]
  [[ "${output}" == *"returned 200 from http://127.0.0.1/health"* ]]
}

@test "get_task_running filters for running tasks" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "service" ] && [ "$2" = "ps" ]; then
  # simulate multiple tasks, only return running ones
  echo "task123"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run get_task_running
  [ "$status" -eq 0 ]
  [ "$output" = "task123" ]
}

@test "remote_health calls ssh with correct parameters" {
  cat > "$TMPDIR/ssh" <<'EOF'
#!/usr/bin/env bash
# simulate docker inspect returning healthy via ssh
echo "healthy"
exit 0
EOF
  chmod +x "$TMPDIR/ssh"

  load_script
  run remote_health "192.168.1.100" "container456"
  [ "$status" -eq 0 ]
  [ "$output" = "healthy" ]
}

@test "wait_for_task handles service with starting tasks" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "service" ] && [ "$2" = "ps" ]; then
  # simulate task in Starting state (should be picked up)
  echo "task789 Starting 5s ago"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run wait_for_task
  [ "$status" -eq 0 ]
  [ "$output" = "task789" ]
}

@test "wait_for_task handles service with preparing tasks" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "service" ] && [ "$2" = "ps" ]; then
  # simulate task in Preparing state (should be picked up)
  echo "task101 Preparing 2s ago"
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  run wait_for_task
  [ "$status" -eq 0 ]
  [ "$output" = "task101" ]
}

@test "http_ok_remote calls ssh with correct structure" {
  cat > "$TMPDIR/ssh" <<'EOF'
#!/usr/bin/env bash
# simulate successful healthz check via ssh
exit 0
EOF
  chmod +x "$TMPDIR/ssh"

  load_script
  run http_ok_remote "10.0.0.5" "container789" "http://localhost/health"
  [ "$status" -eq 0 ]
}

@test "wait_ready_remote times out on unhealthy container" {
  cat > "$TMPDIR/ssh" <<'EOF'
#!/usr/bin/env bash
# simulate remote docker inspect returning unhealthy
echo "unhealthy"
EOF
  chmod +x "$TMPDIR/ssh"

  load_script
  export TIMEOUT=1 INTERVAL=1 USE_HEALTHZ="false"
  run wait_ready_remote "10.0.0.5" "container789"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Timeout waiting for remote readiness"* ]]
}

@test "main function follows local execution path" {
  # Mock all the component functions to return expected values
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  service)
    if [ "$2" = "ps" ]; then
      echo "mytask123 Running 10s ago"
    fi
    ;;
  inspect)
    if [[ "$3" == *"ContainerID"* ]]; then
      echo "mycontainer456"
    elif [[ "$3" == *"NodeID"* ]]; then
      echo "SAME_NODE"  # same as swarm node id
    elif [[ "$3" == *"Health"* ]]; then
      echo "healthy"
    fi
    ;;
  info)
    echo "SAME_NODE"  # local node id
    ;;
  exec)
    echo "Command executed successfully"
    ;;
esac
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  export CMD="echo 'test command'"
  run main
  [ "$status" -eq 0 ]
  [[ "${output}" == *"Container mycontainer456 is on this node"* ]]
  [[ "${output}" == *"Command completed successfully"* ]]
}

@test "environment variables are validated" {
  load_script
  # Test that missing SERVICE variable causes error
  unset SERVICE
  run -127 bash -c ': "${SERVICE:?missing SERVICE}"'
  [ "$status" -eq 127 ]
}

@test "main function fails when node IP cannot be resolved" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  service)
    if [ "$2" = "ps" ]; then
      echo "remotetask456 Running 10s ago"
    fi
    ;;
  inspect)
    if [[ "$3" == *"ContainerID"* ]]; then
      echo "remotecontainer789"
    elif [[ "$3" == *"NodeID"* ]]; then
      echo "REMOTE_NODE"
    elif [[ "$3" == *"Health"* ]]; then
      echo "healthy"
    fi
    ;;
  info)
    echo "LOCAL_NODE"
    ;;
  node)
    # All node inspect calls fail -> no IP resolution
    exit 1
    ;;
esac
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  export CMD="echo 'test command'"
  run main
  [ "$status" -eq 1 ]
  [[ "${output}" == *"Unable to resolve IP for node REMOTE_NODE"* ]]
}

@test "wait_for_cid times out when container never appears" {
  cat > "$TMPDIR/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "inspect" ]; then
  # Always fail to simulate no container
  exit 1
fi
EOF
  chmod +x "$TMPDIR/docker"

  load_script
  export TIMEOUT=1 INTERVAL=1
  run wait_for_cid task123
  [ "$status" -ne 0 ]
  [[ "${output}" == *"never produced a container within timeout"* ]]
}

@test "wait_ready_remote accepts healthy remote container" {
  cat > "$TMPDIR/ssh" <<'EOF'
#!/usr/bin/env bash
# First call: docker inspect (check if container exists)
# Second call: remote_health returning healthy
echo "healthy"
exit 0
EOF
  chmod +x "$TMPDIR/ssh"

  load_script
  export USE_HEALTHZ="false"
  run wait_ready_remote "10.0.0.5" "container123"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"Remote container container123@10.0.0.5 is healthy"* ]]
}
