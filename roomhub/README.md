# Room hub

An Arduino Uno with an LCD Keypad Shield, an IR LED and a DHT11, wired to the
Pi over USB. It is a standalone remote control for the desk lamp and the
Panasonic AC, and the Pi is bolted on beside it — not in charge of it.

```
roomhub.ino        sketch for the Arduino (SMART ROOM IR REMOTE v10)
hub_kamar.py       daemon on the Pi
roomhub.service    systemd unit for the daemon
```

## Who owns what

The Arduino reads its own buttons, draws its own screen, holds the AC state
and sends the IR. Unplug the Pi and the panel still works; that is the point
of a wall control.

The Pi adds the three things the board cannot do alone:

- **The clock.** An Uno has no real-time clock. It counts `millis()` from its
  last boot, so without a `TIME=` line the screen reads `--:--:--` forever.
  Opening the serial port resets the board, so this happens on every connect.
- **Metrics.** The DHT11 readings become Prometheus metrics, so bedroom
  temperature sits in Grafana next to CPU and disk.
- **Remote commands.** Telegram, Home Assistant or cron can turn the AC on
  from outside the room.

## Protocol

Line-based, newline-terminated, 9600 baud.

| Direction | Message | Meaning |
|---|---|---|
| Arduino → Pi | `READY;SMARTROOM` | booted; the clock is unset |
| Arduino → Pi | `STATUS;T=27.5;H=60;JAM=12:34:56;AC=ON;ACT=25;ACF=a` | every 5 s, home screen only |
| Arduino → Pi | `IR;KAT=AC KAMAR;CMD=Suhu  +` | someone pressed a button and IR went out |
| Arduino → Pi | `ACK;TIME`, `PONG` | acknowledgements |
| Pi → Arduino | `TIME=12:34:56` | set the clock |
| Pi → Arduino | `SEND=0,3` | run a menu entry: `0`=lamp, `1`=AC |
| Pi → Arduino | `ACTEMP=24` | AC setpoint, 16–30 |
| Pi → Arduino | `ACPOWER=ON` / `OFF` | AC power |

**9600, not 115200.** There is no negotiation on a serial line. If the two
ends disagree, every byte still arrives — as plausible garbage — and nothing
reports an error. The daemon matches the `Serial.begin()` in the sketch, so
changing one means changing the other.

`STATUS` is only sent while the home screen is showing. Reporting from inside
a menu would collide with IR transmission, whose timing is measured in
microseconds. So metrics pausing while you stand at the panel is normal; the
daemon waits three minutes before it treats silence as a fault.

## Sending commands

```bash
echo 'ACPOWER=OFF' > /var/lib/roomhub/cmd
echo 'SEND=0,0'    > /var/lib/roomhub/cmd     # lamp on/off
```

A FIFO rather than a socket: no port, no listener to secure, and the file
permissions are the whole access-control story. The daemon whitelists the four
command forms above, so a typo in a cron job fails loudly in the journal
instead of becoming a mystery.

Under `/var/lib` and not `/run`, because Home Assistant bind-mounts this
directory. A bind mount pins the inode it was given when the container
started; `RuntimeDirectory` deletes and recreates `/var/lib/roomhub` on every
restart, so Home Assistant would go on writing into an inode nothing reads.
The writes would succeed and the AC would never move — the worst kind of
failure, because everything reports success.

## From the phone

`homeassistant/config/configuration.yaml` turns the FIFO into entities, so
they appear in the Companion app, in Assist, and in automations:

| Entity | What it does |
|---|---|
| `switch.ac_kamar` | AC power |
| `number.ac_suhu` | setpoint, 16–30 |
| `button.lampu_meja` / `lampu_terang` / `lampu_redup` | lamp |
| `sensor.suhu_kamar` / `sensor.kelembapan_kamar` | DHT11 |

The AC toggle can lag up to 30 seconds after a press: its state is read back
from Prometheus rather than assumed, so what you see is what the Arduino
actually holds.

Start `roomhub.service` before the Home Assistant container. The mount point
has to exist first, or Docker creates an empty directory of its own and the
FIFO will not be in it.

## What the AC metrics actually mean

`roomhub_ac_power` and `roomhub_ac_target_celsius` are what the **Arduino
believes**, not what the AC is doing. IR is one-way: there is no channel for
the unit to answer. Use the original remote and the board is out of date until
the next command from the panel. Any AC command resyncs it, because the whole
state is sent in one frame.

## The board is a CH340 clone

It appears as **`/dev/ttyUSB0`**, not `/dev/ttyACM0`. That path belongs to an
Uno with the ATmega16U2 bridge; this one uses a CH340, and Linux hands those
to a different driver. The daemon looks the board up by its USB id
(`1a86:7523`) first, so the number moving between reboots does not matter.

The port is owned by `root:dialout` with mode `crw-rw----`:

```bash
sudo usermod -aG dialout ubuntu
```

## USB or GPIO UART, never both

The header comment in the sketch documents a resistor divider from D1 to the
Pi GPIO pins. That is the alternative to USB, not an addition to it: D0/D1 are
shared with the USB bridge, and two transmitters on one line produce only
garbage. This homelab uses USB. Leave the GPIO wiring off.

## Install

```bash
sudo cp /opt/homelab/roomhub/roomhub.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now roomhub
journalctl -u roomhub -f
```

Stop the daemon before uploading a new sketch. Two processes cannot hold the
same serial port, and `avrdude` will fail with a device-busy error:

```bash
sudo systemctl stop roomhub
```
