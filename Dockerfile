FROM node:20-bookworm

# node:20-bookworm already includes git, curl, ca-certificates

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
