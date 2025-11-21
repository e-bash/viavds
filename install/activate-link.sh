#!/usr/bin/env bash


# -----------------------------------------------------------------------------
# activate_url - функция для вставки в инсталлятор
#  - принимает URL первым аргументом или читает из stdin
#  - пытается скопировать URL в локальный буфер клиента (OSC52 primary)
#  - fallback: wl-copy / xclip / xsel / pbcopy (копия на стороне машины, где выполняется)
#  - делает молчаливую попытку открыть браузер (bonus, не сообщаем об этом пользователю)
#  - при успехе возвращает 0 и печатает только сообщение "Ссылка скопирована в буфер"
#  - при неуспехе возвращает ненулевой код и печатает URL (для ручной копии)
# -----------------------------------------------------------------------------
activate_url() {
  local url

  # Read URL from argument or stdin
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    url="$1"
  else
    url="$(cat - 2>/dev/null)"
  fi

  # Trim leading/trailing whitespace (POSIX-safe)
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"

  if [ -z "$url" ]; then
    printf '%s\n' "activate_url: ошибка — URL не передан" >&2
    return 2
  fi

  # Helper: command exists
  _have_cmd() { command -v "$1" >/dev/null 2>&1; }

  # Helper: portable base64 without newline wrapping
  _b64() {
    if _have_cmd base64; then
      if base64 --help 2>&1 | grep -q -- '-w'; then
        printf '%s' "$1" | base64 -w 0
      else
        printf '%s' "$1" | base64 | tr -d '\n'
      fi
    elif _have_cmd openssl; then
      printf '%s' "$1" | openssl base64 | tr -d '\n'
    else
      return 1
    fi
  }

  # Send OSC52 sequence to terminal (attempt to copy to local clipboard over SSH)
  _send_osc52() {
    local data="$1"
    local b64
    if ! b64="$(_b64 "$data")"; then
      return 1
    fi
    # OSC52: ESC ] 52 ; c ; <base64> BEL
    printf '\033]52;c;%s\a' "$b64"
    return 0
  }

  # Try copying to clipboard on the machine where script runs (GUI server-side)
  _copy_on_server_side() {
    local data="$1"
    if _have_cmd wl-copy; then
      printf '%s' "$data" | wl-copy && return 0
    fi
    if _have_cmd xclip; then
      printf '%s' "$data" | xclip -selection clipboard && return 0
    fi
    if _have_cmd xsel; then
      printf '%s' "$data" | xsel --clipboard --input && return 0
    fi
    if _have_cmd pbcopy; then
      printf '%s' "$data" | pbcopy && return 0
    fi
    return 1
  }

  # Detect PuTTY by TERM
  _is_putty() {
    case "$TERM" in
      putty*|putty-*) return 0 ;;
      *) return 1 ;;
    esac
  }

  # Attempt to silently open browser (bonus). We do this after copying,
  # but we do NOT report success of this action to the user.
  _silent_open_browser() {
    local u="$1"
    # If on macOS server (unlikely) use open
    if [ "$(uname -s)" = "Darwin" ] && _have_cmd open; then
      # run in background, redirect output
      open "$u" >/dev/null 2>&1 &
      return 0
    fi

    # If DISPLAY or WAYLAND set (remote X11/Wayland available) try xdg-open
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${XDG_RUNTIME_DIR:-}" ]; then
      if _have_cmd xdg-open; then
        nohup xdg-open "$u" >/dev/null 2>&1 & disown 2>/dev/null || true
        return 0
      elif _have_cmd gnome-open; then
        nohup gnome-open "$u" >/dev/null 2>&1 & disown 2>/dev/null || true
        return 0
      fi
    fi

    # Otherwise do not attempt anything (headless). Return non-zero harmlessly.
    return 1
  }

  # -----------------------
  # Try copying (priority: OSC52 -> server-side clipboard -> fail)
  # -----------------------
  local copied=0
  local used_method="none"

  # If stdout is terminal, try OSC52 first (targets client's clipboard over SSH)
  if [ -t 1 ]; then
    # send OSC52 (ignore failures)
    if _send_osc52 "$url" >/dev/null 2>&1; then
      copied=1
      used_method="osc52"
    fi
  fi

  # If OSC52 didn't succeed, try server-side clipboard utilities
  if [ "$copied" -eq 0 ]; then
    if _copy_on_server_side "$url" >/dev/null 2>&1; then
      copied=1
      used_method="server-clipboard"
    fi
  fi

  # As requested: always attempt to open browser silently (bonus).
  # Do this regardless of copy result (but after attempts to copy).
  # We don't report the outcome of opening to user.
  _silent_open_browser "$url" >/dev/null 2>&1 || true

  # -----------------------
  # Output to user (only about copy status and helpful hints)
  # -----------------------
  printf '\n%s\n' "=== Activation link ==="
  printf '%s\n\n' "$url"

  if [ "$copied" -eq 1 ]; then
    # If PuTTY detected, OSC52 might be blocked in client — give hint.
    if _is_putty; then
      # If we used osc52 and PuTTY detected, still mention PuTTY caveat.
      if [ "$used_method" = "osc52" ]; then
        cat <<'MSG'
✓ Ссылка была отправлена в буфер локального терминала (OSC52).
⚠ Обнаружен PuTTY: по умолчанию PuTTY может НЕ ПРИНИМАТЬ OSC52.
  Если вставка (Ctrl+V) не сработала, включите в PuTTY:
    Window → Selection → "Allow terminal to access clipboard" (или похожую опцию)
MSG
      else
        # copied by server-side tools but client is PuTTY — still warn that future OSC52 may not work
        cat <<'MSG'
✓ Ссылка записана в clipboard на стороне сервера.
⚠ Вы подключены через PuTTY: автоматическое копирование в локальный буфер может не работать.
  Рекомендуется в настройках PuTTY включить поддержку OSC52 для более плавного UX.
MSG
      fi
    else
      # Normal case (not PuTTY) — tell only that it's copied
      printf '✓ Ссылка скопирована в буфер обмена.\n'
    fi
  else
    # Not copied automatically — print hint and URL already printed above
    printf '✖ Не удалось автоматически скопировать ссылку в буфер.\n'
    printf '  Скопируйте её вручную из строки выше (Ctrl/Cmd+V).\n'
  fi

  # Optional: show QR if qrencode present (useful for quick phone activation)
  if _have_cmd qrencode; then
    printf '\n%s\n' "QR (сканируйте телефоном):"
    # Try UTF8 rendering; fallback to ANSIUTF8
    if qrencode -o - -t UTF8 "$url" 2>/dev/null; then
      true
    else
      qrencode -o - -t ANSIUTF8 "$url" 2>/dev/null || true
    fi
    printf '\n'
  else
    # Quiet hint only if copy succeeded (don't spam if everything failed)
    if [ "$copied" -eq 1 ]; then
      printf '\n%s\n' "ℹ Чтобы вывести QR прямо в терминале, установите qrencode (Debian/Ubuntu):"
      printf '    sudo apt-get update && sudo apt-get install -y qrencode\n\n'
    fi
  fi

  # Return success if copied, else non-zero
  if [ "$copied" -eq 1 ]; then
    return 0
  else
    return 3
  fi
}


activate_url https://shtampmaster.ru