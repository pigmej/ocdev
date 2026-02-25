#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Bind Port
# @raycast.mode compact

# Optional parameters:
# @raycast.icon :heavy_plus_sign:
# @raycast.packageName ocdev
# @raycast.argument1 { "type": "dropdown", "placeholder": "container", "data": [{"title": "myproject", "value": "myproject"}, {"title": "myproject-2", "value": "myproject-2"}] }
# @raycast.argument2 { "type": "text", "placeholder": "port or cport:hport" }

# Documentation:
# @raycast.description Bind a port to an ocdev container (e.g. 5173 or 3000:8080)
# @raycast.author pigmej

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_ocdev-config.sh"

ocdev_ssh bind -n="$1" -p="$2"
