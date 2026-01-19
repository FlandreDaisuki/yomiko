#!/usr/bin/env bash

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/db.sh" ]] && source "${HOME}/lib/db.sh"
db_init

httpd -f -v -p '0.0.0.0:80' -h "${HOME}/web" -c "${HOME}/server/httpd.conf"
