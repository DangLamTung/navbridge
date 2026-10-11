#!/usr/bin/env bash
# ==============================================================================
# NavBridge - Automated Monthly Crawl & Offline Data Update
#
# Automates the entire end-to-end dataset pipeline:
#   1. WME Smart Diff: Scan active tiles (~3,500 tiles), detect new/modified
#      cameras, traffic signs & speed limits, diff vs previous month.
#   2. WME Decoders: extract_mapcomments -> extract_compare -> build_mod_db_v2
#   3. VietMap KC01: Download latest monthly edog_data.txt & merge cameras/signs
#   4. Phạt nguội: Incremental crawl & geocode from official police lists
#   5. Deduplication: Spatial dedup (VietMap > WME > Police > OSM)
#   6. GraphHopper: (Optional) Build offline routing graph (.ghz)
#   7. Packaging: Generate manifest.json & version.json bundle in update/latest/
#   8. Remote Sync: Git push to repository & upload to GitHub Releases / Google Drive
#
# Usage:
#   ./tools/auto_update.sh                    # Standard monthly update
#   ./tools/auto_update.sh --cron             # Unattended monthly cron mode (logs to file)
#   ./tools/auto_update.sh --wme-type cameras # Only diff cameras from WME
#   ./tools/auto_update.sh --no-wme           # Skip WME diff crawl (rebuild from cache)
#   ./tools/auto_update.sh --crawl-police     # Force full re-crawl of police lists
#   ./tools/auto_update.sh --push             # Auto-commit & push updated datasets to git
#   ./tools/auto_update.sh --upload github    # Push release bundle to GitHub Releases
#   ./tools/auto_update.sh --graph saigon     # Build GraphHopper graph for region
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

LOG_DIR="${REPO_DIR}/update"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/auto_update.log"

export PYTHONUNBUFFERED=1

# Log to file in cron or non-interactive mode
if [ "${1:-}" = "--cron" ] || [ ! -t 1 ]; then
    exec >> >(tee -a "${LOG_FILE}") 2>&1
fi

echo "=============================================================================="
echo " [NavBridge Auto-Update] Started at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " Working directory: ${REPO_DIR}"
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

PYTHON_ARGS=("--all-sources")
BUILD_GRAPH_REGION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --crawl-wme)
            PYTHON_ARGS+=("--crawl-wme")
            shift
            ;;
        --no-wme|--no-crawl-wme)
            PYTHON_ARGS+=("--no-crawl-wme")
            shift
            ;;
        --wme-type)
            PYTHON_ARGS+=("--wme-type" "$2")
            shift 2
            ;;
        --crawl|--crawl-police)
            PYTHON_ARGS+=("--crawl-police")
            shift
            ;;
        --budget)
            PYTHON_ARGS+=("--budget" "$2")
            shift 2
            ;;
        --force)
            PYTHON_ARGS+=("--force")
            shift
            ;;
        --push|--git-push)
            PYTHON_ARGS+=("--git-push")
            shift
            ;;
        --upload)
            PYTHON_ARGS+=("--upload" "$2")
            shift 2
            ;;
        --graph|--build-graph)
            BUILD_GRAPH_REGION="${2:-saigon}"
            shift 2
            ;;
        --cron)
            # Handled above
            shift
            ;;
        *)
            PYTHON_ARGS+=("$1")
            shift
            ;;
    esac
done

# If UPLOAD_TARGET is set in env and not already in args
if [ -n "${UPLOAD_TARGET:-}" ]; then
    if [[ ! " ${PYTHON_ARGS[*]} " =~ " --upload " ]]; then
        PYTHON_ARGS+=("--upload" "${UPLOAD_TARGET}")
    fi
fi

# Step 0: Check WME authentication profile
echo -e "\n--> [Step 0] Checking WME session credentials..."
if [ -d "$HOME/.wme-profile" ]; then
    echo "[wme] Using persistent Chrome profile: $HOME/.wme-profile"
else
    echo "[wme] Notice: $HOME/.wme-profile not found. Running wme_auth_notifier..."
    if [ -f "tools/wme_auth_notifier.py" ]; then
        "${PYTHON}" tools/wme_auth_notifier.py || true
    fi
fi

# Step 1: Optional GraphHopper routing graph build
if [ -n "${BUILD_GRAPH_REGION}" ]; then
    echo -e "\n--> [Step 1] Building GraphHopper graph for region: ${BUILD_GRAPH_REGION}..."
    "${PYTHON}" tools/update_server.py --build-graph "${BUILD_GRAPH_REGION}"
fi

# Step 2: Run the full all-sources monthly pipeline
echo -e "\n--> [Step 2] Executing monthly update pipeline (WME diff + KC01 + Phạt Nguội + Dedup + Package)..."
"${PYTHON}" tools/update_server.py "${PYTHON_ARGS[@]}"

echo -e "\n=============================================================================="
echo " [NavBridge Auto-Update] Finished successfully at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " Releases: ${REPO_DIR}/update/releases/"
echo " Latest:   ${REPO_DIR}/update/latest/"
if [ -f "${REPO_DIR}/update/latest/version.json" ]; then
    echo " Latest version payload:"
    cat "${REPO_DIR}/update/latest/version.json"
    echo ""
fi
echo "=============================================================================="
