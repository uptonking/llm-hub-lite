#!/bin/bash
# Upstream's WORKER_AND_APP supervisor polls child liveness with
# `while kill -0 ...; do sleep 1; done`, forking a fresh process every
# second forever. On a 1-core VPS that churn alone costs roughly a tenth
# of the node's CPU. This is the same supervisor with the polling
# replaced by an interruptible wait: it wakes only when a child exits or
# a stop signal arrives.
set -u

if [ "$#" -gt 0 ]; then
	exec "$@"
fi

export AP_CONTAINER_TYPE="${AP_CONTAINER_TYPE:-WORKER_AND_APP}"
export AP_PORT="${AP_PORT:-80}"

# Mirror the upstream worker-token bootstrap so the worker authenticates
# to the API with the same generated token both processes inherit.
if [ -z "${AP_WORKER_TOKEN:-}" ] && [ -n "${AP_JWT_SECRET:-}" ]; then
	export AP_WORKER_TOKEN
	AP_WORKER_TOKEN=$(node -e "
		const jwt = require('jsonwebtoken');
		const crypto = require('crypto');
		const token = jwt.sign(
			{ id: crypto.randomUUID(), type: 'WORKER' },
			process.env.AP_JWT_SECRET,
			{ expiresIn: '100y', keyid: '1', algorithm: 'HS256', issuer: 'activepieces' }
		);
		process.stdout.write(token);
	")
fi

APP_SCRIPT="packages/server/api/dist/src/bootstrap.js"
WORKER_SCRIPT="packages/server/worker/dist/src/bootstrap.js"

AP_CONTAINER_TYPE=APP node --enable-source-maps "$APP_SCRIPT" &
app_pid=$!
node --enable-source-maps "$WORKER_SCRIPT" &
worker_pid=$!

shutdown() { kill "$app_pid" "$worker_pid" 2>/dev/null || true; }
trap shutdown TERM INT

wait -n "$app_pid" "$worker_pid"
shutdown
wait
exit 1
