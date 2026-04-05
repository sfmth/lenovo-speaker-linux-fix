# TAS2781 Bypass

Run the runtime test first:

```bash
./test.sh
```

If the runtime test makes your internal laptop speakers work, install the permanent systemd workaround:

```bash
sudo ./setup.sh
```

To remove the permanent workaround later:

```bash
sudo ./uninstall.sh
```

This repository provides a runtime and systemd-based workaround for Lenovo laptops where Linux can route audio to `ALC287 Analog`, but the internal speakers stay silent because the TAS2781 smart amp is not initialized correctly.

## What This Fix Does

This repo does **not** patch the kernel. It works around a broken TAS2781 bring-up path by:

1. unloading the TAS2781 HDA side-codec modules
2. accessing the TAS2781 amp chips directly over I2C
3. writing the bypass/init register sequence manually
4. reapplying that state at boot and after resume with systemd

The TAS2781 itself is an I2C-controlled smart amp, which is why a direct I2C workaround is even possible on affected machines.

On the machine this was developed on, the normal Linux audio stack was already working at the PCM/routing level:

- PipeWire/WirePlumber were routing to the correct sink
- `speaker-test` could open the ALC287 analog device
- the kernel repeatedly logged `tasdevice_prmg_load: Firmware is NULL`
- direct I2C programming of the amps immediately restored speaker output

## What Problem This Targets

This is for the class of bugs where:

- HDMI audio works
- Bluetooth audio works
- headphones may work
- the internal speaker sink exists
- `ALC287 Analog` playback looks active
- but the laptop speakers are silent

This repo is especially relevant if you find any of these strings in logs, forum posts, or web searches:

- `tasdevice_prmg_load: Firmware is NULL`
- `tas2781-hda i2c-TIAS2781:00`
- `snd_hda_scodec_tas2781_i2c`
- `ALC287 Analog playback works but no speaker sound`
- `Lenovo Legion Pro 7 internal speakers not working Linux`
- `TIAS2781:00 no sound`
- `TXNW2781:00 no sound`
- `speaker-test runs but laptop speakers are silent`
- `PipeWire routed correctly but internal speakers don't work`

## Confirmed And Likely Hardware

Confirmed working:

- Lenovo Legion Pro 7 16ARX8H (`82WS`)
- Realtek `ALC287`
- ACPI amp device `TIAS2781:00`
- dual-amp layout on I2C bus `1`, addresses `0x3f` and `0x38`

Likely compatible, but unverified in this repo:

- other Lenovo laptops using `ALC287` with `TIAS2781:00` or `TXNW2781:00`
- systems where the dual-amp layout is still `0x3f` and `0x38`
- models discussed in upstream patches and bug reports for Lenovo Legion / Yoga families using the TAS2781 HDA side-codec path

Reported affected examples in upstream or community references:

- Lenovo Legion Pro 7 16IRX8 / 16IRX8H variants
- Lenovo Yoga Pro 9i Gen 9 variants
- Lenovo boards with codec subsystem IDs `17aa:38a7` or `17aa:38a8`

Probably **not** for:

- laptops using Cirrus `CS35L41` speaker amps instead of TI TAS2781
- laptops with non-`ALC287` codecs
- laptops whose amp addresses or amp count differ from the dual-amp `0x3f` + `0x38` layout
- 4-amp TAS2781 layouts unless you adapt the script first

This repository is intentionally conservative. Run `./test.sh` first. If the test does not produce sound, do **not** install the permanent units unchanged.

## How To Check Whether Your Hardware Matches

Check the laptop model:

```bash
cat /sys/class/dmi/id/product_name
cat /sys/class/dmi/id/product_version
```

Check whether the Realtek codec is `ALC287`:

```bash
grep -R "Codec: Realtek ALC287" /proc/asound/card*/codec* 2>/dev/null
grep -R "Subsystem Id:" /proc/asound/card*/codec* 2>/dev/null
```

Check whether Linux sees the TI smart amp ACPI device:

