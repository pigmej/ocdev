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
containers=$(ssh $SSH_OPTS "$SSH_HOST" ~/.local/bin/ocdev list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort)

if [[ -z "$containers" ]]; then
  echo "No containers found. Aborting."
  exit 1
fi

# Build the JSON dropdown data array
json_items=()
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  json_items+=("{\"title\": \"${name}\", \"value\": \"${name}\"}")
done <<< "$containers"

# Join with ", "
dropdown_data=$(IFS=", "; echo "${json_items[*]}")

echo "Found containers: $(echo "$containers" | tr '\n' ' ')"
echo "Dropdown JSON: [${dropdown_data}]"
echo ""

# Pattern to match existing dropdown argument lines
# Matches lines containing @raycast.argument that have "dropdown" and "container"
pattern='@raycast\.argument[0-9].*"dropdown".*"container"'

# Update all ocdev scripts in this directory
updated=0
for script in "${SCRIPT_DIR}"/ocdev-*.sh; do
  [[ ! -f "$script" ]] && continue

  if grep -qE "$pattern" "$script"; then
    # Extract the argument number and rebuild the line
    argnum=$(grep -oE '@raycast\.argument[0-9]' "$script" | grep -oE '[0-9]' | head -1)

    # Build replacement line
    new_line="# @raycast.argument${argnum} { \"type\": \"dropdown\", \"placeholder\": \"container\", \"data\": [${dropdown_data}] }"

    # Replace the matching line
    sed -i.bak -E "s|^# @raycast\.argument${argnum} .*\"dropdown\".*\"container\".*|${new_line}|" "$script"
    rm -f "${script}.bak"

    echo "Updated: $(basename "$script")"
    updated=$((updated + 1))
  fi
done

echo ""
echo "Done. Updated ${updated} script(s)."
