#!/usr/bin/env bash

set -euo pipefail

SELF="$(readlink -f "$0")"
REPO_ROOT="$(cd -- "$(dirname -- "$SELF")" && pwd)"
# shellcheck source=./systemd/tas2781-bypass-common.sh
source "$REPO_ROOT/systemd/tas2781-bypass-common.sh"

FORCE=0
INSTALL_BLACKLIST=1
INSTALL_LIB_DIR="/usr/local/lib/tas2781-bypass"
INSTALL_UNIT_DIR="/etc/systemd/system"
INSTALL_MODPROBE_DIR="/etc/modprobe.d"
ORIG_ARGS=("$@")

usage() {
  cat <<'EOF'
Usage:
  sudo ./setup.sh
  sudo ./setup.sh --force
  sudo ./setup.sh --no-blacklist

What it installs:
  - /usr/local/lib/tas2781-bypass/tas2781-bypass-apply.sh
  - /usr/local/lib/tas2781-bypass/tas2781-bypass-common.sh
  - /etc/systemd/system/tas2781-bypass.service
  - /etc/systemd/system/tas2781-bypass-resume.service
  - /etc/modprobe.d/tas2781-bypass-blacklist.conf

Then it enables the boot and resume units and starts the boot unit once.
EOF
}

main() {
  local acpi_path

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        FORCE=1
        ;;
      --no-blacklist)
        INSTALL_BLACKLIST=0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    shift
  done

  if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SELF" "${ORIG_ARGS[@]}"
  fi

  tas2781_require_root
  tas2781_require_cmd install
  tas2781_require_cmd systemctl
  tas2781_require_cmd modprobe
  tas2781_require_cmd i2cget
  tas2781_require_cmd i2cset

  acpi_path="$(tas2781_find_amp_acpi_path 2>/dev/null || true)"

  printf '\n'
  tas2781_log "persistent setup start"
  tas2781_print_summary

  if [[ "$FORCE" -ne 1 ]]; then
    tas2781_has_alc287 || tas2781_die "ALC287 not detected; use --force only if you have already validated the bypass manually"
    [[ -n "$acpi_path" ]] || tas2781_die "TIAS2781/TXNW2781 ACPI device not detected; use --force only if you have already validated the bypass manually"
  fi

  install -d "$INSTALL_LIB_DIR" "$INSTALL_UNIT_DIR" "$INSTALL_MODPROBE_DIR"

  install -m 0755 "$REPO_ROOT/systemd/tas2781-bypass-apply.sh" \
    "$INSTALL_LIB_DIR/tas2781-bypass-apply.sh"
  install -m 0644 "$REPO_ROOT/systemd/tas2781-bypass-common.sh" \
    "$INSTALL_LIB_DIR/tas2781-bypass-common.sh"
  install -m 0644 "$REPO_ROOT/systemd/tas2781-bypass.service" \
    "$INSTALL_UNIT_DIR/tas2781-bypass.service"
  install -m 0644 "$REPO_ROOT/systemd/tas2781-bypass-resume.service" \
    "$INSTALL_UNIT_DIR/tas2781-bypass-resume.service"

  if [[ "$INSTALL_BLACKLIST" -eq 1 ]]; then
    install -m 0644 "$REPO_ROOT/systemd/tas2781-bypass-blacklist.conf" \
      "$INSTALL_MODPROBE_DIR/tas2781-bypass-blacklist.conf"
    tas2781_log "installed modprobe blacklist to keep the broken side-codec helper from auto-loading"
  else
    tas2781_log "skipping modprobe blacklist at user request"
  fi

  systemctl daemon-reload
  systemctl enable --now tas2781-bypass.service
  systemctl enable tas2781-bypass-resume.service

  printf '\n'
  tas2781_log "install complete"
  tas2781_log "verify with:"
  tas2781_log "  systemctl status tas2781-bypass.service"
  tas2781_log "  systemctl status tas2781-bypass-resume.service"
  tas2781_log "  journalctl -u tas2781-bypass.service -b"
  tas2781_log "  journalctl -u tas2781-bypass-resume.service -b"
  tas2781_log "reboot once if the speakers do not come up immediately"
}

main "$@"
