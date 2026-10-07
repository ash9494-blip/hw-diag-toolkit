# Charging test - design notes (built in 1.15.0, toolkit/chargetest.sh)

Requested by Ash on 2026-10-01; built the same day into Peripherals (not the
Battery menu, as first planned). The steps below are what it does.

## What it answers on the bench

1. Does the machine see the charger at all? (DC jack, USB-C)
2. When plugged in, does the battery actually charge - and how fast?
3. Does the connection hold, or drop when the plug is moved? (loose DC jack,
   worn cable, cracked USB-C port - the most common charging repair)
4. Which USB-C ports can charge the machine, and at what power?
5. Is charging held back on purpose (a charge limit), so it is not
   mistaken for a fault?

## Where it lives

- New script `toolkit/chargetest.sh`, result key `CHARGE_RESULT`.
- Battery tile menu (battery.sh already has a menu: health, drain test) gets
  "Charging test". Every test gets a "Charging" tile. Not part of Full run -
  it needs someone to plug and unplug.
- Report section `CHARGING`, one `RESULT:` line.

## Steps

1. **Detect** (no action needed)
   - Adapters: `/sys/class/power_supply/*` with `type=Mains` (ADP1, AC) -
     `online`. USB-C sources: `ucsi-source-psy-*` - `online`, `voltage_now`,
     `current_max`, `usb_type` (needs `ucsi_acpi`; usbtest.sh loads it).
   - Battery: `status`, capacity, `power_now` or `current_now x voltage_now`.
   - Charge limit: `charge_control_end_threshold` (Toshiba/Dynabook "eco"
     mode via toshiba_acpi, also ThinkPad, ASUS). **Read only** - never
     written; changing firmware settings is off limits (invariant 4 spirit).
   - No battery but adapter online -> "runs on the adapter, no battery".
   - **Which flag decides "connected" (1.19.0).** The Mains flag, when there
     is one: the ACPI `ac` driver re-reads `_PSR` on every read. A USB-C
     psy's `online` (and `/sys/class/typec/portN-partner`) is only what the
     UCSI driver last heard from the port - on the TECRA A40-J the test said
     "connected" a minute after the unplug and the USB-C step waited forever
     for an unplug. USB-C flags count only with no Mains flag; with no flags,
     the battery status. The battery is also a second witness: discharging
     5 s straight after the unplug, or charging while no flag says so, means
     a flag is wrong - WARN, and the rest of the run goes by the battery.
     Every flag is shown on screen ("Charger flags") for the photo.

2. **Unplug / plug** (guided, like the drain test's steps)
   - "Unplug the charger" -> within 10 s: adapter `online=0` and battery
     `Discharging`. Else: "the machine does not notice the charger leaving".
   - "Plug it back in" -> within 10 s: `online=1` and `Charging` (or
     `Not charging` / `Full` when at or above the charge limit - say so).
   - Time from plug-in to "Charging" is recorded.

3. **Charge rate** (60-120 s, battery below ~95 %)
   - Sample power into the battery every 2 s. Report watts and % per minute.
   - Some firmware reports `power_now=0` while charging: fall back to the
     change in `energy_now`/`charge_now` over the window (needs 2-5 min).
   - Verdicts: charging normally / slowly (under ~10 W, or under 0.2 C of
     the pack's full capacity) / plugged in but not charging (below the
     limit, adapter online, status not Charging) -> suspect charger, DC jack
     board, charge IC or the pack.

4. **Wiggle check** (30 s, operator moves the plug and cable)
   - Count `online` drops and `Charging` <-> `Discharging` flips (poll every
     0.2 s; also watch `udevadm monitor --subsystem-match=power_supply`).
   - Any drop -> "connection broke N times while moved - suspect the DC jack
     or the cable". A live counter on screen, like the touchpad test.

5. **USB-C ports** (only when the machine has UCSI connectors)
   - Ask for the USB-C charger in each port in turn. A port only counts as
     tested if a charger was connected to it during the test (same rule as
     the USB test, invariant 6).
   - Per port: negotiated voltage x current (from the ucsi psy), PD or not,
     and whether the battery went to Charging. Example line:
     `USB-C port 1: charges - PD 20 V 3.25 A (65 W)`.
   - A barrel-jack adapter's wattage cannot be read on Linux; only USB-C PD
     reports it. Say so instead of guessing.
   - In and out by `plugged()`, never by the port. The port the charger went
     into is the one whose partner *appears* after the plug; a port that
     never reported its unplug cannot say, and the try is then recorded as
     "USB-C try N (the machine did not say which port)".

## Result

- PASS: seen, charges at a normal rate, no drops (and every USB-C port that
  had a charger charged).
- FAIL: not seen / not charging below the limit / drops on wiggle / a USB-C
  port that would not charge.
- PARTIAL: charging slowly, or a step skipped (no charger to hand).
- Report also lists: adapter type, charge limit if set, rate, time to start
  charging, drops counted, per-port USB-C results.

## Testing it

- QEMU has no battery or charger, but the kernel's `test_power` module
  (linux-modules-extra) creates a fake AC adapter and battery whose state is
  set through `/sys/module/test_power/parameters/` (`ac_online`,
  `battery_status`, `battery_capacity`...). Use it in the VM to script
  plug / unplug / drops. Check it is on the image before relying on it.
- Real hardware needed for: actual rates, UCSI USB-C reporting (still never
  verified on a real machine - see Open items), Toshiba charge limit.
