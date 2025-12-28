#!/usr/bin/env bash

set -uo pipefail

# Absolute path to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the local HTML file
INDEX_FILE="${SCRIPT_DIR}/index.html"

# Window class name for the Chromium kiosk window (useful for WM rules etc.)
WINDOW_CLASS="ChromiumKiosk"

# Prefer `chromium` but fall back to `chromium-browser`
if command -v chromium >/dev/null 2>&1; then
    BROWSER_CMD="chromium"
elif command -v chromium-browser >/dev/null 2>&1; then
    BROWSER_CMD="chromium-browser"
else
    echo "Chromium is not installed (neither 'chromium' nor 'chromium-browser' found in PATH)." >&2
    exit 1
fi

PULL_INTERVAL_SECONDS=60
WATCH_INTERVAL_SECONDS=2

PULL_PID=""
WATCH_PID=""
CHROMIUM_PID=""
BROWSER_LOOP_PID=""

cleanup() {
    if [[ -n "${PULL_PID}" ]] && kill -0 "${PULL_PID}" 2>/dev/null; then
        kill "${PULL_PID}" 2>/dev/null || true
    fi
    if [[ -n "${WATCH_PID}" ]] && kill -0 "${WATCH_PID}" 2>/dev/null; then
        kill "${WATCH_PID}" 2>/dev/null || true
    fi
    if [[ -n "${CHROMIUM_PID}" ]] && kill -0 "${CHROMIUM_PID}" 2>/dev/null; then
        kill "${CHROMIUM_PID}" 2>/dev/null || true
    fi
    if [[ -n "${BROWSER_LOOP_PID}" ]] && kill -0 "${BROWSER_LOOP_PID}" 2>/dev/null; then
        kill "${BROWSER_LOOP_PID}" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

git_auto_pull() {
    while true; do
        (
            cd "${SCRIPT_DIR}" &&
            git pull --rebase --autostash >/dev/null 2>&1 || true
        )
        sleep "${PULL_INTERVAL_SECONDS}"
    done
}

browser_loop() {
    while true; do
        "${BROWSER_CMD}" \
          --class="${WINDOW_CLASS}" \
          --kiosk \
          --incognito \
          --noerrdialogs \
          --disable-infobars \
          --overscroll-history-navigation=0 \
          "file://${INDEX_FILE}" &

        CHROMIUM_PID=$!
        # Wait for Chromium to exit (either manually closed or killed by watcher)
        wait "${CHROMIUM_PID}" || true

        # Small delay before relaunching
        sleep 1
    done
}

watch_index_file() {
    local last_mtime=""
    if [[ -f "${INDEX_FILE}" ]]; then
        last_mtime="$(stat -c %Y "${INDEX_FILE}")"
    fi

    while true; do
        if [[ -f "${INDEX_FILE}" ]]; then
            local current_mtime
            current_mtime="$(stat -c %Y "${INDEX_FILE}")"
            if [[ -n "${last_mtime}" && "${current_mtime}" != "${last_mtime}" ]]; then
                last_mtime="${current_mtime}"
                # Restart Chromium by killing the current process; the loop will relaunch it
                if [[ -n "${CHROMIUM_PID}" ]] && kill -0 "${CHROMIUM_PID}" 2>/dev/null; then
                    kill "${CHROMIUM_PID}" 2>/dev/null || true
                fi
            fi
        fi
        sleep "${WATCH_INTERVAL_SECONDS}"
    done
}

git_auto_pull &
PULL_PID=$!

watch_index_file &
WATCH_PID=$!

browser_loop &
BROWSER_LOOP_PID=$!

wait "${BROWSER_LOOP_PID}"
