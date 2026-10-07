---
name: Hardware Diagnostic Toolkit
description: Full-screen framebuffer UI of a bootable laptop bench-test stick, drawn with Pillow; five colour themes, two of them whole skins.
colors:
  light-ground: "#eaeef4"
  light-paper: "#ffffff"
  light-ink: "#111720"
  light-muted: "#6a7684"
  light-line: "#e2e8f1"
  light-accent: "#2f6df6"
  light-pass: "#0f7a4f"
  light-pass-soft: "#e6f4ed"
  light-warn: "#9a6400"
  light-warn-soft: "#fdf1dd"
  light-fail: "#c0342f"
  light-fail-soft: "#fbeaea"
  light-shadow: "#d0d7e2"
  dark-ground: "#0f141b"
  dark-paper: "#1a212c"
  dark-ink: "#e4eaf3"
  dark-muted: "#8c99aa"
  dark-line: "#2c3747"
  dark-accent: "#609eff"
  dark-pass: "#4ad495"
  dark-pass-soft: "#163429"
  dark-warn: "#f0bb4e"
  dark-warn-soft: "#3b2e12"
  dark-fail: "#ff7a70"
  dark-fail-soft: "#3f1d1c"
  dark-shadow: "#0a0e13"
  contrast-ground: "#000000"
  contrast-paper: "#161616"
  contrast-ink: "#ffffff"
  contrast-muted: "#c8c8c8"
  contrast-line: "#ffffff"
  contrast-accent: "#ffd600"
  contrast-pass: "#00ff78"
  contrast-pass-soft: "#003018"
  contrast-warn: "#ffd600"
  contrast-warn-soft: "#382e00"
  contrast-fail: "#ff5050"
  contrast-fail-soft: "#400000"
  contrast-shadow: "#000000"
  mecha-ground: "#0b0b0d"
  mecha-paper: "#16161a"
  mecha-ink: "#ecece8"
  mecha-muted: "#9696a0"
  mecha-line: "#3e3e48"
  mecha-accent: "#ff6a00"
  mecha-pass: "#39d98a"
  mecha-pass-soft: "#0e3222"
  mecha-warn: "#ffc400"
  mecha-warn-soft: "#3a2e00"
  mecha-fail: "#ff5c50"
  mecha-fail-soft: "#46100e"
  mecha-shadow: "#000000"
  kawaii-ground: "#ffe4ee"
  kawaii-paper: "#ffffff"
  kawaii-ink: "#3b2142"
  kawaii-muted: "#76567e"
  kawaii-line: "#f6bad2"
  kawaii-accent: "#6c4af0"
  kawaii-pass: "#107c58"
  kawaii-pass-soft: "#def7ec"
  kawaii-warn: "#a05c00"
  kawaii-warn-soft: "#fff0d6"
  kawaii-fail: "#c8203c"
  kawaii-fail-soft: "#ffe2e8"
  kawaii-shadow: "#d9ccff"
  mecha-skin-bar: "#121216"
  mecha-skin-haz-a: "#ffc400"
  mecha-skin-haz-b: "#111113"
  mecha-skin-tab: "#28282f"
  mecha-skin-text-on: "#0b0b0d"
  kawaii-skin-band: "#ffc7de"
  kawaii-skin-backing: "#d9ccff"
  kawaii-skin-sel-edge: "#5030d6"
  kawaii-skin-chip: "#ffecf4"
  kawaii-skin-star-edge: "#baa0ff"
  kawaii-skin-candy: "#9278ff"
  kawaii-skin-honey: "#ffc448"
