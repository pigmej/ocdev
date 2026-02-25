# Shared configuration for ocdev Raycast script commands
# Edit SSH_HOST to match your ~/.ssh/config alias for the Incus server

SSH_HOST="your-ssh-alias"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5"

ocdev_ssh() {
  local output
  if ! output=$(ssh $SSH_OPTS "$SSH_HOST" ~/.local/bin/ocdev "$@" 2>&1); then
    if [[ "$output" == *"Connection refused"* ]] || [[ "$output" == *"Connection timed out"* ]] || [[ "$output" == *"Could not resolve"* ]]; then
      echo "Cannot reach ${SSH_HOST} -- check SSH config and connectivity"
      exit 1
    fi
    # Pass through ocdev's own error messages
    echo "$output"
    exit 1
  fi
  echo "$output"
}
