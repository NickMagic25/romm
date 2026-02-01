#!/usr/bin/env bash

set -e

echo "Starting RomM backend entrypoint..."

export ROMM_BASE_PATH=${ROMM_BASE_PATH:-/romm}

# Set ROMM_AUTH_SECRET_KEY if not already set
if [[ -z ${ROMM_AUTH_SECRET_KEY} ]]; then
	ROMM_AUTH_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
	export ROMM_AUTH_SECRET_KEY
fi

# Define a signal handler to propagate termination signals
function handle_termination() {
	echo "Terminating child processes..."
	# trunk-ignore(shellcheck)
	kill -TERM $(jobs -p) 2>/dev/null
}

trap handle_termination SIGTERM SIGINT

# Start backend API
cd /app/backend
uv run python main.py &

# Start RQ scheduler
RQ_REDIS_HOST=${REDIS_HOST:-127.0.0.1} \
	RQ_REDIS_PORT=${REDIS_PORT:-6379} \
	RQ_REDIS_USERNAME=${REDIS_USERNAME:-""} \
	RQ_REDIS_PASSWORD=${REDIS_PASSWORD:-""} \
	RQ_REDIS_DB=${REDIS_DB:-0} \
	RQ_REDIS_SSL=${REDIS_SSL:-0} \
	rqscheduler \
	--path /app/backend \
	--pid /tmp/rq_scheduler.pid &

# Start RQ worker
if [[ -n ${REDIS_PASSWORD-} ]]; then
	REDIS_URL="redis${REDIS_SSL:+s}://${REDIS_USERNAME-}:${REDIS_PASSWORD}@${REDIS_HOST:-127.0.0.1}:${REDIS_PORT:-6379}/${REDIS_DB:-0}"
elif [[ -n ${REDIS_USERNAME-} ]]; then
	REDIS_URL="redis${REDIS_SSL:+s}://${REDIS_USERNAME}@${REDIS_HOST:-127.0.0.1}:${REDIS_PORT:-6379}/${REDIS_DB:-0}"
else
	REDIS_URL="redis${REDIS_SSL:+s}://${REDIS_HOST:-127.0.0.1}:${REDIS_PORT:-6379}/${REDIS_DB:-0}"
fi

PYTHONPATH="/app/backend:${PYTHONPATH-}" rq worker \
	--path /app/backend \
	--pid /tmp/rq_worker.pid \
	--url "${REDIS_URL}" \
	high default low &

# Start filesystem watcher
watchfiles \
	--target-type command \
	'uv run python watcher.py' \
	"${ROMM_BASE_PATH}/library" &

wait
