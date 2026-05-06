#!/usr/bin/env bash
set -euo pipefail

QBT_URL="${QBT_URL:-http://localhost:8090}"

for arg in "$@"; do
    case "$arg" in
        magnet:*|http://*|https://*)
            curl -fsS -X POST "$QBT_URL/api/v2/torrents/add" --data-urlencode "urls=$arg" >/dev/null
            ;;
        file://*)
            path="${arg#file://}"
            path="$(printf '%b' "${path//%/\\x}")"
            curl -fsS -X POST "$QBT_URL/api/v2/torrents/add" -F "torrents=@${path}" >/dev/null
            ;;
        /*)
            curl -fsS -X POST "$QBT_URL/api/v2/torrents/add" -F "torrents=@${arg}" >/dev/null
            ;;
        *)
            echo "qbt-add: unsupported argument: $arg" >&2
            exit 2
            ;;
    esac
done
