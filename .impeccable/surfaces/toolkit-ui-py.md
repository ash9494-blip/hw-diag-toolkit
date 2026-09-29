---
version: 1
slug: "toolkit-ui-py"
primary_target: "toolkit/ui.py"
related_targets: ["toolkit/menu.sh"]
---

# Surface brief: navigation (home grid and menus)

Scope: toolkit/ui.py home tile grid (gridmenu), list menus (menu), header.
Test screens keep the current look for now. Mode: Operate.

Audience and job: bench technicians picking the next test, sometimes with a
customer watching; read at arm's length on 1366x768 to 1920x1080 laptop
panels, driven by keys, touchpad or mouse.

Constraints: Pillow onto the framebuffer - no blur, glow, gradients or
per-frame effects; Carlito + DejaVu Sans Mono only; light/dark/high-contrast
and 100-200 % text size must keep working; digit shortcuts and numbering
stay; must not become hard to read, slow, or toy-like.

Unresolved: whether it ships as the default look or a Settings theme - Ash
decides after the preview.

## Direction contract

THESIS: The screen is the bench itself - tests laid out on a matte ESD mat,
ruled in a fine engineering grid, marked with QC stickers. Refuses the
floating-white-cards tile grid.

OWN-WORLD: Deep blue-grey dissipative mat (#27394a) with a lighter mat
tone, 1 px white-alpha ruled grid with lettered/numbered edge coordinates,
white 2 px outlined bays, yellow ESD tag (#f2c230) as the only selection
mark, round QC stickers green PASS / red FAIL, Carlito caps labels, DejaVu
Mono for every number. Whole pixels, no shadows or blur.

STORY: The tech sees the whole bench, finds the next test by position or
number, and the machine's session results sit on it as stickers.

FIRST VIEWPORT: Printed border strip across the top (TOOLKIT name left, Wi-Fi
+ clock right as maker's print); the mat below with column letters along the
top edge and row numbers down the left; 16 bays on the grid, icon + caps
name + bay coordinate; the selected bay outlined yellow with a tag in its
top-left corner; a detail strip along the bottom naming the selected test
large with its last result.

FORM: Bench Mat - candidate 7 of the re-rolled grounded list; seed 50ca2ee1.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
