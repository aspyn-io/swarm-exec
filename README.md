# 🐳 Swarm Exec

Reusable GitHub Action to:
1. Wait for a Docker Swarm service container to be **healthy** (Docker `HEALTHCHECK`) or **running** if no healthcheck exists.
2. Optionally probe an in-container **`/healthz` HTTP endpoint** (default `http://127.0.0.1/healthz`) and treat **HTTP 200** as ready.
3. Execute a command inside that container.
4. Transparently SSH to the correct Swarm node when the task is remote.

---

## 🔧 Inputs

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `docker_host` | ✅ | — | DOCKER_HOST (e.g. `ssh://opsadmin@swarm-manager`) |
| `service` | ✅ | — | Swarm service name (e.g. `example_app`) |
| `command` | ❌ | `php artisan migrate` | Command to run inside the container |
| `ssh_user` | ❌ | `opsadmin` | SSH user for remote nodes |
| `timeout_seconds` | ❌ | `600` | Max wait time for health |
| `interval_seconds` | ❌ | `5` | Polling interval in seconds |
| `use_healthz` | ❌ | `true` | If `true`, probe `healthz_url` inside the container; success on HTTP 200 |
| `healthz_url` | ❌ | `http://127.0.0.1/healthz` | URL to probe *inside the container* (via loopback) |

**Health readiness logic**  
Ready when **any** of the following is true:
- Docker health is `healthy`, or
- `use_healthz` is `true` **and** `healthz_url` returns **HTTP 200**, or
- No Docker healthcheck is present and the container is simply **running** (fallback).

> The `/healthz` probe is **non-blocking**: if the endpoint does not exist or returns non‑200, we continue waiting on Docker health or running-state as usual.

---

## 🚀 Usage

```yaml
- name: Run migrations after deploy
  uses: aspyn-io/swarm-exec@v1
  with:
    docker_host: ssh://opsadmin@${{ vars.SWARM_STAGING_HOST }}
    service: example_app
    command: php artisan migrate:fresh --seed
```

### Example: custom healthz URL
```yaml
- uses: aspyn-io/swarm-exec@v1
  with:
    docker_host: ssh://opsadmin@${{ vars.SWARM_STAGING_HOST }}
    service: example_app
    command: php artisan migrate
    use_healthz: true
    healthz_url: http://127.0.0.1:8080/healthz
```

### Example: disable /healthz probe
```yaml
- uses: aspyn-io/swarm-exec@v1
  with:
    docker_host: ssh://opsadmin@${{ vars.SWARM_STAGING_HOST }}
    service: example_app
    command: php artisan migrate
    use_healthz: false
```

---

## 🧠 Behavior Details

- If the container defines a Docker `HEALTHCHECK`, the action waits for `healthy`.
- If `use_healthz` is enabled, the action will also try an HTTP GET to `healthz_url` **inside the container** using `curl` or `wget`. An HTTP 200 result **immediately** satisfies readiness.
- If no healthcheck exists, we fall back to the container being **running** (`running-no-health`).

The action detects if the service task is local or remote:
- Local → `docker exec`
- Remote → SSH to the node and `docker exec` there

---

## 🧰 Requirements

- Docker CLI and SSH available on the GitHub runner.
- SSH key-based access to the Swarm manager and worker nodes.
- The provided `docker_host` must point to a Swarm **manager** node (or a node with access to `docker service` commands).
