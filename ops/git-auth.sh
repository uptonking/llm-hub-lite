#!/usr/bin/env bash

setup_github_https_auth() {
	local token_file="${GITHUB_TOKEN_FILE:-}"
	[[ -n "$token_file" && -s "$token_file" ]] || return 0
	[[ "$(stat -c '%a' "$token_file" 2>/dev/null || stat -f '%Lp' "$token_file" 2>/dev/null)" == 600 ]] || {
		printf 'git-auth: token file must be mode 600: %s\n' "$token_file" >&2
		return 1
	}
	export GIT_TERMINAL_PROMPT=0 GITHUB_TOKEN_FILE="$token_file"
	GITHUB_ASKPASS_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-hub-lite-askpass.XXXXXX")"
	cat >"$GITHUB_ASKPASS_FILE" <<'EOF'
#!/bin/sh
case "${1:-}" in *[Uu]sername*) printf '%s\n' x-access-token ;; *) cat -- "${GITHUB_TOKEN_FILE:?GITHUB_TOKEN_FILE is not set}" ;; esac
EOF
	chmod 700 "$GITHUB_ASKPASS_FILE"
	export GIT_ASKPASS="$GITHUB_ASKPASS_FILE"
}
cleanup_github_https_auth() {
	[[ -n "${GITHUB_ASKPASS_FILE:-}" ]] && rm -f -- "$GITHUB_ASKPASS_FILE"
	unset GITHUB_ASKPASS_FILE GIT_ASKPASS GIT_TERMINAL_PROMPT GITHUB_TOKEN_FILE
}
