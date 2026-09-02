#!/usr/bin/env bash
# Shared assertions for Bash 3.2-compatible test suites.

test_fail() {
	printf 'test failure: %s\n' "$*" >&2
	return 1
}

assert_equal() {
	local expected="$1" actual="$2" message="${3:-values differ}"
	if [[ "$expected" != "$actual" ]]; then
		printf 'test failure: %s (expected %q, got %q)\n' "$message" "$expected" "$actual" >&2
		return 1
	fi
}

assert_file_exists() {
	local path="$1"
	if [[ ! -e "$path" ]]; then
		printf 'test failure: expected file: %s\n' "$path" >&2
		return 1
	fi
}

assert_file_absent() {
	local path="$1"
	if [[ -e "$path" ]]; then
		printf 'test failure: unexpected file: %s\n' "$path" >&2
		return 1
	fi
}

assert_contains() {
	local needle="$1" haystack="$2" message="${3:-text does not contain expected value}"
	if ! grep -Fq -- "$needle" <<<"$haystack"; then
		printf 'test failure: %s (%q)\n' "$message" "$needle" >&2
		return 1
	fi
}
