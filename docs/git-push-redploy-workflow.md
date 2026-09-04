# Git Push to Redeploy Workflow

This document explains how a `git push` to `main` becomes a redeployment on the cluster.
It describes the mechanics of the generated Woodpecker deployment workflows, the per-node deployment controller, and the Caddy publication step that keeps all public traffic flowing through the Leader.

The Leader also runs `platform-woodpecker-repair.timer`. Woodpecker v3 signs
repository webhook URLs with the repository hash; restoring or migrating its
SQLite database can leave GitHub with a missing or stale hook. The timer calls
Woodpecker's authenticated `POST /api/repos/repair` endpoint and recreates the
hook automatically after the server is healthy. It is safe to run repeatedly.

## TL; DR

`git push` → GitHub webhook → Woodpecker server (on the Leader) → Leader `push-audit` planner and full `control-sync-leader` gate → follower `control-sync-<node>` verification workflows fetch and validate only node-local inputs → targeted app/foundation workflows run on the selected agents (active-active stages fan out in parallel; singleton stage → publish → stop remains ordered) → each step runs `deploy-controller` locally on that node, which fetches the same commit, validates it, swaps the service release only after the control release is ready, and recreates only the
affected Compose projects, health-checks them, and only then does the Leader rewrite the Caddy route and reload. GitHub Actions ( `validate.yml` ) never deploys; it is test-only. There is no SSH fan-out: every node pulls the commit itself.

## The pieces and where they live

| Concern | File |
| --- | --- |
| Node inventory (Leader/Followers, states, origin hostnames, agent labels) | `config/cluster/policy.env` , `config/cluster/nodes/*.env` |
| Which node runs which app | `config/cluster/apps/<app>.policy` ( `ENABLED` , `NODES` ) |
| App metadata (upstream mode, Compose project, health URL, route templates) | `apps/<app>/manifest.env` |
| CI (no deploy) | `.github/workflows/validate.yml` |
| CD (the deployer) | `.woodpecker/*.yml` , all machine-generated |
| Workflow generator | `ops/generate-woodpecker-workflows.sh` |
| Per-node deploy engine | `ops/deploy-controller.sh` and `ops/platformctl.sh` , wrapped by `ops/platform-submit.sh` |

Each active node runs a Woodpecker agent that connects to the Woodpecker
server on the Leader ( `compose/foundation/woodpecker-worker.yml` on Followers,
`woodpecker-deployer.yml` on the Leader). The agent labels come from
`WOODPECKER_AGENT_LABELS` in `config/cluster/nodes/<node>.env` , for example
`node=worker-1,deployment=true,target=production` . A workflow YAML declaring
`labels: node: worker-1` therefore lands on that exact VPS.

## The workflows are generated from the cluster config

The `.woodpecker/` files are not hand-written.
`ops/generate-woodpecker-workflows.sh` reads every `apps/*/manifest.env` plus
its placement policy and emits, per application:

Generation is transactional: workflows and image locks are rendered into a
temporary sibling tree, dependency-checked, and applied only after the whole
set succeeds. A failed render or copy restores the previous generated set and
never removes hand-authored workflows.

- **Deployment triggers**: `when: event: push, branch: main` with a `path` include list of
`apps/<app>/**` , `config/cluster/apps/<app>.policy` ,
`config/cluster/overrides/**/<app>.env` , `config/routes.d/**` , and
`apps/<app>/route*.caddy` and `apps/<app>/images.lock.env` . A push touching unrelated files triggers
  no deployment workflow. The generated `push-audit` workflow has no path
  filter and runs once on the Leader for every `main` push, printing the SHA
  and changed paths in Woodpecker Activity. This gives webhook and push
  visibility without deploying unrelated changes.

  Reloadable ingress changes (`config/Caddyfile` and `config/foundation-routes.d/**`) use generated push workflows (`foundation-reconcile-<node>`) chained Leader-first. They validate, rewrite the runtime Caddy tree, and reload Caddy without recreating foundation containers. Foundation Compose, image, environment-template, and controller/runner changes use reviewed manual foundation/runner workflows instead. A foundation upgrade computes the affected Compose projects and recreates only those projects; it refuses to recreate Caddy or Woodpecker from the Woodpecker job that depends on them, so that disruptive stage must be run locally on the target node against the committed SHA. If Woodpecker reports no pipeline at
  all for a push, check the webhook delivery and the Leader's
  `platform-woodpecker-repair.service`; a repaired hook should show a new
  `POST /api/hook` delivery in GitHub.
