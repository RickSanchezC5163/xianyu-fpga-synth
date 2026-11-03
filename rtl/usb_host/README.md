# USB Host transport prototype

`usb_hid_host.v`, `usb_hid_host_rom.v`, `ukp.s`, `asukp.py`, and the generated
`usb_hid_host_rom.mem` are adapted from
[m1nl/usb_hid_host](https://github.com/m1nl/usb_hid_host), commit
`e49217661b275554807760d4e12097b0f189316a`, Apache-2.0. The upstream
copyright notices are preserved; see `LICENSE`.

Local changes recognize this project's measured SMK-25 VID/PID 4353:4B4D,
select bulk-IN endpoint 4, skip HID-only initialization requests, and expose
received bytes. The upstream eight-byte receive cap was expanded to the
device's 64-byte bulk maximum. The receiver now buffers the complete packet,
checks SYNC, DATA PID, bit stuffing, length and CRC16 at EOP, and tracks the
DATA0/DATA1 sequence for this one configured bulk-IN endpoint. Invalid packets
skip the ROM's ACK branch; valid duplicates remain ACK eligible but emit no
MIDI bytes. Reset/reconfiguration/disconnect resets the expected toggle.
Committed bytes drain at one byte per eight USB clocks to preserve the bundled
USB-to-audio CDC interval. A new transaction cannot start until draining ends.
Enumeration and HID receive paths retain their original protocol behavior. This is a
dedicated USB transaction sequencer in FPGA HDL, not a general-purpose RISC-V
CPU and not part of the audio sample computation.

**Status (2026-09-28):** the SMK-25 has enumerated on Tang Mega 60K and
played through the FPGA audio engine without a PC in the MIDI path. The
`mega60k_usb_audio_top` image has been programmed to external Flash and
verified by Programmer. Its direct-USB power-on gain is now 255/255; keyboard
KNOB-B volume spans 0–255. A JTAG reprogram loaded this image and UART status
read back volume 255. A full power-off startup check remains pending. Keep the
speaker or headphone's physical volume low before connecting or rebooting.
This is still a device-specific Host; polyphony, delay, DAC format, and the
self-designed-interaction boundary need separate competition verification.

**Repair validation (2026-10-01):** see [review regression record](../REVIEW_REGRESSIONS_2026-10-01.md). The repaired image has simulation and build evidence; it has not replaced the previously programmed Flash image or undergone a new listening test. Recovered-bit tests verify the receive path and ACK eligibility flag, not electrical USB timing or actual ACK turnaround.
