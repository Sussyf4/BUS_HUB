#!/data/data/com.termux/files/usr/bin/bash
# Termux -> Ubuntu (proot-distro) -> Node.js -> OpenCode
set -e

echo "==> Updating Termux"
pkg update -y
pkg upgrade -y

echo "==> Installing proot-distro"
pkg install -y proot-distro

echo "==> Installing Ubuntu (skipped if already installed)"
proot-distro login ubuntu -- true 2>/dev/null || proot-distro install ubuntu

echo "==> Installing Node.js, npm and OpenCode inside Ubuntu"
proot-distro login ubuntu -- bash -c '
  apt update &&
  DEBIAN_FRONTEND=noninteractive apt install -y nodejs npm curl ca-certificates &&
  npm install -g opencode-ai
'

echo "==> Downloading AGENTS.md and starting OpenCode"
proot-distro login ubuntu -- bash -c '
  cd /root &&
  curl -fL "https://raw.githubusercontent.com/togg53192-cmd/jailbreaks/refs/heads/main/DeepSeek/deepseekv4.1%20and%20v4.1-1017.md" -o AGENTS.md &&
  opencode
'
