# Wall display (kiosk)

Runs a Grafana dashboard fullscreen on a physical screen attached to the
Proxmox host, with no login prompt and no browser chrome. Everything here is
host-level setup — the repo side is just `KIOSK_IP` in `.env`.

## How the no-login part works

Two pieces, both already in this repo:

- An Authelia `bypass` rule scoped to a single address (`KIOSK_IP` in `.env`)
- Grafana's anonymous `Viewer` role, enabled in `docker-compose.yml`

Scoping the bypass to one host matters: bypassing the whole Grafana hostname
would hand every client on the LAN an unauthenticated dashboard. Editing still
requires a real Grafana login, and every other client still hits the SSO portal.

## A caveat worth weighing first

If the Proxmox host also runs the router as a VM — OPNsense here — then a
browser on that host competes for CPU with everything routing your traffic. On
a 2-core machine, a rendering dashboard can make the network feel laggy for
reasons that look completely unrelated.

Mitigate by raising the router VM's **CPU units** (Options → CPU units, 100 →
2000) so the scheduler always favours it. A Raspberry Pi or any spare device
with a browser avoids the problem entirely and needs no server-side setup.

## Setup

All commands run on the **Proxmox host**, not in a container. Use SSH or the web
UI shell — not the physical console, since the service takes it over.

Minimal X, no desktop environment:

```bash
apt update && apt install --no-install-recommends -y \
  xserver-xorg-core xserver-xorg-input-libinput xinit x11-xserver-utils \
  chromium unclutter openbox xdotool
```

`openbox` is not optional. Chromium's `--kiosk` relies on a window manager to be
given the screen size; without one the page renders cut off.

An unprivileged user — Chromium refuses to run as root:

```bash
useradd -m -G video,input,tty kiosk
printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
```

The session script:

```sh
#!/bin/sh
# /home/kiosk/kiosk.sh
xset -dpms; xset s off; xset s noblank
unclutter -idle 0 -root &
openbox &
sleep 2
(sleep 5; xdotool mousemove 9999 9999) &
exec chromium --kiosk --noerrdialogs --disable-infobars \
  --disable-session-crashed-bubble --check-for-update-interval=31536000 \
  "https://grafana.<domain>/d/<uid>/<slug>?orgId=1&refresh=60s&kiosk"
```

`sleep 2` gives openbox time to come up first. The pointer parks itself in the
far corner five seconds in — `unclutter` alone sometimes leaves it sitting in the
middle of the screen, covering a panel. `&kiosk` on the URL drops
Grafana's menus and header; `&kiosk=tv` keeps the top bar. Prefer an explicit
`refresh=60s` over `refresh=auto` on a screen that never sleeps.

The unit:

```ini
# /etc/systemd/system/kiosk.service
[Unit]
Description=Grafana kiosk display on tty1
After=network-online.target

[Service]
User=kiosk
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
ExecStart=/usr/bin/startx /home/kiosk/kiosk.sh -- vt1 -nolisten tcp
Restart=always
RestartSec=10
# startx ignores SIGTERM, so without this every restart waits out the default
# 90s stop timeout before systemd gives up and kills it.
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
```

```bash
chmod +x /home/kiosk/kiosk.sh && chown kiosk:kiosk /home/kiosk/kiosk.sh
systemctl daemon-reload && systemctl enable --now kiosk.service
```

## Two things that will bite

**`getty@tty1` owns the console.** Proxmox runs a login prompt on tty1, and X
loses the fight for it silently — the service reports `active (running)` with a
single task and a few MB of memory, no error anywhere, and the screen never
changes. The Xorg log shows `VT_GETSTATE failed: Input/output error`.

```bash
systemctl disable --now getty@tty1.service
```

The text console then lives on **Ctrl+Alt+F2**; SSH is unaffected.

**The host needs to resolve the service hostname.** Its resolver is whatever the
Proxmox installer wrote, which is usually not your local DNS server. Set it in
**Datacenter → node → System → DNS**, then confirm:

```bash
getent hosts grafana.<domain>
```

Without this the service runs correctly and displays a DNS error page, which
looks nothing like a DNS problem.

## Turning the panel off on a schedule

The session disables DPMS so the screen never sleeps mid-day, which also means it
cannot be blanked without re-enabling it first. This wrapper does both:

```sh
#!/bin/sh
# /usr/local/bin/kiosk-screen
export DISPLAY=:0 XAUTHORITY=/home/kiosk/.Xauthority
case "$1" in
  off) xset +dpms; xset dpms force off ;;
  on)  xset -dpms; xset s off; xset s noblank; xset dpms force on ;;
  *)   echo "usage: kiosk-screen on|off"; exit 1 ;;
esac
```

```bash
chmod +x /usr/local/bin/kiosk-screen
```

Overnight, via root's crontab:

```
0 23 * * * /usr/local/bin/kiosk-screen off
0 7  * * * /usr/local/bin/kiosk-screen on
```

Only the panel is powered down — Chromium and the dashboard keep running, so the
display is already current the moment it comes back rather than reloading.

Worth doing less for the ~5-10 W than for the panel: a wall display otherwise
shows the same layout continuously, and eight dark hours a night is cheap
insurance against image retention.

## Diagnosing

`Tasks:` and `Memory:` in `systemctl status` tell you instantly whether X and
Chromium actually started — a real session is dozens of tasks and hundreds of
MB, not one task and 1.5 MB.

```bash
systemctl status kiosk.service --no-pager -l
journalctl -u kiosk.service -n 40 --no-pager
tail -30 /home/kiosk/.local/share/xorg/Xorg.0.log
```

## Reverting

```bash
systemctl disable --now kiosk.service
systemctl enable --now getty@tty1.service
```
