#!/usr/bin/env bash
# ==============================================================================
# NavBridge - Monthly VietMap KC01 Update Cron Script
#
# Designed to be invoked via:
#   * crontab (e.g. `0 3 1 * * /path/to/tools/cron_update_vietmap.sh`)
#   * systemd timer
#   * manual terminal run: `./tools/cron_update_vietmap.sh [--force] [--push]`
#
# Environment Variables:
#   AUTO_GIT_PUSH=1   Automatically git add, commit, and push if data updated
#   LOG_TO_FILE=1     Redirect stdout & stderr to update/cron_vietmap.log (default: 1 in cron/non-tty)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

LOG_DIR="${REPO_DIR}/update"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/cron_vietmap.log"

export PYTHONUNBUFFERED=1

# If stdout is not a terminal (e.g. executed by cron), log to LOG_FILE as well
if [ ! -t 1 ] || [ "${LOG_TO_FILE:-0}" = "1" ]; then
    exec >> >(tee -a "${LOG_FILE}") 2>&1
fi

echo "=============================================================================="
echo " [VietMap Cron] Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " Repo: ${REPO_DIR}"
echo "=============================================================================="

# Resolve python interpreter
PYTHON="python3"
if [ -x "${REPO_DIR}/.venv/bin/python3" ]; then
    PYTHON="${REPO_DIR}/.venv/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON="python3"
else
    echo "ERROR: python3 not found on PATH." >&2
    exit 1
fi

DO_PUSH=0
PYTHON_ARGS=("--vietmap-only")

for arg in "$@"; do
    case "$arg" in
        --force)
            PYTHON_ARGS+=("--force")
            ;;
        --check)
            PYTHON_ARGS=("--check-only")
            ;;
        --push)
            DO_PUSH=1
            ;;
        *)
            PYTHON_ARGS+=("$arg")
            ;;
    esac
done

# Run the update server VietMap pipeline
"${PYTHON}" tools/update_server.py "${PYTHON_ARGS[@]}"

# If git push requested and there are changes in assets or update directories
if [ "${AUTO_GIT_PUSH:-0}" = "1" ] || [ "${DO_PUSH}" = "1" ]; then
    CHANGES=$(git status --porcelain assets/offline_map update/ 2>/dev/null || true)
    if [ -n "${CHANGES}" ]; then
        TODAY=$(date '+%Y-%m-%d')
        echo "[VietMap Cron] Detected changes. Staging and committing..."
        git add assets/offline_map update/
        git commit -m "chore(data): auto-update VietMap KC01 dataset (${TODAY})" || true
        echo "[VietMap Cron] Pushing to remote..."
        git push origin HEAD || echo "[VietMap Cron] WARNING: git push failed." >&2
    else
        echo "[VietMap Cron] No repository changes to commit."
    fi
fi

echo "=============================================================================="
echo " [VietMap Cron] Finished successfully: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "=============================================================================="
