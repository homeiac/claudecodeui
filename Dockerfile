FROM node:20-slim

# Install dependencies for Claude CLI and git operations
RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Claude CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create app directory
WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --only=production

# Copy application code
COPY . .

# Build frontend
RUN npm run build

# Create app user
RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /home/claude/projects \
    && chown -R claude:claude /home/claude /app

USER claude

# Expose the default port
EXPOSE 3001

ENV PORT=3001
ENV NODE_ENV=production

# Start server
CMD ["node", "server/cli.js", "start"]
