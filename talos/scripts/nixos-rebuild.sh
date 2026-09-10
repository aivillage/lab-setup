#!/usr/bin/env bash

export TMPDIR="/tmp"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/ssh_auth_sock}"
export NIX_SSHOPTS="${NIX_SSHOPTS:--A}"

FIRST_ARG="${1:-}"

case "$FIRST_ARG" in
  switch|boot|test|build|dry-run|build-vm|build-vm-with-bootloader|edit|repl)
    exec nixos-rebuild "$@"
    ;;
  help|--help|-h|"")
    echo -e "\033[1;36mAI Village NixOS Rebuild Helper\033[0m"
    echo -e "Usage:"
    echo -e "  \033[1mnixos-rebuild <node-or-host> [action] [options...]\033[0m"
    echo -e "  \033[1mnixos-rebuild [action] [options...]\033[0m"
    echo -e "\nExamples:"
    echo -e "  nixos-rebuild spark2 switch      # Rebuild and switch spark2 over SSH"
    echo -e "  nixos-rebuild spark0 boot        # Rebuild and set boot profile on spark0"
    echo -e "  nixos-rebuild coordinator        # Rebuild and switch coordinator"
    echo -e "  nixos-rebuild switch --flake .#spark1\n"
    exec nixos-rebuild --help
    ;;
esac

TARGET="$FIRST_ARG"
shift

if [ "$TARGET" = "coordinator" ]; then
  if [ -n "${COORDINATOR_HOST:-}" ]; then
    TARGET="$COORDINATOR_HOST"
  else
    echo -e "\033[1;31mError: No coordinator hostname defined in cluster.nix. Please specify target host explicitly (e.g. nixos-rebuild spark2 switch).\033[0m" >&2
    exit 1
  fi
fi

ACTION="${1:-switch}"
case "$ACTION" in
  switch|boot|test|build|dry-run|build-vm|build-vm-with-bootloader)
    shift || true
    ;;
  *)
    ACTION="switch"
    ;;
esac

CURRENT_HOST=$(hostname 2>/dev/null || echo "")
if [ "$CURRENT_HOST" = "$TARGET" ]; then
  echo -e "\033[1;36mRebuilding $TARGET ($ACTION) locally...\033[0m"
  exec sudo nixos-rebuild "$ACTION" -L --flake "path:.#$TARGET" "$@"
fi

SSH_USER="admin"
if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no "admin@$TARGET" "true" 2>/dev/null; then
  SSH_USER="admin"
elif ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no "root@$TARGET" "true" 2>/dev/null; then
  SSH_USER="root"
fi

SUDO_FLAG=()
if [ "$SSH_USER" = "admin" ]; then
  SUDO_FLAG=("--elevate=sudo")
fi

echo -e "\033[1;36mRebuilding $TARGET ($ACTION) via $SSH_USER@$TARGET...\033[0m"
exec nixos-rebuild "$ACTION" -L --flake "path:.#$TARGET" --target-host "$SSH_USER@$TARGET" --build-host "$SSH_USER@$TARGET" "${SUDO_FLAG[@]}" "$@"
