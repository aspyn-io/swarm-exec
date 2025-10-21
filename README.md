# 🐳 Swarm Exec

**Reusable GitHub Action** to:
1. Wait for a Docker Swarm service container to be **healthy** (or running if no healthcheck),
2. Run a command inside that container,
3. Handle cross-node execution via SSH automatically.

## 🔧 Inputs

| Name | Required | Default | Description |
|------|-----------|----------|-------------|
| `docker_host` | ✅ | — | DOCKER_HOST (e.g. `ssh://opsadmin@swarm-manager`) |
| `service` | ✅ | — | Swarm service name (e.g. `sales_app`) |
| `command` | ❌ | `php artisan migrate` | Command to run inside the container |
| `ssh_user` | ❌ | `opsadmin` | SSH user for remote nodes |
| `timeout_seconds` | ❌ | `600` | Max wait time for health |
| `interval_seconds` | ❌ | `5` | Polling interval in seconds |
