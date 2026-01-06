# ocdev - Incus Development Environment Manager

A CLI tool to manage isolated development environments using Incus system containers. Each environment comes with Docker pre-installed, SSH access, and shared host configurations.

## Features

- **Isolated dev environments** - Each container is fully isolated with its own Docker daemon
- **Non-root user** - Runs as `dev` user with matching UID, passwordless sudo available
- **SSH access** - Unique port per container (starting at 2201)
- **Shared configs** - Automatically mounts `~/.config`, `~/.opencode`, `~/.ssh`, `~/.gitconfig`
- **Docker-in-Docker** - Full Docker support via Incus nesting
- **Low overhead** - ~100-200MB RAM per container vs 512MB+ for VMs
- **Custom setup scripts** - Run post-create scripts to install additional tools

## Prerequisites

1. **Incus installed and initialized**
   ```bash
   sudo apt install incus
   sudo incus admin init
   ```

2. **User in incus-admin group**
   ```bash
   sudo usermod -aG incus-admin $USER
   # Log out and back in for group to take effect
   ```

3. **~/.local/bin in PATH**
   ```bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```

## Installation

From the repository root:

```bash
mkdir -p ~/.local/bin
ln -sf "$(pwd)/bin/ocdev" ~/.local/bin/ocdev
```

## Usage

```bash
# Create a new dev environment
ocdev create myproject
# Output: Created ocdev-myproject, SSH: ssh -p 2201 dev@localhost

# Create with a custom setup script
ocdev create myproject --post-create ~/dotfiles/dev-setup.sh

# List all environments
ocdev list

# Access via shell (direct)
ocdev shell myproject

# Access via SSH
ssh -p 2201 dev@localhost
# Or get the command:
ocdev ssh myproject

# Run Docker inside
ocdev shell myproject
docker run hello-world   # Works!

# Stop/Start
ocdev stop myproject
ocdev start myproject

# Delete when done
ocdev delete myproject

# View all port allocations
ocdev ports
```

## Commands

| Command | Description |
|---------|-------------|
| `ocdev create <name> [--post-create <script>]` | Create new dev environment |
| `ocdev list` | List all dev environments |
| `ocdev start <name>` | Start a stopped environment |
| `ocdev stop <name>` | Stop a running environment |
| `ocdev shell <name>` | Get interactive shell inside |
| `ocdev ssh <name>` | Show SSH connection info |
| `ocdev delete <name>` | Remove environment |
| `ocdev ports` | Show all port mappings |

## How It Works

1. **Incus Profile**: Creates an `ocdev` profile with Docker nesting enabled
2. **Container**: Launches Ubuntu 25.10 system container with the profile
3. **Mounts**: Binds host directories into `/home/dev/` inside container
4. **Provisioning**: Installs Docker, SSH server, git, curl
5. **Port Forwarding**: Maps unique host port to container's SSH (port 22)

## Directory Structure

```
~/.local/bin/ocdev       # Executable (or symlink)
~/.ocdev/                # Config directory
~/.ocdev/ports           # Port assignments (name:port format)
~/.ocdev/.lock           # Lock file for concurrent operations
```

## Host Directory Mounts

| Host Path | Container Path | Mode |
|-----------|----------------|------|
| `~/.config` | `/home/dev/.config` | read-write |
| `~/.opencode` | `/home/dev/.opencode` | read-write |
| `~/.ssh` | `/home/dev/.ssh` | read-only |
| `~/.gitconfig` | `/home/dev/.gitconfig` | read-only |

## Custom Setup Scripts

Run a custom script after container provisioning using `--post-create`:

```bash
ocdev create myproject --post-create ./setup.sh
```

The script runs as the `dev` user inside the container after base provisioning (Docker, SSH, git, etc. are already installed). The script has:
- Network access
- Passwordless sudo via `sudo`
- Full access to install packages, configure tools, etc.

Example setup script:

```bash
#!/bin/bash
# Install additional tools
sudo apt-get update
sudo apt-get install -y neovim tmux ripgrep

# Install Node.js via nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
source ~/.nvm/nvm.sh
nvm install 20
```

If the post-create script fails, the container is kept so you can debug:

```bash
ocdev shell myproject  # Debug what went wrong
```

## Troubleshooting

### "incus not found"
Install Incus: `sudo apt install incus`

### "User not in incus-admin group"
```bash
sudo usermod -aG incus-admin $USER
# Then log out and back in
```

### Container creation fails
Check Incus is initialized: `incus list`
If not: `sudo incus admin init`

### SSH connection refused
1. Check container is running: `ocdev list`
2. Start if stopped: `ocdev start <name>`
3. Verify port: `ocdev ssh <name>`

### Docker not working inside container
The container needs `security.nesting=true`. This is set automatically via the `ocdev` profile. If issues persist:
```bash
incus profile show ocdev
# Should show security.nesting: "true"
```