typography:
  body:
    fontFamily: "Carlito, IBM Plex Sans, DejaVu Sans"
    fontSize: "22px"
    fontWeight: 400
  body-small:
    fontFamily: "Carlito, IBM Plex Sans, DejaVu Sans"
    fontSize: "18px"
    fontWeight: 400
  body-tiny:
    fontFamily: "Carlito, IBM Plex Sans, DejaVu Sans"
    fontSize: "15px"
    fontWeight: 400
  number:
    fontFamily: "DejaVu Sans Mono"
    fontSize: "17px"
    fontWeight: 700
  number-label:
    fontFamily: "DejaVu Sans Mono"
    fontSize: "13px"
    fontWeight: 400
  mecha-display:
    fontFamily: "Bebas Neue, Carlito"
    fontSize: "46px"
    fontWeight: 700
    letterSpacing: "1px"
  mecha-header:
    fontFamily: "Bebas Neue, Carlito"
    fontSize: "34px"
    fontWeight: 700
    letterSpacing: "1.5px"
  mecha-plate:
    fontFamily: "Bebas Neue, Carlito"
    fontSize: "28px"
    fontWeight: 700
  mecha-bay-name:
    fontFamily: "Bebas Neue, Carlito"
    fontSize: "28px"
    fontWeight: 700
  mecha-tag:
    fontFamily: "Bebas Neue, Carlito"
    fontSize: "22px"
    fontWeight: 400
  kawaii-display:
    fontFamily: "Comfortaa, Carlito"
    fontSize: "30px"
    fontWeight: 700
  kawaii-stamp:
    fontFamily: "Comfortaa, Carlito"
    fontSize: "24px"
    fontWeight: 700
  kawaii-sticker-name:
    fontFamily: "Comfortaa, Carlito"
    fontSize: "19px"
    fontWeight: 700
  kawaii-chip:
    fontFamily: "Comfortaa, Carlito"
    fontSize: "15px"
    fontWeight: 700
rounded:
  mecha: "0px"
  kawaii-card: "26px"
  kawaii-status: "22px"
  pill: "9999px"
spacing:
  card-pad: "34px"
  gutter: "22px"
  gutter-tight: "14px"
components:
  mecha-bay:
    backgroundColor: "{colors.mecha-paper}"
    textColor: "{colors.mecha-ink}"
    typography: "{typography.mecha-bay-name}"
    rounded: "{rounded.mecha}"
  mecha-bay-selected:
    backgroundColor: "{colors.mecha-paper}"
    textColor: "{colors.mecha-accent}"
    typography: "{typography.mecha-bay-name}"
    rounded: "{rounded.mecha}"
  mecha-bay-tab:
    backgroundColor: "{colors.mecha-skin-tab}"
    textColor: "{colors.mecha-muted}"
    typography: "{typography.number}"
    height: "24px"
  mecha-bay-tab-selected:
    backgroundColor: "{colors.mecha-accent}"
    textColor: "{colors.mecha-skin-text-on}"
    typography: "{typography.number}"
    height: "24px"
  mecha-plate-pass:
    backgroundColor: "{colors.mecha-pass}"
    textColor: "{colors.mecha-skin-text-on}"
    typography: "{typography.mecha-plate}"
    height: "40px"
  mecha-plate-warn:
    backgroundColor: "{colors.mecha-warn}"
    textColor: "{colors.mecha-skin-text-on}"
    typography: "{typography.mecha-plate}"
    height: "40px"
  mecha-plate-fail:
    backgroundColor: "{colors.mecha-fail}"
    textColor: "{colors.mecha-skin-text-on}"
    typography: "{typography.mecha-plate}"
    height: "40px"
  mecha-plate-unlit:
    backgroundColor: "{colors.mecha-skin-tab}"
    textColor: "{colors.mecha-ink}"
    typography: "{typography.mecha-plate}"
    height: "40px"
  mecha-menu-row-selected:
    backgroundColor: "{colors.mecha-accent}"
    textColor: "{colors.mecha-skin-text-on}"
    typography: "{typography.body}"
  mecha-choice-unlit:
    textColor: "{colors.mecha-muted}"
    typography: "{typography.mecha-plate}"
    width: "150px"
    height: "46px"
  kawaii-sticker:
    backgroundColor: "{colors.kawaii-paper}"
    textColor: "{colors.kawaii-ink}"
    typography: "{typography.kawaii-sticker-name}"
  kawaii-sticker-selected:
    backgroundColor: "{colors.kawaii-accent}"
    textColor: "{colors.kawaii-paper}"
    typography: "{typography.kawaii-sticker-name}"
  kawaii-number-badge:
    backgroundColor: "{colors.kawaii-skin-band}"
    textColor: "{colors.kawaii-ink}"
    typography: "{typography.number}"
    rounded: "{rounded.pill}"
  kawaii-stamp-pass:
    backgroundColor: "{colors.kawaii-pass}"
    textColor: "{colors.kawaii-paper}"
    typography: "{typography.kawaii-stamp}"
    rounded: "{rounded.pill}"
    height: "40px"
  kawaii-stamp-warn:
    backgroundColor: "{colors.kawaii-skin-honey}"
    textColor: "{colors.kawaii-ink}"
    typography: "{typography.kawaii-stamp}"
    rounded: "{rounded.pill}"
    height: "40px"
  kawaii-stamp-fail:
    backgroundColor: "{colors.kawaii-fail}"
    textColor: "{colors.kawaii-paper}"
    typography: "{typography.kawaii-stamp}"
    rounded: "{rounded.pill}"
    height: "40px"
  kawaii-stamp-unlit:
    backgroundColor: "{colors.kawaii-skin-chip}"
    textColor: "{colors.kawaii-ink}"
    typography: "{typography.kawaii-stamp}"
    rounded: "{rounded.pill}"
    height: "40px"
  kawaii-menu-row-selected:
    backgroundColor: "{colors.kawaii-accent}"
    textColor: "{colors.kawaii-paper}"
    typography: "{typography.body}"
    rounded: "{rounded.pill}"
  kawaii-choice-unlit:
    backgroundColor: "{colors.kawaii-paper}"
    textColor: "{colors.kawaii-muted}"
    typography: "{typography.kawaii-stamp}"
    rounded: "{rounded.pill}"
    width: "150px"
    height: "46px"
