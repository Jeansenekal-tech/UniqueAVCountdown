# Unique AV Countdown

A stage / event countdown timer for macOS. The operator runs the show from the Mac, the presenter sees a big full-screen timer on a second display or projector, and you can drive it from a phone, Bitfocus Companion / Stream Deck (OSC), or a MIDI controller.

## Build it

Needs macOS 13 Ventura or later and Xcode (or just the Command Line Tools: `xcode-select --install`).

```bash
cd UniqueAVCountdown
./build_app.sh
```

This makes `build/Unique AV Countdown.app` (universal, Apple Silicon + Intel). Drag it to Applications. Run `./make_dmg.sh` afterwards for a drag-to-install `.dmg`. The first time, right-click → **Open** because it's not notarised.

To work on the code, double-click `Package.swift` to open it in Xcode, pick the *UniqueAVCountdown* scheme and *My Mac*, and press ⌘R.

The first time the phone remote or OSC is used, macOS asks to allow incoming network connections — click **Allow**.

## Updates

When the app opens, it checks your GitHub repo for a newer release. If there is one, it shows what's new with a **Download** button. To install, quit the app and drag the new one into Applications. You can also choose **Unique AV Countdown › Check for Updates…**. Settings › Updates turns the launch check off.

**One-time setup**

1. Put the project on GitHub (GitHub Desktop → *Add Existing Repository* → *Publish*). The repo must be **public**, because the app checks without logging in.
2. `Info.plist` → `UpdateGitHubRepo` is set to `Jeansenekal-tech/UniqueAVCountdown`. Change it only if the repo moves.
3. Install the GitHub command-line tool once: `brew install gh`, then `gh auth login`.
4. Build and install that version on your Macs. Only copies built after step 2 know where to look.

**Publishing a new version (easiest, no tools needed)**

On github.com/Jeansenekal-tech/UniqueAVCountdown go to **Actions → Build & Release → Run workflow**, type the new version (e.g. `1.1.0`) and what's new, and click **Run workflow**. GitHub builds the app on its own Macs (about 5 minutes) and publishes the release. Every push to `main` also gets a test build, so you can see straight away whether the code compiles.

**Or from your Mac with the GitHub CLI**

```bash
./release.sh 1.1.0 "Added video PIP and crop"
```

This sets the version number, builds the app, zips it and publishes it as a GitHub release. Every installed copy then offers it the next time it opens. Commit the version change in GitHub Desktop afterwards. Without `gh`, the script builds the zip and tells you what to upload on the GitHub website.

The app isn't signed with an Apple Developer ID, so after installing an update macOS may ask for Camera or Screen Recording permission again. The first launch may also need right-click → Open.

## What it does

**Rundown** – a list of segments (title, speaker, duration, warning times). Drag to reorder, double-click to cue, right-click for more. Save/open rundowns as `.json` files (⌘S / ⌘O). Each segment can be:

- **Countdown** – counts down from a duration, then counts up in red overtime (`+01:23`).
- **Count up** – stopwatch, with an optional target for colours.
- **End at time of day** – counts down to a clock time, e.g. "break ends 10:30".

**Warnings** – timer turns yellow, then red at the times you set, with optional sounds; the screen flashes red in overtime. "Auto-start next" chains segments together.

**Presenter screen** – choose the display and press *Show Presenter Screen* (⇧⌘D). With only one screen it opens as a window so you can test. Shows title, speaker, time of day, next segment and a progress bar (each can be switched off in Settings), plus a **Blackout** button.

**Messages** – type a message or click a preset ("Please wrap up", "5 minutes left" …) to put a yellow banner on the presenter screen. *Flash* makes it blink for 5 seconds. Edit the presets in Settings → Messages.

**Video input (picture-in-picture)** – put a live picture on the presenter screen next to the timer, e.g. the PowerPoint Presenter View with speaker notes. Choose the source under *Video input (PIP)*:

- **Capture cards & cameras** – USB capture cards (HDMI to USB/UVC, Elgato, Magewell, ATEM Mini/Web Presenter USB out), webcams, iPhone Continuity Camera, and NDI sources through *NDI Virtual Input* from NDI Tools. Pick the resolution/frame rate under *Format* if the card doesn't default to the one you want.
- **Whole display** – any screen connected to this Mac.
- **Window** – a single app window, e.g. PowerPoint's Presenter View on the same Mac, with no capture card needed.

Layouts (also on the phone remote, OSC and MIDI):

| Layout | What the presenter sees |
|---|---|
| Timer only | the normal timer |
| Video + timer PIP | video full screen, timer in a corner box (corner and size adjustable) |
| Timer + video PIP | timer full screen, small video in a corner |
| Side by side | video on the left, timer on the right (width adjustable) |
| Video + timer bar | video on top, timer strip along the bottom |

