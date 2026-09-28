#!/bin/sh
set -e
cd "$(dirname "$0")/.."
chmod 700 models/gguf data 2>/dev/null || true
chmod 640 models/gguf/*.gguf 2>/dev/null || true
echo "1. sudo ufw allow from 192.168.0.0/16 to any port 9090 proto tcp"
echo "2. sudo cp deploy/systemd/arcis.service /etc/systemd/system/"
echo "   sudo systemctl daemon-reload && sudo systemctl enable --now arcis"
echo "3. ./tools/doctor.sh"
echo "Keep 9090 off the router WAN. Infer is not an open internet API."
