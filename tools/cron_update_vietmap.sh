#!/usr/bin/env bash
# ==============================================================================
# NavBridge - Monthly Cron Update Wrapper
# Delegated to auto_update.sh for unified dataset build & publishing.
#
# Crontab example (runs on 1st of every month at 03:00):
#   0 3 1 * * cd /Users/tungdl/Documents/Eink/navbridge && ./tools/cron_update_vietmap.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

exec "${SCRIPT_DIR}/auto_update.sh" --cron "$@"
