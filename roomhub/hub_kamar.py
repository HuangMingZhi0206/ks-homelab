#!/usr/bin/env python3
"""Room hub — Raspberry Pi side, for the SMART ROOM sketch on the Arduino.

The Arduino owns the panel: it reads its own buttons, draws its own screen and
sends the IR. It is not a dumb terminal, so this daemon does not drive it. It
does the three things the Arduino cannot do for itself:

  1. Tell it what time it is. An Uno has no clock. It counts millis() from
     whenever it last booted, and it boots blank every time this port is
     opened, so without us the screen shows --:--:-- forever.
  2. Publish the DHT11 readings as Prometheus metrics, so room temperature
     lands in Grafana next to everything else.
  3. Accept commands from the rest of the house — Telegram, Home Assistant,
     a cron job — and pass them to the board.

Run it under systemd (see roomhub.service). It is written to survive the
Arduino being unplugged, reset, or re-enumerated on a different port.
"""

from __future__ import annotations

import errno
import logging
import os
import re
import select
import time
from pathlib import Path

import serial
from serial.tools import list_ports

# A CH340 board appears as /dev/ttyUSB*, not /dev/ttyACM* — that is an Uno
# clone with a different USB bridge, and the difference matters because the
# number can also move between reboots. Prefer finding the board by its USB id
# and fall back to the fixed path.
CH340_VID_PID = (0x1A86, 0x7523)
FALLBACK_PORT = "/dev/ttyUSB0"

# Must match Serial.begin() in roomhub.ino. There is no negotiation on a
# serial line: if the two ends disagree, every byte arrives as plausible
# garbage and nothing reports an error.
BAUD = 9600

# The sketch keeps time with millis(), clocked by whatever oscillator the
# clone was built with. A ceramic resonator drifts on the order of minutes per
# day, so resend the time regularly rather than only at boot.
RESYNC_EVERY = 30 * 60

# node-exporter reads every .prom file in this directory on each scrape and
# serves whatever it finds. It also publishes node_textfile_mtime_seconds, so
# a stale file is visible as stale instead of quietly reporting old numbers.
TEXTFILE = Path(
    os.environ.get("ROOMHUB_TEXTFILE", "/opt/homelab/monitoring/textfile/roomhub.prom")
)

# Commands arrive here as lines. A FIFO rather than a socket: no port, no
# listener to secure, and file permissions are the whole access control story.
#   echo 'ACPOWER=OFF' > /run/roomhub/cmd
FIFO = Path(os.environ.get("ROOMHUB_FIFO", "/run/roomhub/cmd"))

# Only these reach the board. The sketch ignores anything it does not
# recognise, but a whitelist keeps a typo in a cron job from becoming a
# mystery, and the ranges here are the same ones the sketch enforces.
ALLOWED = re.compile(
    r"^(SEND=[0-1],\d{1,2}|ACTEMP=(1[6-9]|2\d|30)|ACPOWER=(ON|OFF)|PING|TIME)$"
)

log = logging.getLogger("roomhub")


def find_port() -> str:
    for p in list_ports.comports():
        if (p.vid, p.pid) == CH340_VID_PID:
            return p.device
    return FALLBACK_PORT


def parse_status(line: str) -> dict[str, str]:
    """STATUS;T=27.5;H=60;JAM=12:34:56;AC=ON;ACT=25;ACF=a -> dict.

    JAM contains colons, so split each field on the first '=' only.
    """
    out: dict[str, str] = {}
    for field in line.split(";")[1:]:
        key, sep, value = field.partition("=")
        if sep:
            out[key] = value
    return out


def as_float(value: str | None) -> float | None:
    """The sketch prints NA when the DHT11 read failed. That is not zero, and
    writing zero would put a believable wrong number on the graph."""
    if value is None or value == "NA":
        return None
    try:
        return float(value)
    except ValueError:
        return None


