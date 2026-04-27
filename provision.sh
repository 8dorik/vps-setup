#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || error "Must run as root."
}

NODE_ROLE=""
parse_args() {
    for arg in "$@"; do
        case $arg in
            --role=*) NODE_ROLE="${arg#*=}" ;;
            *) error "Unknown argument: $arg" ;;
        esac
    done
    [[ -n $NODE_ROLE ]] || error "--role is required (antidetect|orchestrator|validator)"
    case $NODE_ROLE in
        antidetect|orchestrator|validator) ;;
        *) error "Invalid role: $NODE_ROLE" ;;
    esac
    info "Provisioning role: $NODE_ROLE"
}

validate_env() {
    [[ -n "${GH_PAT:-}" ]] || error "GH_PAT env var required (GitHub PAT with repo + read:packages scopes)"
}

update_system() {
    info "Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
}

install_packages() {
    info "Installing base packages..."
    apt-get install -y -qq \
        zsh fzf git curl wget ufw ca-certificates gnupg htop unzip
}

install_ohmyzsh() {
    if [[ -d /usr/share/oh-my-zsh ]]; then
        info "oh-my-zsh already installed, skipping."
        return
    fi
    info "Installing oh-my-zsh..."
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /usr/share/oh-my-zsh
}

install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker already installed, skipping."
        return
    fi
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
}

install_zsh_plugins() {
    local plugin_dir=/usr/share/oh-my-zsh/custom/plugins
    mkdir -p "$plugin_dir"

    for plugin in zsh-autosuggestions zsh-syntax-highlighting zsh-completions; do
        if [[ -d $plugin_dir/$plugin ]]; then
            info "Plugin $plugin already installed, skipping."
        else
            info "Installing $plugin..."
            git clone --depth=1 "https://github.com/zsh-users/${plugin}" "$plugin_dir/$plugin"
        fi
    done
}

create_deploy_user() {
    if id deploy &>/dev/null; then
        info "User 'deploy' already exists, skipping creation."
    else
        info "Creating deploy user..."
        useradd -m -s /usr/bin/zsh deploy
    fi

    usermod -aG sudo deploy
    usermod -aG docker deploy

    local deploy_ssh=/home/deploy/.ssh
    mkdir -p "$deploy_ssh"
    chmod 700 "$deploy_ssh"

    # Copy root's authorized_keys
    if [[ -f /root/.ssh/authorized_keys ]]; then
        cp /root/.ssh/authorized_keys "$deploy_ssh/authorized_keys"
    else
        touch "$deploy_ssh/authorized_keys"
    fi

    # Append 8dorik's GitHub SSH public keys (idempotent)
    while IFS= read -r key; do
        grep -qF "$key" "$deploy_ssh/authorized_keys" 2>/dev/null || \
            echo "$key" >> "$deploy_ssh/authorized_keys"
    done <<< "$(curl -fsSL https://github.com/8dorik.keys)"

    chmod 600 "$deploy_ssh/authorized_keys"
    chown -R deploy:deploy "$deploy_ssh"
    info "SSH keys configured for deploy user."
}

write_zshrc() {
    info "Writing .zshrc for deploy user..."
    cat > /home/deploy/.zshrc << 'EOF'
export ZSH=/usr/share/oh-my-zsh
ZSH_THEME="robbyrussell"

plugins=(
  git
  sudo
  z
  dirhistory
  extract
  copypath
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-completions
  fzf
)

# Completion setup — must be before sourcing OMZ
autoload -U compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''

source $ZSH/oh-my-zsh.sh

# Show username in prompt
PROMPT="%n@%m ${PROMPT}"
export PATH="$HOME/.local/bin:$PATH"
EOF
    chown deploy:deploy /home/deploy/.zshrc
}

harden_ssh() {
    info "Hardening SSH..."
    local cfg=/etc/ssh/sshd_config

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$cfg"
    grep -q '^PermitRootLogin' "$cfg" || echo 'PermitRootLogin no' >> "$cfg"

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
    grep -q '^PasswordAuthentication' "$cfg" || echo 'PasswordAuthentication no' >> "$cfg"

    systemctl restart sshd
    warn "Root SSH login disabled. Use: ssh deploy@<ip>"
}

setup_firewall() {
    info "Configuring UFW for role: $NODE_ROLE..."
    ufw --force reset
    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow 443/tcp

    case $NODE_ROLE in
        antidetect)
            ufw allow 8080/tcp
            ufw allow 6080:6099/tcp
            ;;
        orchestrator)
            ufw allow 8090/tcp
            ;;
        validator)
            # Tailscale-internal — no extra public ports
            ;;
    esac

    ufw --force enable
    info "Firewall enabled."
}

clone_project() {
    if [[ -d /opt/pentium/.git ]]; then
        info "Repo already cloned, pulling latest..."
        sudo -u deploy git -C /opt/pentium pull --ff-only
        return
    fi

    info "Cloning pentium repo to /opt/pentium..."
    git clone "https://${GH_PAT}@github.com/8dorik/pentium.git" /opt/pentium
    # Remove PAT from remote URL before chown to avoid dubious ownership error
    git -C /opt/pentium remote set-url origin git@github.com:8dorik/pentium.git
    chown -R deploy:deploy /opt/pentium
}

setup_ghcr() {
    info "Logging into GHCR..."
    echo "$GH_PAT" | docker login ghcr.io -u 8dorik --password-stdin

    # Copy credentials to deploy user
    mkdir -p /home/deploy/.docker
    cp /root/.docker/config.json /home/deploy/.docker/config.json
    chown -R deploy:deploy /home/deploy/.docker
}

setup_data_dirs() {
    [[ $NODE_ROLE == antidetect ]] || return 0
    info "Creating antidetect data directories..."
    mkdir -p /opt/pentium/antidetect/{data,profiles,screenshots}
    chown -R deploy:deploy /opt/pentium/antidetect/
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! role=${NODE_ROLE}${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Open a new terminal and verify:  ssh deploy@<this-ip>"
    case $NODE_ROLE in
        antidetect)
            echo "  2. scp antidetect/.env deploy@<ip>:/opt/pentium/antidetect/.env"
            echo "  3. ssh deploy@<ip> 'cd /opt/pentium/antidetect && docker compose up -d'"
            ;;
        orchestrator)
            echo "  2. scp orchestrator/.env deploy@<ip>:/opt/pentium/orchestrator/.env"
            echo "  3. ssh deploy@<ip> 'cd /opt/pentium/orchestrator && docker compose up -d'"
            ;;
        validator)
            echo "  2. Set up Tailscale (see architecture spec 02)"
            ;;
    esac
    echo ""
    warn "Root SSH login is now DISABLED — only deploy user works going forward."
}

main() {
    check_root
    parse_args "$@"
    validate_env

    update_system
    install_packages
    install_ohmyzsh
    install_docker
    install_zsh_plugins
    create_deploy_user
    write_zshrc
    harden_ssh
    setup_firewall
    clone_project
    setup_ghcr
    setup_data_dirs
    print_summary
}

main "$@"
