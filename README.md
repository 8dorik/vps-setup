# vps-setup

One-command provisioning for Pentium VPS nodes (Hetzner, Ubuntu 22.04+).

## Usage

SSH to a fresh server as root, then:

```bash
export GH_PAT=ghp_xxxx      # GitHub PAT with repo + read:packages scopes
export NODE_ROLE=antidetect  # antidetect | orchestrator | validator

curl -fsSL https://raw.githubusercontent.com/8dorik/vps-setup/main/provision.sh \
  | bash -s -- --role=$NODE_ROLE
```

Takes ~3–5 minutes on a fresh CX22.

## What it does

| Step | Details |
|------|---------|
| System update | `apt-get upgrade` |
| Packages | `zsh`, `fzf`, `git`, `oh-my-zsh`, `ufw`, `htop` |
| Docker | Installed via `get.docker.com` |
| ZSH plugins | `zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-completions` |
| `deploy` user | Created with ZSH shell, added to `sudo` + `docker` groups |
| SSH keys | Root's `authorized_keys` + `github.com/8dorik.keys` copied to deploy user |
| SSH hardening | Root login and password auth disabled |
| Firewall | UFW enabled with role-appropriate ports open |
| Repo | `pentium` cloned to `/opt/pentium`, owned by deploy user |
| GHCR | `docker login ghcr.io` authenticated with the PAT |

Script is idempotent — safe to re-run.

## Firewall ports by role

| Role | Open ports |
|------|-----------|
| `antidetect` | 22, 80, 443, 8080, 6080–6099 (noVNC) |
| `orchestrator` | 22, 80, 443, 8090 |
| `validator` | 22 (Tailscale-internal only) |

## After provisioning

1. Open a new terminal and verify SSH: `ssh deploy@<ip>`
2. Copy your `.env` file to the server
3. `cd /opt/pentium/<service> && docker compose up -d`

## Required GitHub PAT scopes

- `repo` — clone the private pentium repo
- `read:packages` — pull Docker images from GHCR
