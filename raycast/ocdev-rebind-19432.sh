#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Rebind 19432
# @raycast.mode compact

# Optional parameters:
# @raycast.icon :repeat:
# @raycast.packageName ocdev
# @raycast.argument1 { "type": "dropdown", "placeholder": "container", "data": [{"title": "myproject", "value": "myproject"}, {"title": "myproject-2", "value": "myproject-2"}] }

# Documentation:
# @raycast.description Rebind port 19432 to a different ocdev container
# @raycast.author pigmej

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_ocdev-config.sh"

ocdev_ssh rebind -n="$1" -p=19432
