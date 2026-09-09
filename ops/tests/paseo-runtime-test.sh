#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$PASEO_TEST_CHOWN_LOG"
EOF
cat >"$tmp/bin/base-entrypoint" <<'EOF'
#!/bin/sh
printf 'OPENAI=%s ANTHROPIC=%s OPENROUTER=%s\n' "${OPENAI_API_KEY-unset}" "${ANTHROPIC_API_KEY-unset}" "${OPENROUTER_API_KEY-unset}" >"$PASEO_TEST_ENTRYPOINT_LOG"
EOF
chmod 700 "$tmp/bin/chown" "$tmp/bin/base-entrypoint"

run_host() {
	local app="$1" prefix="$2" home="$3" marker="$4"
	PATH="$tmp/bin:$PATH" \
		PASEO_HOME="$home" PASEO_WORKSPACE="$tmp/$app-workspace" \
		PASEO_COMMON_ENTRYPOINT="$repo_root/apps/paseo/entrypoint-common.sh" \
		PASEO_BASE_ENTRYPOINT="$tmp/bin/base-entrypoint" \
		PASEO_APP_PREFIX="$prefix" PASEO_OWNERSHIP_MARKER="$marker" \
		PASEO_TEST_CHOWN_LOG="$tmp/$app-chown.log" PASEO_TEST_ENTRYPOINT_LOG="$tmp/$app-entrypoint.log" \
		"$repo_root/apps/$app/entrypoint.sh" smoke
}

for app_spec in 'aichor AICHOR .aichor-ownership-v1' 'aichor3 AICHOR3 .aichor3-ownership-v1'; do
	IFS=' ' read -r app prefix marker <<EOF
$app_spec
EOF
	: >"$tmp/$app-chown.log"
	: >"$tmp/$app-entrypoint.log"
	if [[ "$app" == aichor ]]; then
		AICHOR_PI_OPENAI_ENABLED=true AICHOR_PI_OPENAI_API_KEY=openai \
			AICHOR_PI_ANTHROPIC_ENABLED=false AICHOR_PI_OPENROUTER_ENABLED=false \
			PASEO_HOME="$tmp/$app-home" PASEO_WORKSPACE="$tmp/$app-workspace" \
			PASEO_COMMON_ENTRYPOINT="$repo_root/apps/paseo/entrypoint-common.sh" \
			PASEO_BASE_ENTRYPOINT="$tmp/bin/base-entrypoint" PASEO_APP_PREFIX="$prefix" \
			PASEO_OWNERSHIP_MARKER="$marker" PASEO_TEST_CHOWN_LOG="$tmp/$app-chown.log" \
			PASEO_TEST_ENTRYPOINT_LOG="$tmp/$app-entrypoint.log" PATH="$tmp/bin:$PATH" \
			"$repo_root/apps/$app/entrypoint.sh" smoke
	else
		AICHOR3_PI_OPENROUTER_ENABLED=true AICHOR3_PI_OPENROUTER_API_KEY=openrouter \
			PASEO_HOME="$tmp/$app-home" PASEO_WORKSPACE="$tmp/$app-workspace" \
			PASEO_COMMON_ENTRYPOINT="$repo_root/apps/paseo/entrypoint-common.sh" \
			PASEO_BASE_ENTRYPOINT="$tmp/bin/base-entrypoint" PASEO_APP_PREFIX="$prefix" \
			PASEO_OWNERSHIP_MARKER="$marker" PASEO_TEST_CHOWN_LOG="$tmp/$app-chown.log" \
			PASEO_TEST_ENTRYPOINT_LOG="$tmp/$app-entrypoint.log" PATH="$tmp/bin:$PATH" \
			"$repo_root/apps/$app/entrypoint.sh" smoke
	fi
	[[ -f "$tmp/$app-home/$marker" ]]
	grep -Fq 'OPENAI=unset' "$tmp/$app-entrypoint.log" || [[ "$app" == aichor ]]
done

printf 'shared Paseo runtime tests passed\n'
