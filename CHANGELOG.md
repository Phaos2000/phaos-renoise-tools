# Changelog

## Simple Browser

### 1.4.5

Changes since 1.4.4 hotfix 1.

**Fixed**
- The auto-prehear speaker icon now changes when toggled. Its "off" state uses a new `Images/speaker_off.png` (a dimmed speaker with an ×) instead of the same image as "on".
- The speaker button is tinted while auto-prehear is on, like the other toggle buttons.
- The Beatsync length box no longer cuts off "Auto". It is wider (about 73 px instead of 49 px).
- Help text for the length box said "Off / 0" for a file; it now says "Auto / 0".

**Changed**
- Layout of the Beatsync cells: the **T** (pitch to tempo) button moved from the Beatsync cell into the Mode cell, giving the length box the room. Controls-mode keyboard navigation and its geometry follow the new layout; the T stop now comes after Mode.

**Internal**
- Removed unused lookups of the `ksb` / `ksbspace` views in `C.apply_kit_rows` (never defined).
- Layout comments updated to match.
- Audit: block structure checks out, no stray debug output or leftovers, versions consistent.

**Packaging**
- Version is 1.4.5 in `manifest.xml` and `C.VERSION`. Installer: [archives/SimpleBrowser-1.4.5.xrnx](archives/SimpleBrowser-1.4.5.xrnx).

### 1.4.4 hotfix 1

Original import (see [provenance/archives.json](provenance/archives.json)); archive kept as `archives/SimpleBrowser-1.4.4-hotfix1.xrnx`.
