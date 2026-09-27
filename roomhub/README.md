# Room hub

An Arduino with an LCD Keypad Shield, wired to the Pi over USB, as a physical
panel for the homelab: five buttons in, two rows of text back.

```
roomhub.ino        sketch for the Arduino
hub_kamar.py       daemon on the Pi
roomhub.service    systemd unit for the daemon
```

## Protocol

Line-based, newline-terminated, in both directions:

| Direction | Message | Meaning |
|---|---|---|
| Arduino → Pi | `HELLO:roomhub` | board booted, link is live |
| Arduino → Pi | `BTN:SELECT` | a button was pressed |
| Pi → Arduino | `LCD:Homelab\|47.2 C` | write two rows, `\|` splits them |
| Pi → Arduino | `BL:0` | backlight off |

Text, not binary, on purpose: you can debug the whole thing with a serial
monitor and read what is happening.

## The board is a CH340 clone

It appears as **`/dev/ttyUSB0`**, not `/dev/ttyACM0`. That path belongs to an
Arduino with the ATmega16U2 bridge; this one uses a CH340, and Linux hands
those to a different driver. The daemon looks the board up by its USB id
(`1a86:7523`) first, so the number moving between reboots does not matter.

## Before it will run

The port is owned by `root:dialout` with mode `crw-rw----`, so the user
running the daemon must be in that group:

```bash
sudo usermod -aG dialout ubuntu
```

Log out and back in — group membership is read at login, so an existing shell
keeps the old set and the daemon inherits it.

## Install

```bash
sudo cp /opt/homelab/roomhub/roomhub.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now roomhub
journalctl -u roomhub -f
```

## Why no `delay()` anywhere

On a board with one thread, every `delay()` is time the rest of the system
does not exist: a button press is missed, and a serial line arrives half-read.
The sketch debounces by *stability* instead — a reading has to hold the same
value for 30 ms before it counts — which also solves a problem specific to
this shield. All five buttons share one analog pin through a resistor ladder,
so a key travelling to its position passes through the voltages of its
neighbours: a single sample can report `LEFT` on the way to `SELECT`.

The thresholds sit midway between the nominal readings rather than near them.
Supply sag, resistor tolerance and a long USB cable all shift the values, and
midpoints keep the widest margin on both sides.

## Actions

`ACTIONS` in `hub_kamar.py` maps a button name to a function returning the two
rows to display. The ones shipped are small on purpose — status, disk, restart
one named container, backlight, and a placeholder.

Keep destructive actions narrow. A wrong press at a wall panel should cost one
container, not the stack.
