#!/usr/bin/env sh

set -e

ROMM_BASE_PATH=${ROMM_BASE_PATH:-/romm}

mkdir -p /usr/share/nginx/html/assets/romm

for subfolder in assets resources; do
	if [ -L "/usr/share/nginx/html/assets/romm/${subfolder}" ]; then
		target=$(readlink "/usr/share/nginx/html/assets/romm/${subfolder}")
		if [ "${target}" != "${ROMM_BASE_PATH}/${subfolder}" ]; then
			rm "/usr/share/nginx/html/assets/romm/${subfolder}"
			ln -s "${ROMM_BASE_PATH}/${subfolder}" "/usr/share/nginx/html/assets/romm/${subfolder}"
		fi
	elif [ ! -e "/usr/share/nginx/html/assets/romm/${subfolder}" ]; then
		ln -s "${ROMM_BASE_PATH}/${subfolder}" "/usr/share/nginx/html/assets/romm/${subfolder}"
	fi
done

exec "$@"