---

# Design: service-manual sheet (home grid and menus)

The navigation screens are a page of the service manual a technician opens
before a board swap. Drawn by `toolkit/ui.py` (`LOOK = "manual"`); Settings ->
Menu style -> Classic tiles restores the 1.0-1.12 look. Test screens keep the
card look in both modes.

## Tokens

All colours come from the active theme (light / dark / contrast in
`THEMES`), so every theme works without a second palette:

| Role | Token | Use |
|---|---|---|
| Sheet | `PAPER` mixed 25 % toward `GROUND` | page background |
| Line work, type | `INK` | frame, part outlines, names |
| Notes | `MUTED` | zone markers, cell labels, descriptions, numbers |
| Hairlines | `LINE` | table row rules |
| Selection | `ACCENT` | the one selected part / row: outline, balloon, name |
| Selection band | `PAPER` mixed 13 % toward `ACCENT` | selected parts-list / table row |
| Results | `PASS_`, `FAIL_`, else `MUTED` | parts-list RESULT column |

The accent means "selected" and nothing else. PASS/FAIL colour always comes
with the word.

## Type

- Carlito Bold: part names (`f_part` 21), titles (`f_ttl` 24, caps, 1.5 px
  tracking), the toolkit name in the title block (`f_bodyb`, 2 px tracking).
- Carlito: parts-list items and table descriptions (`f_body`).
- DejaVu Sans Mono: only numbers and drafting notes - zone markers, cell
  labels, balloons, parts-list numbers and results, key hints (`f_note` 15,
  `f_noteb` 16). Never as a "technical" costume for prose.
- Sizes scale with the panel (`s = H / 800`) and the text-size setting.

## Components

- **Frame:** outer rule 2 px at 14 s, inner rule 1 px at 34 s, zone markers
  1-8 across and A-D down between them.
- **Title block:** top strip under the inner rule, ruled cells right to
  left: TIME (clock + Wi-Fi icon, the click target for the Wi-Fi page),
  DATE, REV (`DIAG_VERSION` from lib.sh), MACHINE (model over CPU and RAM).
  The memory figure is never shortened; the CPU name is tidied first
  ("(R)", "(TM)", "CPU", "Nth Gen" removed), then clipped if it must be.