- **Placement**: `labels: node: <node>` routes each step to that VPS's agent.
- **Concurrency**: each node has its own
  `concurrency: {group: llm-hub-lite-node-<node>, limit: 1}`. Deployments on
  different VPSs can run concurrently, while the host lock still serializes
  mutations on one VPS. Woodpecker's queue preserves order across pushes.
- **Leader gate and supersession**: the Leader performs the expensive immutable
  release validation once. Followers verify the exact commit, tree, policy, and
  image locks locally before installing control metadata. The optional
  root-only `woodpecker-automation.env` enables the Leader planner to decline
  older pending pipelines for the same branch. Running pipelines are never
  canceled; every deployment controller performs a final ancestor check and
  exits before mutation when its SHA has been superseded.
- **Chaining** via `depends_on`: foundation reconciliation is Leader-first;
  active-active stages fan out and publish waits for every selected node;
  singleton transitions remain stage → publish → stale-node stop → finalize.

Cluster inventory, Leader policy, and foundation-policy changes use a separate
generated chain, `cluster-reconcile-leader` followed by each active Follower.
Ingress and foundation implementation paths are deliberately excluded from this
chain so one push cannot schedule overlapping reconciles on the same node.
It runs the same commit on each node and is the normal push-driven path for
enabling or disabling foundation services and activating joining nodes. It
refuses `LEADER_NODE_ID` changes; use bootstrap repair for a break-glass Leader
promotion or IP change.

Control synchronization is deliberately separate from service reconciliation:
`control/current` and `control/previous` track the validated repository contract,
while `apps/current` and `apps/previous` track the last successfully reconciled
service release. A failed app deployment therefore cannot advance or roll back
the control pointer, and a reboot always starts consumers from `apps/current`.

For the current placement ( `librechat` on worker-1 and worker-2 as
active-active; `aichorouter` , `cpapi` , and `cursorapi` as singletons on
worker-1), the generated chains are:

- LibreChat (active-active, `NODES=worker-1,worker-2`):
  `consumer-stage-librechat-worker-1` and
  `consumer-stage-librechat-worker-2` run in parallel, then
  `consumer-publish-librechat` (Leader) waits for both.
- aichorouter / cpapi / cursorapi (singleton,      `NODES=worker-1`):
`consumer-stage-<app>-worker-1` → `consumer-publish-<app>` (Leader) →
`consumer-stop-<app>-worker-2` (the unselected follower) →
`consumer-finalize-<app>-worker-1` (closes the singleton transition journal;
  for an enabled singleton the publish step is a health-gated
`singleton-switch` ).

Every step's command is a single line:

```
CONSUMER_APP_ID=<app> /usr/local/bin/platform-submit consumer-stage "$CI_COMMIT_SHA"
```

`platform-submit` ( `ops/platform-submit.sh` ) runs
`deploy-controller <mode> <sha>` in a fresh container built from the local
`llm-hub-lite/deploy-runner` image (docker CLI plus a digest-pinned Compose
binary; it mounts the Docker socket and the `/opt` runtime roots), verifies
the runner image ID matches the pinned ID in
`/etc/llm-hub-lite/platform.env` , and streams the container log back into the
Woodpecker step.

## What happens on each node: `deploy-controller apply`

The same script ( `ops/deploy-controller.sh` , `apply()` ) runs on every node,
role-aware:

