#!/usr/bin/env bash

set -euo pipefail

SELF="$(readlink -f "$0")"

usage() {
  cat <<'EOF'
Usage:
  sudo ./uninstall.sh

Removes the installed TAS2781 persistent bypass files and disables the systemd
units. Reboot afterward to restore the normal driver path cleanly.
EOF
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SELF" "$@"
  fi

  systemctl disable --now tas2781-bypass.service 2>/dev/null || true
  systemctl disable tas2781-bypass-resume.service 2>/dev/null || true

  rm -f /etc/systemd/system/tas2781-bypass.service
  rm -f /etc/systemd/system/tas2781-bypass-resume.service
  rm -f /etc/modprobe.d/tas2781-bypass-blacklist.conf
  rm -f /usr/local/lib/tas2781-bypass/tas2781-bypass-apply.sh
  rm -f /usr/local/lib/tas2781-bypass/tas2781-bypass-common.sh
  rmdir /usr/local/lib/tas2781-bypass 2>/dev/null || true

  systemctl daemon-reload
  systemctl reset-failed tas2781-bypass.service tas2781-bypass-resume.service 2>/dev/null || true

  echo "TAS2781 persistent bypass removed."
  echo "Reboot to restore the default driver path."
}

main "$@"
