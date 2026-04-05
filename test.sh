#!/usr/bin/env bash

set -euo pipefail

SELF="$(readlink -f "$0")"
REPO_ROOT="$(cd -- "$(dirname -- "$SELF")" && pwd)"
# shellcheck source=./systemd/tas2781-bypass-common.sh
source "$REPO_ROOT/systemd/tas2781-bypass-common.sh"

RESTORE_AT_END=0
ADDR_A="0x3f"
ADDR_B="0x38"
CHAN_A="0x1e"
CHAN_B="0x2e"

usage() {
  cat <<'EOF'
Usage:
  ./test.sh
  ./test.sh --restore

What it does:
  - checks for ALC287 + TIAS2781/TXNW2781
  - applies the bypass non-persistently
  - runs a short speaker test

By default the working runtime state is left in place until reboot or until the
TAS2781 side-codec path is reloaded again.

Use --restore if you want the script to reload the original TAS2781 driver path
at the end of the test.
EOF
}

restore_default_path() {
  tas2781_log "restoring original TAS2781 side-codec path"
  modprobe snd_hda_scodec_tas2781_i2c || true
}

run_user_session_test() {
  local sink

  tas2781_log "restarting user PipeWire session"
  tas2781_restart_user_audio || return 1
  sleep 2

  sink="$(tas2781_find_user_analog_sink 2>/dev/null || true)"
  if [[ -n "$sink" ]]; then
    tas2781_log "setting default sink to $sink"
    tas2781_user_run "pactl set-default-sink '$sink'" || true
  fi

  tas2781_log "running user-session speaker-test on default sink"
  tas2781_user_run 'timeout 8s speaker-test -D default -c 2 -t sine -f 440 || true'
}

run_alsa_fallback_test() {
  local pcm

  pcm="$(tas2781_find_analog_pcm_device 2>/dev/null || true)"
  [[ -n "$pcm" ]] || tas2781_die "could not find an analog ALSA playback PCM device"

  tas2781_log "no usable desktop session detected; falling back to ALSA PCM $pcm"
  timeout 8s speaker-test -D "$pcm" -c 2 -t sine -f 440 || true
}

main() {
  local acpi_path bus

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  if [[ "${1:-}" == "--restore" ]]; then
    RESTORE_AT_END=1
  elif [[ -n "${1:-}" ]]; then
    usage
    exit 1
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SELF" "$@"
  fi

  tas2781_require_root
  tas2781_require_cmd modprobe
  tas2781_require_cmd i2cdetect
  tas2781_require_cmd i2cget
  tas2781_require_cmd i2cset
  tas2781_require_cmd speaker-test
  tas2781_require_cmd timeout

  acpi_path="$(tas2781_find_amp_acpi_path 2>/dev/null || true)"
  bus="$(tas2781_find_i2c_bus "$acpi_path" 2>/dev/null || true)"

  printf '\n'
  tas2781_log "runtime-only test start"
  tas2781_print_summary
  tas2781_log "kernel=$(uname -r)"
  tas2781_log "this test expects the dual-amp layout at 0x3f and 0x38"

  if ! tas2781_has_alc287; then
    tas2781_log "warning: ALC287 was not detected"
  fi
  if [[ -z "$acpi_path" || -z "$bus" ]]; then
    tas2781_die "TIAS2781/TXNW2781 ACPI device was not found"
  fi

  modprobe i2c-dev
  tas2781_wait_for_path "/dev/i2c-$bus" || tas2781_die "missing /dev/i2c-$bus"

  tas2781_best_effort_unload_modules

  tas2781_log "probing I2C addresses after unloading the side-codec stack"
  yes | i2cdetect -r "$bus" || true

  tas2781_wait_for_addr "$bus" "$ADDR_A" || tas2781_die "address $ADDR_A did not respond on bus $bus"
  tas2781_wait_for_addr "$bus" "$ADDR_B" || tas2781_die "address $ADDR_B did not respond on bus $bus"

  tas2781_write_reg_sequence "$bus" "$ADDR_A" "$CHAN_A"
  tas2781_write_reg_sequence "$bus" "$ADDR_B" "$CHAN_B"

  printf '\n'
  tas2781_log "bypass applied successfully"
  tas2781_log "listen for laptop-speaker output during the following tone test"

  if tas2781_have_user_session; then
    run_user_session_test || run_alsa_fallback_test
  else
    run_alsa_fallback_test
  fi

  printf '\n'
  tas2781_log "if you heard sound from the internal speakers, run:"
  tas2781_log "  sudo ./setup.sh"
  tas2781_log "the current working runtime state will survive until reboot or until the TAS2781 driver path is reloaded"

  if [[ "$RESTORE_AT_END" -eq 1 ]]; then
    restore_default_path
  fi
}

main "$@"