```bash
find /sys/devices /sys/bus/i2c/devices -maxdepth 6 -type d \
  \( -name 'i2c-TIAS2781:00' -o -name 'i2c-TXNW2781:00' \) 2>/dev/null
```

The reason this repo uses `/sys` to discover the bus is that Linux exposes logical I2C buses and devices there.

Check for the same failure signature in the kernel log:

```bash
sudo journalctl -k -b | grep -Ei 'tas2781|Firmware is NULL|prmg_load|ALC287'
```

Check whether the analog speaker sink exists and is active:

```bash
wpctl status
pactl get-default-sink
```

If `wpctl` shows `ALC287 Analog`, but the internal speakers are still silent, you are in the exact failure class this repo targets.

## Why This Works

Short version:

- the audio stream path is already alive
- the speaker power/amp stage is not
- the kernel should normally initialize the TAS2781 amp path automatically
- on affected Lenovo systems, that initialization can fail
- this repo bypasses that failing step and initializes the amps directly

More detail:

- The Realtek HDA codec and PCM device can still enumerate correctly, which is why the analog sink exists.
- The TAS2781 chips sit behind a separate HDA/I2C side-codec path.
- If the Realtek quirk selection, ACPI handoff, or TAS2781 firmware/program load fails, the speakers can remain silent even while ALSA and PipeWire look healthy.
- TI support discussions also point at some Lenovo BIOS implementations not providing the full information or init-verb path needed for the Realtek codec to bring the amp chain up correctly.
- The repeated log line `tasdevice_prmg_load: Firmware is NULL` is a strong clue that the TAS2781 side is not receiving a valid program/tuning object when it resumes or probes.
- Because TAS2781 is controlled over I2C, direct register writes can still bring the amps up even when the higher-level auto-init path failed.
- The runtime bypass writes the working register sequence directly to the amp chips, skipping the broken auto-initialization path.

Inference:

- The exact root cause on every affected laptop is not guaranteed to be identical.
- On the validated machine, the combination of upstream quirk history, the `Firmware is NULL` log, successful PCM playback, and successful direct I2C programming strongly points to a broken TAS2781 initialization path rather than a generic PipeWire or TLP problem.

## What `test.sh` Does

`test.sh` is a runtime-only proof step. It does not install anything permanently.

It:

1. checks that your machine looks like a likely match
2. unloads the TAS2781 side-codec modules
3. probes the I2C bus
4. writes the tested dual-amp sequence to `0x3f` and `0x38`
5. runs a short `speaker-test`

If you hear sound from the internal speakers, the persistent workaround is a good candidate for your machine.

## What `setup.sh` Installs

`setup.sh` installs:

- `/usr/local/lib/tas2781-bypass/tas2781-bypass-apply.sh`
- `/usr/local/lib/tas2781-bypass/tas2781-bypass-common.sh`
- `/etc/systemd/system/tas2781-bypass.service`
- `/etc/systemd/system/tas2781-bypass-resume.service`
- `/etc/modprobe.d/tas2781-bypass-blacklist.conf`

Then it:

- enables the boot-time service
- enables the resume-time service
- starts the boot-time service immediately

The blacklist is there to stop the broken `snd_hda_scodec_tas2781_i2c` path from reattaching later and undoing the bypass.

## Why systemd Is Used Here

The workaround must be applied:

- at boot
- after suspend/resume

The repo uses proper systemd units instead of ad-hoc shell hooks so the ordering and logs stay visible in the normal service manager.

- `tas2781-bypass.service` runs once at boot
- `tas2781-bypass-resume.service` uses the `sleep.target` + `ExecStop=` pattern to reapply the bypass after wake

## Original Solution And Related Work

This repo was built from a locally validated fix on a Lenovo Legion Pro 7 16ARX8H, but the starting point for the workaround pattern came from the Lenovo Yoga Pro 9i Gen 9 Linux community workaround:

- Original community workaround repo: <https://github.com/maximmaxim345/yoga_pro_9i_gen9_linux>
- Related community gist: <https://gist.github.com/rraks/4edddb99b50b94fe6298adbf3c9f43eb>