1. **Lock.** `flock` on `/run/lock/llm-hub-lite/platform.lock`; deployments on
   a node serialize behind the lock.
2. **Fetch and guards.** `git fetch` into the local bare mirror
`/opt/platform/control/mirror.git` ( `fetch_main` , five retries). The target
   SHA must be reachable from `main` and must be a **fast-forward** compared
   to the installed release ( `verify_fast_forward` ); pushing an old SHA is
   refused. Rollback has its own workflow that skips this guard.
3. **Release tree.** `git worktree add` creates
`/opt/platform/control/releases/<sha>` — an immutable per-commit checkout.
4. **Validate before touching anything.** Runs the candidate release's own
`platformctl validate --check` ( `validate_release` ): it renders the full
   Caddy configuration into a staging directory, checks `docker compose
   config`, verifies digest-pinned image locks, and checks policy
   consistency. A candidate that fails validation mutates nothing. Successful
   validation is cached per commit and controller checksum on that node, so
   later scoped stages reuse the attestation instead of repeating Compose/Caddy
   inspection.
5. **Scope and ordering.** Control sync runs first on every node, so a consumer
   job may accompany control-plane, foundation, policy, documentation, or test
   changes in one commit. `verify_consumer_scope` still requires the selected
   application to be declared as a consumer; foundation and cluster workflows
   own their respective runtime changes while the consumer workflow reconciles
   only its selected app.
6. **Pre-change backup.** A verified Restic snapshot via
`backup-platform snapshot pre-<mode>` .
7. **Atomic cutover.** Swaps the `current` symlink to the new release while
   keeping the old one as `previous` , syncs `/etc/llm-hub-lite/node.env` from
   the committed node inventory, and installs the app's `images.lock.env`

   (so an image digest bump in `ops/images.apps.prod.env` flows through the
   same reviewed consumer chain; routine source deploys never silently move
   image digests).
8. **Apply.** Pulls pinned images if missing, then `reconcile` calls
`platformctl sync apps` , which recreates only the affected Compose project
   ( `app-librechat` , `app-cursorapi` , and so on) via `docker compose up -d` ,
   followed by `smoke_apps` (container healthcheck) and
