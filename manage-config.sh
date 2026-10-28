#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${STACK_DIR:-${SCRIPT_DIR}}"
# shellcheck source=lib/deploy-common.sh
source "${SCRIPT_DIR}/lib/deploy-common.sh"

manage_main "$@"
