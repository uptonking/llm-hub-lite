# Woodpecker production control plane

This Compose project is intentionally separate from the application release. It
stores the Woodpecker SQLite database and agent configuration outside Git release
directories and connects the server to the existing `shared_network` so Caddy can
proxy `WOODPECKER_HOST` to `woodpecker-server:8000`. The official images are
distroless, so liveness is checked through the agent connection and the external
HTTP smoke checks rather than an in-container shell healthcheck.

## Bootstrap

The supported bootstrap path is `ops/bootstrap-vps.sh` (copy it to the VPS and
run it from an interactive SSH session). For later operations use
`ops/woodpecker/manage.sh`:

```bash
ops/woodpecker/manage.sh validate
ops/woodpecker/manage.sh status
ops/woodpecker/manage.sh upgrade
```

Create a GitHub OAuth App with callback URL
`https://ci.<your-domain>/authorize`. Woodpecker uses an OAuth App rather than a
GitHub App. Keep registration closed and set an explicit administrator.

The production project must be marked trusted only after confirming that pull
request and fork events are disabled. The Docker socket gives this agent
root-equivalent control of the VPS. Restrict its labels to the deployment
repository and keep the runner dedicated to this project.

The manual rollback workflow accepts `ROLLBACK_TARGET=previous` by default. It
can be started from the Woodpecker UI, or with:

```bash
woodpecker-cli pipeline start uptonking/llm-hub-lite last \
  --param ROLLBACK_TARGET=previous
```

Build the pinned deploy runner on the VPS before enabling the workflow:

```bash
docker build -t llm-hub-lite/deploy-runner:0.1.0 ops/deploy-runner
install -d -m 700 /etc/llm-hub-lite
install -m 600 ops/deploy.env.example /etc/llm-hub-lite/deploy.env
install -m 700 ops/deploy-controller.sh /usr/local/bin/deploy-controller
```

Edit `deploy.env` with the real repository and paths. Store the production
`.env.production` at `/opt/apps/llm-hub-lite/shared/.env.production`; it is never
part of a Git release.