- **Part:** 1 px `INK` rectangle, icon (Ash's set) at 40 %, name at 81 %,
  wrapping to two lines and then stepping down a size - never truncated
  while it can fit. Balloon (r 17 s, numbered) off the top-left corner with
  a leader and dot into the part. Selected: 3 px accent outline, filled
  accent balloon, accent icon and name.
- **Parts list:** right 27 % of the sheet. NO. / ITEM / RESULT, one row per
  tile, hairline rules, key hint at the foot (wraps to two lines).
- **Table (menus):** balloon numbers, bold names, one column per `|` cell,
  2 px rule under the heading, hairlines between rows. A long table scrolls
  with a sticky window and an "11-22 OF 26" note.

## Rules

- Flat line work only: no shadows, gradients, glow or blur.
- Whole-screen redraws only on change; the header clock redraws once a minute.
- New navigation entries go through `tui_grid "Label|icon|$(test_result KEY)"`
  so the parts list stays true.

# Design System: the anime themes (Mecha Command Deck, Kawaii Pastel)

Two more entries in Settings -> Colour theme (entries 4 and 5, after light /
dark / contrast; `toolkit/settings.sh` writes `theme=mecha|kawaii`). Each is
a whole skin rather than a palette: while one is on, `toolkit/skins.py`
draws the header, card, title, home grid, status column, menus, badges,
bars, YES/NO, footer hint and the animation title, rule and LIVE chip.
`ui.py` hands over through `THEME_SKIN`, and `apply_theme` rebinds the
shared colour roles from `THEMES["mecha"|"kawaii"]` and rebuilds `BADGE`
via `_badges()`. The Menu style setting (manual / classic) applies to the
three palette themes only. The default theme stays light. Hex values are in
the frontmatter (`mecha-*`, `kawaii-*`, and `*-skin-*` for the colours
that belong to a skin rather than to the shared roles); the RGB triples in
the source are normative and the hex is an exact transcription.

## Overview

**Creative North Star (Mecha): "The Launch Deck."** The bench is a launch
deck. Every test is a system bay with its own status lamp, and a fault is an
alert plate rather than a sentence. The look is a matte console-black
ground, near-black chamfered plates, tracked Bebas capitals, mono readouts
and segmented gauges. The deck has no floating white cards and no rounded
tiles.

**Creative North Star (Kawaii): "The Sticker Sheet."** The toolkit is a
sticker sheet. Every test is a white sticker on its lavender backing paper,
and every result is a reward stamp. The look is a blush-pink ground, a
scalloped header band, plum ink, Comfortaa for names and stamps, round
number badges and four-point sparkles in the margins. The category standard
is played straight, and every verdict must still read from arm's length.

Both themes were picked by Ash for the bench team's enjoyment. They may be
loud, but a verdict must never be ambiguous.

**Key Characteristics:**
- Each theme owns every screen while it is on, but it changes only what is
  around and under the words. Positions and rows stay where they are.
- There is no glow, blur or gradient. Depth comes from flat plates (Mecha)
  or flat offset backing paper (Kawaii).
- Display face for titles, names and verdicts; Carlito for anything read
  as prose; DejaVu Sans Mono for every number.
- Decoration (hazard stripes, scallops, sparkles, candy stripes) goes only
  where no word is drawn.

## Colors

### Mecha Command Deck

The deck is console black, signal orange marks the selection, and the
verdict colours are alarm red, nominal green and amber.

- **Primary: Signal Orange** (`mecha-accent`, 255 106 0): the selection.
  It is used for the selected bay's outline, number tab, icon and name, the
  selected menu row's fill, and the selected status-row number.
- **Verdicts:** **Nominal Green** (`mecha-pass`, 57 217 138), **Amber**
  (`mecha-warn`, 255 196 0) and **Alarm Red** (`mecha-fail`, 255 92 80).
  They are used for lamps, verdict plates, result words, the YES/NO fill,
  and a failed bay's outline. The `*-soft` partners (14 50 34 / 58 46 0 /
  70 16 14) feed the shared `BADGE` table and the animations. The skin's
  own plates do not use them.
- **Neutrals:** **Console Black** ground (`mecha-ground`, 11 11 13).
  **Plate** (`mecha-paper`, 22 22 26) for the card, bays and status column.
  **Bone** ink (`mecha-ink`, 236 236 232). **Steel** notes (`mecha-muted`,
  150 150 160) for labels, unselected numbers, corner brackets and the
  hint. **Gunmetal** outlines (`mecha-line`, 62 62 72). `mecha-shadow` is
  black and the skin does not use it.
