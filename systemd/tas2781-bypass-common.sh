#!/usr/bin/env bash

# Shared helpers for the TAS2781 persistent bypass scripts.
# This repository targets Lenovo laptops whose internal speakers are driven by
# a TI TAS2781 smart amp behind the Realtek HDA codec path.

TAS2781_BYPASS_MODS=(
  snd_hda_scodec_tas2781_i2c
  snd_hda_scodec_tas2781
  snd_soc_tas2781_fmwlib
  snd_soc_tas2781_comlib_i2c
  snd_soc_tas2781_comlib
)

TAS2781_WAIT_RETRIES=20
TAS2781_WAIT_DELAY_SECS=0.25

tas2781_log() {
  printf '[tas2781-bypass] %s\n' "$*"
}

tas2781_die() {
  tas2781_log "ERROR: $*"
  exit 1
}

tas2781_require_root() {
  [[ "$(id -u)" -eq 0 ]] || tas2781_die "run as root"
}

tas2781_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || tas2781_die "missing command: $1"
}

tas2781_read_sysfs() {
  local path="$1"
  [[ -r "$path" ]] && tr -d '\n' < "$path"
}

tas2781_product_name() {
  tas2781_read_sysfs /sys/class/dmi/id/product_name
}

tas2781_product_version() {
  tas2781_read_sysfs /sys/class/dmi/id/product_version
}

tas2781_product_vendor() {
  tas2781_read_sysfs /sys/class/dmi/id/product_vendor
}

tas2781_find_amp_acpi_path() {
  local path

  while IFS= read -r path; do
    printf '%s\n' "$path"
    return 0
  done < <(
    find /sys/devices /sys/bus/i2c/devices -maxdepth 6 -type d \
      \( -name 'i2c-TIAS2781:00' -o -name 'i2c-TXNW2781:00' \) \
      2>/dev/null | sort
  )

  return 1
}

tas2781_find_i2c_bus() {
  local path="$1"
  local bus

  bus="$(printf '%s\n' "$path" | grep -oE 'i2c-[0-9]+' | head -n1 | sed 's/^i2c-//')"
  [[ -n "$bus" ]] && printf '%s\n' "$bus"
}

tas2781_has_alc287() {
  grep -Rqs "Codec: Realtek ALC287" /proc/asound/card*/codec* 2>/dev/null
}

tas2781_find_analog_pcm_device() {
  local line

  while IFS= read -r line; do
    if [[ "$line" =~ ^([0-9]{2})-([0-9]{2}):\ .*[Aa]nalog.*:\ playback ]]; then
      printf 'hw:%d,%d\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      return 0
    fi
  done < /proc/asound/pcm

  return 1
}

tas2781_have_user_session() {
  local uid runtime

  [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]] || return 1
  uid="$(id -u "$SUDO_USER" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 1
  runtime="/run/user/$uid"
  [[ -S "$runtime/bus" ]]
}

tas2781_user_run() {
  local uid runtime bus_addr cmd

  [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]] || return 1
  uid="$(id -u "$SUDO_USER" 2>/dev/null || return 1)"
  runtime="/run/user/$uid"
  bus_addr="unix:path=$runtime/bus"
  cmd="$1"

  [[ -S "$runtime/bus" ]] || return 1

  runuser -u "$SUDO_USER" -- env \
    XDG_RUNTIME_DIR="$runtime" \
    DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
    bash -lc "$cmd"
}

tas2781_find_user_analog_sink() {
  local sinks

  sinks="$(tas2781_user_run 'pactl list short sinks' 2>/dev/null || true)"
  [[ -n "$sinks" ]] || return 1

  printf '%s\n' "$sinks" | awk 'tolower($2) ~ /analog-stereo/ { print $2; exit }'
}

tas2781_restart_user_audio() {
  tas2781_have_user_session || return 1
  tas2781_user_run 'systemctl --user restart pipewire pipewire-pulse wireplumber'
}

tas2781_wait_for_path() {
  local path="$1"
  local i

  for ((i = 0; i < TAS2781_WAIT_RETRIES; i++)); do
    [[ -e "$path" ]] && return 0
    sleep "$TAS2781_WAIT_DELAY_SECS"
  done

  return 1
}

tas2781_wait_for_addr() {
  local bus="$1"
  local addr="$2"
  local i

  for ((i = 0; i < TAS2781_WAIT_RETRIES; i++)); do
    if i2cget -f -y "$bus" "$addr" 0x00 b >/dev/null 2>&1; then
      return 0
    fi
    sleep "$TAS2781_WAIT_DELAY_SECS"
  done

  return 1
}

