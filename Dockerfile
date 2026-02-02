FROM node:20-bookworm

# node:20-bookworm already includes git, curl, ca-certificates

# Install additional tools for Claude Code operations
# To add more packages: edit this list and rebuild image
# Current packages: sudo, sshpass, ssh-client, jq, sqlite3
RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo \
    sshpass \
    openssh-client \
    jq \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl via apt
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update && apt-get install -y kubectl \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install Flux CLI
RUN curl -s https://fluxcd.io/install.sh | bash

# Install Claude CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create app directory
WORKDIR /app

# Copy package files
COPY package*.json ./

# Install ALL dependencies (including devDeps for build)
RUN npm ci

# Copy application code
COPY . .

# Build frontend
RUN npm run build

# Remove dev dependencies after build
RUN npm prune --production

# Create app user with sudo access
RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /home/claude/projects \
    && chown -R claude:claude /home/claude /app \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

USER claude

# Expose the default port
EXPOSE 3001

ENV PORT=3001
ENV NODE_ENV=production

# Start server
CMD ["node", "server/cli.js", "start"]
