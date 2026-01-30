# ocdev - Incus Development Environment Manager

A CLI tool to manage isolated development environments using Incus system containers. Each environment comes with Docker pre-installed, SSH access, and shared host configurations.

This is especially useful when you need to run **complex projects requiring multiple containers locally** and switch between them quickly. The port forwarding system lets you access services across containers seamlessly, while directory mounts keep your configs and code synchronized.

## Features

- **Isolated dev environments** - Each container is fully isolated with its own Docker daemon
- **Non-root user** - Runs as `dev` user with matching UID, passwordless sudo available
- **SSH access** - Unique port per container (starting at 2200, incrementing by 10)
- **Service ports** - 10 additional forwarded ports per container for services (2300-2309, 2310-2319, etc.)
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
# Output: Container 'myproject' created (SSH: 2200, Services: 2300-2309)

# Create with a custom setup script
ocdev create myproject --post-create ~/dotfiles/dev-setup.sh

# Create from an existing container's snapshot
ocdev create myproject-clone --from-snapshot myproject/initial

# List all environments
ocdev list

# Access via shell (direct)
ocdev shell myproject

# Access via SSH
ssh -p 2200 dev@localhost
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
| `ocdev create <name> [--post-create <script>] [--from-snapshot <container/snapshot>]` | Create new dev environment |
| `ocdev list` | List all dev environments |
| `ocdev start <name>` | Start a stopped environment |
| `ocdev stop <name>` | Stop a running environment |
| `ocdev shell <name>` | Get interactive shell inside |
| `ocdev ssh <name>` | Show SSH connection info |
| `ocdev delete <name>` | Remove environment |
| `ocdev ports` | Show all port mappings |
| `ocdev bind <name> <port> [--list]` | Bind a dynamic port to a container |
| `ocdev unbind <name> <port>` | Remove a dynamic port binding |
| `ocdev rebind <name> <port>` | Move a port binding to a different container |
| `ocdev bindings` | List all dynamic port bindings across containers |

## How It Works

1. **Incus Profile**: Creates an `ocdev` profile with Docker nesting enabled
2. **Container**: Launches Ubuntu 25.10 system container with the profile
3. **Mounts**: Binds host directories into `/home/dev/` inside container
4. **Provisioning**: Installs Docker, SSH server, git, curl
5. **Port Forwarding**: Maps host ports to container ports:
   - SSH: host `22X0` -> container `22` (where X is 0, 1, 2, ... for each VM)
   - Services: host `23X0-23X9` -> container `23X0-23X9` (10 ports per VM)

## Directory Structure

```
~/.local/bin/ocdev       # Executable (or symlink)
~/.ocdev/                # Config directory
~/.ocdev/ports           # Port assignments (name:port format)
~/.ocdev/.lock           # Lock file for concurrent operations
```

## Port Allocation

Each container gets 11 forwarded ports:
- 1 SSH port (host -> container port 22)
- 10 service ports (host -> same port in container)

| VM # | SSH Port | Service Ports | Use For |
|------|----------|---------------|---------|
| 1    | 2200     | 2300-2309     | First container |
| 2    | 2210     | 2310-2319     | Second container |
| 3    | 2220     | 2320-2329     | Third container |
| n    | 2200+(n-1)*10 | 2300+(n-1)*10 to 2309+(n-1)*10 | nth container |

Service ports are forwarded to the same port inside the container. For example, if your app inside container 1 listens on port 2300, access it from host at `localhost:2300`.

### Dynamic Port Bindings

In addition to the static service ports above, you can dynamically bind any port to a container:

```bash
# Bind host port 5173 to the same port in the container
ocdev bind myproject 5173

# Bind host port 8080 to container port 3000
ocdev bind myproject 3000:8080

# List current dynamic bindings
ocdev bind myproject --list

# Remove a binding
ocdev unbind myproject 5173

# Move a binding from one container to another
# (automatically unbinds from the current owner)
ocdev rebind otherproject 5173

# See all dynamic bindings across all containers
ocdev bindings
# CONTAINER            HOST       CONTAINER      STATUS
# myproject            5173       5173           RUNNING
# otherproject         8080       3000           STOPPED
```

The `rebind` command is useful when switching between projects — it finds which container currently owns the port, unbinds it, and binds it to the target container in one step. If the port is not bound anywhere, it acts as a regular `bind`.

Use `ocdev bindings` for a global overview of which ports are bound where and whether those containers are running.

## Firewall Configuration (Recommended)

By default, ocdev ports are bound to all interfaces (`0.0.0.0`). It is recommended to restrict access to a trusted network interface (e.g., Tailscale) using UFW.

### Enable UFW (if not already enabled)

```bash
sudo ufw enable
```

### Allow on Tailscale only

```bash
# Allow SSH and service ports on Tailscale interface
sudo ufw allow in on tailscale0 to any port 2200:2399 proto tcp

# Block these ports on public interfaces (adjust interface names as needed)
sudo ufw deny in on eth0 to any port 2200:2399 proto tcp
sudo ufw deny in on wlan0 to any port 2200:2399 proto tcp
```

### Verify rules

```bash
sudo ufw status numbered
```

## Host Directory Mounts

| Host Path | Container Path | Mode |
|-----------|----------------|------|
| `~/.config` | `/home/dev/.config` | read-write |
| `~/.opencode` | `/home/dev/.opencode` | read-write |
| `~/.ssh` | `/home/dev/.ssh` | read-only |
| `~/.gitconfig` | `/home/dev/.gitconfig` | read-only |

## Creating from Snapshots

Clone a container from an existing snapshot using `--from-snapshot`:

```bash
# First, create a snapshot of an existing container
incus snapshot create ocdev-myproject initial

# Then create a new container from that snapshot
ocdev create myproject-clone --from-snapshot myproject/initial
```

The format is `container/snapshot` (without the `ocdev-` prefix). The cloned container:
- Gets new SSH and service port assignments (no port conflicts)
- Inherits all installed software and configuration from the snapshot
- Disk mounts are preserved from the source container

This is useful for quickly spinning up pre-configured environments.

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
