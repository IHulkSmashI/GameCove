# Streaming from your PC

The Stream tab plays games that run on your PC, on the handheld's screen. The PC
runs **Vibepollo**; the handheld runs **Moonlight**; GameCove finds the PC, pairs,
shows its games with box art, wakes it, starts the stream sized for this screen
and treats the stream like any running game (Guide goes home and back, the quick
menu works, Exit game ends it).

## The pieces

| Piece | Where | What it does |
| --- | --- | --- |
| [Vibepollo](https://github.com/Nonary/Vibepollo) | PC | The stream host. A fork of [Apollo](https://github.com/ClassicOldSong/Apollo), which is a fork of [Sunshine](https://github.com/LizardByte/Sunshine). Speaks NVIDIA's GameStream protocol, so any Moonlight client can connect. |
| [Moonlight](https://moonlight-stream.org) (moonlight-qt) | Handheld | Decodes the video, plays the sound, sends the controller. GameCove starts it from its command line. Flatpak `com.moonlight_stream.Moonlight`, or a native `moonlight` on PATH. |
| GameCove | Handheld | The Stream tab and `scripts/streaming/`: discovery, pairing, app list, box art, Wake-on-LAN, settings, the session. |

Why Vibepollo: it does what Apollo does on top of Sunshine (a **virtual display**
created for each stream at exactly the resolution, refresh rate and HDR mode the
client asks for, so a 1920x1200 handheld gets a 1920x1200 desktop instead of a
letterboxed 1080p one; **per-client permissions**; **client commands**; an app list
with art) and adds display recovery (no stuck virtual screens), Windows Graphics
Capture as a service, Playnite library sync, a frame limiter that follows the
client's frame rate (RTSS / NVIDIA), Lossless Scaling and Smooth Motion hooks,
scoped API tokens, and, for paired clients it allows, **putting the PC to sleep**.
Windows is its main platform; Linux and SteamOS hosts are beta / experimental.
Plain Sunshine and Apollo hosts work too (GameCove detects which one it talks to).

Which client: on Linux, Moonlight (moonlight-qt) is the reference GameStream
client and the one Vibepollo is tested against. Artemis, Apollo's own client
with its OTP pairing and virtual-display extras, is Android-only. GameCove doesn't
decode video itself and doesn't reimplement the protocol: it drives Moonlight.

## Setting up the PC (once)

1. Install Vibepollo from its [releases page](https://github.com/Nonary/Vibepollo/releases)
   (the Stream tab shows this as a QR code). Releases are code-signed through SignPath.
2. Open its web UI on the PC: `https://localhost:47990`. Make a username and password.
3. Add your games under **Applications** (or turn on Playnite sync). Box art set
   there is what the handheld shows.
4. Leave the virtual display on (the default): streams then match the handheld's
   screen exactly. HDR games need HDR on in the handheld's display settings.
5. Optional: Wake-on-LAN in the PC's BIOS/UEFI and in the network adapter's
   driver settings ("Wake on Magic Packet"), so GameCove can wake a sleeping PC.

## Pairing

1. On the handheld, open the Stream tab. A PC on the same network shows up by itself;
   otherwise press **Y** and type its address.
2. Pick the PC and press **A**. GameCove shows a four-digit PIN and the PC's web UI
   address.
3. On the PC, in Vibepollo's web UI, open **PIN**, type the PIN and a name for the
   handheld, and press **Send**. The handheld moves on by itself.
4. Then, in the web UI under **Clients**, allow **Launch apps** and **controller input**
   for the handheld. Apollo and Vibepollo give new clients only "list" and "view";
   without "launch" streams won't start. GameCove reads the permissions and says so
   when they're missing; if the app list says "Permission denied", allow
   **List applications** too.

How it works: GameCove runs `moonlight pair --pin <PIN> -- <pc>` with
`QT_QPA_PLATFORM=offscreen` (no Moonlight window over GameCove), shows the PIN
itself, and watches Moonlight's settings file for the PC's certificate, which
Moonlight writes once the PIN matched. Pairing belongs to Moonlight: a PC paired in
Moonlight before shows up already paired, and forgetting a PC in GameCove leaves
Moonlight's pairing alone. Apollo's OTP pairing (the host makes the PIN) needs a
client that sends the OTP hash; moonlight-qt doesn't, so GameCove uses the normal
PIN flow.

## What GameCove does, and with what

| Job | How |
| --- | --- |
| Find PCs | `avahi-browse -rpt _nvstream._tcp` (Sunshine-family hosts announce it over mDNS). Nothing found and no PCs yet: a TCP probe of port 47989 across this network (/22 or smaller, 0.7 s), then `serverinfo` on the ones that answer. PCs Moonlight already knows come from its settings. |
| Add by address | IP, `.local` name, `host:port`, `[IPv6]:port`, Tailscale IP or MagicDNS name. Kept even if it doesn't answer yet. |
| Status and latency | `GET http://<pc>:47989/serverinfo` through curl; the TCP connect time is the latency shown. Paired PCs also answer `https://<pc>:47984/serverinfo` with Moonlight's client certificate: the real MAC, what's running (`currentgame`), the Apollo/Vibepollo permission bits, and Vibepollo's sleep permission. Asleep = not answering but its MAC is known (from Moonlight, the paired serverinfo or the ARP cache). |
| Apps and box art | `https://<pc>:47984/applist` and `/appasset?appid=N&AssetType=2&AssetIdx=0` with Moonlight's certificate (curl: Godot's HTTP client can't present a client certificate). Falls back to `moonlight list --csv -- <pc>`. Art is cached under `user://streaming/art/<pc uuid>/`. |
| Wake | The magic packet, sent the way Moonlight sends it: to the PC's addresses, 255.255.255.255 and every network's broadcast, on ports 9, 47009 and 47998-48010 (shifted if the PC moved its port). Then GameCove watches for the PC for 90 s. |
| Sleep | Vibepollo only, when it allows this client: `POST https://<pc>:47984/power-actions/v1/sleep`. |
| Stream | `moonlight stream <settings> -- <pc> "<app>"` with the resolved settings (below; the PC and the app's title come last, after `--`, so a title that begins with `-` is never read as an option), inside a systemd user scope `app-steam-app<id>-<n>` and a small `reaper` wrapper (`/usr/libexec/gamecove/reaper`), so gamescope can tell the stream's app id even for the Flatpak, which moves itself into its own `app-flatpak-*` scope (gamescope finds app ids by cgroup, else by a parent process named `reaper` with `SteamLaunch AppId=<id>`, as Steam's own reaper). GameSession then focuses it like a game; no frame limit and no Auto TDP for streams (the PC renders, the handheld only decodes). |
| End | Moonlight's own exit (Start+Select+LB+RB, or the host quitting the app) ends the session. Exit game in the quick menu stops the wrapper and runs `flatpak kill com.moonlight_stream.Moonlight`; the game keeps running on the PC, so **Resume** picks it up. **Quit on PC** runs `moonlight quit <pc>`. |
| Install Moonlight | `flatpak remote-add --user --if-not-exists flathub …` then `flatpak install --user --noninteractive -y flathub com.moonlight_stream.Moonlight`. A user install needs no password, so it works in Gaming Mode; the installer offers the same under Extras. |

Moonlight's client certificate and key are copied from its settings file to
`$XDG_RUNTIME_DIR/gamecove-stream/` (mode 0600, a tmpfs only this user can read)
for curl, and removed when GameCove quits. curl uses `-k` because the PC's
certificate is self-signed and doesn't name its address; GameCove only reads lists
and pictures this way.

## Stream settings

Per PC, and per app when you want ("Own settings for this game"). X on a PC or an
app opens them; the bottom line says what the stream will actually be.

| Setting | Choices | Notes |
| --- | --- | --- |
| Resolution | Native, 720p, 1080p, 1440p, 4K | Native = this panel (e.g. 1920x1200). Vibepollo makes the PC's virtual display that size. |
| Frame rate | Native, 30, 40, 60, 90, 120 | Native = the panel's top refresh; never above it. |
| Quality | Saver, Balanced, Best | Moonlight's own default bitrate for the resolution and frame rate x 0.6 / 1.0 / 1.6 (moonlight-qt `getDefaultBitrate`). Remote PCs start on Saver. |
| Video format | Auto, AV1, HEVC, H.264 | Auto: AV1 when this handheld decodes it (vainfo, else by GPU family: RDNA3+ and Intel Xe-LPG+ yes, Van Gogh / Vega no) and the PC encodes it (`ServerCodecModeSupport`), else HEVC, else H.264. |
| HDR | On / Off | Only when HDR is on in the handheld's display settings, the decoder does 10-bit and the PC sends 10-bit. |
| Smooth frame pacing, V-Sync, Sound on the PC too, Stream stats, Swap A/B and X/Y, Sound (stereo / 5.1 / 7.1) | | Moonlight's toggles. |

Always on: fullscreen, game optimizations, keep awake, one controller (InputPlumber's
virtual pad; a second would double input), system keys stay local. Settings are
stored in `user://streaming/settings.cfg`; PCs in `user://streaming/hosts.json`.

## Playing away from home

- **Tailscale (easiest):** set it up on the PC and the handheld (Bazzite ships it;
  on SteamOS follow Tailscale's Steam Deck guide), sign both into the same tailnet, then press Y on the Stream tab and type the PC's
  Tailscale address (`100.x.y.z` or `pc-name.tailnet.ts.net`). It shows as Remote and
  starts on the Saver quality. No ports to open.
- **Port forwarding:** forward TCP 47984, 47989, 47990 (web UI; better not), 48010 and
  UDP 47998-48000, 48002, 48010 to the PC, then add the router's public address. Prefer
  a VPN: the GameStream ports aren't meant to face the internet.
- **Waking over the internet:** magic packets don't cross routers on their own. Use a
  router with a WoL feature, or keep the PC awake.
- Upload speed at home matters most: Saver at 1920x1200 / 60 fps is about 14 Mb/s.

## Troubleshooting

- *PC not found:* same network? Vibepollo running? Some networks block mDNS: add by
  address. Windows Firewall must allow Vibepollo (its installer does).
- *Pairing timed out:* start again (new PIN); type it within three minutes.
- *Stream starts then stops:* allow **Launch apps** and controller input for this
  client in Vibepollo's web UI.
- *Can't wake:* Wake-on-LAN off in BIOS or the adapter, or the PC was shut down
  rather than asleep (many boards only wake from sleep). Wi-Fi PCs rarely wake.

## Needs real hardware to confirm

- gamescope focusing the Moonlight Flatpak through the `reaper` parent walk (unit-tested
  wrapper; not yet seen on a device), and Exit game's `flatpak kill` path.
- `moonlight pair` under `QT_QPA_PLATFORM=offscreen` inside the Flatpak (the offscreen
  Qt platform plugin ships in the KDE runtime).
- InputPlumber's virtual pad reaching Moonlight in game mode; Guide returning home mid-stream.
- HDR streams on an OLED handheld with gamescope's HDR on.
- Wake-on-LAN timing and Vibepollo's sleep action.

## Sources

moonlight-qt `app/cli/*` (CLI flags, list CSV, pair `--pin`), `app/backend/nvcomputer.cpp`
(settings file keys, Wake-on-LAN ports), `app/settings/streamingpreferences.cpp` (default
bitrate); moonlight-common-c `Limelight.h` (codec bits); Apollo and Vibepollo
`src/nvhttp.cpp` (serverinfo fields, applist, pairing and OTP, power actions) and
`src/crypto.h` (permission bits); gamescope `src/Utils/Process.cpp` (app ids by cgroup
and reaper); Flatpak `common/flatpak-run.c` (transient `app-flatpak-*` scopes).