- **Skin-only (`skins.MECHA`):** `BAR` (18 18 22) for the command bar and
  lamp bezel. `HAZ_A` / `HAZ_B` (255 196 0 / 17 17 19) for hazard stripes.
  `TAB` (40 40 47) for unlit tabs, unlit gauge segments, the unlit plate and
  the LIVE chip. `TEXT_ON` (11 11 13) for words on orange or on a verdict
  fill.
- **Derived:** the selected status row is `PAPER` mixed 16 % toward
  `ACCENT` (59 35 21). It is that light so a red FAIL on it holds 4.80:1.
  The selected menu row's description is `TEXT_ON` mixed 25 % toward
  `ACCENT` (4.85:1).

**The Signal Orange Rule.** Orange means selected. Corner brackets, plate
outlines and the title rule are grey, never orange. The build has two known
exceptions that are not precedent: the lit segments of the progress gauge
and the brand mark (`_draw_brand`) are also drawn in `ACCENT`.

**The Red Bay Rule.** A failed bay gets a 3 px red outline, so a FAIL can
be found from across the bench without reading lamps. Selection orange
still wins over it.

### Kawaii Pastel

The sheet is blush pink with white stickers. The violet accent is for icons
and the selection, and the verdicts are mint, honey and cherry stamps.

- **Primary: Sticker Violet** (`kawaii-accent`, 108 74 240). It fills the
  selected sticker, menu row and status row, and it is also used for
  unselected sticker icons, the bar fill, the LIVE chip and the brand mark.
  The contract said "selection only", but the build also uses violet for
  icons. Follow the build.
- **Verdicts:** **Mint** (`kawaii-pass`, 16 124 88) and **Cherry**
  (`kawaii-fail`, 200 32 60) stamps carry white text. **WARN is Honey**
  (`kawaii-skin-honey`, 255 196 72) with plum text. `kawaii-warn` (160 92 0)
  is the WARN colour for words drawn on white. The `*-soft` partners feed
  `BADGE` and the animations.
- **Neutrals:** **Blush** ground (`kawaii-ground`, 255 228 238). **Sticker
  White** (`kawaii-paper`). **Plum** ink (`kawaii-ink`, 59 33 66). **Mauve**
  notes (`kawaii-muted`, 118 86 126). **Pink outline** (`kawaii-line`,
  246 186 210), which is also used for the dotted title rule and the bar
  outline. `SHADOW` is lavender (217 204 255), the same as the backing.
- **Skin-only (`skins.KAWAII`):** `BAND` (255 199 222) for the header band
  and unselected number badges. `BACKING` (217 204 255) for the sticker
  backing paper. `SEL_EDGE` (80 48 214) for the selected sticker's outline.
  `CHIP` (255 236 244) for the bar track and the unlit stamp. `STAR_EDGE`
  (186 160 255) for sparkle edges and small sparkles. `CANDY` (146 120 255)
  for the stripes inside the bar fill. `HONEY` (255 196 72) for the WARN
  stamp.

**The Honey Stamp Rule.** WARN is honey with plum text (8.93:1). White on
amber was the weakest pair on the sheet. On a selected violet row or
sticker, every stamp turns white and carries its verdict colour as text.

### Both themes

**The 4.5:1 Rule.** Every word must hold 4.5:1 or better against what it
sits on. These pairs were measured in the shipped build. Kawaii: white on
`PASS_` 5.19, white on `ACCENT` 5.42, white on `FAIL_` 5.63, plum on honey
8.93, mauve on blush 5.17. Mecha: `FAIL_` on the selected status row 4.80,
`TEXT_ON` on orange 6.85, steel on plate 6.16, steel on tab 5.00. The
first violet and green were 4.3:1 and were darkened to pass.

**The Word Wins Rule.** A PASS/WARN/FAIL colour always comes with its word.
Lamps and outlines repeat a verdict that is written elsewhere.

## Typography

