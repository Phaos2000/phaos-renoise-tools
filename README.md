# Phaos' Renoise Tools

Five tools for Renoise, with their original Lua source, manifests, assets and installable `.xrnx` archives preserved.

| Tool / source | Version in manifest | Features | Downloads |
| --- | --- | --- | --- |
| [Simple Browser](SimpleBrowser/) | 1.4.4 (hotfix 1 archive) | Keyboard-driven sample browsing, instant preview, recursive search, keyjazz and multi-sample instrument building. | [Download .xrnx](https://github.com/Phaos2000/phaos-renoise-tools/releases/download/simple-browser-v1.4.4-hotfix1/com.phaos.SimpleBrowser-1.4.4-hotfix1.xrnx) · [Release](https://github.com/Phaos2000/phaos-renoise-tools/releases/tag/simple-browser-v1.4.4-hotfix1) · [Forum archive](https://forum.renoise.com/uploads/short-url/qEt8zN6WdrtzcbRXowZPxrQ6Zzm.xrnx) |
| [Simple Transients](SimpleTransients/) | 1.0.3 | Detect transients, step between hits, adjust selection boundaries and crop hits or loop sections. | [Download .xrnx](https://github.com/Phaos2000/phaos-renoise-tools/releases/download/simple-transients-v1.0.3/com.phaos.SimpleTransients-1.0.3.xrnx) · [Release](https://github.com/Phaos2000/phaos-renoise-tools/releases/tag/simple-transients-v1.0.3) · [Forum archive](https://forum.renoise.com/uploads/short-url/vXGLJaHfLNZ7cbEBmjuOzHEXhhB.xrnx) |
| [Simple Xfade](SimpleXfade/) | 1.2.0 | Equal-power loop crossfades for a selected sample region, an existing loop or an instrument's samples. | [Download .xrnx](https://github.com/Phaos2000/phaos-renoise-tools/releases/download/simple-xfade-v1.2.0/com.phaos.SimpleXfade-1.2.0.xrnx) · [Release](https://github.com/Phaos2000/phaos-renoise-tools/releases/tag/simple-xfade-v1.2.0) · [Forum archive](https://forum.renoise.com/uploads/short-url/jhloHZ4ZJnFXFwUgoSinmsaNIya.xrnx) |
| [Simple Interpolation](SimpleInterpolation/) | 1.0.2 | Set interpolation and anti-aliasing for a sample, instrument or song, and defaults for newly loaded samples. | [Download .xrnx](https://github.com/Phaos2000/phaos-renoise-tools/releases/download/simple-interpolation-v1.0.2/com.phaos.SimpleInterpolation-1.0.2.xrnx) · [Release](https://github.com/Phaos2000/phaos-renoise-tools/releases/tag/simple-interpolation-v1.0.2) · [Forum archive](https://forum.renoise.com/uploads/short-url/4sIlFW8U8z6PzMSvk4YZczdFFzv.xrnx) |
| [Simple Notes Off](SimpleNotesOff/) | 1.0.1 | Remove note-off events from a track, pattern or whole song while preserving other pattern data. | [Download .xrnx](https://github.com/Phaos2000/phaos-renoise-tools/releases/download/simple-notes-off-v1.0.1/com.phaos.SimpleNotesOff-1.0.1.xrnx) · [Release](https://github.com/Phaos2000/phaos-renoise-tools/releases/tag/simple-notes-off-v1.0.1) · [Forum archive](https://forum.renoise.com/uploads/short-url/bDnutJSxQXrI7mZhZQ9l35rVXz.xrnx) |

## Install

Use a **Download .xrnx** link above, or visit [Releases](https://github.com/Phaos2000/phaos-renoise-tools/releases) and download the tool's `.xrnx` attachment under **Assets**. Open it with Renoise. The automatic **Source code** ZIP/tar.gz downloads contain the whole repository and are not tool installers. Original copies also remain in [archives/](archives/) and at the forum links. All five manifests declare Renoise scripting API **6.2**. See each tool's menus, key bindings and help where available.

## Source and provenance

Each tool has its own top-level source directory. The original downloaded archives are retained in `archives/`. [provenance/archives.json](provenance/archives.json) records the exact supplied URLs, resolved download URLs, retrieval times, archive SHA-256 hashes, manifest fields and per-file hashes. All extracted files were checked byte-for-byte by SHA-256 against their ZIP entries. No tool source, manifest or asset was edited for this import. Git text conversion is disabled to preserve the original bytes.

Simple Browser includes **1.4.4 hotfix 1**; its manifest version is 1.4.4.

Feature summaries follow the included manifests. Archive and extraction integrity were checked; behavior inside Renoise has not been tested as part of this import. Original author credits are preserved in each manifest. No new license is assigned by this import.
