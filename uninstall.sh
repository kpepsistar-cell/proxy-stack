#!/bin/bash
# Cleanly uninstall proxy stack

set -e
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

echo -e "${YELLOW}This will stop and remove all proxy containers.${NC}"
echo "Files in $SCRIPT_DIR will be kept (config.env, certs, etc)."
echo
read -p "Continue? [y/N] " -r ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo -e "${RED}Stopping and removing containers...${NC}"
compose down --remove-orphans || true

echo
read -p "Also remove docker images (sing-box, mtg, dashboard)? [y/N] " -r ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    docker rmi ghcr.io/sagernet/sing-box:latest 2>/dev/null || true
    docker rmi nineseconds/mtg:2 2>/dev/null || true
    # dashboard is locally built
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^proxy[-_]dashboard' | xargs -r docker rmi 2>/dev/null || true
    echo -e "${GREEN}Images removed.${NC}"
fi

echo
read -p "Also remove ALL files including config.env (DESTRUCTIVE)? [y/N] " -r ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    cd /
    rm -rf "$SCRIPT_DIR"
    echo -e "${GREEN}All files removed.${NC}"
else
    echo -e "${GREEN}Files kept in $SCRIPT_DIR${NC}"
fi

echo
echo -e "${GREEN}Uninstall complete.${NC}"
