# Changelog

## Simple Browser

### 1.4.5

Changes since 1.4.4 hotfix 1.

**Fixed**
- The auto-prehear speaker icon now changes when toggled. Its "off" state uses a new `Images/speaker_off.png` (a dimmed speaker with an ×) instead of the same image as "on".
- The speaker button is tinted while auto-prehear is on, like the other toggle buttons.
- The Beatsync length box no longer cuts off "Auto". It is wider (about 64 px instead of 49 px).
- Help text for the length box said "Off / 0" for a file; it now says "Auto / 0".

**Changed: a smaller window**
- The folder and sample panes are 326 px wide (were 362 px) and the Multi-Sample panel 330 px (was 394 px). Fully extended the browser is about 995 px wide (was about 1130 px), so it fits a 1024 px screen.
- The bookmark squares and the Options / Help buttons are smaller to fit the narrower pane.
- The Multi-Sample panel's Overlap popup is narrower to fit its third of the panel.

**Changed: the sample panel under the waveform**
- Every control is only as wide as its content needs; the two-pane layout is a 3 × 3 grid with no empty slot:
  - Volume, Octave, Beatsync `[ ][ Auto ][T]`
  - Output, Panning, Loop
  - Interp., Mode, Semi/Fine
- Semitone and Fine tune share one "Semi/Fine" cell. Their boxes show plain numbers (no "st") so they never clip.
- The "Interpolation" label is shortened to "Interp.".
- In two panes the file's details sit beside the grid under bold labels (Format, Bit, Length, Rate, Size, Ch, Peak, Loop). Notes that are not facts of the file (sync length, edited length, the default-loop reminder) stay on the line under the window, which only shows when there is something to say.
- One pane keeps its two columns by five rows and the one-line details under the panel.
- Keyboard order in controls mode (Caps Lock) follows the new grid.

**Internal**
- A control that fails now reports why: the error goes to Renoise's status bar and, with its stack, to `error.txt` in the tool's folder.
- The file-details update can no longer interrupt what follows a sample load (such as enabling Loop, Pitch and Panning).
- Removed unused lookups of the `ksb` / `ksbspace` views in `C.apply_kit_rows` (never defined).
- Version is 1.4.5 in `manifest.xml` and `C.VERSION`. Installer: [archives/SimpleBrowser-1.4.5.xrnx](archives/SimpleBrowser-1.4.5.xrnx).

### 1.4.4 hotfix 1

Original import (see [provenance/archives.json](provenance/archives.json)); archive kept as `archives/SimpleBrowser-1.4.4-hotfix1.xrnx`.
