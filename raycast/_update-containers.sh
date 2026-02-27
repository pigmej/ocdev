#!/bin/bash
# Updates the container dropdown data in all Raycast ocdev scripts.
# Run this after creating or deleting containers.
#
# Usage: ./_update-containers.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_ocdev-config.sh"

echo "Fetching containers from ${SSH_HOST}..."

# Get container names from ocdev list (skip header line, extract first column)
containers=$(ocdev_ssh list | awk 'NR > 1 { print $1 }' | sort)

if [[ -z "$containers" ]]; then
  echo "No containers found. Aborting."
  exit 1
fi

# Build the JSON dropdown data array
json_items=()
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  safe_name=${name//\\/\\\\}
  safe_name=${safe_name//\"/\\\"}
  json_items+=("{\"title\": \"${safe_name}\", \"value\": \"${safe_name}\"}")
done <<< "$containers"

# Join with ", "
dropdown_data=$(IFS=", "; echo "${json_items[*]}")

echo "Found containers: $(echo "$containers" | tr '\n' ' ')"
echo "Dropdown JSON: [${dropdown_data}]"
echo ""

# Pattern to match existing dropdown argument lines for container selection
pattern='@raycast\.argument[0-9]+.*"type"[[:space:]]*:[[:space:]]*"dropdown".*"placeholder"[[:space:]]*:[[:space:]]*"[^\"]*container[^\"]*"'

# Update all ocdev scripts in this directory
updated=0
for script in "${SCRIPT_DIR}"/ocdev-*.sh; do
  [[ ! -f "$script" ]] && continue

  if grep -qiE "$pattern" "$script"; then
    # Extract the argument number from the matched dropdown line
    match_line=$(grep -im1 -E "$pattern" "$script")
    argnum=$(grep -oE '@raycast\.argument[0-9]+' <<< "$match_line" | grep -oE '[0-9]+')

    # Build replacement line
    new_line="# @raycast.argument${argnum} { \"type\": \"dropdown\", \"placeholder\": \"container\", \"data\": [${dropdown_data}] }"

    # Escape replacement string for sed
    escaped_new_line=${new_line//\\/\\\\}
    escaped_new_line=${escaped_new_line//&/\\&}
    escaped_new_line=${escaped_new_line//|/\\|}

    # Replace the matching line
    sed -i.bak -E "s|^# @raycast\.argument${argnum} .*\"type\"[[:space:]]*:[[:space:]]*\"dropdown\".*|${escaped_new_line}|" "$script"
    rm -f "${script}.bak"

    echo "Updated: $(basename "$script")"
    updated=$((updated + 1))
  fi
done

echo ""
echo "Done. Updated ${updated} script(s)."