This repo narrows that workaround to the dual-amp `0x3f` + `0x38` profile validated on the Legion Pro 7 16ARX8H and packages it with a runtime test and systemd installation flow.

## Search Keywords

If you want this README to show up when searching, these are the phrases it is trying to cover:

- Lenovo Legion Pro 7 speakers no sound Linux
- Lenovo Legion Pro 7 16ARX8H 82WS speakers not working Linux
- TAS2781 bypass Linux
- ALC287 internal speakers silent Linux
- snd_hda_scodec_tas2781_i2c no sound
- tasdevice_prmg_load Firmware is NULL
- TIAS2781:00 Linux no sound
- TXNW2781:00 Linux no sound
- speaker-test works but internal speakers silent Linux
- PipeWire sink correct but no laptop speaker sound
- Lenovo Yoga Pro 9i Linux speakers TAS2781

## References

Official and upstream references:

- Linux kernel patch submission guide: <https://docs.kernel.org/process/submitting-patches.html>
- Linux kernel maintainers guide: <https://docs.kernel.org/process/maintainers.html>
- Linux I2C/SMBus subsystem docs: <https://docs.kernel.org/i2c/index.html>
- Linux I2C sysfs docs: <https://docs.kernel.org/i2c/i2c-sysfs.html>
- TI TAS2781 product page and datasheet landing page: <https://www.ti.com/product/TAS2781>
- systemd `sleep.target` and special units: <https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html>
- systemd service semantics including `ExecStop=` and `RemainAfterExit=`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html>
- systemd suspend/resume service behavior: <https://www.freedesktop.org/software/systemd/man/latest/systemd-suspend.service.html>
- TI E2E thread on TAS2781 Linux drivers for Lenovo laptops: <https://e2e.ti.com/support/audio-group/audio/f/audio-forum/1208376/tas2781-tas2781s-linux-drivers-for-lenovo-laptops>
- TI E2E TAS2781 follow-up discussion: <https://e2e.ti.com/support/audio-group/audio/f/audio-forum/1282089/tas2781-tas2781>
- Linux stable patch about conflicting Lenovo PCI SSID `17aa:386f` on Legion Pro 7 family: <https://lists-ec2.96boards.org/archives/list/linux-stable-mirror@lists.linaro.org/message/WQW4FBL5XV4HQXE5EKS2V5VWUAD6L6UU/>
- Linux stable patch showing Lenovo codec subsystem IDs such as `17aa:38a7` mapped into `ALC287_FIXUP_TAS2781_I2C`: <https://lists.linaro.org/archives/list/linux-stable-mirror@lists.linaro.org/message/BGBGOR32MFX5JYM6MZI7IXVN2IZ3DK64/>
- Upstream TAS2781 HDA patch adding support for both `TIAS2781` and `TXNW2781`: <https://www.spinics.net/lists/kernel/msg5723996.html>
- Follow-up TXNW2781 naming fix: <https://www.spinics.net/lists/kernel/msg5754503.html>
- Stable TAS2781-related patch activity showing this driver area is still evolving: <https://www.spinics.net/lists/stable/msg906717.html>
- More recent ALC287/TAS2781 quirk work for Lenovo hardware: <https://www.spinics.net/lists/kernel/msg6016697.html>

Bug reports and field reports:

- Ubuntu / ALSA Launchpad report for Legion Pro 7 speaker failures: <https://bugs.launchpad.net/ubuntu/+source/alsa-driver/+bug/2040020>

Community references:

- Original Yoga Pro 9i Gen 9 Linux workaround repo: <https://github.com/maximmaxim345/yoga_pro_9i_gen9_linux>
- Related gist documenting the same workaround class: <https://gist.github.com/rraks/4edddb99b50b94fe6298adbf3c9f43eb>

## Safety Notes

- This is a hardware-specific workaround, not a proper upstream fix.
- It writes directly to I2C device registers.
- It is intended for Linux systems already known to use the TAS2781 smart amp path.
- If your laptop uses a different amp, a different codec, or a different address layout, do not install this unchanged.
- If a future kernel version fixes your laptop properly, remove this workaround and retest the native driver path.
