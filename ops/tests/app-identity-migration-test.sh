#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/repo/ops" "$tmp/repo/apps/beta" "$tmp/bin" "$tmp/config" "$tmp/data/alpha/docs" "$tmp/state"
cp "$repo_root/ops/migrate-app-identity.sh" "$tmp/repo/ops/"
cat >"$tmp/repo/apps/beta/manifest.env" <<'EOF'
APP_ID=beta
UPSTREAM_MODE=singleton
RUNTIME_ENV_FILE=beta.env
COMPOSE_PROJECT=app-beta
DATA_ROOT_REL=beta
IDENTITY_MIGRATION_FROM_APP_ID=alpha
IDENTITY_MIGRATION_FROM_DATA_ROOT_REL=alpha
IDENTITY_MIGRATION_FROM_RUNTIME_ENV_FILE=alpha.env
IDENTITY_MIGRATION_FROM_COMPOSE_PROJECT=app-alpha
IDENTITY_MIGRATION_FROM_NETWORK=app-alpha_private
IDENTITY_MIGRATION_FROM_ENV_PREFIX=ALPHA
IDENTITY_MIGRATION_TO_ENV_PREFIX=BETA
IDENTITY_MIGRATION_TO_NETWORK=app-beta_private
EOF
cat >"$tmp/config/alpha.env" <<'EOF'
ALPHA_SESSION_SECRET=preserved-secret
ALPHA_BOOT_KEY=preserved-boot-key
UNCHANGED_SETTING=true
EOF
printf 'fresh sqlite data\n' >"$tmp/data/alpha/home.sqlite3"

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$DOCKER_LOG"
case " $* " in
*' ps -aq '*'com.docker.compose.project=app-alpha'*)
	[[ "${DOCKER_PHASE:-}" == prepare ]] && printf 'old-container\n'
	;;
*' ps -q '*'com.docker.compose.project=app-beta'*)
	[[ "${DOCKER_PHASE:-}" == finalize ]] && printf 'new-container\n'
	;;
*' inspect --format '*'new-container'*) printf 'healthy\n' ;;
*' network inspect --format '*) printf '0\n' ;;
*' network inspect '*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/docker" "$tmp/repo/ops/migrate-app-identity.sh"

run_migration() {
	DOCKER_PHASE="$1" DOCKER_LOG="$tmp/docker.log" PATH="$tmp/bin:$PATH" \
		IDENTITY_MIGRATION_TEST_MODE=1 PLATFORM_LOCK_HELD=1 \
		CONFIG_ROOT="$tmp/config" APP_ENV="$tmp/app.env" \
		IDENTITY_MIGRATION_STATE_ROOT="$tmp/state" DATA_ROOT_UNUSED="$tmp/data" \
		bash "$tmp/repo/ops/migrate-app-identity.sh" "$2" beta
}
printf 'DATA_ROOT=%s\n' "$tmp/data" >"$tmp/app.env"

run_migration prepare prepare
[[ -L "$tmp/data/alpha" && "$(readlink "$tmp/data/alpha")" == "$tmp/data/beta" ]]
[[ -d "$tmp/data/beta" && -f "$tmp/data/beta/home.sqlite3" ]]
grep -Fxq 'BETA_SESSION_SECRET=preserved-secret' "$tmp/config/beta.env"
grep -Fxq 'BETA_BOOT_KEY=preserved-boot-key' "$tmp/config/beta.env"
grep -Fxq 'UNCHANGED_SETTING=true' "$tmp/config/beta.env"
if grep -q '^ALPHA_' "$tmp/config/beta.env"; then
	printf 'source-prefixed secret leaked into target runtime env\n' >&2
	exit 1
fi
[[ -f "$tmp/config/alpha.env" ]]

run_migration prepare prepare
run_migration rollback rollback
[[ -d "$tmp/data/alpha" && ! -L "$tmp/data/alpha" && ! -e "$tmp/data/beta" ]]
[[ -f "$tmp/config/alpha.env" && ! -e "$tmp/config/beta.env" ]]

run_migration prepare prepare
run_migration finalize finalize
[[ ! -e "$tmp/data/alpha" && ! -L "$tmp/data/alpha" && -d "$tmp/data/beta" ]]
[[ ! -e "$tmp/config/alpha.env" && -f "$tmp/config/beta.env" ]]
[[ ! -e "$tmp/state/beta.state" ]]
run_migration finalize finalize

rm -rf -- "$tmp/data/beta" "$tmp/config/beta.env"
mkdir -p "$tmp/data/alpha" "$tmp/data/beta"
printf 'ALPHA_SESSION_SECRET=source\n' >"$tmp/config/alpha.env"
if run_migration prepare prepare >"$tmp/conflict.log" 2>&1; then
	printf 'identity migration unexpectedly merged conflicting data directories\n' >&2
	exit 1
fi
grep -Fq 'source and target data paths conflict' "$tmp/conflict.log"

validation_functions="$(sed -n '/^env_value() {/,/^}/p; /^stage_validation_runtime_config() {/,/^}/p' "$repo_root/ops/deploy-controller.sh")"
mkdir -p "$tmp/validation-release/apps/beta" "$tmp/validation-config"
cp "$tmp/repo/apps/beta/manifest.env" "$tmp/validation-release/apps/beta/manifest.env"
printf 'ALPHA_SESSION_SECRET=validation-secret\nUNCHANGED_SETTING=true\n' >"$tmp/validation-config/alpha.env"
VALIDATION_FUNCTIONS="$validation_functions" CONFIG_ROOT="$tmp/validation-config" \
	RELEASE_ROOT="$tmp/validation-release" DESTINATION="$tmp/validation-output" bash -c '
	set -Eeuo pipefail
	die() { printf "%s\n" "$*" >&2; exit 1; }
	eval "$VALIDATION_FUNCTIONS"
	stage_validation_runtime_config "$RELEASE_ROOT" "$DESTINATION"
'
grep -Fxq 'BETA_SESSION_SECRET=validation-secret' "$tmp/validation-output/beta.env"
grep -Fxq 'UNCHANGED_SETTING=true' "$tmp/validation-output/beta.env"
[[ ! -e "$tmp/validation-output/alpha.env" ]]

printf 'application identity migration tests passed\n'