**Display Font:** Bebas Neue (Mecha) and Comfortaa Bold (Kawaii). Both come
from Ubuntu's archive (`fonts-bebas-neue`, `fonts-comfortaa`, OFL).
`finalize_chroot.sh` installs them, asserts that the three files exist, and
runs `skins.py --check`. A missing face falls back to Carlito Bold, never to
PIL's 11 px bitmap.
**Body Font:** Carlito (`f_body` 22, `f_small` 18, `f_tiny` 15).
**Number Font:** DejaVu Sans Mono (`mono_m` Bold 17, `mono_s` Regular 13,
plus the shared `f_mono` / `f_monob` 20). IBM Plex Mono comes first in the
`MONO_*` lists, but the image does not ship it.

All sizes below are px at scale 1. They are multiplied by `ts = s x
TEXT_SCALE`, where `s = H / 800` and `TEXT_SCALE` is the 100-200 % text-size
setting (clamped 0.75-2.5). Card titles are the exception: they grow with
the text size only up to x1.15, because they sit in a fixed band above
row 6.

### Hierarchy (Mecha)
- **Display** (Bebas Bold 46, caps, 1 px tracking): the home title "CHOOSE
  A TEST", card titles and animation titles (title capped at x1.15 text
  scale).
- **Header** (Bebas Bold 34, caps, 1.5 px tracking): HARDWARE DIAGNOSTIC
  TOOLKIT in the command bar.
- **Plate** (Bebas Bold 28): verdict plates, YES/NO, the SYSTEM STATUS
  heading.
- **Bay name** (Bebas Bold, caps): a ladder of 28/25/22/19 x ts plus
  23/21/19/17 x s. The layout takes the largest size that fits.
- **Tag** (Bebas Regular 22): the LIVE chip.
- **Numbers** (Mono Bold 17): bay tabs, readout values, status numbers and
  result words (stepping down to Mono 13). Readout labels REV / DATE / TIME
  are Mono 13 in steel.

### Hierarchy (Kawaii)
- **Display** (Comfortaa Bold 30, sentence case): the toolkit name in the
  band, the home title, card and animation titles (title capped at x1.15).
- **Stamp** (Comfortaa Bold 24): result stamps, YES/NO, the Checklist
  heading.
- **Sticker name** (Comfortaa Bold, sentence case): a ladder of 19/17/15/13
  x ts plus 17/15/13/11 x s.
- **Chip** (Comfortaa Bold 15, stepping to 12): stamps on stickers and in
  the Checklist, and the LIVE chip.
- **Numbers** (Mono Bold 17): number badges and the clock chip.

**The Read-Not-Glanced Rule.** The footer hint and the YES/NO help line are
Carlito 18 in sentence case, in muted colour, on both themes. 13 px mono
capitals were the hardest words on the deck to make out.

**The Name First Rule.** In the status column the test name has the first
claim on its row. A long result steps down a size first, then to its short
form (NOT TESTED -> N/T, MARGINAL -> MARG, PARTIAL -> PART, STOPPED ->
STOP), and only after that is the name clipped.

## Layout

**The Fixed Rows Rule.** A skin never moves anything. Every test script
places its lines by row number, and the skins draw the same rows, card box
(`_card_box`), header height (`hdr` 74), footer (`ftr` 56) and card padding
(`pad` 34). Only what is around and under the words changes, so no script
needs to know which skin is on.

**Home grid** (`_grid_layout`, `_tile_fit`):
- The status column takes the right 25 % of the width, with a 30 px gap
  before it. The grid area starts 78 px under the header and ends at the
  footer. Spare width goes to the gap before the column, and the grid stays
  left-aligned under the heading.
- Columns from 2 to 8 are tried. Tile height = min(0.9 x width, the
  height available per row). Width is capped at 1.5 x height: tiles may be
  a little wider than tall, and no more. The winner is the layout where
  every name fits, then the one with the largest tile area, then the one
  with the largest name size.
- **Gutter fallback:** 22 px gutters first. 14 px gutters are tried only
  when nothing fits at 22.
- Inside a tile, the name block sits at the bottom. It is sized for the most
  lines any name needs (at most two). `BOTTOM_PAD` is 10. `NAME_INSET` is
  12 (both sides together). The icon takes what is left, starting at
  `ICON_TOP` (Mecha 30, which may rise into the middle of the top band
  because only its corners hold the tab and lamp; Kawaii 44, because the
  badge and stamp can be wide).
