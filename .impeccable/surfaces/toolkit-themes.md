---
version: 1
slug: "toolkit-themes"
primary_target: "toolkit/themes"
related_targets: ["toolkit/ui.py","toolkit/settings.sh"]
---

# Surface brief: the anime themes (Mecha Command Deck, Kawaii Pastel)

Scope: two new entries in Settings -> Colour theme, beside light / dark /
contrast (which stay untouched). Each is a whole skin: home grid, menus, test
cards, badges, progress bars, the header; the How-it-works animations follow
the palette. Mode: Operate. Built in toolkit/skins.py, called from ui.py when
the theme's skin is active; the Menu style setting (manual / classic) applies
to the existing themes only.

Audience and job: the bench team, mostly for their own enjoyment (Ash: "mostly
the bench team"), picking the next test and reading verdicts at arm's length
on 1366x768-1920x1080 panels. Playful and loud is fine; verdicts must stay
unambiguous.

Constraints: Pillow onto the framebuffer, whole-frame redraws only on change,
no blur or glow; body text Carlito, numbers DejaVu Sans Mono, plus one display
face per skin from Ubuntu's own archive (OFL): Bebas Neue (fonts-bebas-neue)
for Mecha, Comfortaa Bold (fonts-comfortaa) for Kawaii, installed and asserted
by finalize_chroot.sh, falling back to Carlito Bold; 100-200 % text size must
work, panels from 1024x768; digit shortcuts and numbering stay; every word
keeps 4.5:1 on what it sits on. Ash ruled out: a mascot character,
busy art (speed lines, halftone, patterns) behind text, Japanese lettering.

Unresolved: none; both ship as Settings options, the default theme stays light.

## Direction contract

Two directions, both chosen by Ash ("i want mecha common deck and kawaii
paster both"); each is its own world and owns every screen while active.

### Mecha Command Deck

THESIS: The bench is a launch deck: every test a system bay with its own status lamp, and a fault an alert plate, not a sentence. Refuses floating white cards and rounded tiles.

OWN-WORLD: Matte console black ground, near-black plates, signal orange as the only selection colour, amber hazard stripes only on bay corners and deck furniture, alarm red and nominal green for verdicts. 45-degree chamfered corners, never rounded; 2 px grey plate outlines, grey HUD corner brackets, lamps set in a dark bezel; a failed bay is outlined red. Bebas Neue tracked caps for titles, bay names and verdict plates; Carlito for body text and the help line; DejaVu Mono for every number and readout; segmented block gauges. No glow, no gradients.

STORY: The tech scans the deck, reads each bay's lamp (unlit, green, red, amber), picks the next bay by number; a failed test shows a red alert plate flanked by hazard stripes.

FIRST VIEWPORT: Command bar across the top: hazard block at the left, HARDWARE DIAGNOSTIC TOOLKIT in tracked caps, boxed readouts REV / DATE / TIME at the right. Below, a grid of chamfered bays: a mono "01" tab at the top-left, centred icon, caps name, lamp top-right. The selected bay is outlined orange with a filled orange tab. A SYSTEM STATUS column on the right lists every bay with its lamp and result.

FORM: Mecha Command Deck - candidate 1 of the ordered grounded list, taken by Ash as the pick. Seed provenance: printed by concept-seed DIRECTION CONCEPT SEED key 03d48380; choice recorded with --kind pick.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

### Kawaii Pastel

THESIS: The toolkit as a sticker sheet: each test a sticker, each result a reward stamp - the category standard played straight at commercial polish, with every verdict still readable from arm's length.

OWN-WORLD: Blush pink ground, white sticker plates with a pink outline and a flat offset lavender backing (no blur), deep plum ink, muted mauve notes, lavender-violet for selection only, mint PASS, cherry FAIL, honey WARN. Large radius on plates, pills for rows and chips, a scalloped edge under the header band, a dotted pink rule under each title, four-point sparkles only in margins and band corners, candy stripes inside progress-bar fills (never behind text). WARN stamps are honey with plum text. Comfortaa Bold for titles, sticker names and stamps; Carlito for body text; DejaVu Mono numbers in round badges that stretch to pills from 10 up.

STORY: The tech finds the next sticker by its number badge, sees PASS / FAIL stamps on finished ones, and nothing pastel ever sits behind a word.

FIRST VIEWPORT: A pink header band with a scalloped lower edge, the toolkit name in plum bold, sparkles in the band's corners, date and time chips at the right. Below, a grid of white rounded sticker tiles: a round numbered badge at the top-left, pastel icon, plum name. The selected sticker is filled violet with white icon and name and a sparkle on its corner. A CHECKLIST column on the right with a result chip per test.

FORM: Kawaii Pastel - the standing exit (category standard), chosen by Ash with "your judgment" as the craft bar. Seed provenance: printed by concept-seed DIRECTION CONCEPT SEED key 03d48380; choice recorded with --kind canon.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
