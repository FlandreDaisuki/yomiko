#!/usr/bin/env bash

if [[ -f "${HOME}/lib/db.sh" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/lib/db.sh"
fi

db_init

httpd -f -v -p '0.0.0.0:80' -h "${HOME}/web" -c "${HOME}/server/httpd.conf"
