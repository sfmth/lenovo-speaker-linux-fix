#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./tas2781-bypass-common.sh
source "$SCRIPT_DIR/tas2781-bypass-common.sh"

ACTION="${1:---manual}"
ADDR_A="0x3f"
ADDR_B="0x38"
CHAN_A="0x1e"
CHAN_B="0x2e"

main() {
  local acpi_path bus

  tas2781_require_root
  tas2781_require_cmd modprobe
  tas2781_require_cmd i2cget
  tas2781_require_cmd i2cset
  tas2781_require_cmd lsmod
  tas2781_require_cmd awk
  tas2781_require_cmd grep

  case "$ACTION" in
    --boot|--resume|--manual)
      ;;
    *)
      tas2781_die "usage: $0 [--boot|--resume|--manual]"
      ;;
  esac

  acpi_path="$(tas2781_find_amp_acpi_path 2>/dev/null || true)"
  [[ -n "$acpi_path" ]] || tas2781_die "no TIAS2781/TXNW2781 ACPI device found"

  bus="$(tas2781_find_i2c_bus "$acpi_path" 2>/dev/null || true)"
  [[ -n "$bus" ]] || tas2781_die "could not derive I2C bus from: $acpi_path"

  tas2781_log "start action=$ACTION"
  tas2781_print_summary
  tas2781_log "using dual-amp profile addrs=$ADDR_A,$ADDR_B"

  modprobe i2c-dev
  tas2781_wait_for_path "/dev/i2c-$bus" || tas2781_die "missing /dev/i2c-$bus"

  tas2781_best_effort_unload_modules

  tas2781_wait_for_addr "$bus" "$ADDR_A" || tas2781_die "address $ADDR_A did not respond on bus $bus"
  tas2781_wait_for_addr "$bus" "$ADDR_B" || tas2781_die "address $ADDR_B did not respond on bus $bus"

  tas2781_write_reg_sequence "$bus" "$ADDR_A" "$CHAN_A"
  tas2781_write_reg_sequence "$bus" "$ADDR_B" "$CHAN_B"

  tas2781_log "bypass applied successfully"
  tas2781_log "note: TAS2781 side-codec modules are intentionally left unloaded"
}

main "$@"
