#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title List Containers
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon :desktop_computer:
# @raycast.packageName ocdev

# Documentation:
# @raycast.description List all ocdev containers with status and SSH port
# @raycast.author pigmej

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_ocdev-config.sh"

ocdev_ssh list
