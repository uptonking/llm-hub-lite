#!/usr/bin/env bash
# Unit tests for ops/lib/migration-common.sh
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
lib="$repo_root/ops/lib/migration-common.sh"

bash -n "$lib"
# shellcheck source=ops/lib/migration-common.sh
source "$lib"

# Test IPv4 validation
migration_valid_ipv4 "127.0.0.1" || {
	printf 'valid IPv4 failed\n' >&2
	exit 1
}
migration_valid_ipv4 "192.0.2.1" || {
	printf 'valid IPv4 failed\n' >&2
	exit 1
}
! migration_valid_ipv4 "999.0.0.1" || {
	printf 'invalid IPv4 accepted\n' >&2
	exit 1
}
! migration_valid_ipv4 "10.0.0" || {
	printf 'truncated IPv4 accepted\n' >&2
	exit 1
}
! migration_valid_ipv4 "abc.def.ghi.jkl" || {
	printf 'string IPv4 accepted\n' >&2
	exit 1
}

# Test SHA validation
migration_valid_sha "0123456789abcdef0123456789abcdef01234567" || {
	printf 'valid SHA failed\n' >&2
	exit 1
}
! migration_valid_sha "xyz" || {
	printf 'invalid SHA accepted\n' >&2
	exit 1
}
migration_valid_sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" || {
	printf 'valid SHA256 failed\n' >&2
	exit 1
}
! migration_valid_sha256 "short" || {
	printf 'invalid SHA256 accepted\n' >&2
	exit 1
}

# Test CSV helper
migration_csv_has "a,b,c" "b" || {
	printf 'csv_has failed\n' >&2
	exit 1
}
! migration_csv_has "a,b,c" "d" || {
	printf 'csv_has false positive\n' >&2
	exit 1
}

# Test command requirement checker
migration_require_commands bash grep sed awk || {
	printf 'require_commands failed for existing tools\n' >&2
	exit 1
}
! migration_require_commands non_existent_tool_12345 2>/dev/null || {
	printf 'require_commands passed for missing tool\n' >&2
	exit 1
}

# Test SHA256 file hashing
tmp="$(mktemp)"
printf 'test-data\n' >"$tmp"
hash="$(migration_sha256_file "$tmp")"
rm -f -- "$tmp"
migration_valid_sha256 "$hash" || {
	printf 'sha256_file failed to produce valid hash\n' >&2
	exit 1
}

# Test conditional secrets extractor
if [[ -f "$repo_root/apps/flowy/manifest.env" ]]; then
	flowy_keys="$(migration_manifest_conditional_secret_keys "$repo_root/apps/flowy/manifest.env")"
	[[ "$flowy_keys" == *"FLOWY_S3_ENDPOINT"* ]] || {
		printf 'flowy conditional secrets not extracted\n' >&2
		exit 1
	}
fi

# Test exclusions
exclusions="$(migration_archive_exclusions)"
grep -Fq 'collector-buffer' <<<"$exclusions"
grep -Fq 'restic' <<<"$exclusions"
grep -Fq 'maintenance' <<<"$exclusions"

# Test phase validation and ordering
phase_order="preflight source-stopped archive-created target-copy-verified"
migration_valid_phase "preflight" "$phase_order" || {
	printf 'valid phase failed\n' >&2
	exit 1
}
migration_valid_phase "archive-created" "$phase_order" || {
	printf 'valid phase failed\n' >&2
	exit 1
}
! migration_valid_phase "invalid-phase" "$phase_order" || {
	printf 'invalid phase accepted\n' >&2
	exit 1
}

migration_phase_at_least "archive-created" "source-stopped" "$phase_order" || {
	printf 'phase_at_least failed\n' >&2
	exit 1
}
migration_phase_at_least "archive-created" "archive-created" "$phase_order" || {
	printf 'phase_at_least failed\n' >&2
	exit 1
}
! migration_phase_at_least "source-stopped" "archive-created" "$phase_order" || {
	printf 'phase_at_least false positive\n' >&2
	exit 1
}

# Test legacy local partial adoption
tmp_dir="$(mktemp -d)"
test_archive="$tmp_dir/test.tar.gz"
printf 'partial-1' >"$test_archive.partial.1"
printf 'partial-longer-2' >"$test_archive.partial.2"
migration_adopt_legacy_local_partial "$test_archive"
[[ -f "$test_archive.partial" ]] || {
	printf 'adopt legacy partial failed to create stable partial\n' >&2
	exit 1
}
[[ "$(<"$test_archive.partial")" == 'partial-longer-2' ]] || {
	printf 'adopt legacy partial chose wrong partial file\n' >&2
	exit 1
}
rm -rf -- "$tmp_dir"

printf 'migration-common tests passed\n'
