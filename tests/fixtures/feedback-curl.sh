#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${MOCK_CURL_TRACE:?}"

case " $* " in
*" https://exhentai.org/mytags "*)
	printf '%s\n' 'var apiuid = 123; var apikey = "abcdef";'
	;;
*" https://s.exhentai.org/api.php "*)
	printf '200'
	;;
*)
	printf '200'
	;;
esac