class Hub:
    def __init__(self) -> None:
        self.ser: serial.Serial | None = None
        self.fifo_fd: int | None = None
        self.rx = bytearray()
        self.last_sync = 0.0
        self.status: dict[str, str] = {}
        self.last_status = 0.0

    # -- link ----------------------------------------------------------------

    def connect(self) -> None:
        """Open the port. Opening it toggles DTR, which resets the board.

        Do not sleep through the reset: the sketch says READY;SMARTROOM when
        it has finished booting, which is both more reliable than a guessed
        delay and the signal that the clock now needs setting.
        """
        port = find_port()
        self.ser = serial.Serial(port, BAUD, timeout=0)
        self.rx.clear()
        log.info("opened %s at %d baud, waiting for the board to boot", port, BAUD)

    def open_fifo(self) -> None:
        """Open read-write, which looks wrong and is deliberate.

        A FIFO opened read-only reports EOF the moment the last writer closes,
        and select() then marks it readable forever. Holding a writer open
        ourselves means it simply stays empty until someone writes a line.
        """
        try:
            FIFO.parent.mkdir(parents=True, exist_ok=True)
            if not FIFO.exists():
                os.mkfifo(FIFO, 0o660)
            self.fifo_fd = os.open(FIFO, os.O_RDWR | os.O_NONBLOCK)
            log.info("command fifo at %s", FIFO)
        except OSError as e:
            log.warning("no command fifo (%s); the panel still works", e)
            self.fifo_fd = None

    def send(self, line: str) -> None:
        if not self.ser:
            return
        try:
            self.ser.write((line + "\n").encode("ascii", "ignore"))
        except serial.SerialException as e:
            log.warning("write failed: %s", e)

    def sync_time(self) -> None:
        self.send(time.strftime("TIME=%H:%M:%S"))
        self.last_sync = time.monotonic()

    # -- dispatch ------------------------------------------------------------

    def handle(self, line: str) -> None:
        if line.startswith("READY"):
            log.info("board booted: %s", line)
            self.sync_time()
        elif line.startswith("STATUS;"):
            self.status = parse_status(line)
            self.last_status = time.time()
            self.write_metrics()
        elif line.startswith("IR;"):
            # Someone pressed a button at the panel and IR went out. Worth a
            # log line: it is the only record that the room was touched.
            log.info("%s", line)
        elif line.startswith("ACK") or line == "PONG":
            log.debug("%s", line)
        else:
            log.debug("unhandled: %s", line)

    def command(self, raw: str) -> None:
        cmd = raw.strip().upper()
        if not cmd:
            return
        if not ALLOWED.match(cmd):
            log.warning("rejected command: %s", raw.strip()[:40])
            return
        if cmd == "TIME":
            self.sync_time()
            return
        log.info("command: %s", cmd)
        self.send(cmd)

    # -- metrics -------------------------------------------------------------

    def write_metrics(self) -> None:
        s = self.status
        temp = as_float(s.get("T"))
        hum = as_float(s.get("H"))

        lines = [
            "# HELP roomhub_up Arduino room panel is answering on serial.",
            "# TYPE roomhub_up gauge",
            "roomhub_up 1",
            "# HELP roomhub_last_status_timestamp_seconds Last STATUS line received.",
            "# TYPE roomhub_last_status_timestamp_seconds gauge",
            f"roomhub_last_status_timestamp_seconds {self.last_status:.0f}",
        ]

        # Omit rather than zero when the sensor failed: a gap in the graph is
        # honest, a 0 C bedroom is not.
        if temp is not None:
            lines += [
                "# HELP roomhub_room_temperature_celsius DHT11 room temperature.",
                "# TYPE roomhub_room_temperature_celsius gauge",
                f"roomhub_room_temperature_celsius {temp}",
            ]
        if hum is not None:
            lines += [
                "# HELP roomhub_room_humidity_percent DHT11 relative humidity.",
                "# TYPE roomhub_room_humidity_percent gauge",
                f"roomhub_room_humidity_percent {hum}",
            ]

        # What the Arduino believes about the AC, which is not the same as what
        # the AC is doing — a one-way IR link cannot know. If the original
        # remote was used, this is wrong until the next command from here.
        if "AC" in s:
            lines += [
                "# HELP roomhub_ac_power AC power as last commanded from the panel.",
                "# TYPE roomhub_ac_power gauge",
                f"roomhub_ac_power {1 if s['AC'] == 'ON' else 0}",
            ]
        target = as_float(s.get("ACT"))
        if target is not None:
            lines += [
                "# HELP roomhub_ac_target_celsius AC setpoint as last commanded.",
                "# TYPE roomhub_ac_target_celsius gauge",
                f"roomhub_ac_target_celsius {target}",
            ]

        lines += [
            "# HELP roomhub_clock_synced Arduino clock has been set since it booted.",
            "# TYPE roomhub_clock_synced gauge",
            f"roomhub_clock_synced {0 if s.get('JAM', 'NA') == 'NA' else 1}",
            "",
        ]

        # Write and rename: node-exporter may read this file at any moment, and
        # a partial write would be served as a truncated metrics page.
        try:
            TEXTFILE.parent.mkdir(parents=True, exist_ok=True)
            tmp = TEXTFILE.with_suffix(".prom.tmp")
            tmp.write_text("\n".join(lines))
            os.replace(tmp, TEXTFILE)
        except OSError as e:
            log.warning("cannot write %s: %s", TEXTFILE, e)

    def drop_metrics(self) -> None:
        """The board is gone. Say so, rather than leaving the last reading in
        place looking current."""
        try:
            TEXTFILE.write_text(
                "# HELP roomhub_up Arduino room panel is answering on serial.\n"
                "# TYPE roomhub_up gauge\nroomhub_up 0\n"
            )
        except OSError:
            pass

    # -- loop ----------------------------------------------------------------

    def pump_serial(self) -> None:
        assert self.ser is not None
        data = self.ser.read(4096)
        if not data:
            return
        self.rx.extend(data)
        while b"\n" in self.rx:
            raw, _, rest = self.rx.partition(b"\n")
            self.rx = bytearray(rest)
            line = raw.decode("utf-8", "replace").strip()
            if line:
                self.handle(line)
        # A sender stuck mid-line must not grow this without limit.
        if len(self.rx) > 4096:
            self.rx.clear()

    def pump_fifo(self) -> None:
        assert self.fifo_fd is not None
        try:
            data = os.read(self.fifo_fd, 4096)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return
            raise
        for line in data.decode("utf-8", "replace").splitlines():
            self.command(line)

    def run_forever(self) -> None:
        self.open_fifo()
        while True:
            try:
                if self.ser is None:
                    self.connect()

                fds = [self.ser.fileno()]  # type: ignore[union-attr]
                if self.fifo_fd is not None:
                    fds.append(self.fifo_fd)

                # select() sleeps in the kernel until something arrives. That
                # is what keeps this at roughly zero CPU while still reacting
                # to a command the instant it is written — a poll-and-sleep
                # loop would cost both idle wakeups and latency.
                ready, _, _ = select.select(fds, [], [], 5.0)

                for fd in ready:
                    if fd == self.fifo_fd:
                        self.pump_fifo()
                    else:
                        self.pump_serial()

                if time.monotonic() - self.last_sync > RESYNC_EVERY:
                    self.sync_time()

                # The sketch reports every 5 s, but only while it is showing
                # the home screen: reporting mid-menu would interrupt IR
                # timing. Standing in a menu is therefore not a fault, and
                # three minutes of silence is.
                if self.last_status and time.time() - self.last_status > 180:
                    log.warning("no STATUS for 3 minutes, pinging")
                    self.send("PING")
                    self.last_status = time.time()

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
                self.drop_metrics()
                time.sleep(3)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        Hub().run_forever()
    except KeyboardInterrupt:
        log.info("stopped")


if __name__ == "__main__":
    main()
