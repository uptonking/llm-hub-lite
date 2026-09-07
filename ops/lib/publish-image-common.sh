#!/usr/bin/env bash

publisher_require_commands() {
	local command_name
	for command_name in "$@"; do
		command -v "$command_name" >/dev/null 2>&1 || {
			printf 'required command is unavailable: %s\n' "$command_name" >&2
			return 1
		}
	done
}

publisher_validate_version() {
	local version="$1" package_name="$2"
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || {
		printf 'invalid npm version for %s: %s\n' "$package_name" "$version" >&2
		return 1
	}
}

publisher_set_release_var() {
	local file="$1" key="$2" value="$3" tmp
	[[ -f "$file" ]] || {
		printf 'release metadata file is missing: %s\n' "$file" >&2
		return 1
	}
	tmp="$(mktemp "${file}.tmp.XXXXXX")"
	if ! awk -v key="$key" -v value="$value" '
		BEGIN { prefix = key "="; replaced = 0 }
		index($0, prefix) == 1 { print prefix value; replaced = 1; next }
		{ print }
		END { if (!replaced) print prefix value }
	' "$file" >"$tmp"; then
		rm -f -- "$tmp"
		return 1
	fi
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}

publisher_assert_tag_unused() {
	local image_ref="$1" display_name="$2" release_file="$3" inspect_error
	if inspect_error="$(docker buildx imagetools inspect "$image_ref" 2>&1)"; then
		printf 'refusing to overwrite existing %s release tag: %s\n' "$display_name" "$image_ref" >&2
		printf 'choose a new image tag in %s\n' "$release_file" >&2
		return 1
	fi
	if ! printf '%s\n' "$inspect_error" | grep -Eiq 'manifest unknown|not found|status[^0-9]*404'; then
		printf 'unable to prove that %s release tag is unused: %s\n' "$display_name" "$image_ref" >&2
		printf '%s\n' "$inspect_error" >&2
		return 1
	fi
}

publisher_extract_digest() {
	local metadata_file="$1" digest
	digest="$(jq -r '."containerimage.digest" // empty' "$metadata_file")"
	[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
		printf 'build did not return a valid registry digest\n' >&2
		return 1
	}
	printf '%s\n' "$digest"
}

publisher_verify_digest() {
	docker buildx imagetools inspect "$1@$2" >/dev/null
}

publisher_verify_anonymous_ghcr() {
	local image_repository="$1" image_tag="$2" digest="$3" tmp="$4" display_name="$5"
	[[ "$image_repository" == ghcr.io/*/* ]] || return 0
	local package_path owner package_name
	package_path="${image_repository#ghcr.io/}"
	owner="${package_path%%/*}"
	package_name="${package_path#*/}"
	local settings_url="https://github.com/users/$owner/packages/container/$package_name/settings"
	local anonymous_token manifest_headers registry_digest
	anonymous_token="$(curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:$package_path:pull" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)"
	[[ -n "$anonymous_token" ]] || {
		printf '%s GHCR package is not anonymously pullable. Make it public once at:\n%s\n' "$display_name" "$settings_url" >&2
		return 1
	}
	manifest_headers="$tmp/manifest.headers"
	if ! curl -fsSI -H "Authorization: Bearer $anonymous_token" \
		-H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
		-o "$manifest_headers" "https://ghcr.io/v2/$package_path/manifests/$image_tag"; then
		printf '%s GHCR package manifest is not anonymously readable. Make it public once at:\n%s\n' "$display_name" "$settings_url" >&2
		return 1
	fi
	registry_digest="$(awk 'BEGIN { IGNORECASE=1 } /^docker-content-digest:/ { gsub("\r", ""); print $2 }' "$manifest_headers" | tail -n1)"
	[[ "$registry_digest" == "$digest" ]] || {
		printf 'anonymous registry digest mismatch: expected %s, found %s\n' "$digest" "$registry_digest" >&2
		return 1
	}
}
