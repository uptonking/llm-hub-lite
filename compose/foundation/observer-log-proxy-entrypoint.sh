#!/bin/sh
set -eu

template=/templates/haproxy.cfg
runtime_config=/run/haproxy/haproxy.cfg
stream_timeout="${OBSERVER_LOG_PROXY_STREAM_TIMEOUT:-24h}"

case "$stream_timeout" in
*[smhd]) timeout_value="${stream_timeout%?}" ;;
*)
	echo "observer-log-proxy: OBSERVER_LOG_PROXY_STREAM_TIMEOUT must be a positive integer followed by s, m, h, or d" >&2
	exit 1
	;;
esac
case "$timeout_value" in
'' | 0 | *[!0-9]*)
	echo "observer-log-proxy: OBSERVER_LOG_PROXY_STREAM_TIMEOUT must be a positive integer followed by s, m, h, or d" >&2
	exit 1
	;;
esac
if [ "${#timeout_value}" -gt 6 ]; then
	echo "observer-log-proxy: OBSERVER_LOG_PROXY_STREAM_TIMEOUT is unreasonably large" >&2
	exit 1
fi

client_timeouts="$(grep -c '^    timeout client 10m$' "$template" || true)"
server_timeouts="$(grep -c '^    timeout server 10m$' "$template" || true)"
if [ "$client_timeouts" != 1 ] || [ "$server_timeouts" != 1 ]; then
	echo "observer-log-proxy: pinned socket-proxy timeout template no longer matches the reviewed configuration" >&2
	exit 1
fi

if [ "${DISABLE_IPV6:-0}" = 1 ]; then
	bind_protocol=':2375'
else
	bind_protocol='[::]:2375 v4v6'
fi

mkdir -p /run/haproxy
sed \
	-e "s/@@BIND_PROTO@@/${bind_protocol}/g" \
	-e "s/^    timeout client 10m$/    timeout client ${stream_timeout}/" \
	-e "s/^    timeout server 10m$/    timeout server ${stream_timeout}/" \
	"$template" >"$runtime_config"
grep -q "^    timeout client ${stream_timeout}$" "$runtime_config"
grep -q "^    timeout server ${stream_timeout}$" "$runtime_config"

echo "observer-log-proxy: Docker stream idle timeout=${stream_timeout}"
if [ "${OBSERVER_LOG_PROXY_CONFIG_CHECK_ONLY:-0}" = 1 ]; then
	exec /usr/sbin/haproxy -c -f "$runtime_config"
fi
exec /usr/sbin/haproxy -f "$runtime_config" -W -db