**Crop…** shows only part of the source, e.g. just the notes area of Presenter View, with *Left/Right/Top/Bottom half* shortcuts. *Fill* crops to the edges instead of showing black bars. Until a source is selected, the presenter screen stays on the timer only. If the signal drops, the operator preview shows "No signal".

Permissions: the first time you pick a capture card macOS asks for **Camera** access. Displays and windows need **Screen & System Audio Recording** permission (click *Allow…*, tick the app in System Settings, then quit and reopen it). Because the app is self-signed, macOS may ask again after each rebuild.

**Quick timer** – type minutes and hit *Start Now* for an instant one-off countdown.

The Mac won't sleep its displays while the app is open.

## Keyboard (operator window, when not typing in a field)

| Key | Action |
|---|---|
| Space / Return | Start / pause |
| → / ← | Next / previous segment |
| ↑ / ↓ or + / − | Add / remove 1 minute |
| ] / [ | Add / remove 10 seconds |
| R | Reset segment |
| F / H | Flash / hide message |
| B | Blackout |
| D | Show / hide presenter screen |
| V | Video PIP on / off |
| L | Next video layout |

The same actions are in the **Timer** menu with ⌘ shortcuts.

## Phone remote

Open the address shown under *Output & remote* (e.g. `http://192.168.1.20:8080`) in Safari or Chrome on any phone on the same network. You get the live timer, start/pause/next/prev, ± time, messages with presets, blackout, and tap-to-cue rundown. On iPhone, *Share → Add to Home Screen* makes it feel like an app.

HTTP API (handy for Companion's "Generic HTTP" module):

```
GET /api/state                      → JSON state
GET /api/cmd?c=next                 → run a command
GET /api/cmd?c=add&v=30             → command with a value
GET /api/cmd?c=message&v=Wrap%20up
```

## OSC (UDP port 8000)

| Address | Argument |
|---|---|
| `/timer/toggle` `/timer/start` `/timer/pause` `/timer/reset` | – |
| `/timer/next` `/timer/prev` | – |
| `/timer/add` `/timer/sub` | seconds (default 60) |
| `/timer/goto` | segment number (1-based) |
| `/timer/message` | text (shows it) |
| `/timer/flash` | optional text |
| `/timer/message/hide` | – |
| `/timer/blackout` | 1 / 0 (no arg = toggle) |
| `/timer/quick` | seconds – instant countdown |
| `/timer/video` | – (toggles video PIP on/off) |
| `/timer/layout` | none = next layout, or 1–5 (1 timer only, 2 video+timer PIP, 3 timer+video PIP, 4 side by side, 5 video+bar) |

Buttons that send `1` on press and `0` on release (Companion, TouchOSC) work fine — the release is ignored.

**Companion:** add a *Generic OSC* connection to the Mac's IP, port 8000, and set each button to send one of the addresses above.

## MIDI

Listens to all MIDI inputs (channel and first note set in Settings → Remote). Default from note 60 (C3):

| Note | Action | Note | Action |
|---|---|---|---|
| 60 | Start / pause | 66 | +1 min |
| 61 | Start | 67 | −1 min |
| 62 | Pause | 68 | Flash message |
| 63 | Reset | 69 | Hide message |
| 64 | Next | 70 | Toggle blackout |
| 65 | Previous | 71 | Next video layout |
| | | 72 | Timer only (video off) |

CC numbers follow the same table (value ≥ 64 triggers). **Program Change N** cues segment N+1. The last command received from any remote shows in the operator window, useful for checking your mapping.

## Project layout

```
Package.swift                  Swift package (open in Xcode)
build_app.sh                   builds the .app
release.sh                     builds + publishes a new version to GitHub
Info.plist                     app bundle info
Resources/AppIcon.icns         icon
Sources/UniqueAVCountdown/
  App.swift                    app entry, menus, keyboard, file open/save
  TimerEngine.swift            timer logic, rundown, messages, remote commands
  Models.swift                 segments, settings, file format
  PresenterView.swift          the presenter screen and its layouts
  VideoInput.swift             capture cards, cameras, display/window capture
  VideoSurface.swift           draws the live video, crop and fit/fill
  DisplayManager.swift         puts the presenter window on the chosen display
  ControlView.swift            operator window
  SettingsView.swift           preferences
  WebRemoteServer.swift        HTTP server for the phone remote
  RemotePage.swift             the phone remote web page
  OSCServer.swift              OSC over UDP
  MIDIController.swift         CoreMIDI input
  NetworkUtils.swift           finds this Mac's IP addresses
  UpdateChecker.swift          checks GitHub for new versions
```
