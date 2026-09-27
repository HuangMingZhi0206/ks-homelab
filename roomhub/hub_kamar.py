#!/usr/bin/env python3
"""Room hub — Raspberry Pi side.

Listens to the Arduino on USB serial, turns button presses into actions, and
writes the result back to the LCD so the person standing at the panel sees
whether it worked.

Run it under systemd (see roomhub.service). It is written to survive the
Arduino being unplugged, reset, or re-enumerated on a different port.
"""

from __future__ import annotations

import logging
import subprocess
import time
from pathlib import Path
from typing import Callable

import serial
from serial.tools import list_ports

# A CH340 board appears as /dev/ttyUSB*, not /dev/ttyACM* — that is an Uno
# clone with a different USB bridge, and the difference matters because the
# number can also move between reboots. Prefer finding the board by its USB id
# and fall back to the fixed path.
CH340_VID_PID = (0x1A86, 0x7523)
FALLBACK_PORT = "/dev/ttyUSB0"
BAUD = 115200

log = logging.getLogger("roomhub")


def find_port() -> str:
    for p in list_ports.comports():
        if (p.vid, p.pid) == CH340_VID_PID:
            return p.device
    return FALLBACK_PORT


# --- actions -----------------------------------------------------------------
#
# Each returns the two LCD rows to show. Keep them short: the screen is 16
# characters wide and anything longer is silently cut off.
#
# These are deliberately small and safe. Replace the bodies with what you
# actually want the panel to do.


def run(cmd: list[str], timeout: int = 20) -> bool:
    """Run a command, log its failure, and never raise.

    A daemon that dies because one action failed is worse than an action that
    quietly did nothing: the panel stops responding entirely.
    """
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if r.returncode:
            log.warning("%s exited %d: %s", cmd[0], r.returncode, r.stderr.strip()[:200])
        return r.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        log.warning("%s failed: %s", cmd[0], e)
        return False


def action_status(_: "Hub") -> tuple[str, str]:
    """Temperature and load — the two numbers worth a glance in passing."""
    try:
        milli = Path("/sys/class/thermal/thermal_zone0/temp").read_text().strip()
        temp = f"{int(milli) / 1000:.1f}C"
    except (OSError, ValueError):
        temp = "?"
    load = Path("/proc/loadavg").read_text().split()[0]
    return ("Homelab", f"{temp}  load {load}")


def action_disk(_: "Hub") -> tuple[str, str]:
    try:
        out = subprocess.run(
            ["df", "-h", "--output=avail,pcent", "/"],
            capture_output=True, text=True, timeout=5,
        ).stdout.split("\n")[1].split()
        return ("Disk /", f"{out[0]} free {out[1]}")
    except Exception:  # noqa: BLE001 - the panel should never crash on df
        return ("Disk /", "unavailable")


def action_restart_service(hub: "Hub") -> tuple[str, str]:
    """DUMMY: restart one container. Point this at whatever you actually fix
    from the panel — and keep it to one named service, never a blanket restart:
    a wrong press should cost you one container, not the stack."""
    hub.lcd("Restarting", "homepage...")
    ok = run(["docker", "restart", "homepage"], timeout=60)
    return ("Restart", "done" if ok else "FAILED")


def action_backlight(hub: "Hub") -> tuple[str, str] | None:
    """The panel lives in a bedroom; being able to kill the glare matters."""
    hub.backlight = not hub.backlight
    hub.send(f"BL:{1 if hub.backlight else 0}")
    return None  # nothing to say on screen, the screen just changed


def action_ask_ai(hub: "Hub") -> tuple[str, str]:
    """DUMMY: a placeholder for calling a local model.

    Left unwired on purpose — Ollama is stopped on this Pi because inference
    pulls the supply down hard enough to reboot the board. See docs/storage.
    """
    return ("AI", "disabled")


ACTIONS: dict[str, Callable[["Hub"], tuple[str, str] | None]] = {
    "SELECT": action_status,
    "UP": action_disk,
    "DOWN": action_restart_service,
    "LEFT": action_backlight,
    "RIGHT": action_ask_ai,
}


# --- hub ---------------------------------------------------------------------


class Hub:
    def __init__(self) -> None:
        self.ser: serial.Serial | None = None
        self.backlight = True

    # -- link ----------------------------------------------------------------

    def connect(self) -> None:
        """Open the port, waiting for the board to finish resetting.

        Opening a serial port toggles DTR, which resets the Arduino. Anything
        sent in the first couple of seconds lands in a bootloader that is not
        listening, so wait, then throw away whatever noise arrived.
        """
        port = find_port()
        self.ser = serial.Serial(port, BAUD, timeout=1)
        time.sleep(2.0)
        self.ser.reset_input_buffer()
        log.info("connected to %s at %d baud", port, BAUD)
        self.lcd("Homelab", "hub connected")

    def send(self, line: str) -> None:
        if not self.ser:
            return
        try:
            self.ser.write((line + "\n").encode("ascii", "ignore"))
        except serial.SerialException as e:
            log.warning("write failed: %s", e)

    def lcd(self, top: str, bottom: str = "") -> None:
        self.send(f"LCD:{top[:16]}|{bottom[:16]}")

    # -- dispatch ------------------------------------------------------------

    def handle(self, line: str) -> None:
        if line.startswith("HELLO:"):
            log.info("board announced itself: %s", line[6:])
            self.lcd("Homelab", "hub connected")
            return

        if not line.startswith("BTN:"):
            log.debug("ignored: %s", line)
            return

        name = line[4:].strip().upper()
        action = ACTIONS.get(name)
        if action is None:
            log.info("button %s has no action", name)
            return

        log.info("button %s", name)
        try:
            result = action(self)
        except Exception:  # noqa: BLE001 - one bad action must not end the daemon
            log.exception("action for %s raised", name)
            self.lcd("Error", name.lower())
            return

        if result:
            self.lcd(*result)

    # -- loop ----------------------------------------------------------------

    def run_forever(self) -> None:
        while True:
            try:
                if self.ser is None:
                    self.connect()

                # readline() blocks inside the kernel until a line arrives or
                # the 1s timeout expires. That is what keeps this at roughly
                # zero CPU — a polling loop with sleep() would wake constantly
                # and still add latency to every press.
                raw = self.ser.readline()  # type: ignore[union-attr]
                if not raw:
                    continue

                line = raw.decode("utf-8", "replace").strip()
                if line:
                    self.handle(line)

            except (serial.SerialException, OSError) as e:
                # Unplugged, reset, or renumbered. Drop the handle and retry —
                # the board is on the end of a USB cable in a bedroom, so this
                # is normal operation, not an error worth dying over.
                log.warning("link lost (%s), reconnecting in 3s", e)
                try:
                    if self.ser:
                        self.ser.close()
                except Exception:  # noqa: BLE001
                    pass
                self.ser = None
                time.sleep(3)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    try:
        Hub().run_forever()
    except KeyboardInterrupt:
        log.info("stopped")


if __name__ == "__main__":
    main()
