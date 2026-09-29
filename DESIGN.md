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
