#!/usr/bin/env bash
activate_url() {
  local url
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then url="$1"; else url="$(cat - 2>/dev/null)"; fi
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  printf '\nДля активации сервиса перейдите по ссылке %s\n\n' "$url"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o - -t UTF8 "$url" 2>/dev/null || qrencode -o - -t ANSIUTF8 "$url" 2>/dev/null
    printf '\n'
  fi
}
activate_url https://shtampmaster.ru
