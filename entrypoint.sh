#!/usr/bin/env bash
set -euo pipefail

YOMIKO_ENABLE_WEB_VALUE="${YOMIKO_ENABLE_WEB:-true}"
case "${YOMIKO_ENABLE_WEB_VALUE}" in
true | false) ;;
*)
	echo "ERROR: YOMIKO_ENABLE_WEB must be 'true' or 'false'." >&2
	exit 1
	;;
esac

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/db.sh" ]] && source "${HOME}/lib/db.sh"
db_init

if [[ "${YOMIKO_ENABLE_WEB_VALUE}" == "true" ]]; then
	printf 'Starting Yomiko web server on 0.0.0.0:80.\n'
	"${CRONJOB_DIR}/cron-simulate" &
	exec httpd -f -v -p '0.0.0.0:80' -h "${HOME}/web" -c "${HOME}/server/httpd.conf"
else
	printf 'Starting Yomiko in CLI-only mode.\n'
	exec "${CRONJOB_DIR}/cron-simulate"
fi
