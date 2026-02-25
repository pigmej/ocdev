#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Unbind Port
# @raycast.mode compact

# Optional parameters:
# @raycast.icon :heavy_minus_sign:
# @raycast.packageName ocdev
# @raycast.argument1 { "type": "dropdown", "placeholder": "container", "data": [{"title": "myproject", "value": "myproject"}, {"title": "myproject-2", "value": "myproject-2"}] }
# @raycast.argument2 { "type": "text", "placeholder": "host port" }

# Documentation:
# @raycast.description Remove a dynamic port binding from an ocdev container
# @raycast.author pigmej

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_ocdev-config.sh"

ocdev_ssh unbind -n="$1" -p="$2"
