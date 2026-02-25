# Raycast Script Commands for ocdev

Manage ocdev container port bindings from [Raycast](https://raycast.com) on your Mac via SSH.

## Setup

1. Edit `_ocdev-config.sh` and set `SSH_HOST` to your `~/.ssh/config` alias for the Incus server
2. Run `./_update-containers.sh` to populate the container dropdown from the live server
3. In Raycast: Preferences > Extensions > `+` > Add Script Directory > select this folder

## Commands

| Command | Description |
|---------|-------------|
| **List Containers** | Show all ocdev containers with status and SSH port |
| **List Bindings** | Show all dynamic port bindings across containers |
| **Bind Port** | Add a new port binding (supports `5173` or `3000:8080` syntax) |
| **Unbind Port** | Remove a port binding |
| **Rebind Port** | Move a port binding to a different container |
| **Rebind 5173** | Quick-action: rebind port 5173 to a selected container |
| **Rebind 19432** | Quick-action: rebind port 19432 to a selected container |

## Updating container list

Container names are stored as static dropdown data in each script (Raycast limitation).
After creating or deleting containers, run:

```
./_update-containers.sh
```

This SSHs to the server, fetches current containers, and rewrites the dropdown metadata in all scripts.

## Requirements

- SSH key-based auth to the server (scripts use `BatchMode=yes`)
- `ocdev` installed at `~/.local/bin/ocdev` on the server
