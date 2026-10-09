#!/usr/bin/env bash
# Common library for llm-hub-lite VPS migration workflows.
# Shared across Leader and Consumer/Follower migration orchestrators.
# Compatible with Bash 3.2+ on macOS and Linux.

# shellcheck disable=SC2016,SC2029

migration_have() { command -v "$1" >/dev/null 2>&1; }

migration_require_commands() {
	local cmd
	for cmd in "$@"; do
		migration_have "$cmd" || {
			printf 'migration: required command is unavailable: %s\n' "$cmd" >&2
			return 1
		}
	done
}

migration_valid_ipv4() {
	local ip="$1" octet old_ifs
	[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	old_ifs="$IFS"
	IFS=.
	for octet in $ip; do
		[[ "$octet" =~ ^[0-9]+$ && "$octet" -le 255 ]] || {
			IFS="$old_ifs"
			return 1
		}
	done
	IFS="$old_ifs"
}

migration_valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
migration_valid_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

migration_sha256_file() {
	if migration_have sha256sum; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

migration_csv_has() {
	local csv=",${1//[[:space:]]/},"
	[[ "$csv" == *",$2,"* ]]
}

migration_build_ssh_opts() {
	local port="$1" known_hosts="$2"
	printf '%s\n' \
		"-p" "$port" \
		"-o" "BatchMode=yes" \
		"-o" "StrictHostKeyChecking=yes" \
		"-o" "UserKnownHostsFile=$known_hosts" \
		"-o" "ConnectTimeout=10" \
		"-o" "ConnectionAttempts=3" \
		"-o" "ServerAliveInterval=15" \
		"-o" "ServerAliveCountMax=4"
}

migration_build_scp_opts() {
	local port="$1" known_hosts="$2"
	printf '%s\n' \
		"-P" "$port" \
		"-o" "BatchMode=yes" \
		"-o" "StrictHostKeyChecking=yes" \
		"-o" "UserKnownHostsFile=$known_hosts" \
		"-o" "ConnectTimeout=10" \
		"-o" "ConnectionAttempts=3" \
		"-o" "ServerAliveInterval=15" \
		"-o" "ServerAliveCountMax=4"
}

migration_build_sftp_opts() {
	local port="$1" known_hosts="$2"
	printf '%s\n' \
		"-P" "$port" \
		"-o" "BatchMode=yes" \
		"-o" "StrictHostKeyChecking=yes" \
		"-o" "UserKnownHostsFile=$known_hosts" \
		"-o" "ConnectTimeout=10" \
		"-o" "ConnectionAttempts=3" \
		"-o" "ServerAliveInterval=15" \
		"-o" "ServerAliveCountMax=4"
}

migration_archive_exclusions() {
	printf '%s\n' \
		"--exclude=collector-buffer" \
		"--exclude=collector-buffer/*" \
		"--exclude=opt/platform/observer/collector-buffer" \
		"--exclude=opt/platform/*/collector-buffer" \
		"--exclude=opt/platform/*/*/collector-buffer" \
		"--exclude=opt/platform/*restic*" \
		"--exclude=opt/platform/*/restic*" \
		"--exclude=etc/llm-hub-lite/maintenance" \
		"--exclude=etc/llm-hub-lite/node-retirement.*" \
		"--exclude=etc/llm-hub-lite/firewall-reconcile.request" \
		"--exclude=opt/apps/llm-hub-lite/shared/runtime/transaction.*" \
		"--exclude=opt/platform/control/*/transaction.*" \
		"--exclude=opt/apps/llm-hub-lite/shared/logs"
}

migration_manifest_conditional_secret_keys() {
	local manifest="$1" rule selector expected keys config_file result=''
	config_file="$(dirname "$manifest")/$(sed -n 's/^CONFIG_FILE=//p' "$manifest" | tail -n1)"
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		selector="${rule%%=*}"
		expected="${rule#*=}"
		keys="${expected#*|}"
		expected="${expected%%|*}"
		[[ "$(sed -n "s/^${selector}=//p" "$config_file" 2>/dev/null | tail -n1)" == "$expected" ]] || continue
		result="${result:+$result,}$keys"
	done < <(sed -n 's/^CONDITIONAL_SECRET_KEYS=//p' "$manifest" 2>/dev/null | tail -n1 | tr ';' '\n')
	printf '%s\n' "$result"
}

migration_resolve_node_origin_ip() {
	local repo_root="$1" node="$2" desc origin ip
	desc="$repo_root/config/cluster/nodes/$node.env"
	[[ -f "$desc" ]] || return 1
	while IFS= read -r line; do
		origin="${line#*=}"
		[[ -n "$origin" ]] || continue
		ip="$(curl -fsS --max-time 5 "https://cloudflare-dns.com/dns-query?name=$origin&type=A" -H "accept: application/dns-json" 2>/dev/null | jq -r '.Answer[]?.data' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)"
		if migration_valid_ipv4 "$ip"; then
			printf '%s\n' "$ip"
			return 0
		fi
	done < <(grep -E 'ORIGIN_HOST=' "$desc")
	return 1
}

migration_cleanup_direct_credentials() {
	local target_ip="$1" source_ip="$2" ssh_port="$3" known_hosts="$4" marker="$5" remote_key="$6" remote_hosts="$7" local_key="$8" local_hosts="$9"
	[[ -n "$marker" ]] || return 0
	local ssh_cmd=(-p "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
	ssh "${ssh_cmd[@]}" "root@$target_ip" "set -Eeuo pipefail; file=/root/.ssh/authorized_keys; if [ -f \"\$file\" ]; then tmp=\$(mktemp /root/.ssh/authorized_keys.XXXXXX); awk -v marker='$marker' 'index(\$0, \" \" marker) == 0' \"\$file\" >\"\$tmp\"; chmod 600 \"\$tmp\"; mv -f \"\$tmp\" \"\$file\"; fi" >/dev/null 2>&1 || true
	if [[ -n "$remote_key" ]]; then
		ssh "${ssh_cmd[@]}" "root@$source_ip" "rm -f '$remote_key' '$remote_hosts'" >/dev/null 2>&1 || true
	fi
	[[ -z "$local_key" ]] || rm -f -- "$local_key" "$local_key.pub"
	[[ -z "$local_hosts" ]] || rm -f -- "$local_hosts"
}

migration_prepare_direct_credentials() {
	local source_ip="$1" target_ip="$2" ssh_port="$3" known_hosts="$4" marker="$5" local_key="$6" local_hosts="$7" remote_key="$8" remote_hosts="$9"
	local lookup="$target_ip" public_key
	local ssh_cmd=(-p "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
	local scp_cmd=(-P "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)

	[[ "$ssh_port" == 22 ]] || lookup="[$target_ip]:$ssh_port"
	ssh-keygen -F "$lookup" -f "$known_hosts" 2>/dev/null | awk '!/^#/ && NF >= 3 {print}' >"$local_hosts"
	[[ -s "$local_hosts" ]] || {
		printf 'migration: target host key is absent from known-hosts for direct transfer: %s\n' "$lookup" >&2
		return 1
	}
	rm -f -- "$local_key" "$local_key.pub"
	ssh-keygen -q -t ed25519 -N '' -C "$marker" -f "$local_key"
	chmod 600 "$local_key" "$local_key.pub" "$local_hosts"
	public_key="$(<"$local_key.pub")"

	printf 'from="%s",restrict,command="internal-sftp" %s\n' "$source_ip" "$public_key" | ssh "${ssh_cmd[@]}" "root@$target_ip" \
		"set -Eeuo pipefail; umask 077; install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; tmp=\$(mktemp /root/.ssh/authorized_keys.XXXXXX); trap 'rm -f \"\$tmp\"' EXIT HUP INT TERM; grep -Fv ' $marker' /root/.ssh/authorized_keys >\"\$tmp\" || true; cat >>\"\$tmp\"; chmod 600 \"\$tmp\"; mv -f \"\$tmp\" /root/.ssh/authorized_keys; trap - EXIT HUP INT TERM"

	scp "${scp_cmd[@]}" "$local_key" "root@$source_ip:$remote_key"
	scp "${scp_cmd[@]}" "$local_hosts" "root@$source_ip:$remote_hosts"
	ssh "${ssh_cmd[@]}" "root@$source_ip" "chmod 600 '$remote_key' '$remote_hosts'; printf 'pwd\\n' | sftp -q -b - -P '$ssh_port' -i '$remote_key' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile='$remote_hosts' -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 root@'$target_ip' >/dev/null"
}

migration_verify_remote_archive() {
	local ip="$1" ssh_port="$2" known_hosts="$3" archive="$4"
	local ssh_cmd=(-p "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
	ssh "${ssh_cmd[@]}" "root@$ip" "set -Eeuo pipefail; archive='$archive'; checksum=\"\${archive}.sha256\"; test -f \"\$archive\" && test ! -L \"\$archive\" && test -f \"\$checksum\" && test ! -L \"\$checksum\"; expected=\$(sed 's/[[:space:]].*//' \"\$checksum\"); printf '%s\\n' \"\$expected\" | grep -Eq '^[0-9a-f]{64}\$'; actual=\$(sha256sum \"\$archive\" | sed 's/[[:space:]].*//'); test \"\$expected\" = \"\$actual\""
}

migration_discover_source_direct_state() {
	local ip="$1" node_id="$2" port="$3" known_hosts="$4"
	local ssh_cmd=(-p "$port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
	ssh "${ssh_cmd[@]}" "root@$ip" "node_id='$node_id' bash -s" <<'REMOTE_DIRECT_STATE'
set -Eeuo pipefail
current=/opt/platform/control/current
csv_has() { case ",${1//[[:space:]]/}," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }
for manifest in "$current"/apps/*/manifest.env; do
	[ -f "$manifest" ] || continue
	app="${manifest%/manifest.env}"; app="${app##*/}"
	rel="$(sed -n 's/^POLICY_FILE=//p' "$manifest" | tail -n1)"; policy="$current/config/$rel"
	[ "$(sed -n 's/^ENABLED=//p' "$policy" | tail -n1)" = true ] || continue
	[ "$(sed -n 's/^INGRESS_MODE=//p' "$manifest" | tail -n1)" = direct ] || continue
	nodes="$(sed -n 's/^NODES=//p' "$policy" | tail -n1)"; csv_has "$nodes" "$node_id" || continue
	runtime_rel="$(sed -n 's/^RUNTIME_ENV_FILE=//p' "$manifest" | tail -n1)"
	config_rel="$(sed -n 's/^RUNTIME_CONFIG_FILE=//p' "$manifest" | tail -n1)"
	data_rel="$(sed -n 's/^DATA_ROOT_REL=//p' "$manifest" | tail -n1)"
	data_root="$(sed -n 's/^DATA_ROOT=//p' /opt/apps/llm-hub-lite/shared/.env.prod | tail -n1)"; data_root="${data_root:-/opt/apps/llm-hub-lite/shared/data/prod}"
	runtime=''; rendered=''; data="$data_root/$data_rel"
	[ -z "$runtime_rel" ] || runtime="/etc/llm-hub-lite/$runtime_rel"
	[ -z "$config_rel" ] || rendered="/etc/llm-hub-lite/$config_rel"
	[ -z "$runtime_rel" ] || [ -s "$runtime" ] || { printf 'direct runtime env is missing: %s\n' "$runtime" >&2; exit 1; }
	[ -z "$config_rel" ] || [ -s "$rendered" ] || { printf 'direct rendered runtime config is missing: %s\n' "$rendered" >&2; exit 1; }
	[ -d "$data" ] || { printf 'direct data directory is missing: %s\n' "$data" >&2; exit 1; }
	printf '%s\t%s\t%s\t%s\n' "$app" "$runtime" "$rendered" "$data"
done
REMOTE_DIRECT_STATE
}

migration_verify_target_direct_state() {
	local ip="$1" port="$2" known_hosts="$3"
	local ssh_cmd=(-p "$port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
	ssh "${ssh_cmd[@]}" "root@$ip" 'set -Eeuo pipefail; current=/opt/platform/control/current; node_id=$(sed -n "s/^NODE_ID=//p" /etc/llm-hub-lite/node.env | tail -n1); data_root=$(sed -n "s/^DATA_ROOT=//p" /opt/apps/llm-hub-lite/shared/.env.prod | tail -n1); data_root=${data_root:-/opt/apps/llm-hub-lite/shared/data/prod}; csv_has(){ case ",$1," in *",$2,"*) return 0;; *) return 1;; esac; }; safe_rel(){ case "$1" in ""|/*|*..*) return 1;; esac; }; found=0; for manifest in "$current"/apps/*/manifest.env; do [ -f "$manifest" ] || continue; app=${manifest%/manifest.env}; app=${app##*/}; rel=$(sed -n "s/^POLICY_FILE=//p" "$manifest" | tail -n1); policy="$current/config/$rel"; [ "$(sed -n "s/^ENABLED=//p" "$policy" | tail -n1)" = true ] || continue; [ "$(sed -n "s/^INGRESS_MODE=//p" "$manifest" | tail -n1)" = direct ] || continue; nodes=$(sed -n "s/^NODES=//p" "$policy" | tail -n1); csv_has "$nodes" "$node_id" || continue; runtime_rel=$(sed -n "s/^RUNTIME_ENV_FILE=//p" "$manifest" | tail -n1); config_rel=$(sed -n "s/^RUNTIME_CONFIG_FILE=//p" "$manifest" | tail -n1); [ -z "$config_rel" ] && config_rel="runtime/$app/config.yaml"; safe_rel "$runtime_rel" || { printf "unsafe direct runtime env path: %s\\n" "$runtime_rel" >&2; exit 1; }; safe_rel "$config_rel" || { printf "unsafe direct rendered config path: %s\\n" "$config_rel" >&2; exit 1; }; data_rel=$(sed -n "s/^DATA_ROOT_REL=//p" "$manifest" | tail -n1); runtime="/etc/llm-hub-lite/$runtime_rel"; rendered="/etc/llm-hub-lite/$config_rel"; data="$data_root/$data_rel"; [ -z "$runtime_rel" ] || [ -s "$runtime" ] || { printf "direct runtime env missing: %s\\n" "$runtime" >&2; exit 1; }; [ -z "$config_rel" ] || [ -s "$rendered" ] || { printf "direct rendered runtime config missing: %s\\n" "$rendered" >&2; exit 1; }; [ -d "$data" ] || { printf "direct data directory missing: %s\\n" "$data" >&2; exit 1; }; platformctl direct-smoke "$app"; found=1; done; [ "$found" -eq 1 ] || { printf "no active direct applications found on target\\n" >&2; exit 1; }'
}

migration_verify_source_direct_state() {
	local ip="$1" direct_state="$2" port="$3" known_hosts="$4"
	local app runtime rendered data
	local ssh_cmd=(-p "$port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
	while IFS=$'\t' read -r app runtime rendered data; do
		[[ -n "$app" ]] || continue
		[[ "$runtime$rendered$data" != *"'"* && "$runtime$rendered$data" != *$'\n'* && "$runtime$rendered$data" != *$'\r'* ]] || return 1
		[[ -z "$runtime" || "$runtime" == /etc/llm-hub-lite/* ]] || return 1
		[[ -z "$rendered" || "$rendered" == /etc/llm-hub-lite/runtime/* ]] || return 1
		[[ "$data" == /opt/apps/llm-hub-lite/* ]] || return 1
		ssh "${ssh_cmd[@]}" "root@$ip" "if [ -n '$runtime' ]; then test -s '$runtime' || exit 1; fi; if [ -n '$rendered' ]; then test -s '$rendered' || exit 1; fi; test -d '$data'" || return 1
		printf 'migration: direct state: %s runtime=%s config=%s data=%s\n' "$app" "${runtime:-none}" "${rendered:-none}" "$data"
	done <<<"$direct_state"
}
migration_valid_phase() {
	local phase="$1" order="$2"
	case " $order " in *" $phase "*) return 0 ;; *) return 1 ;; esac
}

migration_phase_at_least() {
	local current="$1" wanted="$2" order="$3" p n=-1 w=-1 i=0
	for p in $order; do
		[[ "$p" == "$current" ]] && n="$i"
		[[ "$p" == "$wanted" ]] && w="$i"
		i=$((i + 1))
	done
	[[ "$n" -ge "$w" ]]
}

migration_adopt_legacy_local_partial() {
	local archive_local="$1"
	local stable="$archive_local.partial" c l='' sz lsz=0
	if [[ -e "$stable" || -L "$stable" ]]; then
		[[ -f "$stable" && ! -L "$stable" ]] && return 0
		rm -f -- "$stable"
		[[ ! -e "$stable" && ! -L "$stable" ]] || return 1
	fi
	for c in "$archive_local.partial."*; do
		[[ -f "$c" && ! -L "$c" ]] || continue
		sz="$(wc -c <"$c" | tr -d '[:space:]')"
		[[ "$sz" =~ ^[0-9]+$ ]] && ((sz > lsz)) && {
			l="$c"
			lsz="$sz"
		}
	done
	[[ -z "$l" ]] || mv -f -- "$l" "$stable"
}

migration_discover_source_origins() {
	local ip="$1" node_id="$2" domain="$3" port="$4" known_hosts="$5"
	local ssh_cmd=(-p "$port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
	ssh "${ssh_cmd[@]}" "root@$ip" "node_id='$node_id' domain='$domain' bash -s" <<'REMOTE_ORIGIN_DISCOVERY'
set -Eeuo pipefail
current=/opt/platform/control/current; node_file=/etc/llm-hub-lite/node.env
csv_has() { case ",${1//[[:space:]]/}," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }
for manifest in "$current"/apps/*/manifest.env; do
	[ -f "$manifest" ] || continue
	app="${manifest%/manifest.env}"; app="${app##*/}"
	rel="$(sed -n 's/^POLICY_FILE=//p' "$manifest" | tail -n1)"; policy="$current/config/$rel"
	[ "$(sed -n 's/^ENABLED=//p' "$policy" | tail -n1)" = true ] || continue
	nodes="$(sed -n 's/^NODES=//p' "$policy" | tail -n1)"; csv_has "$nodes" "$node_id" || continue
	ingress="$(sed -n 's/^INGRESS_MODE=//p' "$manifest" | tail -n1)"
	if [ "$ingress" = direct ]; then
		while IFS='|' read -r public_key host; do
			[ -n "$host" ] || continue
			printf '%s\t%s\t%s\n' "$host.$domain" "$app" "$public_key"
		done <<EOF_ENDPOINTS
$(printf '%s\n' "$(sed -n 's/^PUBLIC_ENDPOINTS=//p' "$manifest" | tail -n1)" | tr ';' '\n')
EOF_ENDPOINTS
		continue
	fi
	groups="$(sed -n 's/^ROUTE_GROUPS=//p' "$manifest" | tail -n1)"
	[ -n "$groups" ] || continue
	while IFS='|' read -r public_key origin_key upstream_key; do
		[ -n "$origin_key" ] || continue
		printf '%s\n' "$origin_key" | grep -Eq '^[A-Z][A-Z0-9_]*$' || { printf 'invalid origin key for %s: %s\n' "$app" "$origin_key" >&2; exit 1; }
		origin="$(sed -n "s/^$origin_key=//p" "$node_file" | tail -n1)"
		[ -n "$origin" ] || { printf 'missing origin value for %s/%s\n' "$app" "$origin_key" >&2; exit 1; }
		printf '%s\t%s\t%s\n' "$origin" "$app" "${public_key:-route}"
	done <<EOF_GROUPS
$(printf '%s\n' "$groups" | tr ';' '\n')
EOF_GROUPS
done | sort -u
REMOTE_ORIGIN_DISCOVERY
}
