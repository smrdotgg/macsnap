# MacSnap

A native macOS screenshot and annotation tool. It's a Mac adaptation of
[Omasnap](https://github.com/omacom/omasnap), the Omarchy/Hyprland tool.

Press a hotkey and MacSnap freezes the screen under the pointer and shows a
selection overlay. Drag an area, click a window, or click open space for the
whole screen. The capture is copied to the clipboard, saved to
`~/Pictures/Screenshots`, and shown as a floating preview in the bottom-right
corner. The preview fades after 7 seconds unless you pin it. Hover it to
**Edit**, **Copy**, drag the file out, copy its path, or reveal it in Finder.

The editor keeps annotations as movable, resizable vector layers in an undoable
operation log. Nothing is flattened until you copy, save or pin.

## Features

- **Smart selection**: drag for an area, click a window to crop it, or click
  open space for the full screen. Area, Window, Screen and Scroll modes are
  also available. A readout next to the pointer shows the position, or the
  size in native pixels, so any drag doubles as a ruler. `Tab` cycles the area
  shape (free, 1:1, 3:4, 16:9).
- **Previews and pins**: captures stack as a tilted deck in the bottom-right
  corner and fan out on hover. Pin one with the pin button (dragging a card
  also pins it). Pins stay until closed. Your own previews never show up
  in later captures.
- **Annotation editor**, as a full-screen overlay or a normal window (`W`
  switches between them):
  - Arrows in standard, pointy, curved and double styles; lines; a smoothed
    pen; and a highlighter that snaps to text rows (found with Vision).
  - Rectangles and ellipses (outline, filled, or rounded), numbered markers,
    and text in Neucha, JetBrains Mono or Inter Display (on a pill, plain, or
    outlined).
  - Redaction that destroys pixels, either as a randomized mosaic or a solid
    block.
  - A spotlight/loupe with wheel magnification.
  - A **cut** tool that removes a band of the image and closes the gap (hold
    `⌃` to insert a transparent band instead).
  - **OCR** with Vision: the whole image or a dragged region. Text is copied
    and shown beside the capture.
  - An eyedropper.
  - Gradient **backdrops** (Slate, Aurora, Sunset, Lagoon, Violet), window
    gray, or your own image, with a card shadow.
  - **Canvas growth**: draw past the edge and the canvas grows. Overflow (the
    default) adds transparent space, Framed adds a light-gray mat, and Image
    clips annotations to the capture.
  - Recrop handles outside the image, unlimited undo and redo, and zoom/pan.
- **Scroll capture**: select an area and scroll it yourself, or let MacSnap
  scroll it for you. The frames are aligned and stitched into one tall or
  wide image.
- **Recents shelf**: the last five captures sit on the right edge of the
  selection overlay. Click one to reopen it with its layers still editable.
  They're also in the menu bar under *Recent Captures*.
- PNGs are written at native resolution with Retina DPI, so Preview and Finder
  show them at their logical size, and so does MacSnap when it reopens them.

## Install

Requirements: macOS 15 or later and the Xcode command-line tools (Swift 6).

```bash
git clone <this repo> macsnap && cd macsnap
make install
```

This builds a release `MacSnap.app`, installs it to `~/Applications`, adds a
`macsnap` command to `~/.local/bin`, and launches it. A camera-viewfinder icon
appears in the menu bar.

On your first capture, macOS asks for **Screen Recording** permission
(System Settings › Privacy & Security › Screen & System Audio Recording).
Allow MacSnap, then quit and reopen it from the menu bar. Auto-scroll in
scroll capture also needs **Accessibility** permission, which macOS asks for
the first time you use it.

To start it automatically, choose **Launch at Login** in the menu bar menu.

### Why there's a "MacSnap Local Signing" keychain

macOS ties privacy permissions to an app's code signature. An ad-hoc
signature changes with every build, so each rebuild would lose your Screen
Recording permission. On the first build, `scripts/signing-identity.sh`
creates a self-signed code-signing certificate in its own keychain
(`~/Library/Keychains/macsnap-signing.keychain-db`). Your login keychain is
untouched, and nothing is trusted system-wide. Every build is signed with that
certificate, so your permissions survive rebuilds. To remove it:
`security delete-keychain ~/Library/Keychains/macsnap-signing.keychain-db`.

## Hotkeys

| Hotkey | Action |
|---|---|
| `⌘⇧2` | Capture (smart selection) |
| `⌘⇧1` | Scroll capture |

Press the same hotkey again to dismiss an open overlay. You can change these
or add more (annotate, region, window, fullscreen, clipboard) in the config.
Keys can be letters, digits, `f1`–`f19`, `space`, or punctuation such as
`cmd+.`. Once the config has a `[hotkeys]` section, that section is the
complete list: comment a line out to turn that hotkey off. If a hotkey can't
be parsed or is already taken, MacSnap shows an alert saying which one.
`⌘⇧3/4/5` belong to macOS. To use one of them, turn off the system shortcut
first under System Settings › Keyboard › Keyboard Shortcuts › Screenshots.

## CLI

```bash
macsnap                         # smart capture
macsnap region|window|fullscreen|scroll
macsnap --editor overlay        # annotate before any output
macsnap --copy / --save         # quick output: no preview, no editor
macsnap ~/Desktop/image.png     # open an image in the editor
macsnap --clipboard             # annotate the image on the clipboard
```

There is only ever one instance: the command is handed to the running app.
The `macsnap://` URL scheme works too, for example
`open "macsnap://capture?mode=region&annotate=1"`, `macsnap://clipboard`, or
`macsnap://open?path=/path/to.png`. That's handy for Raycast, Alfred, or
Shortcuts.

## Controls

### Selection overlay

| Input | Action |
|---|---|
| Click | Window under the pointer, or the full screen outside any window |
| Drag | Area, with its native pixel size at the pointer |
| `Tab` / `⇧Tab` | Area shape: free, 1:1, 3:4, 16:9 |
| `S` | Scrolling-area mode |
| `W` | Window mode |
| `E` / `A` | Annotate after capture (on/off) |
| `R` | Restore the last area (`Return` or click inside to capture) |
| `⌘A` | Full screen |
| `Return` | Capture the highlighted window |
| `⌘` + arrows | Move between windows |
| Hover the right edge | Fan out recent captures; click one to reopen it |
| `?` | Show/hide the shortcuts card |
| `Esc` / right-click | Dismiss |

### Editor

| Input | Action |
|---|---|
| `V` | Select / move / resize; drag empty canvas for a marquee; outer handles recrop |
| `A` | Arrow (press again: standard → pointy → curved → double) |
| `L` / `F` / `H` | Line / pen / highlighter (`H` again: snap-to-text ↔ freehand) |
| `R` / `E` | Rectangle / ellipse (press again: outline ↔ filled) |
| `C` | Numbered marker |
| `T` / `⇧T` | Text (again: pill → plain → outline) / cycle the font |
| `D` | Redact (again: mosaic ↔ solid) |
| `S` | Spotlight (again: ellipse → rectangle → rounded) |
| `X` (`⌃X`) | Cut a band (insert one) |
| `O` | Recognize and copy all text |
| `I` | Eyedropper |
| `1`–`8` | Color (also recolors the selection) |
| `B` / `⇧B` | Cycle backdrop / toggle card shadow |
| `G` / `⇧G` | Canvas growth: Overflow → Image → Framed |
| Wheel | Scale the selection; magnify a spotlight; or change the tool size |
| `⌥` + wheel | Pen smoothing, corner radius, spotlight border |
| `⌘` + wheel, pinch, `+` `-` `0` | Zoom; `0` fits |
| Space-drag, middle-drag | Pan |
| `⇧` while dragging | Square/circle, 45° snapping, keep the aspect ratio |
| `⌥` while dragging | Draw from the center |
| Arrows (`⇧` for 10 px) | Nudge the selection |
| `⌥D` | Duplicate the selection |
| Double-click text / `Return` on selected text | Edit it |
| `⌫` | Delete the selection |
| `⌘Z` / `⇧⌘Z` | Undo / redo |
| `⌘C` / `⌘S` / `⇧⌘S` | Copy / save / save as |
| `Return` | Copy and save |
| `P` / `⌘P` | Pin on screen |
| `Esc` | Close (edits are kept in recents, and in the pin you opened it from) |
| Right-click | Back to Select; cancel the current drawing |

Right-click (or `⌃`-click) a tool button for its variants. Use the backdrop
button for backdrops, canvas growth, and *Scroll capture this area…*.

### Previews and pins

| Input | Action |
|---|---|
| Hover | Fan the stack out; pause the countdown |
| Pin button | Keep on screen (again: unpin and restart the countdown) |
| Drag the card | Move it (this also pins it); drop it on the stack to reorder |
| Six-dot handle | Drag the PNG into another app or Finder |
| Edit | Annotate; `Esc` in the editor updates this same card |
| Copy | Copy the full-resolution PNG |
| Link | Copy the file path (saves the file first if needed) |
| Folder | Reveal in Finder |
| `×`, middle-click | Close |

Unlike Omasnap, cards have no keyboard shortcuts. A card never takes keyboard
focus, so clicking **Copy** and then pressing `⌘V` pastes into the app you're
working in.

## Configuration (optional)

MacSnap runs fine with no config. To change hotkeys, the save location, or
colors, choose **Edit Configuration…** from the menu bar. That creates
`~/.config/macsnap/macsnap.conf` with every key commented. Then choose
**Reload Configuration**.

```ini
[hotkeys]
capture = cmd+shift+2
scroll = cmd+shift+1
# annotate = cmd+shift+3
# clipboard = cmd+shift+v

[editor]
mode = overlay            # or window
canvas = overflow         # framed (gray mat) or image (clip to the capture)

[output]
autosave = true
directory = ~/Pictures/Screenshots
filename = screenshot-{date}_{time}-{app}

[preview]
seconds = 7

[colors]
palette = #ff375f, #ff9f0a, #ffd60a, #30d158, #0a84ff, #bf5af2, #000000, #ffffff
custom = #ff375f

[background]
# image = ~/Pictures/backdrop.jpg
default = none            # slate, aurora, sunset, lagoon, violet, custom, grayShadow, grayFlat
```

`{app}` expands to a slug of the app under the selection (for example
`google-chrome`). When nothing is known it's dropped along with its separator.
Existing names get `-2`, `-3`, and so on. Environment overrides:
`MACSNAP_SCREENSHOT_DIR`, `MACSNAP_OCR_LANGS` (for example `en-US+de-DE`), and
`MACSNAP_RECENT_DIR`.

## Troubleshooting

MacSnap writes a plain-text developer log to
`~/Library/Logs/MacSnap/macsnap.log`, including timings for each OCR run.

OCR uses Vision's fast recognizer on purpose. On macOS 27.0.1 the accurate
recognizer takes about 28 s on its first use in a process, blocking all other
text recognition meanwhile, and then fails every later request with a Neural
Engine (`e5rt`) error. Small captures are enlarged before recognition, which
recovers most of the small text the fast recognizer would otherwise miss.

## Development

```bash
make test        # core unit tests (op log, cuts, renderer, stitcher, config, recents)
make snapshots   # render the real views offscreen with synthesized input → .build/ui-snapshots
make app         # dist/MacSnap.app
make install
```

- `Sources/MacSnapCore`: the pure, headless-testable parts. That's the document
  model and operation log (`Model.swift`), geometry, the renderer, the
  scroll-capture stitcher, config, and the recents store.
- `Sources/MacSnap`: the AppKit app. That's the capture overlay, editor,
  previews and pins, scroll capture, hotkeys (Carbon `RegisterEventHotKey`, so
  no Accessibility permission is needed), and the CLI.

The editing model is the same as Omasnap's. The operation log is the source of
truth, and what's on screen is a pure function of it. Redaction destroys
pixels at render time. Cuts are recomposed from the untouched source.

## Credits

Based on [Omasnap](https://github.com/omacom/omasnap) by Tobi Lütke and
contributors (MIT). Omasnap was itself inspired by Shottr, Satty, and
Flameshot. Fonts: Neucha, JetBrains Mono, and Inter Display (SIL OFL).