tas2781_best_effort_unload_modules() {
  local m

  for m in "${TAS2781_BYPASS_MODS[@]}"; do
    if lsmod | awk '{print $1}' | grep -Fxq "$m"; then
      tas2781_log "modprobe -r $m"
      modprobe -r "$m" || tas2781_log "module unload failed for $m; continuing"
    else
      tas2781_log "module $m already absent"
    fi
  done
}

tas2781_write_reg() {
  local bus="$1"
  local addr="$2"
  local reg="$3"
  local value="$4"

  i2cset -f -y "$bus" "$addr" "$reg" "$value"
}

tas2781_write_reg_sequence() {
  local bus="$1"
  local addr="$2"
  local chan_mode="$3"

  tas2781_log "programming bus=$bus addr=$addr chan_mode=$chan_mode"
  tas2781_write_reg "$bus" "$addr" 0x00 0x00
  tas2781_write_reg "$bus" "$addr" 0x7f 0x00
  tas2781_write_reg "$bus" "$addr" 0x01 0x01
  tas2781_write_reg "$bus" "$addr" 0x0e 0xc4
  tas2781_write_reg "$bus" "$addr" 0x0f 0x40
  tas2781_write_reg "$bus" "$addr" 0x5c 0xd9
  tas2781_write_reg "$bus" "$addr" 0x60 0x10
  tas2781_write_reg "$bus" "$addr" 0x0a "$chan_mode"
  tas2781_write_reg "$bus" "$addr" 0x0d 0x01
  tas2781_write_reg "$bus" "$addr" 0x16 0x40
  tas2781_write_reg "$bus" "$addr" 0x00 0x01
  tas2781_write_reg "$bus" "$addr" 0x17 0xc8
  tas2781_write_reg "$bus" "$addr" 0x00 0x04
  tas2781_write_reg "$bus" "$addr" 0x30 0x00
  tas2781_write_reg "$bus" "$addr" 0x31 0x00
  tas2781_write_reg "$bus" "$addr" 0x32 0x00
  tas2781_write_reg "$bus" "$addr" 0x33 0x01
  tas2781_write_reg "$bus" "$addr" 0x00 0x08
  tas2781_write_reg "$bus" "$addr" 0x18 0x00
  tas2781_write_reg "$bus" "$addr" 0x19 0x00
  tas2781_write_reg "$bus" "$addr" 0x1a 0x00
  tas2781_write_reg "$bus" "$addr" 0x1b 0x00
  tas2781_write_reg "$bus" "$addr" 0x28 0x40
  tas2781_write_reg "$bus" "$addr" 0x29 0x00
  tas2781_write_reg "$bus" "$addr" 0x2a 0x00
  tas2781_write_reg "$bus" "$addr" 0x2b 0x00
  tas2781_write_reg "$bus" "$addr" 0x00 0x0a
  tas2781_write_reg "$bus" "$addr" 0x48 0x00
  tas2781_write_reg "$bus" "$addr" 0x49 0x00
  tas2781_write_reg "$bus" "$addr" 0x4a 0x00
  tas2781_write_reg "$bus" "$addr" 0x4b 0x00
  tas2781_write_reg "$bus" "$addr" 0x58 0x40
  tas2781_write_reg "$bus" "$addr" 0x59 0x00
  tas2781_write_reg "$bus" "$addr" 0x5a 0x00
  tas2781_write_reg "$bus" "$addr" 0x5b 0x00
  tas2781_write_reg "$bus" "$addr" 0x00 0x00
  tas2781_write_reg "$bus" "$addr" 0x02 0x00
}

tas2781_print_summary() {
  local acpi_path bus

  acpi_path="$(tas2781_find_amp_acpi_path 2>/dev/null || true)"
  bus="$(tas2781_find_i2c_bus "$acpi_path" 2>/dev/null || true)"

  tas2781_log "vendor=$(tas2781_product_vendor || true)"
  tas2781_log "product=$(tas2781_product_name || true)"
  tas2781_log "version=$(tas2781_product_version || true)"
  tas2781_log "alc287_detected=$(tas2781_has_alc287 && echo yes || echo no)"
  tas2781_log "amp_acpi_path=${acpi_path:-missing}"
  tas2781_log "i2c_bus=${bus:-missing}"
}
