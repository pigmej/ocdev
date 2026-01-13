## Default post-install script for dev user setup
## Installs uv (uvx), nvm (npx), and OpenCode

const PostInstallScript* = """
#!/bin/bash
# Runs as dev user after container provisioning

# Ensure .bashrc exists and has tool paths
touch ~/.bashrc

grep -q "/.local/bin" ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

grep -q ".local/bin/env" ~/.bashrc || echo '[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"' >> ~/.bashrc

grep -q "NVM_DIR" ~/.bashrc || cat >> ~/.bashrc << 'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF

# Ensure .profile sources .bashrc for login shells
touch ~/.profile
grep -q ".bashrc" ~/.profile || echo '[ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"' >> ~/.profile

# Install uv (provides uvx)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install nvm + Node.js LTS (provides npx)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install --lts

# Install OpenCode
curl -fsSL https://opencode.ai/install | bash
"""
