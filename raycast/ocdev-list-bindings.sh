#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title List Bindings
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon :electric_plug:
# @raycast.packageName ocdev

# Documentation:
# @raycast.description List all dynamic port bindings across ocdev containers
# @raycast.author pigmej

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_ocdev-config.sh"

ocdev_ssh bindings
