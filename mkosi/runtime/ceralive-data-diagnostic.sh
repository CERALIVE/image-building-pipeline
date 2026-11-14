#!/usr/bin/env bash
# One volatile status document, shared by the console and bounded inetd handler.
set -euo pipefail
export LC_ALL=C
state=${CERALIVE_ATTENTION_OUTPUT:-/run/ceralive/attention-status}
serve() {
  local method target version line count=0 code='200 OK' body content_type='text/html; charset=utf-8'
  IFS=' ' read -r -t 2 -n 4096 method target version || return 0
  [[ $version == HTTP/1.[01]* ]] || return 0
  while IFS= read -r -t 2 -n 4096 line; do
    [[ $line == $'\r' || -z $line ]] && break
    (( ++count < 64 )) || return 0
  done
  if [[ $method != GET && $method != HEAD ]]; then
    code='405 Method Not Allowed'; body='Read-only status page.'
  elif [[ $target == /attention/status.json && -r $state/status.json ]]; then
    body=$(cat "$state/status.json"); content_type='application/json'
  elif [[ $target != / && $target != /attention/ ]]; then
    code='404 Not Found'; body='Not found.'
  elif [[ -r $state/index.html ]]; then body=$(cat "$state/index.html")
  else code='503 Service Unavailable'; body='Startup status unavailable.'; fi
  printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src '\''none'\''; frame-ancestors '\''none'\''\r\nX-Content-Type-Options: nosniff\r\n\r\n' "$code" "$content_type" "${#body}"
  [[ $method == HEAD ]] || printf '%s' "$body"
}
serve
