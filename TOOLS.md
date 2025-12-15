# Installed Tools in claudecodeui Container

This document tracks tools installed in the Docker image to avoid needing `sudo apt install` at runtime.

## Pre-installed Tools

### From Base Image (node:20-bookworm)
- **node** (v20.x) - Node.js runtime
- **npm** - Node package manager
- **git** - Version control
- **curl** - HTTP client
- **ca-certificates** - SSL certificates

### Added in Dockerfile
| Package | Purpose | Added |
|---------|---------|-------|
| sudo | Elevated commands (NOPASSWD for claude user) | v1.13.0 |
| sshpass | Non-interactive SSH password auth | v1.13.0 |
| openssh-client | SSH/SCP/SFTP client | v1.13.0 |
| jq | JSON processor | v1.15.0 |
| sqlite3 | SQLite CLI for database queries | v1.15.0 |
| kubectl | Kubernetes CLI | v1.13.0 |

### NPM Global Packages
| Package | Purpose | Added |
|---------|---------|-------|
| @anthropic-ai/claude-code | Claude Code CLI | v1.0.0 |

## Adding New Tools

1. Edit `Dockerfile` - add package to the `apt-get install` line
2. Update this file with the new package
3. Bump version in `package.json`
4. Build and push: `./scripts/build-and-push.sh`

## Sudo Access

The `claude` user has passwordless sudo via `/etc/sudoers.d/claude`:
```
claude ALL=(ALL) NOPASSWD:ALL
```

This allows `sudo apt update && sudo apt install <package>` for temporary needs,
but packages should be added to Dockerfile for persistence across pod restarts.
