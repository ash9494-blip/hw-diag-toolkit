# Board swap: restoring the machine's identity

When a Dynabook/Toshiba board is replaced, the new board reports a blank or
donor serial. The DMI fields feed warranty lookup, asset records, Windows OEM
activation (OA3 key) and vendor support tools.

## The toolkit's part: capture only

Run **DMI capture** before the old board comes out. It writes to the stick:
- `DmiCapture/<machine>_<timestamp>/dmichg.txt` — CRLF, ready for SetDmiAll
- `dmi-full.txt` — full dmidecode dump

Fields the firmware never had are written empty (not "Not Specified"). Values
corrected on the Machine details screen win over blank firmware.

## Writing: Toshiba's SetDmiAll, on Windows/WinPE

`DMI Update Tools.EXE` → SetDMIAll 1.0.1.8 (32/64-bit), `dmichg.txt` sample,
TVALZ driver set (`TVALZ.sys`, `TVALZ_O.sys`, `TVALZFL.sys`).
SHA256 of the package: `b82321dfe8daf3e411c7a393aae8f997b44717ed5155a13b0103655163593eeb`.

SetDmiAll installs TVALZ (kernel driver) and calls a Toshiba ACPI/SMI function
that asks the firmware to write the strings. Windows-only; Secure Boot must be
off for TVALZ to load.

`dmichg.txt` fields → SMBIOS: Manufacturer/ProductName/SerialNumber (type 1),
PartNumber (type 1 SKU), SerialNumberType3 + AssetTag (type 3),
AssetTagType2 (type 2), OemType11 (type 11), GSWID (Toshiba-specific).

Workflow: capture → swap board → boot Windows/WinPE → SetDmiAll with that
`dmichg.txt` → check against the chassis sticker. One Ventoy stick can hold the
toolkit ISO and a WinPE ISO side by side.

## Deliberately not built

A Linux DMI writer cloned from SetDmiAll. It would need the SMI function and
argument layout lifted from SetDmiAll.exe/TVALZ.sys, would carry none of the
vendor's model/firmware checks (wrong arguments can corrupt a protected flash
region → dead board), and would remove the gating between "restore this
machine's own serial" and "write any serial onto any board". Do not build it;
do not redistribute Toshiba's binaries. A WinPE build script, if written, takes
the path to Ash's own extracted copy.