- **The icon share:** a name size is accepted only if the icon keeps at
  least max(30 % of the tile height, `ICON_MIN` 28 px x s). Icon size =
  max(12, min(0.86 x room, 0.36 x width, 0.36 x height)).
- Status rows are min(36 px, the height that fits). Their font steps from
  body to small to tiny until size x 1.15 fits the row. The name column
  starts after the widest number.

## Elevation & Depth

### Mecha
The deck is flat. There are no shadows, and `SHADOW` is black and unused.
Depth comes from value steps: ground, then plate, then tab, with the bar
behind the header. Lamps sit in a dark `BAR` bezel with a 2 px gunmetal
ring.

### Kawaii
Kawaii uses one device: **backing paper**. This is a flat lavender
(`BACKING`) copy of the shape, offset down and right, with no blur.
- Card: offset 7 / 9.
- Status column: offset 6 / 7.
- Sticker: offset 5 / 6, or 8 / 9 when selected, so a selected sticker
  lifts.
- Selected menu row: offset 4 / 4.
- Active YES/NO: offset 4 / 5.

This is the sticker's own material. It is never a grey or black drop shadow.

## Shapes

### Mecha
- **Chamfer:** 45-degree cuts, normally on the top-left and bottom-right
  corners (`chamfer_pts`). There are no rounded corners anywhere.
- **Cut sizes:**
  - Card: 26.
  - Bay: 13 % of the tile's short side.
  - Status column: 18.
  - YES/NO: 12.
  - Verdict plate and menu row: 10.
  - LIVE chip: 7.
- **Outlines:** 2 px, or 3 px when selected or failed. HUD corner brackets
  (38 long, 3 px, steel) sit on the card's two square corners.
- **Card title rule:** 2 px gunmetal, ending in a 46 x 4 steel key. It
  stops 150 px short when a long menu prints its "11-22 of 26" note.
- **Gauge:** about 14 px segments with a 3 px gap, at least 10 segments.
  They are 16 tall.

### Kawaii
- **Radii:**
  - Card: 26.
  - Status column: 22.
  - Sticker: 16 % of the tile's short side.
  - Rows, stamps, chips, bars, YES/NO and number badges: pills.
- **Number badges:** a circle (radius max(10, 14, 0.62 x mono size)) that
  stretches into a pill from 10 up.
- **Header band:** scalloped lower edge made of half-circles of radius 10.
- **Title rule:** a dotted rule (dots of radius 1.6 at a 10 px pitch) in
  `LINE`, between the card title and row 6. It is dropped when the gap is
  under 4 px.

## Components

### Header
- **Mecha:**
  - Command bar in `BAR`, ending 10 px above the card, with a 2 px line
    under it.
  - A 46 px hazard block at the left, then the brand mark and the tracked
    name.
  - Boxed readouts on the right, right to left: TIME (with the Wi-Fi icon;
    the click target), DATE in caps, REV.
  - The machine box shows model over CPU and RAM. The CPU name is tidied,
    then clipped; the memory figure is never cut.
  - At large text a readout drops its label and keeps the value.
- **Kawaii:**
  - `BAND` with scalloped edge.
  - Sparkles in the band's corners only.
  - Plum name, white pill chips for date and clock (clock chip is the Wi-Fi
    target).
  - Machine lines right-aligned. The second line is `INK` mixed 25 %
    toward the band (5.13:1).

### Card
Mecha: a chamfered plate with HUD brackets. Kawaii: a white rounded plate
with backing paper, and sparkles only in the ground margin beside it.

### Home tile (bay / sticker)
- **Mecha bay:**
  - Plate fill, 2 px gunmetal outline, Mono "01" tab just past the cut
    corner.
  - Lamp top-right in a bezel: unlit `TAB`, or green, amber or red.
  - Icon and caps name in bone.
  - *Selected:* 3 px orange outline, orange tab with `TEXT_ON` digits, orange
    icon and name, and a hazard strip in the top band between the tab and
    the lamp.
  - *Failed (unselected):* 3 px red outline.
- **Kawaii sticker:**
  - White, 2 px pink outline, backing paper.
  - Number badge in `BAND` with plum digits.
  - Result stamp at the top right: the result's first word, up to four
    letters.
  - Violet icon, plum name.
  - *Selected:* violet fill, 2 px `SEL_EDGE` outline, deeper backing, white
    badge with violet digits, white stamp with verdict-coloured text, white
    icon and name, and a sparkle on the bottom-right corner.
  - *Unlit:* no stamp.