`consumer-origin-smoke` (curl the node's own DNS-only origin host).
9. **On any failure:** a full transaction rollback restores the previous
   symlinks and env files and re-reconciles the previous release. A failed
   stage also halts the `depends_on` chain, so nothing publishes.

## Public traffic enters at the Leader: the publish step

Routing is Caddy on every node, with two templates per application:

- **Follower** (`apps/librechat/route.follower.caddy`): serves the node's
`NODE_LIBRECHAT_ORIGIN_HOST` (for example
`worker1-chat-origin.aichorage.de` , a DNS-only record pointing at the
  follower) and proxies to the local container ( `librechat-client:80` ). The
  follower firewall only permits HTTPS traffic from the Leader IP.
- **Leader** (`apps/librechat/route.leader.caddy`): serves the public site
  ( `chat.aichorage.de` ) and does `reverse_proxy {$LIBRECHAT_UPSTREAMS}` with
  load balancing, retries, and active health checks.

When `consumer-publish-<app>` runs on the Leader,
`deploy-controller consumer-publish` calls `platformctl consumer-publish`

( `consumer_publish_generic` in `ops/platformctl.sh` ), which:

1. Re-smokes every selected follower's origin over their
`NODE_*_ORIGIN_HOST` records. `cluster_upstreams()` builds the upstream
   list from all active followers in policy order; that is how
`LIBRECHAT_UPSTREAMS` becomes
`https://worker1-chat-origin… https://worker2-chat-origin…` . Singleton
   modes pin the single target follower instead.
2. Regenerates only that app's `routes.d/<app>.caddy`, reloads Caddy, and
   curls the public URL as the final smoke test.
3. On failure restores the previous route file and reloads Caddy again. A
   failed publish never stops the old containers.

So the request path is: public DNS → Leader Caddy → follower origins →
containers. The follower-side `consumer-stop-<app>-<node>` jobs clean up
stale instances only after publication succeeded.

## What is not automatic

- **GitHub Actions** (`.github/workflows/validate.yml`) is CI only: shell
  syntax checks, shellcheck, the workflow generator `--check` , the
  ip-privacy and deployment/bootstrap/observer test suites, `docker compose
  config` validation of every Compose model, Caddyfile render validation per
  node, and Woodpecker CLI lint. It deploys nothing.
- **Foundation implementation changes** under `ops/`, `compose/foundation/`,
  or the foundation image manifest use **manual** workflows: the
  `foundation-upgrade-leader` → `foundation-upgrade-worker-1` →
  `foundation-upgrade-worker-2` → `foundation-upgrade-worker-3` chain, the `runner-upgrade-*` chain (rebuilds
  the deploy-runner image), `rollback-*` , and the manual
  `consumer-secrets-<app>-<node>` workflows. The deployer executes
  `deploy-controller` and `platformctl` from the validated `control/current`
  release, not stale `/usr/local/bin` copies. If a selected foundation change
  would recreate the target node's Caddy or Woodpecker process, the workflow
  fails closed: SSH to that node during an approved maintenance window and run
  `/usr/local/bin/platform-submit foundation-upgrade <full-commit-sha>` locally,
  then verify `platformctl health` before proceeding to the next node. Do not
  rerun `bootstrap-vps.sh` for this normal staged upgrade. A push that mixes
  consumer and foundation implementation files is rejected by the scope guard;
  split it and apply the foundation commit first.
- Each node keeps its own `current`/`previous` release pointers under
`/opt/platform/control/` . If a node was offline, rerun the same Woodpecker
  build; the fast-forward guard lets it catch up to the newest SHA.
- Manual workflows are explicitly selected with the `MANUAL_WORKFLOW` variable.
  This is required because Woodpecker evaluates every `event: manual` config
  file in a manually created pipeline. For example, to provision LibreChat's
  key on worker-1, create a manual pipeline for `main` with
  `MANUAL_WORKFLOW=consumer-secrets-librechat-worker-1`. A missing or unknown
  selector intentionally runs no manual workflow. Run the selected secret
  workflow before changing singleton placement or recreating LibreChat.

## Concrete example: editing LibreChat configuration and pushing

1. The push hits `main`; the GitHub webhook notifies the Woodpecker server on
   the Leader.
2. Woodpecker matches the `path` filters for the librechat workflows. Both
   stage jobs are scheduled on their respective followers, then publish waits
   for both completion signals.
3. worker-1's agent picks up the stage step:
`deploy-controller consumer-stage <sha>` → fetch, validate, backup →
`current` symlink swap → `docker compose up -d app-librechat` on worker-1 →
   local health OK.
4. The same happens on worker-2.
5. The Leader's agent runs the publish step: re-checks both follower origins,
   rewrites the `chat.aichorage.de` route with both upstreams, reloads Caddy,
   and performs the public smoke.

If step 3 or 4 fails, the publish never runs and the old route stays live
(and on the failing node, the transaction rollback restores the previous
release). Fix, push, and the chain reruns; the fast-forward guard accepts the
newest SHA.

## Operational rules worth remembering

- Keep unrelated application changes in separate commits. One commit that touches two apps' paths triggers two independent consumer chains; one that mixes an app with foundation files is rejected outright.
- An image digest change uses the same reviewed consumer chain; there is no separate `app-upgrade-*` push family.
- Routine updates require only `git push`. SSH is reserved for first-time bootstrap and break-glass repair; do not rerun bootstrap for a routine update.
- For planned restarts and controller recovery, see [restart-recover.md](restart-recover.md); for initial bootstrap, see [first-deployment.md](first-deployment.md).
