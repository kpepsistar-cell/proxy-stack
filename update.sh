#!/bin/bash
# Pull latest images and restart

set -e
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
NC='\033[0m'

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

echo -e "${GREEN}[1/3]${NC} Pulling latest images..."
compose pull

echo -e "${GREEN}[2/3]${NC} Rebuilding dashboard..."
compose build dashboard

echo -e "${GREEN}[3/3]${NC} Restarting services..."
compose up -d

sleep 2
compose ps

echo
echo -e "${GREEN}Update complete.${NC}"
echo "Run 'bash info.sh' to see node info."