### Status column
- **Mecha (SYSTEM STATUS):** a chamfered plate. Each row has a lamp, a
  two-digit number, the name and the result word.
  - *Unlit:* the lamp is a ring and the result is a steel "-".
  - *Selected:* a tinted band and an orange number.
- **Kawaii (Checklist):** a rounded plate with backing. Each row has a
  number, the name and a pill result stamp.
  - *Selected:* a violet pill row with white text and white stamps.

### Verdict badge (`badge` item)
- **Mecha:** a chamfered plate in the verdict colour with `TEXT_ON` letters.
  - *FAIL:* the alert plate, with hazard flanks (22 px) on both sides.
  - *Unknown:* a `TAB` plate with bone text.
- **Kawaii:** a pill stamp in the verdict colour.
  - *PASS/OK:* a check mark before the word.
  - *FAIL:* a cross mark before the word.
  - *WARN family:* honey with plum text.
  - *Unknown:* a `CHIP` pill with plum text.
- **Both:** the badge's description follows in Carlito 22 ink.

### Progress bar
- **Mecha:** a segmented block gauge, with lit segments in `ACCENT` and
  unlit segments in `TAB`.
- **Kawaii:** a `CHIP` pill track with a pink outline and a violet fill
  that has `CANDY` stripes inside it. No word is ever drawn in the bar.
- **Both:** the percentage is drawn to the right in mono muted.

### YES / NO
Each box is 150 x 46 with a 20 px gap.
- **Active:**
  - YES uses the `PASS_` fill and NO uses the `FAIL_` fill.
  - Mecha: a chamfer with `TEXT_ON` letters.
  - Kawaii: a pill with white letters and backing paper.
- **Inactive:** an outline only, with muted letters.
- **Both:** the help line follows in Carlito small, muted.

### Menu row
- **Mecha:**
  - Two-digit mono numbers in steel.
  - *Selected:* a chamfered orange row, `TEXT_ON` name and number,
    description at 25 % mix.
- **Kawaii:**
  - Round `BAND` number badges.
  - *Selected:* a violet pill row with backing, a white badge with violet
    digit, and a white name and description (5.42:1); the name is told
    apart by its bold weight. A description tinted 18 % toward the violet
    measured 4.17:1 and was dropped - do not tint text on the selection.

### Animation screens
Titles use the skin's title face (Mecha in capitals). The skin's rule runs
beside the title rather than under it.
- **LIVE chip:**
  - Mecha: a chamfered `TAB` plate with a gunmetal outline and Bebas
    Regular in bone.
  - Kawaii: a violet pill with white Comfortaa.

## Do's and Don'ts

### Do:
- **Do** keep every row, the card box and the header height identical to the
  palette themes. A skin changes only what is around and under the words.
- **Do** put decoration only where no word is drawn. That means hazard
  stripes on the bar, bay top bands and plate flanks; scallops and sparkles
  in the band and margins; and candy stripes inside bar fills.
- **Do** keep every word at 4.5:1 or better on what it sits on. Measure
  derived mixes too, not just the base roles.
- **Do** reserve signal orange for the selection on Mecha.
- **Do** keep a fallback for every display face to Carlito Bold, and keep
  the install and assertion in `finalize_chroot.sh` in step with
  `skins.py`.
- **Do** run `python3 toolkit/skins.py --check` (the build runs it). It
  renders home, menu, card and confirm for both skins at 1280x800,
  1366x768 (x1 and x1.5), 1920x1080 and 1024x768.

### Don't:
- **Don't** add a mascot character, busy art behind text (speed lines,
  halftone, patterns), or Japanese lettering. Ash ruled all three out.
- **Don't** round anything on Mecha, and don't add glow, blur or gradients
  to either skin.
- **Don't** give the Kawaii backing paper a grey or black colour or a blur.
  It is lavender sticker paper.
- **Don't** put white text on amber or honey. A WARN stamp is plum on honey.
- **Don't** let a status-column result push the test name out. Step the
  result down first.
