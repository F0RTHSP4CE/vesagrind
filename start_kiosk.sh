#!/usr/bin/env bash

set -uo pipefail

# Absolute path to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the local HTML file
INDEX_FILE="${SCRIPT_DIR}/index.html"

# Window class name for the Chromium kiosk window (useful for WM rules etc.)
WINDOW_CLASS="ChromiumKiosk"

# PID file used to share the Chromium PID between background functions
CHROMIUM_PID_FILE="${SCRIPT_DIR}/.chromium_kiosk.pid"

# Prefer `chromium` but fall back to `chromium-browser`
if command -v chromium >/dev/null 2>&1; then
    BROWSER_CMD="chromium"
elif command -v chromium-browser >/dev/null 2>&1; then
    BROWSER_CMD="chromium-browser"
else
    echo "Chromium is not installed (neither 'chromium' nor 'chromium-browser' found in PATH)." >&2
    exit 1
fi

PULL_INTERVAL_SECONDS=600
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
    # Try PID from variable first
    if [[ -n "${CHROMIUM_PID}" ]] && kill -0 "${CHROMIUM_PID}" 2>/dev/null; then
        kill "${CHROMIUM_PID}" 2>/dev/null || true
    fi
    # Also try PID from file (may be more up to date inside background loops)
    if [[ -f "${CHROMIUM_PID_FILE}" ]]; then
        pid_from_file="$(cat "${CHROMIUM_PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${pid_from_file}" ]] && kill -0 "${pid_from_file}" 2>/dev/null; then
            kill "${pid_from_file}" 2>/dev/null || true
        fi
        rm -f "${CHROMIUM_PID_FILE}" 2>/dev/null || true
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
            # Capture commit hash before pull to detect real changes
            before_hash="$(git rev-parse HEAD 2>/dev/null || echo "")" &&
            git pull --rebase --autostash >/dev/null 2>&1 || true &&
            after_hash="$(git rev-parse HEAD 2>/dev/null || echo "")" &&
            if [[ -n "${before_hash}" && -n "${after_hash}" && "${before_hash}" != "${after_hash}" ]]; then
                # Touch the index file so the watcher notices a change
                touch "${INDEX_FILE}" 2>/dev/null || true
            fi
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
                echo "${CHROMIUM_PID}" > "${CHROMIUM_PID_FILE}" 2>/dev/null || true
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
                local pid_to_kill=""
                if [[ -f "${CHROMIUM_PID_FILE}" ]]; then
                    pid_to_kill="$(cat "${CHROMIUM_PID_FILE}" 2>/dev/null || true)"
                else
                    pid_to_kill="${CHROMIUM_PID:-}"
                fi

                if [[ -n "${pid_to_kill}" ]] && kill -0 "${pid_to_kill}" 2>/dev/null; then
                    kill "${pid_to_kill}" 2>/dev/null || true
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
