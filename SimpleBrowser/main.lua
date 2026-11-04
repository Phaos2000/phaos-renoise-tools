--------------------------------------------------------------------------------
-- Simple Browser  -  Renoise 3.5 / Lua API 6.2
--
-- Keyboard-driven sample browser with live preview, in the spirit of the
-- Impulse/Schism Tracker sample list.
--
--   Folders pane   : the current folder (or Folder Paths at the top)
--   Samples pane   : every sample of the highlighted folder, sub folders
--                    included (scanned in the background); single pane
--                    mode shows folders and samples in one list instead
--   Multi-Sample   : the selected instrument, built and edited here sample
--                    by sample (Drumkit, Distribute or Layer keyzones)
--   Bottom         : waveform with loop markers and a playback line (drag
--                    to select, trim / cut the preview copy), prehear
--                    controls, file details
--   Caps Lock      : controls mode - the buttons and settings by keyboard
--
-- Loading
--   Enter        new instrument in the first free slot after the last used
--                one; with the Multi-Sample panel open: add to that instrument
--   Shift+Enter  replace the selected sample slot of the selected instrument
--   Ctrl+Z / Y   undo / redo what was done in the browser
--
-- NOTE ON HOW PREVIEW WORKS
-- The Renoise scripting API has no "play this file" function, so this tool
-- keeps a scratch instrument at the end of the instrument list for the
-- highlighted file. It is deleted when the browser closes. The API also does not report where a voice is playing, so the
-- playback line is calculated from time, sample rate, pitch and loop.
--------------------------------------------------------------------------------

local TOOL_NAME        = "Simple Browser"
local SCRATCH_NAME     = "[Simple Browser Preview]"
local KIT_SCRATCH_NAME = "[Simple Browser Multi-Sample]"
-- constants live in this table (keeps the main chunk under Lua 5.1's
-- limit of 200 local variables)
local C = {}

C.LEGACY_SCRATCH   = "[Sample Browser Preview]"   -- names of earlier versions:
local SCRATCH_NAMES = {
  [SCRATCH_NAME] = true, [KIT_SCRATCH_NAME] = true, [C.LEGACY_SCRATCH] = true,
  ["[Simple Browser Kit]"] = true,   -- removed when found
}

local VISIBLE_ROWS     = 20
C.ROW_HEIGHT       = 18
local PANEL_WIDTH      = 362     -- folder / contents panel, scrollbar included
local KIT_WIDTH        = 394     -- multi-sample panel, scrollbar included
                                  -- (its list = 3 buttons of 124 + gaps)
local SCROLLBAR_WIDTH  = 16
-- When shown, the waveform extends the Multi-Sample list by KIT_EXTRA rows
-- so its controls align with the sample panel. Four rows cover the waveform,
-- its frame and one gap; hidden sections need no extra rows.
local KIT_EXTRA        = 4
local WAVE_HEIGHT      = KIT_EXTRA * 18 - 2
                         - renoise.ViewBuilder.DEFAULT_CONTROL_SPACING

C.PREVIEW_NOTE     = 48      -- C-4: the sample's original pitch
C.PREVIEW_DELAY_MS = 25      -- throttle: holding an arrow keeps previewing
C.WAVE_DELAY_MS    = 140     -- waveform is drawn once scrolling settles
C.CONTENTS_DELAY_MS = 90     -- debounce before rescanning the contents
C.WHEEL_ROWS       = 3
C.DOUBLE_CLICK_S   = 0.4     -- two clicks on a sample this fast: load it

C.SCAN_MAX_FILES   = 20000   -- stop a recursive scan after this many files
C.SCAN_MAX_DEPTH   = 16
C.FIND_MAX_FILES   = 400000  -- files a search may look through
C.FIND_SHOW        = 5000    -- matches listed at most
C.SCAN_BUDGET_S    = 0.012   -- time spent scanning per UI tick
C.SCAN_CACHE_SIZE  = 48      -- folders whose scan results are kept

C.PEAK_RES         = 512     -- waveform overview resolution
C.PEAK_READS       = 32      -- sample reads per overview column

-- Highlights follow the loaded theme. List backgrounds can be overridden
-- independently in Options for themes with poor browser contrast.
C.FOCUS   = "selection_back"           -- the highlight / control you are on
C.STANDBY = "standby_selection_back"   -- the highlight of the other panes
C.EDIT    = "valuebox_font"            -- a value while you change it
C.MARK    = "pattern_selection"        -- rows of a Shift selection
C.GLOW    = "automation_marker_play"   -- Multi-Sample rows sounding now
C.LIT     = "selected_button_back"     -- a toggle that is on
C.LOOP_MARK = "automation_marker_pair" -- loop markers on the waveform
C.LOOP_ICON = "selection_back"         -- the loop mode arrow on the waveform
-- used only if a Renoise version does not know one of the names above
C.FALLBACK = {
  selection_back = { 255, 143, 53 }, standby_selection_back = { 109, 114, 124 },
  valuebox_font = { 116, 236, 92 }, pattern_selection = { 115, 79, 26 },
  automation_marker_play = { 128, 246, 82 }, selected_button_back = { 255, 255, 255 },
  automation_marker_pair = { 226, 246, 66 }, main_font = { 228, 228, 228 },
  main_back = { 19, 19, 24 },
}
local DEFAULT_COLOR    = { 0, 0, 0 }        -- {0,0,0} = theme default

-- a view's colour from the theme (RGB fallback if the name is unknown)
function C.tint(v, color)
  if type(color) == "string" then
    if pcall(function() v.color = color end) then return end
    color = C.FALLBACK[color] or DEFAULT_COLOR
  end
  pcall(function() v.color = color end)
end

local LOOP_ITEMS = { "Off", "Forward", "Reverse", "PingPong" }  -- = LOOP_MODE_*
C.INTERP_ITEMS = { "None", "Linear", "Cubic", "Sinc" }   -- = INTERPOLATE_*

local KIT_MODES = { "Drumkit", "Distribute", "Layer" }  -- Renoise keyzone terms
C.VERSION = "1.4.4"
C.LIST_BACK_ITEMS = { "Theme", "Dark", "Grey", "Light", "Custom" }
C.LIST_BACK_COLORS = { false, { 28, 28, 32 }, { 80, 80, 84 }, { 224, 224, 228 } }
C.LIST_TEXT_ITEMS = { "Auto", "Light", "Dark", "Custom" }
C.TEXT_LIGHT, C.TEXT_DARK = { 255, 255, 255 }, { 1, 1, 1 }
-- the Beatsync popup: Off, then Renoise's Beatsync modes (prefs.sync_tempo and
-- prefs.sync_mode in one)
C.SYNC_ITEMS = { "Off", "Repitch", "Percussion", "Texture" }
C.ICON_W  = 24  -- every icon button (one size everywhere)
C.COUNT_W = 64  -- the [n/m] count, right end of every pane's header
C.NUM_W   = 20  -- the instrument number in the Multi-Sample's header
C.KEY_W   = 48  -- the [C-4] key cell in front of each Multi-Sample row:
                -- fits the widest, [G#4], so Renoise never widens one
-- fixed widths of controls, one per kind so equal things are equal
C.W = {
  box = 66,        -- value boxes (Oct, from): as wide as a popup
  check = 18,      -- check boxes
  popup = 66,      -- popups (Beatsync mode, Loop, Overlap)
}
-- Renoise's own icons (Resources/Icons), each with a fallback drawing of ours
C.ICONS = {
  prehear_on  = { "Icons/Browser_PrehearOn.bmp", "Images/speaker.png" },
  prehear_off = { "Icons/Browser_PrehearOff.bmp", "Images/speaker.png" },
  menu        = { "Icons/Options.bmp", "Images/menu.png" },
  multi       = { "Icons/Library.bmp", "Images/multisample.png" },
  piano       = { "Icons/Transport_ChordModeOff.bmp", "Images/piano.png" },
  left        = { "Icons/ArrowLeft.bmp", "Images/arrow_left.png" },
  right       = { "Icons/ArrowRight.bmp", "Images/arrow_right.png" },
  find        = { "Icons/Browser_Search.bmp", "Images/find.png" },
  snap        = { "Icons/SnapX.bmp", "Images/snap.png" },
  -- Renoise's icons trimmed to 15 px (a wider bitmap widens its button,
  -- off centre): the crossfade and the computer keyboard
  keyjazz     = { "Images/keyjazz.png", "Icons/Transport_ComputerKeyboard.bmp" },
  panes       = { "Icons/Transport_PatternSingleTrackMode.bmp",
                  "Images/arrow_right.png" },
  folder      = { "Icons/Browser_ShowDirectories.bmp", "Images/folder.png" },
  xfade       = { "Images/xfade.png", "Icons/SampleEd_XFade.bmp" },
}
-- put an icon on a button (or bitmap view); false if neither file loads
function C.set_icon(v, key)
  for _, path in ipairs(C.ICONS[key]) do
    if pcall(function() v.bitmap = path end) then return true end
  end
  return false
end
C.FILE_BROWSER = ({ WINDOWS = "Explorer", MACINTOSH = "Finder" })
                     [os.platform()] or "File Manager"
local KIT_DRUM, KIT_DIST, KIT_LAYERS = 1, 2, 3
local OVERLAP_ITEMS = { "Play All", "Cycle", "Random" }  -- Overlap: 0, 1, 2
C.WHITE_KEY = { [0] = true, [2] = true, [4] = true, [5] = true,
                    [7] = true, [9] = true, [11] = true }

-- the sample editor draws waveforms in the theme's "Main Font" colour, so
-- the preview uses that theme slot and follows whatever theme is loaded
C.WAVE_COLOR = "main_font"
C.WAVE_FALLBACK = { 228, 228, 228 }

C.AUDIO_EXTENSIONS = {
  wav = true, aif = true, aiff = true, flac = true, mp3 = true, ogg = true,
}

C.NOTE_NAMES = { "C-", "C#", "D-", "D#", "E-", "F-",
                     "F#", "G-", "G#", "A-", "A#", "B-" }

local IS_WINDOWS = (os.platform() == "WINDOWS")
local SEP = IS_WINDOWS and "\\" or "/"


--------------------------------------------------------------------------------
-- Preferences
-- (the document name is the first version's, so settings carry over)
--------------------------------------------------------------------------------

local prefs = renoise.Document.create("SampleBrowserPreferences") {
  prefs_version     = 0,
  list_background   = 1,      -- Theme / Dark / Grey / Light / Custom
  list_custom_hex   = "202024",
  list_text_colour  = 1,      -- Auto / Light / Dark / Custom
  list_text_hex     = "F5F5F5",
  list_selected_hex = "",     -- empty: use Renoise highlight colours
  list_marked_hex   = "",
  list_user_themes  = "",     -- named themes, stored with the tool preferences
  list_theme_name   = "",
  root_folder       = "",
  save_root         = false,  -- no longer used: the root is always kept
  remember_location = true,   -- reopen where we last were
  last_path         = "",
  remember_folder_sel = true,  -- reopen with the last folder highlighted
  remember_sample_sel = true,  -- reopen with the last sample highlighted
  folder_memory     = false,  -- every folder remembers its last highlight
  last_folder_sel   = "",     -- the folder highlighted in the folders pane
  last_folder_off   = 0,      -- ... and how far down the pane it was
  last_sample       = "",     -- the sample highlighted last
  last_sample_off   = 0,      -- ... and how far down the pane it was
  last_focus        = 1,      -- 1 = folders pane, 2 = samples pane
  autoplay          = true,   -- preview when the highlight moves onto a file
  show_contents     = true,   -- two panes (folders | samples)
  show_kit          = false,  -- Multi-Sample panel visible
  show_waveform     = true,
  show_controls     = true,   -- sample and Multi-Sample bottom panels
  default_loop      = 1,      -- loop of a sample without one: Off
  remember_default_loop = false,
  file_loops        = true,   -- use the loop a file carries
  default_interp    = 3,      -- Interpolation of every sample played and loaded
  kit_mode          = KIT_DRUM,
  kit_start         = 48,     -- first note of a drumkit (C-4)
  kit_default_open  = false,  -- open the Multi-Sample panel with the browser
  sync_tempo        = false,  -- Beatsync looping samples to the song tempo
  sync_keep         = false,  -- Beatsync on / off is kept between sessions
                              -- (off: it starts off with every session)
  white_keys        = false,  -- drumkit: white keys only
  overlap           = 1,      -- layer: index into OVERLAP_ITEMS
  include_subfolders = true,  -- samples pane lists sub folders' samples too
  find_root         = true,   -- find searches the whole root
  prehear_volume    = 0.9,
  prehear_master    = true,   -- prehear on the master track (Renoise default)
  sync_mode         = 2,      -- Beatsync mode: Repitch / Percussion / Texture
  insert_advance    = false,  -- 'Insert' moves to the next sample afterwards
  hidden_paths      = "",     -- items hidden from the browser, one per line
  places            = "",     -- extra folders next to the root, one per line
  snap_zero         = true,   -- loop points snap to zero crossings
  audition_changes  = false,  -- play again after Semitone / Fine tune / ... change
  kit_keyjazz       = false,  -- piano keys play the Multi-Sample everywhere
  bookmark_1 = "", bookmark_2 = "", bookmark_3 = "", bookmark_4 = "",
  bookmark_5 = "", bookmark_6 = "", bookmark_7 = "", bookmark_8 = "",
  -- no longer used; kept so settings files of earlier versions still load
  add_octave = false, loop_mode = 5, wave_color = 1, show_help = false,
  show_info = true,
}
renoise.tool().preferences = prefs

-- Pure RGB black is the button API's reset-to-theme sentinel. Use near
-- black instead so an explicitly requested black stays independent.
function C.hex_rgb(hex)
  hex = tostring(hex):match("^%s*#?(%x%x%x%x%x%x)%s*$")
  if not hex then return nil end
  local rgb = { tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16),
                tonumber(hex:sub(5, 6), 16) }
  if rgb[1] == 0 and rgb[2] == 0 and rgb[3] == 0 then return { 1, 1, 1 } end
  return rgb
end

function C.list_background()
  local mode = prefs.list_background.value
  if mode == 5 then
    return C.hex_rgb(prefs.list_custom_hex.value) or { 32, 32, 36 }
  end
  return C.LIST_BACK_COLORS[mode] or DEFAULT_COLOR
end

-- Resolve the actual row background, including theme highlights. Pure black
-- is the button API's reset sentinel, so it means button_back here.
function C.row_rgb(background)
  local name = type(background) == "string" and background or nil
  if not name and (background[1] ~= 0 or background[2] ~= 0 or background[3] ~= 0) then
    return background
  end
  name = name or "button_back"
  local ok, rgb = pcall(function() return renoise.app().theme.colors[name] end)
  return (ok and rgb) or C.FALLBACK[name] or { 48, 48, 48 }
end

function C.luminance(rgb)
  local function linear(v)
    v = v / 255
    return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * linear(rgb[1]) + 0.7152 * linear(rgb[2]) + 0.0722 * linear(rgb[3])
end

function C.row_text(background, highlighted, mode, custom)
  mode = highlighted and 1 or (mode or prefs.list_text_colour.value)
  if mode == 2 then return C.TEXT_LIGHT end
  if mode == 3 then return C.TEXT_DARK end
  if mode == 4 then return custom or C.hex_rgb(prefs.list_text_hex.value) or C.TEXT_LIGHT end
  local lum = C.luminance(C.row_rgb(background))
  local light = (C.luminance(C.TEXT_LIGHT) + 0.05) / (lum + 0.05)
  local dark = (lum + 0.05) / (C.luminance(C.TEXT_DARK) + 0.05)
  return light >= dark and C.TEXT_LIGHT or C.TEXT_DARK
end

function C.style_row(v, background, highlighted, mode, custom)
  C.tint(v, background)
  v.secondary_color = C.row_text(background, highlighted, mode, custom)
end

function C.highlight_colour(kind)
  local hex = kind == "marked" and prefs.list_marked_hex.value or prefs.list_selected_hex.value
  return C.hex_rgb(hex) or (kind == "marked" and C.MARK
    or kind == "standby" and C.STANDBY or C.FOCUS)
end

C.THEME_FIELDS = { "back", "back_hex", "text", "text_hex", "selected", "marked" }
function C.theme_copy(theme)
  local out = {}
  for _, key in ipairs(C.THEME_FIELDS) do out[key] = theme[key] end
  return out
end
function C.theme_equal(a, b)
  for _, key in ipairs(C.THEME_FIELDS) do if a[key] ~= b[key] then return false end end
  return true
end
function C.theme_name(name)
  name = tostring(name):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or name:find("[%z\1-\31\127]") or name:lower() == "current colours" then return nil end
  return name
end
function C.themes_read(data)
  local themes, seen = {}, {}
  for line in tostring(data):gmatch("[^\n]+") do
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    local name = fields[1] and C.theme_name((fields[1]:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)))
    local back, text = tonumber(fields[2]), tonumber(fields[4])
    if #fields == 7 and name and not seen[name:lower()]
       and back and back >= 1 and back <= 5 and back == math.floor(back)
       and text and text >= 1 and text <= 4 and text == math.floor(text)
       and C.hex_rgb(fields[3]) and C.hex_rgb(fields[5])
       and (fields[6] == "" or C.hex_rgb(fields[6])) and (fields[7] == "" or C.hex_rgb(fields[7])) then
      themes[#themes + 1] = { name = name, back = back, back_hex = fields[3],
        text = text, text_hex = fields[5], selected = fields[6], marked = fields[7] }
      seen[name:lower()] = true
    end
  end
  return themes
end
function C.themes_write(themes)
  local lines = {}
  for _, theme in ipairs(themes) do
    local fields = { (theme.name:gsub("[^%w _%.%-]", function(c) return string.format("%%%02X", c:byte()) end)) }
    for _, key in ipairs(C.THEME_FIELDS) do fields[#fields + 1] = tostring(theme[key]) end
    lines[#lines + 1] = table.concat(fields, "\t")
  end
  return table.concat(lines, "\n")
end

-- settings of earlier versions:
-- the Multi-Sample modes became Drumkit / Distribute / Layer (Layer 2 -> 3)
if prefs.prefs_version.value < 5 then
  if prefs.kit_mode.value == 2 then prefs.kit_mode.value = KIT_LAYERS end
  prefs.prefs_version.value = 5
end

-- the samples pane became the default
if prefs.prefs_version.value < 6 then
  prefs.show_contents.value = true
  prefs.prefs_version.value = 6
end

-- find searches the whole folder path by default
if prefs.prefs_version.value < 7 then
  prefs.find_root.value = true
  prefs.prefs_version.value = 7
end

-- the root stays the root until you set another one (save_root is no
-- longer used)

-- Beatsync starts off with every Renoise session, unless Options > Keep
-- Beatsync on / off between sessions is ticked (see also cleanup)
if not prefs.sync_keep.value then prefs.sync_tempo.value = false end


--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- A panel: entries + highlighted index + first visible row.
--   folder   entries: { name=, is_dir=, up= }
--   contents entries: { name=, rel=, full=, is_dir=false }
--   kit      entries: { name=, full=, is_dir=false }
local L = { key = "l", entries = {}, sel = 0, top = 1, width = PANEL_WIDTH,
            rows = VISIBLE_ROWS }
local R = { key = "r", entries = {}, sel = 0, top = 1, width = PANEL_WIDTH,
            rows = VISIBLE_ROWS, dir = nil, scanning = false, truncated = false }
local K = { key = "k", entries = {}, sel = 0, top = 1, width = KIT_WIDTH,
            rows = VISIBLE_ROWS + KIT_EXTRA + 2,   -- the most (one pane); see C.apply_kit_rows
            dirty = true }     -- kit entries survive closing the browser

local S = {
  root        = "",
  path        = "",
  focus       = L,     -- panel that receives the arrow keys
  dialog      = nil,
  vb          = nil,
  loaded_path = nil,   -- file currently sitting in the preview instrument
  file_loop   = nil,   -- loop settings the file came with
  held        = {},    -- id -> { name=, track=, note= } for sounding notes
  wave        = nil,   -- waveform overview of the loaded file
  play        = nil,   -- playback line state
  info_path   = nil,   -- file shown in the details box
  info        = nil,   -- parsed header of that file
  updating_sb = false, -- guards scrollbar notifiers during refreshes
  scratch_inst = nil,  -- exact preview instrument object owned by this session
}

local BM = {}           -- bookmark functions (filled in further down)
local F = {}            -- find (type to search) functions, further down

-- two panes = folders + samples (default); single pane = one mixed list.
-- A search shows its results in the samples pane (two panes) or in the
-- one list (single pane) - see F.pane.
local function two_pane()
  return prefs.show_contents.value
end

local scan_job   = nil  -- running recursive scan for the contents panel
local scan_cache = {}   -- dir -> { files=, truncated= }
local scan_cache_order = {}


--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function shorten_tail(s, n)
  if #s <= n then return s end
  return "..." .. s:sub(-(n - 3))
end

local function shorten_head(s, n)
  if #s <= n then return s end
  return s:sub(1, n - 3) .. "..."
end

-- List rows: Renoise cuts a button's text off at its edge, so a name that is
-- too wide has to be shortened by hand. The width is estimated from the
-- advance widths of a typical UI sans (1/2048 em; "i" is narrow, "W" wide), so
-- the row is filled instead of cut at a fixed character count, and the middle
-- goes: head and tail stay, which is where names differ ("... Part 1 (1991)]",
-- the extension).
local CHAR_UNITS = {}
do
  local function set(chars, w)
    for c in chars:gmatch(".") do CHAR_UNITS[c] = w end
  end
  set(" ,.", 651)  set("!", 821)  set('"', 937)  set("#", 1716)
  set("$0123456789", 1303)  set("%", 1946)  set("&", 1585)  set("'", 569)
  set("()[]", 799)  set("*_`", 1024)  set("+<=>^~", 1716)  set("-", 739)
  set("/\\:;|", 690)  set("?", 1087)  set("@", 2048)  set("{}", 1311)
  set("A", 1401)  set("B", 1405)  set("C", 1430)  set("D", 1577)
  set("E", 1294)  set("F", 1178)  set("G", 1587)  set("H", 1540)
  set("IJ", 604)  set("K", 1362)  set("L", 1141)  set("M", 1767)
  set("N", 1532)  set("O", 1612)  set("P", 1235)  set("Q", 1612)
  set("R", 1423)  set("S", 1300)  set("T", 1251)  set("U", 1499)
  set("V", 1401)  set("W", 2025)  set("X", 1403)  set("Y", 1251)
  set("Z", 1300)  set("a", 1255)  set("b", 1300)  set("c", 1126)
  set("d", 1300)  set("e", 1260)  set("f", 721)   set("g", 1300)
  set("h", 1298)  set("ij", 569)  set("k", 1186)  set("l", 569)
  set("m", 1995)  set("n", 1298)  set("o", 1253)  set("p", 1300)
  set("q", 1300)  set("r", 842)   set("s", 1067)  set("t", 803)
  set("u", 1298)  set("v", 1212)  set("w", 1675)  set("xy", 1212)
  set("z", 1075)
end
local CHAR_UNITS_OTHER = 1300           -- anything else (accents, symbols)
local UNITS_PER_PX = 210                -- measured on the list font; the
                                        -- list font is the one thing to retune
                                        -- if names ever fall short or overrun

-- the characters of a UTF-8 string, so a multibyte one is never split
local function utf8_chars(s)
  local t = {}
  for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
  return t
end

local function char_units(c)
  return CHAR_UNITS[c] or CHAR_UNITS_OTHER
end

local function text_units(s)
  local u = 0
  for _, c in ipairs(utf8_chars(s)) do u = u + char_units(c) end
  return u
end

-- fit s into `cap` units: as is, or head ... tail (55 % / 45 %)
local function shorten_mid(s, cap)
  if text_units(s) <= cap then return s end
  local ell = "..."
  local budget = cap - text_units(ell)
  if budget <= 0 then return ell end
  local chars = utf8_chars(s)
  local head, hu = {}, 0
  for i = 1, #chars do
    local w = char_units(chars[i])
    if hu + w > budget * 0.55 then break end
    head[#head + 1], hu = chars[i], hu + w
  end
  local tail, tu = {}, 0
  for i = #chars, #head + 1, -1 do
    local w = char_units(chars[i])
    if hu + tu + w > budget then break end
    table.insert(tail, 1, chars[i])
    tu = tu + w
  end
  return table.concat(head) .. ell .. table.concat(tail)
end

local function basename(path)
  return path:match("([^/\\]+)[/\\]*$") or path
end

local function stem(path)
  local b = basename(path)
  return b:match("^(.+)%.[^%.]+$") or b
end

local function note_name(n)
  n = clamp(math.floor(n + 0.5), 0, 119)
  return C.NOTE_NAMES[n % 12 + 1] .. math.floor(n / 12)
end

local function parse_note(s)
  s = (s or ""):upper():gsub("%s", "")
  local num = tonumber(s)
  if num then return clamp(num, 0, 119) end
  local name, oct = s:match("^([A-G][%-#]?)(%d)$")
  if not name then return nil end
  if #name == 1 then name = name .. "-" end
  for i, nn in ipairs(C.NOTE_NAMES) do
    if nn == name then return clamp((i - 1) + tonumber(oct) * 12, 0, 119) end
  end
  return nil
end

-- strip trailing separators but keep roots like "/" and "C:\"
local function norm(path)
  if not path or path == "" then return "" end
  local p = path
  if IS_WINDOWS then p = p:gsub("/", "\\") end
  while #p > 1 and p:sub(-1):match("[/\\]") do
    if p:match("^%a:[/\\]$") then break end
    p = p:sub(1, -2)
  end
  return p
end

local function same_path(a, b)
  if a == nil or b == nil then return false end
  if IS_WINDOWS then return a:lower() == b:lower() end
  return a == b
end

local function join(dir, name)
  if dir:sub(-1) == SEP then return dir .. name end
  return dir .. SEP .. name
end

local function is_within(path, root)
  if same_path(path, root) then return true end
  local prefix = root
  if prefix:sub(-1) ~= SEP then prefix = prefix .. SEP end
  return same_path(path:sub(1, #prefix), prefix)
end

local function parent_of(path)
  local p = norm(path)
  local parent = p:match("^(.*)[/\\][^/\\]*$")
  if parent == nil then return nil end
  if parent == "" then return SEP end
  if parent:match("^%a:$") then parent = parent .. SEP end
  return parent
end

local function dir_exists(path)
  if not path or path == "" then return false end
  local ok, res = pcall(io.exists, path)
  if ok and res then return true end
  -- fallback: look for it in the parent's directory listing
  local parent = parent_of(path)
  local p = norm(path)
  if parent and not same_path(parent, p) then
    local base = basename(p)
    local ok2, dirs = pcall(os.dirnames, parent)
    if ok2 and type(dirs) == "table" then
      for _, d in ipairs(dirs) do
        if basename(tostring(d)) == base then return true end
      end
    end
  end
  return false
end

local function ci_less(a, b)
  return a:lower() < b:lower()
end

-- hidden items (right-click > Hide from browser)
C.hidden = {}
function C.hide_key(path)
  local p = norm(path)
  return IS_WINDOWS and p:lower() or p
end
function C.load_hidden()
  C.hidden = {}
  for line in (prefs.hidden_paths.value .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then C.hidden[C.hide_key(line)] = line end
  end
end
function C.save_hidden()
  local list = {}
  for _, p in pairs(C.hidden) do list[#list + 1] = p end
  table.sort(list)
  prefs.hidden_paths.value = table.concat(list, "\n")
end
C.load_hidden()

local function list_dir(path)
  local dirs, files = {}, {}
  local function shown(name)
    return next(C.hidden) == nil or not C.hidden[C.hide_key(join(path, name))]
  end

  local ok, dn = pcall(os.dirnames, path)
  if ok and type(dn) == "table" then
    for _, d in ipairs(dn) do
      local name = basename(tostring(d))
      if name:sub(1, 1) ~= "." and shown(name) then dirs[#dirs + 1] = name end
    end
  end

  local ok2, fn = pcall(os.filenames, path)
  if ok2 and type(fn) == "table" then
    for _, f in ipairs(fn) do
      local name = basename(tostring(f))
      local ext = name:match("%.([^%.]+)$")
      if name:sub(1, 1) ~= "." and ext and C.AUDIO_EXTENSIONS[ext:lower()]
         and shown(name) then
        files[#files + 1] = name
      end
    end
  end

  -- Fold each name once, rather than twice for every sort comparison.
  local folded = {}
  for _, name in ipairs(dirs) do folded[name] = name:lower() end
  for _, name in ipairs(files) do folded[name] = name:lower() end
  local function less(a, b) return folded[a] < folded[b] end
  table.sort(dirs, less)
  table.sort(files, less)
  return dirs, files
end

local function view(id)
  return S.vb and S.vb.views[id] or nil
end

-- Messages go to Renoise's own status bar (no status line in the dialog).
local function set_status(msg)
  S.said = (S.said or 0) + 1        -- counts messages (see C.ctl_key)
  renoise.app():show_status(TOOL_NAME .. ": " .. msg)
end

local function remove_timer(fn)
  pcall(function()
    local tool = renoise.tool()
    if tool:has_timer(fn) then tool:remove_timer(fn) end
  end)
end

local function restart_timer(fn, ms)
  remove_timer(fn)
  renoise.tool():add_timer(fn, ms)
end

local function dialog_open()
  return S.dialog ~= nil and S.dialog.visible
end


--------------------------------------------------------------------------------
-- Wall clock
-- Renoise replaces os.clock() with a high precision timer. The docs are not
-- clear on whether it counts seconds or milliseconds, so measure it once
-- against os.time() shortly after the tool loads, assuming seconds till then.
--------------------------------------------------------------------------------

local clock_scale = 1.0
local calib = { t1 = nil, c1 = nil, start = os.time(), done = false }

local function now()
  return os.clock() * clock_scale
end

local function calib_idle()
  if not calib.done then
    local t = os.time()
    if calib.t1 == nil then
      if t ~= calib.start then calib.t1, calib.c1 = t, os.clock() end
    elseif t >= calib.t1 + 2 then
      local per_second = (os.clock() - calib.c1) / (t - calib.t1)
      if per_second > 100 then clock_scale = 0.001 end
      calib.done = true
    end
  end
  if calib.done then
    local obs = renoise.tool().app_idle_observable
    if obs:has_notifier(calib_idle) then obs:remove_notifier(calib_idle) end
  end
end
renoise.tool().app_idle_observable:add_notifier(calib_idle)


--------------------------------------------------------------------------------
-- File header probe (format, encoding, rate, length, loop ...)
-- Reads only headers; chunks are skipped with seek, so it is cheap.
--------------------------------------------------------------------------------

local probe_file  -- defined in the block below (keeps the main chunk's
                  -- local count under Lua 5.1's limit of 200)
do
  local function u16le(s, i) local a, b = s:byte(i, i + 1) return a + b * 256 end
  local function u32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
  end
  local function u16be(s, i) local a, b = s:byte(i, i + 1) return a * 256 + b end
  local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a * 16777216 + b * 65536 + c * 256 + d
  end

  local WAV_CODECS = {
    [1] = "PCM", [2] = "MS ADPCM", [3] = "Float", [6] = "A-law",
    [7] = "mu-law", [17] = "IMA ADPCM", [85] = "MP3",
  }
  local AIFC_CODECS = {
    NONE = "PCM", sowt = "PCM (LE)", twos = "PCM", fl32 = "Float",
    FL32 = "Float", fl64 = "Float", FL64 = "Float", alaw = "A-law",
    ulaw = "mu-law", ima4 = "IMA ADPCM",
  }

  local function probe_wav(f, head, info)
    info.format = "WAV"
    info.container = head:sub(1, 4)
    local pos, data_size, ds64_data, block = 12, nil, nil, nil
    for _ = 1, 64 do
      f:seek("set", pos)
      local h = f:read(8)
      if not h or #h < 8 then break end
      local id, size = h:sub(1, 4), u32le(h, 5)
      if id == "ds64" then
        local d = f:read(math.min(size, 28)) or ""
        if #d >= 16 then ds64_data = u32le(d, 9) + u32le(d, 13) * 4294967296 end
      elseif id == "fmt " then
        local d = f:read(math.min(size, 40)) or ""
        if #d >= 16 then
          local tag = u16le(d, 1)
          info.channels = u16le(d, 3)
          info.rate     = u32le(d, 5)
          block         = u16le(d, 13)
          info.bits     = u16le(d, 15)
          if tag == 65534 and #d >= 26 then tag = u16le(d, 25) end -- extensible
          info.codec = WAV_CODECS[tag] or string.format("Codec 0x%04X", tag)
        end
      elseif id == "data" then
        data_size = (size == 4294967295 and ds64_data) or size
        info.audio_end = pos + 8 + (data_size or 0)
        if size == 4294967295 then size = data_size or 0 end
      elseif id == "smpl" then
        local d = f:read(math.min(size, 60)) or ""
        if #d >= 36 then
          info.root_note = u32le(d, 13)
          if u32le(d, 29) > 0 and #d >= 60 then
            local t = u32le(d, 41)
            info.loop = {
              mode  = (t == 1 and 4) or (t == 2 and 3) or 2,  -- renoise modes
              start = u32le(d, 45) + 1,
              stop  = u32le(d, 49) + 1,
            }
          end
        end
      elseif id == "bext" then
        info.format = "BWF"
      end
      pos = pos + 8 + size + (size % 2)
    end
    if data_size and block and block > 0 then
      info.frames = math.floor(data_size / block)
    end
  end

  local function probe_aiff(f, head, info)
    local aifc = head:sub(9, 12) == "AIFC"
    info.format = aifc and "AIFF-C" or "AIFF"
    info.container = "FORM"
    info.codec = "PCM"
    local pos = 12
    for _ = 1, 64 do
      f:seek("set", pos)
      local h = f:read(8)
      if not h or #h < 8 then break end
      local id, size = h:sub(1, 4), u32be(h, 5)
      if id == "COMM" then
        local d = f:read(math.min(size, 26)) or ""
        if #d >= 18 then
          info.channels = u16be(d, 1)
          info.frames   = u32be(d, 3)
          info.bits     = u16be(d, 7)
          -- 80 bit IEEE extended sample rate
          local e = (d:byte(9) % 128) * 256 + d:byte(10) - 16383
          local mant = u32be(d, 11) * 4294967296 + u32be(d, 15)
          info.rate = math.floor(mant * 2 ^ (e - 63) + 0.5)
          if aifc and #d >= 22 then
            local c = d:sub(19, 22)
            info.codec = AIFC_CODECS[c] or c
          end
        end
      end
      pos = pos + 8 + size + (size % 2)
    end
  end

  local function probe_flac(f, info)
    info.format, info.container, info.codec = "FLAC", "FLAC", "FLAC"
    f:seek("set", 0)
    local d = f:read(42) or ""
    if #d < 42 then return end
    local s = d:sub(9)  -- STREAMINFO block body
    info.rate = s:byte(11) * 4096 + s:byte(12) * 16 + math.floor(s:byte(13) / 16)
    info.channels = math.floor((s:byte(13) % 16) / 2) + 1
    info.bits = (s:byte(13) % 2) * 16 + math.floor(s:byte(14) / 16) + 1
    local total = (s:byte(14) % 16) * 4294967296 + u32be(s, 15)
    if total > 0 then info.frames = total end
  end

  local function probe_ogg(f, info)
    info.format, info.container = "OGG", "OGG"
    f:seek("set", 0)
    local d = f:read(160) or ""
    if #d < 28 then return end
    local p = 28 + d:byte(27)  -- first packet after the segment table
    local opus_skip = 0
    if d:sub(p, p + 6) == "\1vorbis" and #d >= p + 23 then
      info.codec = "Vorbis"
      info.channels = d:byte(p + 11)
      info.rate = u32le(d, p + 12)
      local nominal = u32le(d, p + 20)
      if nominal > 0 and nominal < 2000000 then
        info.codec = string.format("Vorbis %dk", math.floor(nominal / 1000))
      end
    elseif d:sub(p, p + 7) == "OpusHead" and #d >= p + 15 then
      info.codec = "Opus"
      info.channels = d:byte(p + 9)
      opus_skip = u16le(d, p + 10)
      info.rate = 48000   -- opus always decodes at 48 kHz
    elseif d:sub(p, p + 4) == "\127FLAC" then
      info.codec = "FLAC"
    end
    -- length: granule position of the last page
    local size = info.size or 0
    local start = math.max(0, size - 65536)
    f:seek("set", start)
    local tail = f:read(65536) or ""
    local last
    local i = 1
    while true do
      local j = tail:find("OggS", i, true)
      if not j then break end
      last, i = j, j + 4
    end
    if last and #tail >= last + 13 then
      local gran = u32le(tail, last + 6) + u32le(tail, last + 10) * 4294967296
      if gran > 0 and gran < 2 ^ 50 then info.frames = gran - opus_skip end
    end
  end

  local MP3_RATES = {
    [3] = { 44100, 48000, 32000 }, [2] = { 22050, 24000, 16000 },
    [0] = { 11025, 12000, 8000 },
  }
  local MP3_KBPS = {
    v1l3 = { 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 },
    v1l2 = { 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 },
    v2   = { 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
  }

  local function probe_mp3(f, head, info)
    info.format, info.container = "MP3", "MPEG"
    local offset = 0
    if head:sub(1, 3) == "ID3" then
      local s = head:sub(7, 10)
      offset = 10 + ((s:byte(1) * 128 + s:byte(2)) * 128 + s:byte(3)) * 128
               + s:byte(4)
    end
    f:seek("set", offset)
    local d = f:read(4096) or ""
    for i = 1, #d - 3 do
      local b1, b2, b3, b4 = d:byte(i, i + 3)
      if b1 == 255 and b2 >= 224 then
        local ver = math.floor(b2 / 8) % 4
        local layer = math.floor(b2 / 2) % 4
        local bri, sri = math.floor(b3 / 16), math.floor(b3 / 4) % 4
        if ver ~= 1 and layer ~= 0 and bri > 0 and bri < 15 and sri < 3 then
          info.rate = MP3_RATES[ver][sri + 1]
          info.channels = (math.floor(b4 / 64) == 3) and 1 or 2
          local tbl = (ver ~= 3 and MP3_KBPS.v2)
                   or (layer == 1 and MP3_KBPS.v1l3) or MP3_KBPS.v1l2
          local kbps = tbl[bri]
          info.codec = string.format("L%d %dk", 4 - layer, kbps)
          if info.size and kbps > 0 then   -- constant bit rate estimate
            local secs = (info.size - offset) * 8 / (kbps * 1000)
            info.frames = math.floor(secs * info.rate)
            info.approx = true
          end
          break
        end
      end
    end
  end

  probe_file = function(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local info = {}
    local ok = pcall(function()
      info.size = f:seek("end")
      f:seek("set", 0)
      local head = f:read(12) or ""
      local id = head:sub(1, 4)
      if (id == "RIFF" or id == "RF64" or id == "BW64")
         and head:sub(9, 12) == "WAVE" then
        probe_wav(f, head, info)
      elseif id == "FORM" and (head:sub(9, 12) == "AIFF"
                               or head:sub(9, 12) == "AIFC") then
        probe_aiff(f, head, info)
      elseif id == "fLaC" then
        probe_flac(f, info)
      elseif id == "OggS" then
        probe_ogg(f, info)
      elseif head:sub(1, 3) == "ID3" or (head:byte(1) == 255
             and (head:byte(2) or 0) >= 224) then
        probe_mp3(f, head, info)
      else
        info.format = (path:match("%.([^%.]+)$") or "?"):upper()
      end
    end)
    f:close()
    if not ok then return nil end
    return info
  end

end

--------------------------------------------------------------------------------
-- Scratch instruments
--------------------------------------------------------------------------------

local function find_instrument(name)
  local song = renoise.song()
  for i, inst in ipairs(song.instruments) do
    if inst.name == name then return i end
  end
  return nil
end

local function find_scratch_index()
  local target = S.scratch_inst
  if not target then return nil end
  for i, inst in ipairs(renoise.song().instruments) do
    if rawequal(inst, target) then return i end
  end
  S.scratch_inst = nil
  return nil
end

-- Renoise's own undo history. Everything a tool changes in the song lands
-- there, the hidden preview instrument too. So prehearing goes in as ONE
-- merged step ("Simple Browser: Prehear") instead of a step per sample, and
-- what you really do is a step of its own with a name you recognise.
-- (The browser's 'Ctrl'+'Z' is separate - see Undo / redo.)
function C.quiet()
  pcall(function()
    renoise.song():describe_batch_undo(TOOL_NAME .. ": Prehear", 3600000)
  end)
end
function C.loud(what)
  if C.check_song_history and not S.undoing then C.check_song_history() end
  pcall(function() renoise.song():describe_undo(TOOL_NAME .. ": " .. what) end)
end

local function ensure_instrument(name)
  local song = renoise.song()
  local idx = (name == SCRATCH_NAME) and find_scratch_index() or find_instrument(name)
  if not idx then
    C.quiet()
    local previous = song.selected_instrument_index
    idx = #song.instruments + 1
    S.inst_busy = true
    local ok, err = pcall(function() song:insert_instrument_at(idx) end)
    S.inst_busy = false
    if not ok then error(err, 0) end
    local inst = song:instrument(idx)
    inst.name = name
    if name == SCRATCH_NAME then S.scratch_inst = inst end
    song.selected_instrument_index = previous
  end
  return idx
end

local function ensure_scratch()
  local idx = ensure_instrument(SCRATCH_NAME)
  local inst = renoise.song():instrument(idx)
  if #inst.samples == 0 then inst:insert_sample_at(1) end
  return idx
end

local function scratch_sample()
  local idx = find_scratch_index()
  if not idx then return nil end
  local inst = renoise.song():instrument(idx)
  if #inst.samples == 0 then return nil end
  return inst:sample(1)
end

-- the prehear volume as the preview instrument's volume, which applies to
-- notes already sounding; false if this Renoise has no instrument volume
function C.prehear_gain()
  local idx = find_scratch_index()
  if not idx then return false end
  local inst = renoise.song():instrument(idx)
  local v = clamp(prefs.prehear_volume.value, 0, 1)
  return pcall(function()
    if math.abs(inst.volume - v) > 1e-6 then
      C.quiet()
      inst.volume = v
    end
  end)
end

local function remove_scratch()
  local idx = find_scratch_index()
  if not idx then S.scratch_inst = nil return end
  C.quiet()
  S.inst_busy = true
  pcall(function()
    local song = renoise.song()
    if #song.instruments > 1 then
      song:delete_instrument_at(idx)
    else
      local inst = song:instrument(idx)
      inst:clear()
      inst.name = ""
    end
  end)
  S.inst_busy = false
  S.scratch_inst = nil
end

local function is_scratch(inst)
  return S.scratch_inst ~= nil and rawequal(inst, S.scratch_inst)
end

local function sequencer_track_index()
  local song = renoise.song()
  if song.selected_track.type == renoise.Track.TRACK_TYPE_SEQUENCER then
    return song.selected_track_index
  end
  for i, tr in ipairs(song.tracks) do
    if tr.type == renoise.Track.TRACK_TYPE_SEQUENCER then return i end
  end
  return 1
end


--------------------------------------------------------------------------------
-- Waveform + playback line
--------------------------------------------------------------------------------

local function loop_name(mode)
  return LOOP_ITEMS[mode] or "?"
end

-- Read a min/max overview of the buffer once per file.
local function compute_wave(sample, path)
  S.wave = nil
  local ok, err = pcall(function()
    local buf = sample.sample_buffer
    if not buf.has_sample_data then return end
    local n   = buf.number_of_frames
    local chs = math.min(buf.number_of_channels, 2)
    local res = math.min(C.PEAK_RES, n)
    local per = n / res
    local mins, maxs = {}, {}
    local peak, approximate = 0, buf.number_of_channels > chs
    for i = 1, res do
      local a = math.floor((i - 1) * per) + 1
      local b = math.max(a, math.floor(i * per))
      local step = math.max(1, math.floor((b - a + 1) / C.PEAK_READS))
      approximate = approximate or step > 1
      local mn, mx = 0, 0
      for f = a, b, step do
        for c = 1, chs do
          local v = buf:sample_data(c, f)
          if v < mn then mn = v elseif v > mx then mx = v end
        end
      end
      mins[i], maxs[i] = mn, mx
      if -mn > peak then peak = -mn end
      if mx > peak then peak = mx end
    end
    S.wave = {
      path = path, frames = n, rate = buf.sample_rate, res = res,
      channels = buf.number_of_channels,
      mins = mins, maxs = maxs, peak = peak, peak_approximate = approximate,
      loop_mode = sample.loop_mode,
      loop_start = sample.loop_start, loop_end = sample.loop_end,
    }
  end)
  if not ok then set_status("Waveform failed: " .. tostring(err)) end
end

-- keep loop info in the overview in sync with the preview sample
local function refresh_wave_loop()
  local smp = scratch_sample()
  if S.wave and smp then
    S.wave.loop_mode  = smp.loop_mode
    S.wave.loop_start = smp.loop_start
    S.wave.loop_end   = smp.loop_end
  end
end

-- Assign a theme colour, falling back to RGB if the name is unknown.
local function paint(ctx, prop, theme, rgb)
  if not pcall(function() ctx[prop] = theme end) then
    ctx[prop] = rgb or C.FALLBACK[theme] or { 128, 128, 128 }
  end
end

local function render_wave(ctx)
  local w, h = ctx.size.width, ctx.size.height
  local mid = h / 2
  local color = C.WAVE_COLOR

  -- background like the sample editor: the theme's "Main Back"
  paint(ctx, "fill_color", "main_back", { 19, 19, 24 })
  ctx:fill_rect(0, 0, w, h)

  ctx.global_alpha = 60
  paint(ctx, "fill_color", color, C.WAVE_FALLBACK)
  ctx:fill_rect(0, math.floor(mid), w, 1)
  ctx.global_alpha = 255

  local W = S.wave
  if not W then return end


  -- waveform outline: top edge left->right, bottom edge right->left
  local amp = mid - 2
  local res = W.res
  local function range(x)
    local a = math.floor(x * res / w) + 1
    local b = math.max(a, math.floor((x + 1) * res / w))
    return clamp(a, 1, res), clamp(b, 1, res)
  end

  ctx:begin_path()
  for x = 0, w - 1 do
    local a, b = range(x)
    local mx = W.maxs[a]
    for i = a + 1, b do if W.maxs[i] > mx then mx = W.maxs[i] end end
    local y = mid - mx * amp - 0.5
    if x == 0 then ctx:move_to(x, y) else ctx:line_to(x, y) end
  end
  for x = w - 1, 0, -1 do
    local a, b = range(x)
    local mn = W.mins[a]
    for i = a + 1, b do if W.mins[i] < mn then mn = W.mins[i] end end
    ctx:line_to(x, mid - mn * amp + 0.5)
  end
  ctx:close_path()
  paint(ctx, "fill_color", color, C.WAVE_FALLBACK)
  ctx:fill()
  paint(ctx, "stroke_color", color, C.WAVE_FALLBACK)
  ctx.line_width = 1
  ctx:stroke()

  -- a selection made by dragging on the waveform
  local r = S.sel_range
  if r and not S.wave_from_kit and W.frames > 1 then
    local x1 = math.floor((r[1] - 1) / W.frames * w)
    local x2 = math.ceil(r[2] / W.frames * w)
    ctx.global_alpha = 90
    paint(ctx, "fill_color", "selection_back", { 255, 143, 53 })
    ctx:fill_rect(x1, 0, math.max(1, x2 - x1), h)
    ctx.global_alpha = 255
  end

  if W.loop_mode and W.loop_mode ~= 1 and W.frames > 1 then
    C.draw_loop(ctx, W, w, h)
  end
  C.draw_channels(ctx, W, w, h)
end

-- Mono or stereo, bottom right, as Renoise draws them (one ring, two
-- linked rings), as big as the loop arrow above it and in its colour.
function C.draw_channels(ctx, W, w, h)
  if not W.channels then return end
  local r, y = 4, h - 8.5               -- ring radius, centre line
  local right = w - 6                   -- the loop arrow's right end
  paint(ctx, "stroke_color", C.LOOP_ICON)
  ctx.line_width = 1
  local function ring(cx)
    ctx:begin_path()
    ctx:arc(cx, y, r, 0, 2 * math.pi, false)
    ctx:stroke()
  end
  if W.channels >= 2 then
    ring(right - 14 + r + 0.5)          -- two rings across the arrow's 14 px
    ring(right - r - 0.5)
  else
    ring(right - 7)                     -- one, under the arrow's middle
  end
end

-- Loop markers like the sample editor's: a line at the loop start and
-- end, each with a small flag at the top pointing into the loop, and the
-- loop mode as an arrow in the top right corner (forward, reverse,
-- ping-pong).
function C.draw_loop(ctx, W, w, h)
  local x1 = math.floor((W.loop_start - 1) / W.frames * w)
  local x2 = math.min(w - 1, math.floor(W.loop_end / W.frames * w))
  -- controls mode on the Crossfade button: what it would fade in (before
  -- the loop start) and the end of the loop it is blended into
  local on_xfade = S.ctl_mode and S.ctl and S.ctl.id == "xfade_btn"
                   and not S.sel_range
  local len = on_xfade and C.xfade_max() or 0
  if len > 1 then
    local function band(a, b)
      local xa = math.floor((a - 1) / W.frames * w)
      local xb = math.ceil(b / W.frames * w)
      ctx:fill_rect(xa, 0, math.max(1, xb - xa), h)
    end
    ctx.global_alpha = 70
    paint(ctx, "fill_color", C.FOCUS)
    band(W.loop_start - len, W.loop_start - 1)
    band(W.loop_end - len + 1, W.loop_end)
    ctx.global_alpha = 255
  end
  paint(ctx, "fill_color", C.LOOP_MARK)
  ctx:fill_rect(x1, 0, 1, h)
  ctx:fill_rect(x2, 0, 1, h)
  ctx:begin_path()                         -- start flag, pointing right
  ctx:move_to(x1 + 1, 0)
  ctx:line_to(x1 + 7, 0)
  ctx:line_to(x1 + 1, 6)
  ctx:close_path()
  ctx:fill()
  ctx:begin_path()                         -- end flag, pointing left
  ctx:move_to(x2, 0)
  ctx:line_to(x2 - 6, 0)
  ctx:line_to(x2, 6)
  ctx:close_path()
  ctx:fill()

  -- mode arrow, top right
  local r, y, len = w - 6, 7, 14
  local l = r - len
  paint(ctx, "stroke_color", C.LOOP_ICON)
  paint(ctx, "fill_color", C.LOOP_ICON)
  ctx.line_width = 1
  ctx:begin_path()
  ctx:move_to(l, y + 0.5)
  ctx:line_to(r, y + 0.5)
  ctx:stroke()
  local function head(x, dir)              -- dir 1: points right
    ctx:begin_path()
    ctx:move_to(x, y + 0.5)
    ctx:line_to(x - 4 * dir, y - 3.5)
    ctx:line_to(x - 4 * dir, y + 4.5)
    ctx:close_path()
    ctx:fill()
  end
  if W.loop_mode == 2 then head(r, 1)                  -- forward
  elseif W.loop_mode == 3 then head(l, -1)             -- reverse
  else head(r, 1) head(l, -1) end                      -- ping-pong
end

local function render_playhead(ctx)
  paint(ctx, "fill_color", "main_font", { 240, 240, 240 })
  ctx:fill_rect(0, 0, ctx.size.width, ctx.size.height)
end

local function redraw_wave()
  if S.wave_view and prefs.show_waveform.value then S.wave_view:update() end
end

local function wave_width()
  if S.wave_view then return S.wave_view.width end
  return PANEL_WIDTH
end

local function hide_playhead()
  S.play = nil
  if S.playhead_view then S.playhead_view.visible = false end
end

local playhead_timer
local wave_timer

-- Position (0-based frames) a voice has reached after `t` seconds.
local function play_position(P, t)
  local pos = (P.offset or 0) + t * P.speed
  local mode = P.loop_mode
  if mode == 1 or P.le <= P.ls then
    if pos >= P.frames then return nil end
    return pos
  end
  if pos < P.le then return pos end
  local len = P.le - P.ls
  if mode == 2 then                         -- forward
    return P.ls + (pos - P.ls) % len
  elseif mode == 3 then                     -- reverse
    return P.le - (pos - P.le) % len
  else                                      -- ping-pong
    local k = (pos - P.le) % (2 * len)
    if k < len then return P.le - k end
    return P.ls + (k - len)
  end
end

playhead_timer = function()
  local P = S.play
  local ph = S.playhead_view
  if not P or not ph or not dialog_open() then
    remove_timer(playhead_timer)
    hide_playhead()
    return
  end
  local pos = play_position(P, now() - P.t0)
  if not pos then
    remove_timer(playhead_timer)
    hide_playhead()
    return
  end
  local w = wave_width()
  local x = clamp(math.floor(pos / P.frames * w), 0, w - 2)
  ph.origin = { x = x, y = 0 }
  ph.visible = prefs.show_waveform.value
end

-- `offset` (frames) is set when playing from a clicked waveform position
local function start_playhead(id, note, offset, smp)
  smp = smp or scratch_sample()
  if not smp or not S.playhead_view then return end
  local ok = pcall(function()
    local buf = smp.sample_buffer
    local base = 48
    pcall(function() base = smp.sample_mapping.base_note end)
    local semis = (offset and 0 or (note - base))
                  + smp.transpose + smp.fine_tune / 128
    local speed = buf.sample_rate * 2 ^ (semis / 12)
    if smp.beat_sync_enabled and not offset then
      local t = renoise.song().transport
      local secs = smp.beat_sync_lines * 60 / (t.bpm * t.lpb)
      speed = buf.number_of_frames / secs
    end
    S.play = {
      id = id, t0 = now(), offset = offset,
      frames = buf.number_of_frames,
      speed = speed,
      loop_mode = offset and 1 or smp.loop_mode,
      ls = smp.loop_start - 1, le = smp.loop_end,
      oneshot = smp.oneshot,
    }
  end)
  if ok then restart_timer(playhead_timer, 30) end
end


--------------------------------------------------------------------------------
-- File details box
--------------------------------------------------------------------------------

local function fmt_size(bytes)
  if not bytes then return nil end
  if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
  if bytes >= 1024 then return string.format("%d KB", math.floor(bytes / 1024 + 0.5)) end
  return bytes .. " B"
end

local function fmt_length(frames, rate, approx)
  if not frames or not rate or rate <= 0 then return nil end
  local s = frames / rate
  local txt
  if s >= 60 then
    txt = string.format("%d:%05.2f", math.floor(s / 60), s % 60)
  else
    txt = string.format("%.3f s", s)
  end
  return (approx and "~" or "") .. txt
end

-- One labelled line: format, bit depth, rate, channels, length, size,
-- loop, peak. Shows "-" for anything unknown or when nothing is highlighted.
function C.peak_text(wave)
  if wave.peak <= 0 then
    return wave.peak_approximate and "not detected (approx.)" or "silent"
  end
  return (wave.peak_approximate and "~" or "")
    .. string.format("%.1f dB", 20 * math.log10(wave.peak))
end

local function info_lines()
  local I = (S.info_path and S.info) or {}
  local fmt = "-"
  if I.format then
    fmt = I.format
    if (I.format == "WAV" or I.format == "BWF") and I.container then
      fmt = fmt .. "/" .. I.container
    end
    local c = I.codec
    if c and c ~= "PCM" and c ~= "PCM (LE)" and c ~= "FLAC" then
      fmt = fmt .. " " .. c
    end
  end
  local bit = (I.bits and I.bits > 0) and tostring(I.bits) or "-"
  local ch = "-"
  if I.channels then
    ch = (I.channels == 1 and "mono") or (I.channels == 2 and "stereo")
         or tostring(I.channels)
  end
  local loop = "-"
  if I.loop then loop = loop_name(I.loop.mode):lower()
  elseif I.format == "WAV" or I.format == "BWF" then loop = "none" end
  -- the sample as it sounds now: its loop and interpolation
  local interp = I.interp
  pcall(function()
    local smp = S.info_path and not S.wave_from_kit
                and same_path(S.loaded_path, S.info_path) and scratch_sample()
    if smp then
      loop = smp.loop_mode > 1 and loop_name(smp.loop_mode):lower() or "off"
      interp = smp.interpolation_mode
    end
  end)
  local peak = "-"
  local p = S.info_path
  if p and S.wave and S.wave.path == p and S.wave.peak then
    peak = C.peak_text(S.wave)
  end
  local sync = ""
  pcall(function()
    local smp = scratch_sample()
    if p and smp and same_path(S.loaded_path, p) and smp.beat_sync_enabled then
      sync = string.format("  sync: %d lines", smp.beat_sync_lines)
    end
  end)
  if S.edited and p and same_path(p, S.loaded_path) and S.wave then
    sync = sync .. "  (edited: " .. (fmt_length(S.wave.frames, S.wave.rate)
                                    or "?") .. ")"
  end
  local reminder = prefs.default_loop.value > 1
    and ("DEFAULT LOOP: " .. loop_name(prefs.default_loop.value) .. "  |  ") or ""
  return reminder .. string.format("format: %s  bit: %s  sr: %s  ch: %s  "
    .. "len: %s  size: %s  loop: %s%s  peak: %s" .. sync,
    fmt, bit, I.rate and string.format("%.1f kHz", I.rate / 1000) or "-",
    ch, fmt_length(I.frames, I.rate, I.approx) or "-",
    fmt_size(I.size) or "-", loop,
    interp and ("  interp: " .. C.INTERP_ITEMS[interp]:lower()) or "", peak)
end

-- The info text's font, measured once per window: the height of a line
-- and the width of a character (an average, from the text itself). If
-- this Renoise does not size a probe text view to its font, the old
-- estimates are used (16 px a line, 5.8 px a character).
function C.info_font(text)
  local lh, cw = 16, 5.8
  pcall(function()
    local vb = renoise.ViewBuilder()
    local probe = vb:text { text = "Xg", font = "italic" }
    -- (taller than 16: a control's height, not the font's - not used)
    if probe.height and probe.height >= 8 and probe.height <= 16 then
      lh = probe.height
    end
    local s = (text ~= "" and text) or string.rep("0", 60)
    local wide = vb:text { text = s, font = "italic" }
    local per = (wide.width or 0) / #s
    if per >= 3 and per <= 12 then cw = per end
  end)
  return lh, cw
end

-- the info text's height: as many lines as it wraps to at the current
-- width (words wrapped as Renoise wraps them), no more
function C.size_info()
  local v = view("info")
  if not v then return end
  local lh, cw = C.info_font(v.text)
  local room = math.max(20, math.floor((v.width - 4) / cw))  -- chars a line
  local lines, len = 1, 0
  for gap, word in v.text:gmatch("(%s*)(%S+)") do
    local need = (len > 0 and #gap or 0) + #word
    if len > 0 and len + need > room then
      lines, len = lines + 1, #word
    else
      len = len + need
    end
  end
  v.height = lines * lh + 2   -- a few px of padding
end

local function refresh_info_box()
  if not S.vb then return end
  local v = view("info")
  if v then
    v.text = info_lines()
    C.size_info()
  end
end

local function show_file_info(path)
  if path == S.info_path then return end
  S.info_path = path
  S.info = path and probe_file(path) or nil
  refresh_info_box()
end


--------------------------------------------------------------------------------
-- Note triggering
--------------------------------------------------------------------------------

-- "Play from here" works by slicing the preview sample at the clicked point
-- and playing that slice; the marker is removed before anything else plays.
local function clear_preview_slices()
  if not S.sliced then return end
  C.quiet()
  S.sliced = false
  pcall(function()
    local smp = scratch_sample()
    if not smp then return end
    local marks = {}
    for _, m in ipairs(smp.slice_markers) do marks[#marks + 1] = m end
    for _, m in ipairs(marks) do smp:delete_slice_marker(m) end
  end)
  pcall(function()
    local m = scratch_sample().sample_mapping
    m.base_note = 48
    m.note_range = { 0, 119 }
  end)
end

local function release_rec(rec)
  pcall(function()
    local idx = rec.idx or (rec.name == SCRATCH_NAME and find_scratch_index()
      or find_instrument(rec.name))
    if idx then
      renoise.song():trigger_instrument_note_off(idx, rec.track, rec.note)
    end
  end)
end

local function stop_playhead_for(id)
  if S.play and S.play.id == id and not S.play.oneshot then
    remove_timer(playhead_timer)
    hide_playhead()
  end
end

local function release_id(id)
  local rec = S.held[id]
  if rec then
    release_rec(rec)
    S.held[id] = nil
    stop_playhead_for(id)
  end
end

local function release_all()
  for id, rec in pairs(S.held) do
    release_rec(rec)
    S.held[id] = nil
  end
  remove_timer(playhead_timer)
  hide_playhead()
end

-- Start a note on the preview instrument, or on instrument number `inst`
-- (the Multi-Sample). `id` identifies the sounding note so it can be
-- released later (a key name, or "preview").
local function trigger(id, note, inst, offset)
  local inst_name = type(inst) == "string" and inst or nil
  if inst == nil then inst_name = SCRATCH_NAME end
  if inst_name == SCRATCH_NAME and not offset then clear_preview_slices() end
  local ok, err = pcall(function()
    local song = renoise.song()
    local idx = inst_name and (inst_name == SCRATCH_NAME and find_scratch_index()
      or find_instrument(inst_name)) or inst
    if not idx or not song.instruments[idx] then return end
    local ins = song:instrument(idx)
    if #ins.samples == 0 then return end
    if inst_name and not ins:sample(1).sample_buffer.has_sample_data then
      return
    end

    release_id(id)
    local track = sequencer_track_index()
    if prefs.prehear_master.value then        -- "Prehear on Master"
      for i, tr in ipairs(song.tracks) do
        if tr.type == renoise.Track.TRACK_TYPE_MASTER then track = i end
      end
    end
    local rec = { name = inst_name, idx = not inst_name and idx or nil,
                  track = track, note = clamp(note, 0, 119) }
    S.held[id] = rec
    -- the preview instrument: full velocity, its volume is the prehear
    -- volume (live: the slider reaches a note that is already sounding);
    -- other instruments (the Multi-Sample): the volume as the velocity
    local vol = clamp(prefs.prehear_volume.value, 0, 1)
    if inst_name == SCRATCH_NAME and C.prehear_gain() then vol = 1.0 end
    if not pcall(function()
      song:trigger_instrument_note_on(idx, rec.track, rec.note, vol)
    end) then                                 -- fall back to a normal track
      rec.track = sequencer_track_index()
      song:trigger_instrument_note_on(idx, rec.track, rec.note, vol)
    end
    if inst_name == SCRATCH_NAME then
      if S.wave_from_kit and not S.keep_kit_wave then   -- back to the file
        S.wave_from_kit = false
        S.wave = nil
        restart_timer(wave_timer, 1)
        if S.loaded_path then show_file_info(S.loaded_path) end
      end
      start_playhead(id, rec.note, offset)
    end
  end)
  if not ok then set_status("Trigger failed: " .. tostring(err)) end
end

-- Load a file into a sample slot, with the loop and interpolation every
-- new sample starts with (Options): the loop the file carries (if "Use
-- loops stored in files" is on), else the default loop over the whole
-- sample; the default interpolation. If Renoise did not pick up a loop
-- the file's smpl chunk defines, it is applied from our own header probe.
local function load_file_into_sample(smp, path, info)
  pcall(function() smp.loop_mode = 1 end)  -- no stale loop from before
  local loaded = smp.sample_buffer:load_from(path)
  if loaded == false or not smp.sample_buffer.has_sample_data then
    error("could not read " .. basename(path), 0)
  end
  info = info or probe_file(path)
  pcall(function()
    local n = smp.sample_buffer.number_of_frames
    if prefs.file_loops.value then
      if info and info.loop and smp.loop_mode == 1 then
        local s = clamp(info.loop.start, 1, n)
        local e = clamp(info.loop.stop, s, n)
        smp.loop_mode = info.loop.mode
        smp.loop_end = n
        smp.loop_start = s
        smp.loop_end = e
      end
    else
      smp.loop_mode = 1
    end
    if smp.loop_mode == 1 and prefs.default_loop.value > 1 then
      smp.loop_start = 1
      smp.loop_end = n
      smp.loop_mode = clamp(prefs.default_loop.value, 1, 4)
    end
  end)
  pcall(function()
    smp.interpolation_mode = clamp(prefs.default_interp.value, 1, 4)
  end)
end

-- Beats a looping sample should span at the song tempo, or nil.
-- Uses a BPM in the file name ("loop_120bpm.wav") when there is one,
-- otherwise the power of two beats closest to the song tempo.
local function sync_beats(smp, path)
  if not prefs.sync_tempo.value then return nil end
  local buf = smp.sample_buffer
  local secs = buf.number_of_frames / math.max(1, buf.sample_rate)
  if secs < 0.05 then return nil end
  local named = tonumber((basename(path or ""):lower()
                          :match("(%d%d%d?)%s*_?bpm")))
  if named and named >= 40 and named <= 300 then
    return math.max(1, math.floor(secs * named / 60 + 0.5))
  end
  local bpm = renoise.song().transport.bpm
  -- one-shots shorter than about a beat are never stretched
  if smp.loop_mode == 1 and secs < 0.9 * 60 / bpm then return nil end
  local best, best_err
  for _, n in ipairs { 1, 2, 4, 8, 16, 32, 64 } do
    local err = math.abs(math.log((n * 60 / secs) / bpm))
    if not best_err or err < best_err then best, best_err = n, err end
  end
  if best_err > math.log(1.5) then return nil end
  return best
end

-- Apply the browser's Beatsync setting to a sample. Used for the preview
-- and for everything that gets loaded, so what you hear is what you get.
local function apply_browser_settings(smp, path)
  pcall(function()
    local lines
    if prefs.sync_tempo.value then
      local own = C.synclen_of(path)      -- a length set in the Sync length box
      if own and own > 0 then
        lines = clamp(own, 1, 512)
      else
        local beats = sync_beats(smp, path)
        if beats then
          lines = clamp(beats * renoise.song().transport.lpb, 1, 512)
        end
      end
    end
    if lines then
      smp.beat_sync_lines = lines
      pcall(function() smp.beat_sync_mode = clamp(prefs.sync_mode.value, 1, 3) end)
      smp.beat_sync_enabled = true
    else
      smp.beat_sync_enabled = false
    end
  end)
end

-- the Beatsync length (lines) set for a file in the browser, or nil (the
-- browser's own choice). It is a step of the file like the others.
function C.synclen_of(path)
  local n
  for _, op in ipairs(path and C.ops_of(path) or {}) do
    if op.t == "synclen" then n = op.n end
  end
  return n
end

-- the Sync popup's value: 1 Off, 2 .. 4 on, in that mode
function C.sync_get()
  return prefs.sync_tempo.value and clamp(prefs.sync_mode.value, 1, 3) + 1 or 1
end
function C.sync_set(v)
  if v > 1 then prefs.sync_mode.value = v - 1 end
  prefs.sync_tempo.value = v > 1
end
-- the boxes show the prefs (changed by key bindings, undo ...)
function C.show_sync()
  S.updating_sync = true
  pcall(function()
    local on = view("sync")
    if on and on.value ~= prefs.sync_tempo.value then
      on.value = prefs.sync_tempo.value
    end
  end)
  S.updating_sync = false
  pcall(C.show_pitch)
end

-- the key binding: Repitch, Percussion, Texture, round
function C.cycle_sync_mode()
  prefs.sync_mode.value = prefs.sync_mode.value % 3 + 1
  set_status("Beatsync mode: " .. C.SYNC_ITEMS[prefs.sync_mode.value + 1])
end

-- Beatsync changed: apply it to the preview again
local function apply_loop_mode()
  local smp = scratch_sample()
  if not smp or not smp.sample_buffer.has_sample_data then return end
  C.quiet()
  apply_browser_settings(smp, S.loaded_path)
  refresh_wave_loop()
  redraw_wave()
end

-- Draws the waveform of the preview sample (deferred, so holding an arrow
-- key keeps previewing without stalling on the overview).
wave_timer = function()
  remove_timer(wave_timer)
  local smp = scratch_sample()
  if not smp or not S.loaded_path then return end
  compute_wave(smp, S.loaded_path)
  refresh_wave_loop()
  redraw_wave()
  refresh_info_box()  -- peak level is known now
end

-- Per file edits ---------------------------------------------------------
-- What you change on a sample in the browser (its loop, interpolation,
-- trims, cuts, crossfades) is kept as a list of steps per file for as long
-- as the browser is open. The preview is always the file plus its steps,
-- replayed when the file is highlighted again; undo / redo take steps off
-- and put them back. The file itself is never changed.
S.ops = {}     -- file key -> { step, ... }
function C.file_key(path) return IS_WINDOWS and path:lower() or path end
function C.ops_of(path, create)
  local k = C.file_key(path)
  if create and not S.ops[k] then S.ops[k] = {} end
  return S.ops[k]
end
C.DATA_OPS = { trim = true, cut = true, xfade = true }
function C.has_data_ops(path)
  for _, op in ipairs(C.ops_of(path) or {}) do
    if C.DATA_OPS[op.t] then return true end
  end
  return false
end

-- Stream a file into the preview instrument (no-op if it is already there).
local function load_preview(path)
  if S.loaded_path == path then return true end
  C.quiet()
  local ok, err = pcall(function()
    local idx = ensure_scratch()
    local inst = renoise.song():instrument(idx)
    release_all()
    clear_preview_slices()
    local smp = inst:sample(1)
    load_file_into_sample(smp, path,
      same_path(path, S.info_path) and S.info or nil)
    inst.name = SCRATCH_NAME   -- keep our marker even if loading renames
    S.loaded_path = path
    S.edited, S.edit_tmp, S.sel_range = false, nil, nil   -- a fresh copy
    pcall(function() smp.transpose = 0 smp.fine_tune = 0 smp.panning = 0.5 end)
    -- the file's steps again; one that cannot be done (and what follows
    -- it) is left out, the rest stays
    local list = C.ops_of(path) or {}
    for i, op in ipairs(list) do
      local done, why = pcall(C.apply_op, smp, op)
      if not done then
        for k = #list, i, -1 do list[k] = nil end
        set_status("Could not repeat a change of " .. basename(path) .. ": "
                   .. tostring(why))
        break
      end
    end
    S.edited = C.has_data_ops(path)
    S.wave = nil             -- drawn by wave_timer once scrolling settles
    restart_timer(wave_timer, C.WAVE_DELAY_MS)
  end)
  if not ok then
    S.loaded_path = nil
    S.wave = nil
    redraw_wave()
    refresh_info_box()
    C.show_loop()
    set_status("Preview failed: " .. tostring(err))
    return false
  end
  local smp = scratch_sample()
  if smp then apply_browser_settings(smp, path) end
  refresh_wave_loop()
  redraw_wave()
  C.show_loop()
  C.loop_baseline()
  return true
end

-- the preview shows the file plus its steps again (after an undo)
function C.reload_preview(path)
  if path and same_path(path, S.loaded_path) then
    S.loaded_path = nil
    load_preview(path)
    refresh_info_box()
  end
end

--------------------------------------------------------------------------------
-- Panels (shared logic)
--------------------------------------------------------------------------------

local function entry_path(P, e)
  if e.full then return e.full end   -- samples pane, search results
  return join(S.path, e.name)
end

-- the room a row's text has, in the units of shorten_mid (the button's own
-- padding left and right and 5 % of safety taken off)
local function row_units(P)
  local w = P.width - SCROLLBAR_WIDTH - 9
  if P == K then w = w - C.KEY_W end
  return w * UNITS_PER_PX * 0.95
end

-- Key of kit sample i (Drumkit). With "White keys only" black keys are
-- skipped, starting at the first white key at or above the start note.
local function kit_note(i)
  local n = prefs.kit_start.value
  if not prefs.white_keys.value then return n + i - 1 end
  while n <= 119 and not C.WHITE_KEY[n % 12] do n = n + 1 end
  for _ = 2, i do
    n = n + 1
    while n <= 119 and not C.WHITE_KEY[n % 12] do n = n + 1 end
  end
  return n
end

-- Key range of kit sample i of n (Distribute): even split of C-0..B-9.
local function dist_range(i, n)
  local lo = math.floor((i - 1) * 120 / n)
  return lo, math.max(lo, math.floor(i * 120 / n) - 1)
end

local function display_name(P, e, idx)
  local cap = row_units(P)
  if e.rel then
    -- file name first, then the sub folder it is in
    local parent = e.rel:match("([^/\\]+)[/\\][^/\\]+$")
    return shorten_mid(parent and (e.name .. "  (" .. parent .. ")")
                       or e.name, cap)
  end
  if P == K then return shorten_mid(e.name, cap) end
  if e.up then return "[..]" end
  if e.here then return "[ this folder ]" end
  if e.is_dir then return shorten_mid("[" .. e.name .. "]", cap) end
  return shorten_mid(e.name, cap)
end

-- the key cell of Multi-Sample row idx: [C-4] (Drumkit), the zone's first
-- key (Distribute) or the layer number [01] (Layer)
function C.kit_tag(idx)
  local tag = "---"
  pcall(function()
    local m = C.map_of(renoise.song().selected_instrument.samples[idx])
    if m.lo == 0 and m.hi == 119 then
      tag = string.format("%02d", idx)   -- on all keys: the layer number
    else
      tag = note_name(m.lo)              -- its (first) key
    end
  end)
  return "[" .. tag .. "]"
end

-- file under the focused panel's highlight, or nil
local function selected_file()
  local P = S.focus
  if P == K then return nil end         -- instrument samples, not files
  local e = P.entries[P.sel]
  if e and not e.is_dir then return entry_path(P, e) end
  return nil
end

local function ensure_selected_loaded()
  local path = selected_file()
  if path then return load_preview(path) end
  return S.loaded_path ~= nil
end

local function max_top(P)
  return math.max(1, #P.entries - P.rows + 1)
end

-- Search syntax:  kick 909   both words      kick or snare / kick | snare
--                 -loop / not loop   exclude    "tr 909"   exact phrase
--                 kick*.wav   * = any text, ? = one character
-- Returns OR-groups of { inc = {...}, exc = {...} } matchers.
function F.parse(q)
  local tokens = {}
  q = q:lower()
  local i = 1
  while i <= #q do
    local c = q:sub(i, i)
    if c == '"' then
      local j = q:find('"', i + 1, true) or (#q + 1)
      tokens[#tokens + 1] = { text = q:sub(i + 1, j - 1), quoted = true }
      i = j + 1
    elseif c:match("%s") then
      i = i + 1
    else
      local j = q:find("[%s\"]", i) or (#q + 1)
      tokens[#tokens + 1] = { text = q:sub(i, j - 1) }
      i = j
    end
  end
  local groups = { { inc = {}, exc = {} } }
  local negate = false
  for _, t in ipairs(tokens) do
    local w = t.text
    if not t.quoted and (w == "or" or w == "|") then
      groups[#groups + 1] = { inc = {}, exc = {} }
    elseif not t.quoted and w == "and" then
      -- words are joined with AND anyway
    elseif not t.quoted and w == "not" then
      negate = true
    elseif w ~= "" then
      local neg = negate
      if not t.quoted and #w > 1 and w:sub(1, 1) == "-" then
        neg, w = true, w:sub(2)
      end
      local m = { text = w }
      if not t.quoted and w:find("[%*%?]") then
        m.pattern = w:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
                     :gsub("%*", ".*"):gsub("%?", function()
                       return "[%z\1-\127\194-\244][\128-\191]*"
                     end)
      end
      local g = groups[#groups]
      if neg then g.exc[#g.exc + 1] = m else g.inc[#g.inc + 1] = m end
      negate = false
    end
  end
  -- an exclusion applies to the whole search, whichever side of an OR
  local exc = {}
  for _, g in ipairs(groups) do
    for _, m in ipairs(g.exc) do exc[#exc + 1] = m end
  end
  for _, g in ipairs(groups) do g.exc = exc end
  return groups
end

function F.match(groups, hay)
  local function hit(m)
    if m.pattern then return hay:find(m.pattern) ~= nil end
    return hay:find(m.text, 1, true) ~= nil
  end
  for _, g in ipairs(groups) do
    local ok = true
    for _, m in ipairs(g.inc) do if not hit(m) then ok = false break end end
    if ok then
      for _, m in ipairs(g.exc) do if hit(m) then ok = false break end end
    end
    if ok then return true end
  end
  return false
end

-- the pane a search shows its results in: the samples pane with two
-- panes, else the one list (where its header shows what you type)
function F.pane()
  return two_pane() and R or L
end

-- Find: list the files whose path matches the search. New files
-- found by the running scan are checked as they come in (`full` = start
-- over, after the search text changed).
function F.apply(full)
  local P = R
  if not S.find or F.pane() ~= R then
    R.entries = R.all or {}
  end
  if S.find then
    P = F.pane()
    local f = S.find
    local paths = f.paths or {}
    if full or not f.upto then
      f.groups = F.parse(f.query)
      P.entries, f.upto, P.truncated = {}, 0, false
    end
    -- check the paths in slices of a few milliseconds, so a big library
    -- never freezes Renoise; F.timer carries on with the rest
    local groups, out, low = f.groups, P.entries, f.lower or {}
    local deadline = now() + 0.008
    local i = f.upto
    while i < #paths do
      i = i + 1
      local rel = paths[i]
      if F.match(groups, low[i] or rel:lower()) then
        if #out < C.FIND_SHOW then
          out[#out + 1] = { name = basename(rel), rel = rel,
                            full = join(f.dir, rel), is_dir = false }
        else
          P.truncated = true
        end
      end
      if i % 512 == 0 and now() >= deadline then break end
    end
    f.upto = i
    if f.upto < #paths then restart_timer(F.timer, 15) end
  end
  for _, Q in ipairs { R, P } do
    if Q.sel > #Q.entries then Q.sel = #Q.entries end
    if Q.sel == 0 and #Q.entries > 0 then Q.sel = 1 end
    Q.top = clamp(Q.top, 1, max_top(Q))
  end
end

-- header text while searching: "Find: kick 909_"
function F.head()
  local f = S.find
  return shorten_tail("Find: " .. f.query .. (f.typing and "_" or "")
    .. (R.scanning and "  (searching)" or ""), 36)
end

local function refresh_scrollbar(P)
  local sb = view(P.key .. "sb")
  local spacer = view(P.key .. "sbspace")
  local n = #P.entries
  local needed = n > P.rows
  if spacer then spacer.visible = not (needed and sb ~= nil) end
  if not sb then return end
  S.updating_sb = true
  pcall(function()
    if needed then
      sb.value = 0
      sb.min = 0
      sb.pagestep = P.rows
      sb.max = n
      sb.value = clamp(P.top - 1, 0, n - P.rows)
    end
    sb.visible = needed
  end)
  S.updating_sb = false
end

local function refresh_header(P)
  local head = view(P.key .. "head")
  local cnt  = view(P.key .. "count")
  if head then
    if S.find and P == F.pane() then
      head.text = F.head()
    elseif P == L then
      local chars = math.max(12, math.floor((head.width or 200) / 6.5))
      local warn = S.missing and ("  (" .. basename(S.missing) .. " missing)") or ""
      head.text = shorten_tail(S.at_places and "Folder Paths" or S.path,
                               math.max(8, chars - #warn)) .. warn
      head.tooltip = S.missing and ("The root folder is not there (a drive "
        .. "not connected, or moved?):\n" .. S.missing .. "\nFolder icon > "
        .. "Rescan folders looks again, Set root folder... picks another.")
        or (S.at_places and "The root and the folder paths" or S.path)
    elseif P == R then
      do
        local name = R.dir and basename(R.dir) or "-"
        head.text = shorten_head(name, 22)
          .. (R.scanning and "  (scanning)"
              or (R.has_sub and "  (+ sub)" or ""))
      end
    end
  end
  if P == K then
    local tf = view("kit_name")
    local editing = false
    pcall(function() editing = tf.edit_mode end)
    local idx, inst = C.kit_index()
    if tf and not editing then
      S.updating_name = true
      tf.value = inst and inst.name or ""
      pcall(function() tf.active = inst ~= nil end)
      S.updating_name = false
    end
    local num = view("kit_num")
    if num then num.text = idx and string.format("%02X", idx - 1) or "--" end
  end
  if cnt then
    local n = P.truncated and "+" or ""
    cnt.text = string.format("[%d/%d%s]", math.max(P.sel, 0), #P.entries, n)
  end
end

C.KIT_HINT = {
  "The selected instrument has no samples.",
  "",
  "'Enter' adds the highlighted sample to it",
  "('Insert': a whole folder too), each on",
  "its own keys: Drumkit, Distribute or",
  "Layer - see below.",
  "",
  "'New' starts another instrument. Select",
  "an instrument in Renoise to edit it here.",
}
C.KIT_HINT_NONE = {
  "A preview instrument is selected.",
  "",
  "Select an instrument in Renoise, or press",
  "'New' - 'Enter' then adds samples to it.",
}

local function refresh_panel(P)
  if not S.vb then return end
  local background = C.list_background()
  local sel_color = C.highlight_colour((S.focus == P and not S.ctl_mode) and "selected" or "standby")
  for i = 1, P.rows do
    local btn = view(P.key .. "row" .. i)
    if not btn then break end
    local idx = P.top + i - 1
    local e = P.entries[idx]
    local key = (P == K) and view("kkey" .. i) or nil
    local row_back, highlighted = background, false
    if e then
      btn.text = display_name(P, e, idx)
      if idx == P.sel then row_back, highlighted = sel_color, true
      elseif P.marked and P.marked[e] then row_back, highlighted = C.highlight_colour("marked"), true end
      btn.active = true
    else
      local hint = (P == K and #K.entries == 0)
                   and (C.kit_index() and C.KIT_HINT or C.KIT_HINT_NONE)
      btn.text = hint and hint[i] or ""
      btn.active = false
    end
    -- Multi-Sample keyjazz: the rows that are sounding glow
    if P == K and e and C.kit_glowing(idx) then row_back, highlighted = C.GLOW, true end
    C.style_row(btn, row_back, highlighted)
    if key then
      key.text = e and C.kit_tag(idx) or ""
      C.style_row(key, row_back, highlighted)
      key.active = e ~= nil
    end
  end
  refresh_header(P)
  refresh_scrollbar(P)
end

-- carries on filtering a search, a slice at a time
F.timer = function()
  remove_timer(F.timer)
  if not S.find or not dialog_open() then return end
  F.apply()
  refresh_panel(F.pane())
end

-- typing: wait for a short pause before searching again
F.retype = function()
  remove_timer(F.retype)
  if not S.find or not dialog_open() then return end
  F.apply(true)
  refresh_panel(F.pane())
end

local function refresh_all()
  refresh_panel(L)
  refresh_panel(R)
  refresh_panel(K)
end

local function sync_info()
  local path = selected_file()
  if path then show_file_info(path) end
end


--------------------------------------------------------------------------------
-- Debounced auto-preview
--------------------------------------------------------------------------------

local preview_timer
preview_timer = function()
  remove_timer(preview_timer)
  if not dialog_open() then return end
  if S.focus == K then C.kit_play_row() return end
  local path = selected_file()
  if path and load_preview(path) then
    trigger("preview", C.PREVIEW_NOTE)
  end
end


--------------------------------------------------------------------------------
-- Contents panel: recursive scan, a time slice per timer tick
--------------------------------------------------------------------------------

local scan_timer
local contents_timer

local function cache_put(dir, files, truncated)
  if not scan_cache[dir] then
    scan_cache_order[#scan_cache_order + 1] = dir
    if #scan_cache_order > C.SCAN_CACHE_SIZE then
      scan_cache[table.remove(scan_cache_order, 1)] = nil
    end
  end
  scan_cache[dir] = { files = files, truncated = truncated }
end

local function clear_scan_cache()
  scan_cache, scan_cache_order = {}, {}
  S.find_cache = nil
end

local function stop_scan()
  scan_job = nil
  R.scanning = false
  remove_timer(scan_timer)
end

scan_timer = function()
  local job = scan_job
  if not job or not dialog_open() then
    stop_scan()
    return
  end
  local deadline = now() + C.SCAN_BUDGET_S
  repeat
    local item = table.remove(job.stack)
    if not item then break end
    local dirs, files = list_dir(item.path)
    local cap = job.find and C.FIND_MAX_FILES or C.SCAN_MAX_FILES
    for _, f in ipairs(files) do
      if #job.files >= cap then
        job.truncated = true
        break
      end
      if job.find then                    -- search: just the relative path
        local rel = item.rel .. f
        job.files[#job.files + 1] = rel
        job.lower[#job.lower + 1] = rel:lower()   -- searched as-is later
      else
        job.files[#job.files + 1] = {
          name = f, rel = item.rel .. f, full = join(item.path, f),
          is_dir = false,
        }
      end
    end
    if item.depth < job.max_depth and not job.truncated then
      for i = #dirs, 1, -1 do  -- reversed so the stack pops them A..Z
        job.stack[#job.stack + 1] = {
          path = join(item.path, dirs[i]),
          rel = item.rel .. dirs[i] .. SEP,
          depth = item.depth + 1,
        }
      end
    end
  until job.truncated or now() >= deadline

  if not job.find then R.truncated = job.truncated end
  F.apply()

  if job.truncated or #job.stack == 0 then
    if job.find then
      S.find_cache = { dir = job.dir, paths = job.files, lower = job.lower }
    else
      cache_put(job.key, job.files, job.truncated)
    end
    stop_scan()
    if job.truncated then
      set_status(string.format("Stopped after %d samples",
        job.find and C.FIND_MAX_FILES or C.SCAN_MAX_FILES))
    end
  end
  if not job.find then C.try_restore() end   -- the remembered sample may be in
  refresh_panel(job.find and F.pane() or R)
end

-- Fill the samples pane with the samples of `dir`, down to `depth` levels
-- of sub folders (0 = only that folder).
local function show_contents_of(dir, depth, force)
  depth = depth or (prefs.include_subfolders.value and C.SCAN_MAX_DEPTH or 0)
  if not force and same_path(dir, R.dir) and depth == R.depth then return end
  stop_scan()
  C.clear_marks(R)
  R.dir, R.depth = dir, depth
  -- "(+ sub)" only when sub folders are included AND there are some
  R.has_sub = false
  if depth > 0 then
    local subs = list_dir(dir)
    R.has_sub = #subs > 0
  end
  R.sel, R.top = 0, 1
  R.truncated = false
  local key = dir .. "|" .. depth
  local cached = scan_cache[key]
  if cached then
    R.all = cached.files
    R.truncated = cached.truncated
  else
    R.all = {}
    scan_job = {
      dir = dir, key = key, files = R.all, truncated = false,
      max_depth = depth,
      stack = { { path = dir, rel = "", depth = 0 } },
    }
    R.scanning = true
    restart_timer(scan_timer, 15)
  end
  F.apply()
  if #R.entries > 0 then R.sel = 1 end
  if S.focus == R and not S.find then S.focus = L end
  -- a pick for another folder is out of date; a folder with a remembered
  -- sample (per-folder memory) picks it. The sample of the last session
  -- (no `dir`) stays until it is found or the user takes over.
  local w = C.want_sample
  if w and w.dir and not same_path(w.dir, dir) then C.want_sample = nil end
  if (not C.want_sample or C.want_sample.dir) and prefs.folder_memory.value
     and not S.find then
    local m = C.mem[C.mem_key(dir)]
    if m and m.sample then
      C.want_sample = { path = m.sample, off = m.soff, dir = dir }
    end
  end
  C.try_restore()
  refresh_all()
end

-- folder the contents panel should show: highlighted sub folder, else the
-- folder being browsed
local function contents_target()
  local e = L.entries[L.sel]
  if e and e.is_dir and not e.up and not e.here then
    return e.full or join(S.path, e.name)
  end
  return S.path
end

contents_timer = function()
  remove_timer(contents_timer)
  if not dialog_open() or not two_pane() or S.find then return end
  show_contents_of(contents_target())
end

local function schedule_contents(immediate)
  if not two_pane() or S.find then return end
  local depth = prefs.include_subfolders.value and C.SCAN_MAX_DEPTH or 0
  if same_path(contents_target(), R.dir) and depth == R.depth then return end
  if immediate then
    remove_timer(contents_timer)
    show_contents_of(contents_target())
  else
    restart_timer(contents_timer, C.CONTENTS_DELAY_MS)
  end
end


--------------------------------------------------------------------------------
-- Selection + navigation
--------------------------------------------------------------------------------

-- Remembered highlights (see "Reopen with the last ... highlighted" in the
-- options). The last ones are kept in the preferences, so closing the browser
-- or Renoise keeps them; C.mem is the per-folder memory of this session.
C.mem = {}   -- folder -> { lname =, loff = (folders pane), sample =, soff = }

function C.mem_key(p)
  p = norm(p or "")
  return IS_WINDOWS and p:lower() or p
end

function C.mem_entry(dir)
  local k = C.mem_key(dir)
  C.mem[k] = C.mem[k] or {}
  return C.mem[k]
end

-- called whenever the highlight of the folders / samples pane has moved
function C.note_sel(P)
  if P ~= L and P ~= R then return end
  if S.find or S.at_places then return end
  local e = P.entries[P.sel]
  if not e or e.up then return end
  local off = P.sel - P.top              -- rows down the visible list
  local mem = prefs.folder_memory.value
  prefs.last_focus.value = (P == R) and 2 or 1
  if P == L then
    if e.is_dir then
      prefs.last_folder_sel.value = e.here and S.path
                                    or (e.full or join(S.path, e.name))
      prefs.last_folder_off.value = off
    elseif not two_pane() then           -- one list: a sample in it
      prefs.last_sample.value = join(S.path, e.name)
      prefs.last_sample_off.value = off
      prefs.last_folder_sel.value = ""
    end
    if mem and S.path ~= "" then
      local m = C.mem_entry(S.path)
      m.lname = (e.is_dir and not e.here) and e.name or nil
      m.loff = off
    end
  elseif e.full then
    prefs.last_sample.value = e.full
    prefs.last_sample_off.value = off
    if mem and R.dir then
      local m = C.mem_entry(R.dir)
      m.sample, m.soff = e.full, off
    end
  end
end

-- which sub folder open_dir highlights when it was not told: the one of the
-- last session (once), else the one this folder remembers. Returns its name
-- and how many rows down the pane it was.
function C.remembered_folder(path)
  local p = C.start_pick
  if p then
    C.start_pick = nil
    if same_path(p.dir, path) then return p.name or true, p.off end
  end
  if prefs.folder_memory.value then
    local m = C.mem[C.mem_key(path)]
    if m and m.lname then return m.lname, m.loff end
  end
  return nil
end

-- Highlight the sample C.want_sample names, as soon as it is in the list: the
-- samples pane is filled in the background, so this is tried again after every
-- slice of the scan. Quiet: it does not play the sample.
function C.try_restore()
  local w = C.want_sample
  if not w or S.find or not S.vb then return end
  local P = two_pane() and R or L
  if P == R and not R.dir then return end
  local list = P.entries
  if w.list ~= list then w.list, w.upto = list, 0 end   -- another list
  local found
  for i = (w.upto or 0) + 1, #list do
    local e = list[i]
    if not e.is_dir then
      local full = e.full or join(S.path, e.name)
      if same_path(full, w.path) then found = i break end
    end
  end
  if not found then
    w.upto = #list
    if P == L or not R.scanning then C.want_sample = nil end   -- not there
    return
  end
  C.want_sample = nil
  C.set_selection(P, found, false, true)
  P.top = clamp(found - (w.off or 0), 1, max_top(P))
  refresh_panel(P)
  if w.focus and C.panel_visible(P) then C.set_focus(P) end
end

-- Move a panel's highlight. `preview` = allowed to auto-preview;
-- `force` = redraw (and re-preview) even if the index did not change.
local function set_selection(P, i, preview, force)
  local n = #P.entries
  if n == 0 then
    P.sel, P.top = 0, 1
    refresh_panel(P)
    return
  end

  i = clamp(i, 1, n)
  if i == P.sel and not force then return end
  P.sel = i

  if P.sel < P.top then
    P.top = P.sel
  elseif P.sel > P.top + P.rows - 1 then
    P.top = P.sel - P.rows + 1
  end
  P.top = clamp(P.top, 1, max_top(P))
  refresh_panel(P)
  C.note_sel(P)

  if P == L and F.pane() ~= L then
    if S.find and not S.find.typing then F.stop() end
    schedule_contents(false)
  end
  if P == K then
    pcall(function() renoise.song().selected_sample_index = i end)
    K.sig = nil
    if S.focus == K then C.kit_show(i) end
  end
  if S.focus == P then sync_info() end

  if preview then
    release_id("preview")
    local e = P.entries[i]
    if e and not e.is_dir and prefs.autoplay.value
       and not renoise.tool():has_timer(preview_timer) then
      renoise.tool():add_timer(preview_timer, C.PREVIEW_DELAY_MS)
    end
  end
end

C.set_selection = set_selection

-- scroll the view without moving the highlight (mouse wheel / scrollbar)
local function scroll_panel(P, new_top)
  new_top = clamp(new_top, 1, max_top(P))
  if new_top == P.top then return end
  P.top = new_top
  refresh_panel(P)
end

-- Folder paths: the root plus any extra folders added with the folder icon (like a
-- plugin host's search paths). With extra ones, the level above them
-- lists them all ("Folder Paths").
function C.extra_places()
  local out = {}
  for line in (prefs.places.value .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then out[#out + 1] = norm(line) end
  end
  return out
end

function C.places()
  local main = prefs.root_folder.value
  local out = { main ~= "" and norm(main) or (S.root or "") }
  for _, p in ipairs(C.extra_places()) do
    local dup = false
    for _, q in ipairs(out) do if same_path(p, q) then dup = true end end
    if not dup then out[#out + 1] = p end
  end
  return out
end

function C.has_places() return #C.extra_places() > 0 end

-- the place a path lies in (the deepest one, if places are nested)
function C.place_of(path)
  local best
  for _, p in ipairs(C.places()) do
    if p ~= "" and is_within(path, p) and (not best or #p > #best) then
      best = p
    end
  end
  return best
end

function C.save_places(list)
  prefs.places.value = table.concat(list, "\n")
end

function C.add_place()
  local p = renoise.app():prompt_for_path("Add Folder Path")
  if not p or p == "" then return end
  p = norm(p)
  local list = C.extra_places()
  for _, q in ipairs(list) do if same_path(p, q) then return end end
  list[#list + 1] = p
  C.save_places(list)
  set_status("Folder path added: " .. p .. "  ('Left' at the top of one "
             .. "shows them all)")
  if dialog_open() then
    if S.at_places then C.open_places(p)
    else
      local e = L.entries[L.sel]
      C.open_dir(S.path, e and e.is_dir and e.name or nil)  -- shows the way up
    end
  end
end

function C.remove_place(p)
  local list = {}
  for _, q in ipairs(C.extra_places()) do
    if not same_path(p, q) then list[#list + 1] = q end
  end
  C.save_places(list)
  if dialog_open() then
    if S.at_places and C.has_places() then C.open_places()
    elseif S.at_places or is_within(S.path, p) then
      if not C.open_dir(C.places()[1]) then
        C.open_dir(C.nearest_existing(S.root) or S.root)
      end
    else
      C.open_dir(S.path)     -- the way up (..) goes when no paths are left
    end
  end
end

local function open_dir(path, select_name)
  path = norm(path)
  if not dir_exists(path) then
    set_status("Folder not found: " .. path .. "  (folder icon > Rescan "
               .. "folders, once it is back)")
    return false
  end
  if S.find and F.pane() == L then F.drop() end   -- the list is a folder again
  S.path = path
  S.at_places = false
  S.root = C.place_of(path) or S.root
  C.clear_marks(L)
  L.entries = {}
  release_id("preview")

  if not same_path(path, S.root) or C.has_places() then
    L.entries[#L.entries + 1] = { name = "..", is_dir = true, up = true }
  end

  local dirs, files = list_dir(path)
  local split = prefs.show_contents.value
  if split then
    L.entries[#L.entries + 1] = { name = basename(path), is_dir = true,
                                  here = true }
  end
  for _, d in ipairs(dirs) do
    L.entries[#L.entries + 1] = { name = d, is_dir = true }
  end
  if not split then
    for _, f in ipairs(files) do
      L.entries[#L.entries + 1] = { name = f, is_dir = false }
    end
  end

  prefs.last_path.value = path

  local sel, picked, off = 1, false, nil
  local given = select_name ~= nil
  if not given then select_name, off = C.remembered_folder(path) end
  if select_name then
    for i, e in ipairs(L.entries) do
      -- (a name never matches the "this folder" row: it can be named like a
      -- sub folder; `true` asks for that row)
      if e.is_dir and not e.up
         and (select_name == true and e.here
              or select_name ~= true and not e.here
                 and same_path(e.name, select_name)) then
        sel, picked = i, true
        break
      end
    end
  end
  if not given and not picked and L.entries[1] and L.entries[1].up
     and #L.entries > 1 then
    sel = 2   -- skip ".." ("this folder" in two-pane mode)
  end

  S.focus = L
  L.sel, L.top = 0, 1
  if BM.refresh then BM.refresh() end
  set_selection(L, sel, false, true)
  if picked and off then              -- as far down the pane as it was
    L.top = clamp(sel - off, 1, max_top(L))
    refresh_panel(L)
  end
  schedule_contents(true)
  if not two_pane() then C.try_restore() end   -- the one list has the samples
  refresh_all()
  return true
end

C.open_dir = open_dir

-- the list of places (the root and the extra folders)
function C.open_places(select_path)
  if S.find and F.pane() == L then F.drop() end
  release_id("preview")
  S.at_places = true
  L.entries = {}
  local seen = {}
  for _, p in ipairs(C.places()) do
    if p ~= "" then
      local name = basename(p)
      if name == "" then name = p end
      if seen[name] then name = name .. "  (" .. p .. ")" end
      seen[name] = true
      if not dir_exists(p) then name = name .. "  (missing)" end
      L.entries[#L.entries + 1] = { name = name, full = p, is_dir = true,
                                    place = true }
    end
  end
  local sel = 1
  for i, e in ipairs(L.entries) do
    if select_path and same_path(e.full, select_path) then sel = i end
  end
  S.focus = L
  L.sel, L.top = 0, 1
  C.clear_marks(L)
  set_selection(L, sel, false, true)
  schedule_contents(true)
  refresh_all()
end

local function go_up()
  if S.at_places then return end
  if same_path(S.path, S.root) then
    if C.has_places() then C.open_places(S.root) end
    return
  end
  local parent = parent_of(S.path)
  if not parent or same_path(parent, S.path) then return end
  if not is_within(parent, S.root) then parent = S.root end
  open_dir(parent, basename(S.path))
end

local function go_root()
  if not dialog_open() then return end
  local home = C.places()[1]
  if home == "" or not dir_exists(home) then home = S.root end
  if not S.at_places and same_path(S.path, home) then return end
  open_dir(home)
end

local function enter_selected_dir()
  local e = L.entries[L.sel]
  if e and e.is_dir and not e.here then
    if e.up then go_up() else open_dir(e.full or join(S.path, e.name)) end
  end
end

-- is a looping preview sounding? (a loop never ends by itself)
function C.preview_looping()
  local p = S.play
  return S.held["preview"] ~= nil and p ~= nil and p.id == "preview"
         and p.loop_mode ~= nil and p.loop_mode > 1 and p.le > p.ls
end

function C.stop_preview()
  release_id("preview")
  remove_timer(preview_timer)
end

local function play_highlighted()
  local P = S.focus
  if P == K then C.kit_play_row() return end
  local e = P.entries[P.sel]
  if e and e.is_dir and S.loaded_path == nil then return end
  if ensure_selected_loaded() then trigger("preview", C.PREVIEW_NOTE) end
end

-- click on the highlighted sample: play it from the start, or stop it
-- when it is sounding as a loop (a loop never ends by itself)
local function replay()
  if C.preview_looping() then
    C.stop_preview()
  else
    play_highlighted()
  end
end


-- Click on the waveform: play the highlighted sample from that point on.
-- play the preview instrument from a point (a slice marker there, removed
-- again with the next note); `whole` plays it from the start
local function play_scratch_from(frac, whole)
  local smp = scratch_sample()
  if not smp then return end
  local frames = smp.sample_buffer.number_of_frames
  local pos = math.floor(clamp(frac, 0, 1) * frames) + 1
  if pos <= 1 or frames < 64 or pos >= frames - 16 then
    whole()
    return
  end
  release_id("preview")
  clear_preview_slices()
  C.quiet()
  local ok = pcall(function()
    smp:insert_slice_marker(pos)
    S.sliced = true
    local inst = renoise.song():instrument(find_scratch_index())
    local alias = inst:sample(#inst.samples)   -- the slice starting at pos
    trigger("preview", alias.sample_mapping.base_note, nil, pos - 1)
  end)
  if not ok then
    clear_preview_slices()
    whole()
  end
end

local function play_from(frac)
  if not ensure_selected_loaded() then return end
  play_scratch_from(frac, play_highlighted)
end

-- The waveform shows a Multi-Sample row (played there): a click plays that
-- sample from the point. A copy of it goes into the preview instrument, so
-- the instrument itself is never touched; the highlighted file is loaded
-- again when it is needed.
function C.kit_play_from(frac)
  local _, inst = C.kit_index()
  local i = S.wave_kit_row
  local src = inst and i and inst.samples[i]
  if not src then return end
  C.quiet()
  local ok = pcall(function()
    local idx = ensure_scratch()
    release_all()
    clear_preview_slices()
    local smp = renoise.song():instrument(idx):sample(1)
    smp:copy_from(src)
    renoise.song():instrument(idx).name = SCRATCH_NAME
  end)
  if not ok then return end
  S.loaded_path = nil                       -- the preview holds the copy now
  S.keep_kit_wave = true
  play_scratch_from(frac, function()
    trigger("preview", scratch_sample().sample_mapping.base_note)
  end)
  S.keep_kit_wave = false
  C.kit_played("preview", C.kit_row_note(i))
end

--------------------------------------------------------------------------------
-- Editing the preview: trim / cut, loop, crossfade, interpolation
--------------------------------------------------------------------------------
-- Drag on the waveform to select, right-click it to trim, cut, loop or
-- crossfade. Only the copy in the preview instrument changes - never the
-- file. Every change is a step in the file's list (S.ops, see above).
-- Loading that sample (Enter, Shift+Enter, Insert, load + write note)
-- gives it the same loop and interpolation; after a trim, cut or
-- crossfade the edited audio is saved as a new file in the tool's Edits
-- folder and that one is loaded.

C.EDITS_DIR = "Edits"

function C.edits_dir()
  local base = renoise.tool().bundle_path or ""
  return join(base, C.EDITS_DIR)
end

-- A successful API call is not necessarily a successful export: save_as
-- returns false on failure. Check the result and the saved WAV header before
-- a delete/replacement/import is allowed to depend on this file.
function C.verify_audio_file(path, expected)
  local info = probe_file(path)
  if not info or not info.size or info.size <= 44 or not info.frames
     or info.frames ~= expected.frames or info.rate ~= expected.rate
     or info.channels ~= expected.channels or not info.audio_end
     or info.audio_end > info.size then
    error("Audio copy could not be verified: " .. tostring(path), 0)
  end
end

function C.audio_shape(smp)
  local b = smp.sample_buffer
  return { frames = b.number_of_frames, rate = b.sample_rate,
           channels = b.number_of_channels }
end

function C.export_audio(smp, label)
  local dir = C.edits_dir()
  if not dir_exists(dir) then
    local ok, err = pcall(os.mkdir, dir)
    if not ok or not dir_exists(dir) then
      error("Cannot create audio-copy folder: " .. dir .. " " .. tostring(err or ""), 0)
    end
  end
  local path
  repeat
    C.edit_n = (C.edit_n or 0) + 1
    path = join(dir, string.format("%s %d.wav", label, C.edit_n))
  until not io.exists(path)
  local ok, saved = pcall(function() return smp.sample_buffer:save_as(path, "wav") end)
  if not ok or saved ~= true then
    error("Could not save audio copy; operation stopped: " .. path, 0)
  end
  C.verify_audio_file(path, C.audio_shape(smp))
  return path
end

-- the edited copies of an earlier session are not needed any more
function C.clear_edits()
  pcall(function()
    local dir = C.edits_dir()
    if not dir_exists(dir) then return end
    for _, f in ipairs(os.filenames(dir)) do
      -- A failed restore leaves a named recovery copy for manual recovery.
      if not f:match("^recovery ") then os.remove(join(dir, f)) end
    end
  end)
end

-- frame of the preview sample under x (0 .. width)
function C.wave_frame(x)
  local W = S.wave
  local w = S.wave_view and S.wave_view.width or 1
  if not W or W.frames < 2 then return nil end
  return clamp(math.floor(clamp(x, 0, w) / math.max(1, w) * W.frames) + 1,
               1, W.frames)
end

-- the preview sample, if one with audio is shown
function C.preview_smp()
  if S.wave_from_kit then return nil end
  local smp = scratch_sample()
  if smp and smp.sample_buffer.has_sample_data then return smp end
  return nil
end

-- put a sample's loop exactly there (kept inside the sample)
function C.put_loop(smp, mode, ls, le)
  local n = smp.sample_buffer.number_of_frames
  ls = clamp(math.floor(ls), 1, n)
  le = clamp(math.floor(le), ls, n)
  smp.loop_mode = 1
  smp.loop_start = 1
  smp.loop_end = le
  smp.loop_start = ls
  smp.loop_mode = clamp(mode, 1, 4)
end

-- trim to / cut out frames a..b of a sample's audio (the loop moves along)
function C.edit_data(smp, mode, a, b)
  local buf = smp.sample_buffer
  local n, chs = buf.number_of_frames, buf.number_of_channels
  a, b = clamp(a, 1, n), clamp(b, 1, n)
  local keep = (mode == "trim") and { { a, b } } or { { 1, a - 1 }, { b + 1, n } }
  local total = 0
  for _, k in ipairs(keep) do total = total + math.max(0, k[2] - k[1] + 1) end
  if total < 2 then error("nothing would be left", 0) end
  -- where a frame of the old sample ends up
  local function moved(f)
    if mode == "trim" then return clamp(f - a + 1, 1, total) end
    if f < a then return f end
    if f > b then return f - (b - a + 1) end
    return clamp(a, 1, total)
  end
  local data = {}
  for c = 1, chs do
    local t, i = {}, 0
    for _, k in ipairs(keep) do
      for f = k[1], k[2] do i = i + 1 t[i] = buf:sample_data(c, f) end
    end
    data[c] = t
  end
  local rate, bits = buf.sample_rate, buf.bit_depth
  local lm, ls, le = smp.loop_mode, smp.loop_start, smp.loop_end
  local interp = smp.interpolation_mode
  if not buf:create_sample_data(rate, bits, chs, total) then
    error("could not make the new sample", 0)
  end
  buf:prepare_sample_data_changes(false)   -- the preview needs no undo
  for c = 1, chs do
    local t = data[c]
    for f = 1, total do buf:set_sample_data(c, f, t[f]) end
  end
  buf:finalize_sample_data_changes()
  local nls, nle = moved(ls), moved(le)
  C.put_loop(smp, nle > nls and lm or 1, nls, math.max(nls, nle))
  pcall(function() smp.interpolation_mode = interp end)
end

-- equal-power crossfade over `len` frames at the loop (see below)
function C.xfade_data(smp, len)
  local buf = smp.sample_buffer
  local ls, le = smp.loop_start, smp.loop_end
  len = math.min(len, ls - 1, le - ls)
  if len < 2 then error("needs audio before the loop start", 0) end
  local half_pi = math.pi / 2
  local sin, cos = math.sin, math.cos
  buf:prepare_sample_data_changes(false)
  for c = 1, buf.number_of_channels do
    for k = 1, len do
      local t = k / len
      local dst = le - len + k            -- end of the loop, fading out
      local src = ls - len + k - 1        -- before the start, fading in
      buf:set_sample_data(c, dst,
        buf:sample_data(c, dst) * cos(t * half_pi)
        + buf:sample_data(c, src) * sin(t * half_pi))
    end
  end
  buf:finalize_sample_data_changes()
end

-- one step on a sample
function C.apply_op(smp, op)
  if op.t == "loop" then C.put_loop(smp, op.mode, op.s, op.e)
  elseif op.t == "interp" then smp.interpolation_mode = clamp(op.mode, 1, 4)
  elseif op.t == "pitch" then
    smp.transpose = clamp(op.st or 0, -120, 120)
    smp.fine_tune = clamp(op.fine or 0, -127, 127)
  elseif op.t == "pan" then smp.panning = clamp(op.v or 0.5, 0, 1)
  elseif op.t == "synclen" then apply_browser_settings(smp, S.loaded_path)
  elseif op.t == "trim" or op.t == "cut" then C.edit_data(smp, op.t, op.a, op.b)
  elseif op.t == "xfade" then
    if op.ls then C.put_loop(smp, op.mode, op.ls, op.le) end  -- its loop
    C.xfade_data(smp, op.len)
  end
end

-- the loop of a sample as a step
function C.loop_op(smp)
  return { t = "loop", mode = smp.loop_mode, s = smp.loop_start, e = smp.loop_end }
end

-- after the preview changed: waveform, loop popup, details
function C.preview_changed(data)
  S.edit_tmp = nil
  if data then
    S.edited = true
    local smp = scratch_sample()
    if smp then
      apply_browser_settings(smp, S.loaded_path)  -- Beatsync: new length
      compute_wave(smp, S.loaded_path)
    end
  end
  refresh_wave_loop()
  redraw_wave()
  C.show_loop()
  refresh_info_box()
end

-- Record steps just made on the preview (they are already applied).
-- `name` is what Undo / Redo say. A loop or interpolation change right
-- after the same kind of change (holding a key, cycling a popup) merges
-- into it: one undo takes the whole run back.
function C.record(ops, name)
  local path = S.loaded_path
  if not path then return end
  local list = C.ops_of(path, true)
  local top = C.undo_top()
  local one = #ops == 1 and ops[1]
  if one and (one.t == "loop" or one.t == "interp" or one.t == "pitch"
          or one.t == "pan" or one.t == "synclen")
     and top and top.ops
     and #top.ops == 1 and top.ops[1].t == one.t and top.path == path
     and list[#list] == top.ops[1] and #C.U.undone == 0
     and now() - top.t < 1.5 then
    for k, v in pairs(one) do top.ops[1][k] = v end
    top.t = now()
    C.loop_baseline()
    return
  end
  for _, op in ipairs(ops) do list[#list + 1] = op end
  C.loop_baseline()
  C.push_undo {
    name = name, path = path, ops = ops, preview = true,
    undo = function()
      local l = C.ops_of(path, true)
      for i = #ops, 1, -1 do
        if l[#l] ~= ops[i] then error("the steps changed", 0) end
        l[#l] = nil
      end
      C.reload_preview(path)
    end,
    redo = function()
      local l = C.ops_of(path, true)
      for _, op in ipairs(ops) do l[#l + 1] = op end
      local smp = same_path(path, S.loaded_path) and scratch_sample()
      if smp then
        C.quiet()
        local data = false
        for _, op in ipairs(ops) do
          C.apply_op(smp, op)
          data = data or C.DATA_OPS[op.t] ~= nil
        end
        C.preview_changed(data)
        C.loop_baseline()
      end
    end,
  }
end

-- the loop as it was last recorded (or loaded): moving a loop point by
-- dragging or with the keys is recorded once, when it is let go / kept
function C.loop_baseline()
  local smp = C.preview_smp()
  S.loop_seen = smp and C.loop_op(smp) or nil
end
function C.commit_loop(name)
  local smp = C.preview_smp()
  if not smp then return end
  local op = C.loop_op(smp)
  local last = S.loop_seen
  if last and last.mode == op.mode and last.s == op.s and last.e == op.e then
    return
  end
  C.record({ op }, name or "Loop")
end

function C.edit_preview(mode)
  C.quiet()
  local r = S.sel_range
  local smp = C.preview_smp()
  if not r or not smp then
    set_status("Drag across the waveform to select a part first")
    return
  end
  release_all()
  clear_preview_slices()
  local op = { t = mode, a = r[1], b = r[2] }
  local ok, err = pcall(C.apply_op, smp, op)
  if not ok then
    set_status("Edit failed: " .. tostring(err))
    return
  end
  S.sel_range = nil
  C.record({ op }, mode == "trim" and "Trim" or "Cut")
  C.preview_changed(true)
  set_status((mode == "trim" and "Trimmed" or "Cut") .. " the preview copy"
             .. " - loading it now uses this version (the file is untouched)")
end

-- back to the file as it is: all its steps go (one undo brings them back)
function C.undo_edits()
  local p = S.loaded_path
  local list = p and C.ops_of(p)
  if not list or #list == 0 then
    set_status("This sample has no changes")
    return
  end
  local saved = {}
  for i, op in ipairs(list) do saved[i] = op end
  local function clear() S.ops[C.file_key(p)] = {} C.reload_preview(p) end
  clear()
  C.push_undo {
    name = "Back to the file", path = p, preview = true,
    undo = function()
      local l = {}
      for i, op in ipairs(saved) do l[i] = op end
      S.ops[C.file_key(p)] = l
      C.reload_preview(p)
    end,
    redo = clear,
  }
  set_status("Back to the file as it is")
end

-- What to load for `path`: the file, or the edited copy (saved now) after
-- a trim / cut / crossfade; plus the loop and interpolation to give it
-- (nil: the defaults). A file with changes that is not in the preview is
-- put there first, so its steps are replayed.
function C.source_for(path)
  local list = C.ops_of(path)
  local here = same_path(path, S.loaded_path) and not S.wave_from_kit
  if not here and not (list and #list > 0) then return path, false, nil end
  if not here and not load_preview(path) then
    error("Could not prepare the edited sample: " .. basename(path), 0)
  end
  local smp = scratch_sample()
  if not smp then error("The preview sample is no longer available", 0) end
  local props = { loop = C.loop_op(smp), interp = smp.interpolation_mode,
                  pitch = { st = smp.transpose, fine = smp.fine_tune },
                  pan = smp.panning }
  if S.edited then
    if not S.edit_tmp or not io.exists(S.edit_tmp) then
      S.edit_tmp = C.export_audio(smp, "edited")
    end
    C.verify_audio_file(S.edit_tmp, C.audio_shape(smp))
    return S.edit_tmp, true, props
  end
  return path, false, props
end

-- give a loaded sample the loop and interpolation from C.source_for
function C.apply_props(smp, props)
  if not props then return end
  pcall(function()
    local l = props.loop
    if l then C.put_loop(smp, l.mode, l.s, l.e) end
    if props.interp then smp.interpolation_mode = props.interp end
    if props.pitch then
      smp.transpose, smp.fine_tune = props.pitch.st, props.pitch.fine
    end
    if props.pan then smp.panning = props.pan end
  end)
end

-- the Loop popup shows the loop of the sample in the preview
function C.show_loop()
  local smp = C.preview_smp()
  local pop = view("loop")
  if not pop then return end
  local mode = smp and smp.loop_mode or 1
  S.updating_loop = true
  pcall(function()
    if pop.value ~= mode then pop.value = mode end
    pop.active = smp ~= nil
  end)
  S.updating_loop = false
end

-- Loop popup / key bindings: the loop mode of this sample
function C.set_loop_mode(mode)
  C.quiet()
  local smp = C.preview_smp()
  if not smp then
    set_status("Highlight a sample first: the loop belongs to the sample")
    C.show_loop()
    return
  end
  if smp.loop_mode == mode then return end
  pcall(function() smp.loop_mode = clamp(mode, 1, 4) end)
  C.record({ C.loop_op(smp) }, "Loop mode")
  C.preview_changed(false)
end

function C.cycle_loop_mode(delta)
  local smp = C.preview_smp()
  local mode = ((smp and smp.loop_mode or 1) - 1 + delta) % #LOOP_ITEMS + 1
  C.set_loop_mode(mode)
  if smp then set_status("Loop: " .. loop_name(mode)) end
end

-- Interpolation: one setting for every sample the browser plays and loads
function C.set_interp(mode)
  prefs.default_interp.value = clamp(mode, 1, #C.INTERP_ITEMS)
  set_status("Interpolation: " .. C.INTERP_ITEMS[prefs.default_interp.value])
end

-- Semitone / Fine tune: what they belong to. With the Multi-Sample pane
-- focused: that row's sample, in the instrument. Otherwise the sample in the
-- preview (the highlighted file; its steps are kept and given to it when it
-- is loaded). Returns "kit" or "file", the sample, and for "kit" the
-- instrument and row.
function C.pitch_target()
  if S.focus == K and prefs.show_kit.value then
    local idx, inst = C.kit_index()
    local smp = inst and K.sel > 0 and inst.samples[K.sel]
    if smp then return "kit", smp, idx, K.sel end
    return nil
  end
  local smp = C.preview_smp()
  if smp then return "file", smp end
  return nil
end

-- panning as the box shows it: 50 L .. Center .. 50 R
function C.pan_text(v)
  if v == 0 then return "Center" end
  return string.format("%d %s", math.abs(v), v < 0 and "L" or "R")
end

-- what each box edits: its range, how to read and set it on a sample, the
-- step a file keeps (op) and how it is said
C.PITCH_ORDER = { "transpose", "fine_tune", "panning", "synclen" }
function C.sync_zero_text()
  return C.pitch_target() == "kit" and "Off" or "Auto"
end
C.PITCH = {
  transpose = { lo = -120, hi = 120, name = "Semitone", box = "semi",
    get = function(s) return s.transpose end,
    set = function(s, v) s.transpose = v end,
    op = function(s, v) return { t = "pitch", st = v, fine = s.fine_tune } end,
    text = function(v) return v .. " st" end },
  fine_tune = { lo = -127, hi = 127, name = "Fine tune", box = "fine",
    get = function(s) return s.fine_tune end,
    set = function(s, v) s.fine_tune = v end,
    op = function(s, v) return { t = "pitch", st = s.transpose, fine = v } end,
    text = function(v) return tostring(v) end },
  panning = { lo = -50, hi = 50, name = "Panning", box = "pan",
    get = function(s) return math.floor((s.panning - 0.5) * 100 + 0.5) end,
    set = function(s, v) s.panning = clamp(0.5 + v / 100, 0, 1) end,
    op = function(s, v) return { t = "pan", v = clamp(0.5 + v / 100, 0, 1) } end,
    text = function(v) return C.pan_text(v) end },
  synclen = { lo = 0, hi = 512, name = "Sync length", box = "slen",
    get = function(s) return s.beat_sync_enabled and s.beat_sync_lines or 0 end,
    set = function(s, v)
      if v <= 0 then
        s.beat_sync_enabled = false
      else
        s.beat_sync_lines = v
        s.beat_sync_enabled = true
      end
    end,
    op = function(s, v) return { t = "synclen", n = v } end,
    text = function(v) return v == 0 and C.sync_zero_text() or (v .. " lines") end },
}

-- the value a box shows for the sample it belongs to. A file's Sync length
-- is the one set in the box, else the one Beatsync gave it (0: none).
function C.pitch_value(field)
  local kind, smp = C.pitch_target()
  if not smp then return 0 end
  local P = C.PITCH[field]
  if field == "synclen" and kind == "file" then
    local own = C.synclen_of(S.loaded_path)
    if own then return own end
  end
  return P.get(smp)
end

-- the boxes show the sample they belong to (and rest when there is none)
function C.show_pitch()
  local kind, smp = C.pitch_target()
  S.updating_pitch = true
  pcall(function()
    for _, field in ipairs(C.PITCH_ORDER) do
      local P = C.PITCH[field]
      local v = view(P.box)
      if v then
        local val = smp and C.pitch_value(field) or 0
        -- The formatter is set at construction. Refresh zero's wording when
        -- switching between files (Auto) and kit samples (Off).
        if field == "synclen" and val == 0 and S.pitch_kind ~= kind then v.value = 1 end
        if v.value ~= val then v.value = val end
        if v.active ~= (smp ~= nil) then v.active = smp ~= nil end
      end
    end
    local t = view("sync_t")
    local on = smp ~= nil and C.pitch_value("synclen") > 0
    if t and t.active ~= on then t.active = on end
  end)
  S.updating_pitch = false
  S.pitch_kind = kind
end

-- a value as controls mode and the status line say it
function C.pitch_text(field)
  local _, smp = C.pitch_target()
  if not smp then return "highlight a sample first" end
  return C.PITCH[field].text(C.pitch_value(field))
end

-- each change of a Multi-Sample sample is a step of the browser's undo; a
-- run on the same value (holding an arrow) merges into one
function C.kit_pitch_undo(idx, row, field, old, new)
  local P = C.PITCH[field]
  local key = field .. "|" .. idx .. "|" .. row
  local top = C.undo_top()
  if top and top.pitch == key and #C.U.undone == 0 and now() - top.t < 1.5 then
    top.new, top.t = new, now()
    return
  end
  local e = { song = true, pitch = key, old = old, new = new, name = P.name }
  local function put(v)
    local smp = C.inst_at(idx).samples[row]
    if not smp then error("the sample was changed outside the browser", 0) end
    P.set(smp, v)
  end
  e.undo = function() put(e.old) end
  e.redo = function() put(e.new) end
  C.push_undo(e)
end

-- hear it again soon after the last change (when auto-prehear is on)
local pitch_timer
pitch_timer = function()
  remove_timer(pitch_timer)
  if not dialog_open() or not prefs.autoplay.value
     or not prefs.audition_changes.value then return end
  if S.focus == K then C.kit_play_row() return end
  if C.preview_smp() then trigger("preview", C.PREVIEW_NOTE) end
end

function C.set_pitch(field, v)
  local P = C.PITCH[field]
  v = clamp(math.floor(v + 0.5), P.lo, P.hi)
  local kind, smp, idx, row = C.pitch_target()
  if not kind then
    C.show_pitch()
    set_status("Highlight a sample first: this belongs to the sample")
    return
  end
  local old = C.pitch_value(field)
  if old == v then return end
  if kind == "file" then
    C.quiet()
    local op = P.op(smp, v)
    C.record({ op }, P.name)       -- first: Beatsync looks the step up
    C.apply_op(smp, op)
    C.show_pitch()
  else
    C.loud(P.name)
    P.set(smp, v)
    C.kit_pitch_undo(idx, row, field, old, v)
  end
  set_status(string.format("%s: %s", P.name, C.pitch_text(field)))
  restart_timer(pitch_timer, 180)
end

-- Renoise's "T": Semitone and Fine tune so that the sample lasts exactly
-- Sync length lines at the current tempo (played at C-4)
function C.tempo_tune()
  local kind, smp, idx, row = C.pitch_target()
  if not kind then set_status("Highlight a sample first") return end
  local lines = C.pitch_value("synclen")
  if lines <= 0 then
    set_status("Set a Sync length first: the pitch is worked out from it")
    return
  end
  local buf = smp.sample_buffer
  if not buf.has_sample_data then return end
  local secs = buf.number_of_frames / math.max(1, buf.sample_rate)
  local t = renoise.song().transport
  local target = lines * 60 / (t.bpm * t.lpb)
  local semis = 12 * math.log(secs / target) / math.log(2)
  local st = clamp(math.floor(semis + 0.5), -120, 120)
  local fine = clamp(math.floor((semis - st) * 128 + 0.5), -127, 127)
  if st == smp.transpose and fine == smp.fine_tune then
    set_status("Already at that pitch")
    return
  end
  if kind == "file" then
    C.quiet()
    local op = { t = "pitch", st = st, fine = fine }
    C.record({ op }, "Pitch to tempo")
    C.apply_op(smp, op)
    C.show_pitch()
  else
    local old = { st = smp.transpose, fine = smp.fine_tune }
    C.loud("Pitch to tempo")
    smp.transpose, smp.fine_tune = st, fine
    local e = { song = true, name = "Pitch to tempo" }
    local function put(v)
      local s2 = C.inst_at(idx).samples[row]
      if not s2 then error("the sample was changed outside the browser", 0) end
      s2.transpose, s2.fine_tune = v.st, v.fine
    end
    e.undo = function() put(old) end
    e.redo = function() put({ st = st, fine = fine }) end
    C.push_undo(e)
  end
  set_status(string.format("Pitch to tempo: %d st, fine tune %d (%d lines)",
                           st, fine, lines))
  restart_timer(pitch_timer, 180)
end

-- right-click on the waveform
function C.wave_menu()
  local has_sel = S.sel_range ~= nil and not S.wave_from_kit
  local smp = C.preview_smp()
  local items = {
    { name = "Play from selection", active = has_sel, invoke = function()
        local W = S.wave
        if W and S.sel_range then
          play_from((S.sel_range[1] - 1) / W.frames)
        end
      end },
    { name = "Set loop to selection   (Ctrl-Shift-L)", active = has_sel,
      invoke = function() C.loop_to_selection() end },
    { name = (has_sel and "Loop selection and crossfade" or "Crossfade loop"),
      active = C.xfade_possible(),
      invoke = function() C.do_xfade() end },
    { name = "---Trim to selection", active = has_sel,
      invoke = function() C.edit_preview("trim") end },
    { name = "Cut selection", active = has_sel,
      invoke = function() C.edit_preview("cut") end },
  }
  items[#items + 1] = { name = "---Snap loop points to zero crossings",
    selected = prefs.snap_zero.value, invoke = function() C.toggle_snap() end }
  items[#items + 1] = { name = "---Back to the file (undo all changes)",
    active = S.loaded_path ~= nil and #(C.ops_of(S.loaded_path) or {}) > 0,
    invoke = C.undo_edits }
  pcall(function() renoise.app():show_menu(S.dialog, items) end)
end

--------------------------------------------------------------------------------
-- Loop points and loop crossfade
--------------------------------------------------------------------------------
-- Loop points move by keyboard (controls mode) or by dragging their flags
-- on the waveform, snapping to zero crossings (an option). The crossfade
-- is an equal-power blend, inspired by afta8's "xfade pow": the audio before
-- the loop start fades in over the end of the loop, so the jump from the
-- loop end back to its start is seamless.

-- nearest zero crossing to frame f (dir 0: either side, 1 / -1: only
-- that way), within `limit` frames; nil when there is none
function C.zero_near(buf, f, dir, limit)
  local n = buf.number_of_frames
  local chs = math.min(2, buf.number_of_channels)
  local function v(i)
    local t = 0
    for c = 1, chs do t = t + buf:sample_data(c, i) end
    return t
  end
  local function crossing(i)
    if i < 1 or i >= n then return false end
    local a, b = v(i), v(i + 1)
    return a == 0 or (a < 0) ~= (b < 0)
  end
  for d = 0, limit do
    if dir >= 0 and crossing(f + d) then return f + d end
    if dir <= 0 and d > 0 and crossing(f - d) then return f - d end
  end
  return nil
end

-- move a loop point to frame f (kept inside the sample, start before end).
-- A sample without a loop gets one (Forward) - for this sample only.
-- Not recorded yet: see C.commit_loop.
function C.set_loop_point(which, f)
  C.quiet()
  local smp = C.preview_smp()
  if not smp then return end
  local n = smp.sample_buffer.number_of_frames
  pcall(function()
    local mode = smp.loop_mode == 1 and 2 or smp.loop_mode
    local ls, le = smp.loop_start, smp.loop_end
    if smp.loop_mode == 1 then ls, le = 1, n end
    if which == "start" then
      ls = clamp(math.floor(f), 1, math.max(1, le - 1))
    else
      le = clamp(math.floor(f), math.min(n, ls + 1), n)
    end
    C.put_loop(smp, mode, ls, le)
  end)
  C.preview_changed(false)
end

function C.toggle_snap()
  prefs.snap_zero.value = not prefs.snap_zero.value
  set_status("Loop points snap to zero crossings: "
             .. (prefs.snap_zero.value and "on" or "off"))
end

-- the loop from the waveform selection (snapped); returns the step, which
-- is recorded unless `quiet`
function C.loop_to_selection(quiet)
  C.quiet()
  local r, smp = S.sel_range, C.preview_smp()
  if not r or not smp then
    set_status("Drag across the waveform to select a part first")
    return nil
  end
  local buf = smp.sample_buffer
  local a, b = r[1], r[2]
  if prefs.snap_zero.value then
    a = C.zero_near(buf, a, 0, 2000) or a
    b = C.zero_near(buf, b, 0, 2000) or b
  end
  if b <= a then b = math.min(buf.number_of_frames, a + 1) end
  local mode = smp.loop_mode == 1 and 2 or smp.loop_mode
  pcall(C.put_loop, smp, mode, a, b)
  local op = C.loop_op(smp)
  if not quiet then
    C.record({ op }, "Loop to selection")
    C.preview_changed(false)
    set_status("Loop set to the selection (" .. loop_name(op.mode) .. ")")
  end
  return op
end

-- the longest crossfade the loop allows: as much audio as there is before
-- the loop start, and no longer than the loop itself
function C.xfade_max()
  local smp = C.preview_smp()
  if not smp or smp.loop_mode == 1 then return 0 end
  return math.max(0, math.min(smp.loop_start - 1,
                              smp.loop_end - smp.loop_start))
end

-- a crossfade can be made: on the loop, or on the selection (made the loop)
function C.xfade_possible()
  if not C.preview_smp() then return false end
  if S.sel_range and not S.wave_from_kit then return S.sel_range[1] > 2 end
  return C.xfade_max() >= 2
end

-- Crossfade the loop, as long as it can be. With a selection: the
-- selection becomes the loop first (one step to undo for both).
function C.do_xfade()
  C.quiet()
  local smp = C.preview_smp()
  if not smp then
    set_status("Highlight a sample first")
    return
  end
  local ops, before = {}, C.loop_op(smp)
  if S.sel_range and not S.wave_from_kit then
    local op = C.loop_to_selection(true)
    if not op then return end
    ops[1] = op
    S.sel_range = nil
  end
  local len = C.xfade_max()
  if len < 2 then
    if #ops > 0 then pcall(C.put_loop, smp, before.mode, before.s, before.e) end
    C.preview_changed(false)
    set_status(#ops > 0 and "A crossfade needs audio before the loop start"
               or "Nothing to crossfade: select a part of the waveform, or "
                  .. "make a loop with audio before it")
    return
  end
  release_all()
  clear_preview_slices()
  local op = { t = "xfade", len = len, mode = smp.loop_mode,
               ls = smp.loop_start, le = smp.loop_end }
  local ok, err = pcall(C.apply_op, smp, op)
  if not ok then
    if #ops > 0 then pcall(C.put_loop, smp, before.mode, before.s, before.e) end
    C.preview_changed(false)
    set_status("Crossfade failed: " .. tostring(err))
    return
  end
  ops[#ops + 1] = op
  C.record(ops, #ops > 1 and "Loop selection and crossfade" or "Crossfade")
  C.preview_changed(true)
  set_status(string.format("Crossfaded the loop (%s) - loading uses this "
    .. "version, the file is untouched", fmt_length(len,
    smp.sample_buffer.sample_rate) or len .. " frames"))
end

-- Bookmarks 1-8: click goes to the folder, right-click (or Shift+click)
-- saves the current folder there.

function BM.path(i) return prefs["bookmark_" .. i].value end

function BM.refresh()
  for i = 1, 8 do
    local b = view("bm" .. i)
    if b then
      local p = BM.path(i)
      C.tint(b, (p ~= "" and same_path(p, S.path)) and C.LIT or DEFAULT_COLOR)
      -- Renoise's view preset digits: lit when saved, dim when empty
      local icon = (p ~= "" and "Icons/Preset" or "Icons/InactivePreset")
                   .. i .. ".bmp"
      if pcall(function() b.bitmap = icon end) then b.text = "" end
      local gone = p ~= "" and not dir_exists(p)
      b.tooltip = (p ~= "")
        and (p .. (gone and "\n(not found - a drive not connected?)" or "")
             .. "\nClick: go there   Right-click: save the current folder")
        or ("Bookmark " .. i .. " is empty\nRight-click (or Shift-click) "
            .. "saves the current folder")
    end
  end
end

function BM.save(i)
  if not dialog_open() then return end
  prefs["bookmark_" .. i].value = S.path
  BM.refresh()
  set_status(string.format("Bookmark %d: %s", i, S.path))
end

function BM.go(i)
  if not dialog_open() then return end
  local p = BM.path(i)
  if p == "" then
    set_status("Bookmark " .. i .. " is empty - right-click it to save the "
               .. "current folder")
    return
  end
  if not dir_exists(p) then
    set_status("Bookmark " .. i .. " not found: " .. p)
    return
  end
  if not C.place_of(p) then   -- outside every place: browse from there
    S.root = norm(p)
    clear_scan_cache()
    R.dir = nil
  end
  open_dir(p)
end


--------------------------------------------------------------------------------
-- Loading into the song
--------------------------------------------------------------------------------

local function inst_populated(inst)
  if inst.name ~= "" then return true end
  for _, smp in ipairs(inst.samples) do
    if smp.sample_buffer.has_sample_data then return true end
  end
  local ok, plug = pcall(function() return inst.plugin_properties.plugin_loaded end)
  return ok and plug == true
end

local function short_inst_name(i)
  local inst = renoise.song():instrument(i)
  local name = inst.name ~= "" and inst.name or "(empty)"
  return string.format("%02X %s", i - 1, name)
end

-- First free slot after the last used (non-scratch) instrument. Uses that
-- slot when it is empty, otherwise inserts a new instrument there (which
-- keeps the scratch instruments at the end of the list).
-- (`what`: the undo name, given only when inserting one is the change)
local function new_instrument_slot(what)
  local song = renoise.song()
  local last = 0
  for i, inst in ipairs(song.instruments) do
    if not is_scratch(inst) and inst_populated(inst) then last = i end
  end
  local target = last + 1
  local existing = song.instruments[target]
  if existing and not is_scratch(existing) and not inst_populated(existing) then
    return target
  end
  if what then C.loud(what) end
  S.inst_busy = true
  local ok, err = pcall(function() song:insert_instrument_at(target) end)
  S.inst_busy = false
  if not ok then error(err, 0) end
  return target
end

local function select_instrument(i)
  local song = renoise.song()
  song.selected_instrument_index = i
  pcall(function() song.selected_sample_index = 1 end)
end

--------------------------------------------------------------------------------
-- Undo / redo  ('Ctrl'+'Z' / 'Ctrl'+'Y', 'Cmd' on a Mac)
--------------------------------------------------------------------------------
-- One history for what you do in the browser: the controls' settings,
-- changes to samples (loop, interpolation, trim, cut, crossfade) and the
-- Multi-Sample (adding, removing, moving, mapping, naming). While the
-- browser has the keys, Ctrl+Z / Ctrl+Y are always the browser's: with
-- nothing left to undo it says so instead of undoing something in the song.
-- Settings changed in one go (a held key, a dragged slider) are one step.
-- The history ends when the browser closes.

local U = { done = {}, undone = {}, MAX = 300 }
C.U = U
function C.undo_top() return U.done[#U.done] end
function C.push_undo(e)
  if not e.song then C.check_song_history() end
  e.t = now()
  U.done[#U.done + 1] = e
  if #U.done > U.MAX then table.remove(U.done, 1) end
  U.undone = {}
  if e.song then U.guard = C.history_state() end
end
function C.clear_undo()
  U.done, U.undone, U.guard = {}, {}, nil
  for _, watch in pairs(U.watches or {}) do
    pcall(function() watch.obs:remove_notifier(watch.fn) end)
  end
  U.watches = {}
end

-- Keep object identity as well as order: a same-count replacement/reorder
-- must never redirect an old Undo onto a different sample. Buffer events
-- also catch audio replacements which keep the Sample object itself.
function C.history_state()
  U.watches = U.watches or {}
  local state, live = {}, {}
  for idx, inst in ipairs(renoise.song().instruments) do
    if not is_scratch(inst) then
      state[#state + 1] = idx
      state[#state + 1] = inst
      for _, smp in ipairs(inst.samples) do
        live[smp] = true
        local w = U.watches[smp]
        if not w then
          w = { obs = smp.sample_buffer_observable, revision = 0 }
          w.fn = function()
            w.revision = w.revision + 1
            if rawequal(S.wave_sample, smp) then S.kit_wave_dirty = true end
          end
          w.obs:add_notifier(w.fn)
          U.watches[smp] = w
        end
        state[#state + 1] = smp
        state[#state + 1] = w.revision
        local b = smp.sample_buffer
        state[#state + 1] = b.has_sample_data
          and (b.number_of_frames .. ":" .. b.sample_rate .. ":" .. b.number_of_channels) or "empty"
      end
    end
  end
  for smp, w in pairs(U.watches) do
    if not live[smp] then
      pcall(function() w.obs:remove_notifier(w.fn) end)
      U.watches[smp] = nil
    end
  end
  return state
end

function C.drop_song_history()
  local function keep(list)
    local out = {}
    for _, e in ipairs(list) do
      if not (e.song or e.map or e.ov) then out[#out + 1] = e end
    end
    return out
  end
  local before = #U.done + #U.undone
  U.done, U.undone = keep(U.done), keep(U.undone)
  if #U.done + #U.undone < before then
    set_status("Samples changed outside the browser - its song undo starts over")
  end
end

function C.check_song_history()
  local state = C.history_state()
  local same = not U.guard or #state == #U.guard
  if same and U.guard then
    for i, item in ipairs(state) do
      if not rawequal(item, U.guard[i]) then same = false break end
    end
  end
  if not same then C.drop_song_history() end
  U.guard = state
  return same
end

-- Steps on instruments know them by number. When instruments are added,
-- removed or moved outside the browser, those numbers mean other
-- instruments: such steps are dropped rather than undone on the wrong one.
function C.instruments_changed()
  if S.undoing or S.inst_busy or not dialog_open() then return end
  C.check_song_history()
end

local function run_undo(fn, verb)
  if not C.check_song_history() then return end
  local from = fn == "undo" and U.done or U.undone
  local to = fn == "undo" and U.undone or U.done
  local e = table.remove(from)
  if not e then
    set_status("Nothing to " .. verb:lower() .. " in the browser")
    return
  end
  if e.preview then C.quiet() else C.loud(verb .. " " .. e.name) end
  S.undoing = true
  local ok, err = pcall(e[fn], e)
  S.undoing = false
  if ok then
    e.t = -100            -- never merges with what comes next
    to[#to + 1] = e
    set_status(verb .. ": " .. e.name)
  else
    C.drop_song_history()
    set_status("Cannot " .. verb:lower() .. " '" .. e.name .. "': "
               .. tostring(err))
  end
  U.guard = C.history_state()
  if C.after_undo then C.after_undo() end
end
function C.undo() run_undo("undo", "Undo") end
function C.redo() run_undo("redo", "Redo") end

-- Ctrl/Cmd+Z, Ctrl+Y, Ctrl/Cmd+Shift+Z: true when it was one (held: repeats)
function C.undo_key(key, m)
  local lk = tostring(key.name):lower()
  if not (m.control or m.meta) or m.alt or (lk ~= "z" and lk ~= "y") then
    return false
  end
  if lk == "y" or m.shift then C.redo() else C.undo() end
  return true
end

-- A setting watched for undo: `get` / `set` its value; `side` runs after
-- every change (also undo's), e.g. to remap the Multi-Sample.
S.vals = {}
function C.make_watch(key, name, get, set, side)
  return function()
    local new, old = get(), S.vals[key]
    S.vals[key] = new
    if new == old then return end
    if S.silent then return end              -- the browser itself set it
    if not S.undoing and dialog_open() then
      local top = C.undo_top()
      local inst = C.kit_index and C.kit_index() or nil
      if top and top.key == key and #U.undone == 0 and now() - top.t < 1.5
         and top.inst == inst then
        top.after, top.t = new, now()
        S.cur_entry = top
      else
        local e = { key = key, name = name, before = old, after = new,
                    inst = inst }
        e.undo = function(self)
          set(self.before)
          if self.restore then self.restore(self, "before") end
        end
        e.redo = function(self)
          set(self.after)
          if self.restore then self.restore(self, "after") end
        end
        C.push_undo(e)
        S.cur_entry = e
      end
    end
    if side and dialog_open() then
      local ok, err = pcall(side)
      if not ok then set_status(name .. ": " .. tostring(err)) end
    end
    local e = S.cur_entry
    S.cur_entry = nil
    -- changed and changed back in one go: nothing to undo
    if e and e == C.undo_top() and e.before == e.after and not e.map then
      table.remove(U.done)
    end
  end
end
function C.watch(obs, key, name, get, set, side)
  S.vals[key] = get()
  obs:add_notifier(C.make_watch(key, name, get, set, side))
end
function C.watch_pref(pname, name, side)
  local o = prefs[pname]
  C.watch(o, pname, name, function() return o.value end,
          function(v) o.value = v end, side)
end

--------------------------------------------------------------------------------
-- Sample snapshots (to put a removed or replaced sample back)
--------------------------------------------------------------------------------

C.SAMPLE_PROPS = { "name", "volume", "panning", "transpose", "fine_tune",
  "beat_sync_enabled", "beat_sync_lines", "beat_sync_mode",
  "interpolation_mode", "oneshot", "autoseek", "autofade", "new_note_action",
  "mute_group", "modulation_set_index", "device_chain_index",
  "oversample_enabled", "loop_release" }

function C.map_of(smp)
  local m = smp.sample_mapping
  local t = { base = m.base_note, lo = m.note_range[1], hi = m.note_range[2],
              vlo = m.velocity_range[1], vhi = m.velocity_range[2] }
  pcall(function()
    t.layer, t.mvv, t.mkp = m.layer, m.map_velocity_to_volume, m.map_key_to_pitch
  end)
  return t
end
function C.set_map(smp, t)
  local m = smp.sample_mapping
  m.note_range = { t.lo, t.hi }
  m.base_note = t.base
  m.velocity_range = { t.vlo or 0, t.vhi or 127 }
  if t.layer ~= nil then pcall(function() m.layer = t.layer end) end
  if t.mvv ~= nil then pcall(function() m.map_velocity_to_volume = t.mvv end) end
  if t.mkp ~= nil then pcall(function() m.map_key_to_pitch = t.mkp end) end
end
function C.map_sample(smp, lo, hi, base)
  C.set_map(smp, { lo = lo, hi = hi, base = base })
end

-- the keyzones of all samples of an instrument
function C.map_snap(inst)
  local t = {}
  for i, smp in ipairs(inst.samples) do t[i] = C.map_of(smp) end
  return t
end
function C.map_restore(inst, snap)
  if #inst.samples ~= #snap then
    error("the instrument was changed outside the browser", 0)
  end
  for i, smp in ipairs(inst.samples) do pcall(C.set_map, smp, snap[i]) end
end

-- the audio (saved to the Edits folder) and settings of a sample
function C.snap_sample(smp)
  local t = { props = {}, map = C.map_of(smp),
              loop = { smp.loop_mode, smp.loop_start, smp.loop_end },
              had_audio = smp.sample_buffer.has_sample_data }
  for _, k in ipairs(C.SAMPLE_PROPS) do
    pcall(function() t.props[k] = smp[k] end)
  end
  if smp.sample_buffer.has_sample_data then
    t.audio = C.audio_shape(smp)
    t.file = C.export_audio(smp, "backup")
  end
  return t
end
function C.restore_sample(smp, t)
  if t.had_audio and not t.file then error("Audio backup is missing", 0) end
  if t.file then
    C.verify_audio_file(t.file, t.audio)
    local called, ok = pcall(function() return smp.sample_buffer:load_from(t.file) end)
    if not called or ok ~= true or not smp.sample_buffer.has_sample_data then
      local recovery = join(C.edits_dir(), "recovery " .. basename(t.file))
      if not basename(t.file):match("^recovery ") then
        local n = 0
        while io.exists(recovery) do
          n = n + 1
          recovery = join(C.edits_dir(), "recovery " .. n .. " " .. basename(t.file))
        end
        local renamed, result = pcall(os.rename, t.file, recovery)
        if renamed and result then t.file = recovery end
      end
      error("Could not restore audio backup: " .. t.file, 0)
    end
  else
    smp.sample_buffer:delete_sample_data()
  end
  for k, v in pairs(t.props) do pcall(function() smp[k] = v end) end
  if smp.sample_buffer.has_sample_data then
    pcall(C.put_loop, smp, t.loop[1], t.loop[2], t.loop[3])
  end
  pcall(C.set_map, smp, t.map)
end

-- The verified original snapshot remains available if a replacement fails.
-- Roll back both the audio/properties and any automatic instrument rename.
function C.replace_slot(inst, slot, original, load, original_name)
  local ok, err = pcall(load, inst:sample(slot))
  if ok then return end
  local restored, why = pcall(function()
    if original then C.restore_sample(inst:sample(slot), original)
    else inst:delete_sample_at(slot) end
    inst.name = original_name
  end)
  if not restored then
    error(tostring(err) .. "; rollback failed: " .. tostring(why)
      .. (original and original.file and ("; backup kept at " .. original.file) or ""), 0)
  end
  error(tostring(err) .. " (original restored)", 0)
end

-- instrument `idx`, if it still has `count` samples (else it was changed
-- outside the browser, and an undo step on it would do the wrong thing)
function C.inst_at(idx, count)
  local inst = renoise.song().instruments[idx]
  if not inst or (count and #inst.samples ~= count) then
    error("the instrument was changed outside the browser", 0)
  end
  return inst
end

--------------------------------------------------------------------------------
-- Loading samples (each one an undo step)
--------------------------------------------------------------------------------

-- Enter (Multi-Sample panel closed): load as a new instrument
local function load_as_new_instrument(path)
  release_all()
  local ok, err = pcall(function()
    local song = renoise.song()
    local count, prev = #song.instruments, song.selected_instrument_index
    local src, _, props = C.source_for(path)    -- (may prehear it first)
    C.loud("Load " .. basename(path))
    local idx = new_instrument_slot()
    local inserted = #song.instruments > count
    local function load()
      local inst = song:instrument(idx)
      if #inst.samples == 0 then inst:insert_sample_at(1) end
      local smp = inst:sample(1)
      load_file_into_sample(smp, src)
      C.apply_props(smp, props)
      apply_browser_settings(smp, path)
      smp.name = stem(path)
      inst.name = stem(path)
      select_instrument(idx)
    end
    load()
    C.push_undo { song = true,
      name = "Load " .. basename(path),
      undo = function()
        local inst = C.inst_at(idx, 1)
        if inserted then song:delete_instrument_at(idx)
        else inst:clear() end
        song.selected_instrument_index = clamp(prev, 1, #song.instruments)
      end,
      redo = function()
        if inserted then song:insert_instrument_at(idx) end
        load()
      end,
    }
    set_status(string.format("Loaded %s as instrument %02X",
                             basename(path), idx - 1))
  end)
  if not ok then set_status("Load failed: " .. tostring(err)) end
  return ok
end

-- The name an instrument gets when sample `slot` (named `old_sample`) is
-- replaced by `new`. Only names the browser or Renoise made are renamed; a
-- name you chose stays:
--   ""                                  -> the new name
--   the replaced sample's name (slot 1) -> the new name (Renoise and the
--                                          browser name a one sample
--                                          instrument after its sample)
--   "Distribute: <sample 1> +N"         -> "Distribute: <new> +N" (also Layer)
--   anything else (e.g. "Drumkit: ...") -> kept
function C.replaced_inst_name(name, old_sample, slot, new)
  name = name or ""
  if name == "" then return new end
  if slot ~= 1 or not old_sample or old_sample == "" then return name end
  -- compared without case and without an audio extension: "Kick.wav" = "kick"
  local function bare(s)
    return (s:lower():gsub("%.(%w+)$", function(x)
      if C.AUDIO_EXTENSIONS[x] then return "" end
    end))
  end
  if bare(name) == bare(old_sample) then return new end
  local body, count = name:match("^Distribute: (.-)( %+%d+)$")
  if body and bare(body) == bare(old_sample) then
    return "Distribute: " .. new .. count
  end
  body, count = name:match("^Layer: (.-)( %+%d+)$")
  if body and bare(body) == bare(old_sample) then
    return "Layer: " .. new .. count
  end
  return name
end

-- set an instrument's name; the Multi-Sample panel, when it shows that
-- instrument, is told so it does not take the new name for another instrument
function C.set_inst_name(idx, inst, name)
  if inst.name ~= name then inst.name = name end
  if K.idx == idx then K.inst_name = name end
end

-- Shift+Enter: replace the selected sample slot of the selected instrument.
-- Keyzone, envelopes etc. of that slot are kept, only the audio is swapped.
-- The instrument is renamed after the new sample unless you named it (see
-- C.replaced_inst_name).
local function load_into_selected(path)
  release_all()
  local ok, err = pcall(function()
    local song = renoise.song()
    local src, _, props = C.source_for(path)    -- (may prehear it first)
    local idx = song.selected_instrument_index
    local inst = song.selected_instrument
    if is_scratch(inst) then error("select a real instrument first", 0) end
    if C.kit_sliced(inst) then
      error("Replace sliced samples in Renoise's sample editor", 0)
    end
    C.loud("Replace sample with " .. basename(path))
    local fresh = #inst.samples == 0
    if fresh then inst:insert_sample_at(1) end
    local slot = clamp(song.selected_sample_index, 1, #inst.samples)
    local smp = inst:sample(slot)
    local old = (not fresh) and C.snap_sample(smp) or nil
    local old_name = inst.name
    -- the new name is decided once, from the names before anything loads
    -- (loading may rename things), and set again after every load
    local final_name = C.replaced_inst_name(old_name,
      (not fresh) and smp.name or nil, slot, stem(path))
    local function load(s)
      local keep = C.map_of(s)
      load_file_into_sample(s, src)
      C.apply_props(s, props)
      apply_browser_settings(s, path)
      pcall(C.set_map, s, keep)
      s.name = stem(path)
    end
    C.replace_slot(inst, slot, old, load, old_name)
    C.set_inst_name(idx, inst, final_name)
    local count = #inst.samples
    C.push_undo { song = true,
      name = "Replace sample " .. slot .. " with " .. basename(path),
      undo = function()
        local i = C.inst_at(idx, count)
        if old then
          if old.file then C.verify_audio_file(old.file, old.audio) end
          local current = C.snap_sample(i:sample(slot))
          C.replace_slot(i, slot, current,
            function(s) C.restore_sample(s, old) end, i.name)
        else i:delete_sample_at(slot) end
        C.set_inst_name(idx, i, old_name)
      end,
      redo = function()
        local i = C.inst_at(idx, old and count or count - 1)
        if not old then i:insert_sample_at(slot) end
        C.replace_slot(i, slot, old, load, old_name)
        C.set_inst_name(idx, i, final_name)
      end,
    }
    set_status(string.format("Replaced %s, sample %d with %s",
      short_inst_name(idx), slot, basename(path)))
  end)
  if not ok then set_status("Load failed: " .. tostring(err)) end
end

-- Alt+Up/Down: step through instruments, skipping the scratch ones
local function step_instrument(delta)
  local song = renoise.song()
  local i = song.selected_instrument_index
  local n = #song.instruments
  repeat
    i = i + delta
  until i < 1 or i > n or not is_scratch(song:instrument(i))
  if i >= 1 and i <= n then song.selected_instrument_index = i end
end

local function step_sample_slot(delta)
  local song = renoise.song()
  local inst = song.selected_instrument
  if #inst.samples == 0 then return end
  song.selected_sample_index =
    clamp(song.selected_sample_index + delta, 1, #inst.samples)
end


--------------------------------------------------------------------------------
-- Multi-Sample: the selected instrument, built and edited sample by sample
--------------------------------------------------------------------------------
-- The panel shows Renoise's selected instrument and follows it: select
-- another instrument in Renoise (or with Alt+Up/Down) to work on that one.
-- Its rows are the instrument's samples, the highlight is Renoise's
-- selected sample. With the panel open, 'Enter' (or 'Insert') adds the
-- highlighted sample to it as its own keyzone, mapped like Renoise's
-- keyzone buttons: Drumkit, Distribute or Layer. 'New' starts another
-- instrument. Keyzones made by hand are left alone until the mode (or its
-- start note / white keys) is changed.

local apply_layout  -- forward declaration

S.kit_lit = {}     -- key id -> { row indices }

-- the instrument the panel edits (nil while a preview instrument is
-- selected)
function C.kit_index()
  local song = renoise.song()
  local i = song.selected_instrument_index
  local inst = song.instruments[i]
  if not inst or is_scratch(inst) then return nil end
  return i, inst
end

function C.kit_sliced(inst)
  local s1 = inst.samples[1]
  return s1 ~= nil and #s1.slice_markers > 0
end

-- what the mapping of the instrument looks like: a mode, or nil when its
-- keyzones were made by hand
function C.kit_infer(inst)
  local n = #inst.samples
  if n == 0 then return prefs.kit_mode.value, nil end
  local single, full, tiles, expect, low = true, true, true, 0, 119
  for _, smp in ipairs(inst.samples) do
    local r = smp.sample_mapping.note_range
    if r[1] ~= r[2] then single = false end
    if r[1] ~= 0 or r[2] ~= 119 then full = false end
    if r[1] ~= expect then tiles = false end
    expect = r[2] + 1
    low = math.min(low, r[1])
  end
  tiles = tiles and expect == 120
  if n == 1 and full then return prefs.kit_mode.value, nil end  -- any mode
  if full then return KIT_LAYERS, nil end
  if single then return KIT_DRUM, low end
  if tiles then return KIT_DIST, nil end
  return nil, nil
end

-- the panel's rows from the selected instrument; cheap when nothing
-- changed (called on idle, see idle_watch)
function K.sync(force)
  local idx, inst = C.kit_index()
  local song = renoise.song()
  local sig = "-"
  if idx then
    local parts = { idx, inst.name, song.selected_sample_index }
    for _, smp in ipairs(inst.samples) do
      local r = smp.sample_mapping.note_range
      parts[#parts + 1] = smp.name .. "|" .. r[1] .. "|" .. r[2]
    end
    sig = table.concat(parts, "\n")
  end
  if sig == K.sig and not force then return end
  local new_inst = idx ~= K.idx or (inst and inst.name ~= K.inst_name)
  if idx ~= K.idx then                  -- settings of another instrument:
    local top = C.undo_top()            -- never merge with the last change
    if top then top.t = -100 end
  end
  K.sig, K.idx, K.inst_name = sig, idx, inst and inst.name
  K.entries = {}
  if idx then
    for i, smp in ipairs(inst.samples) do
      K.entries[i] = { name = smp.name ~= "" and smp.name
                              or string.format("Sample %02X", i - 1),
                       is_dir = false, slot = i }
    end
  end
  local n = #K.entries
  K.sel = n > 0 and clamp(song.selected_sample_index, 1, n) or 0
  if n == 0 and S.focus == K then       -- nothing left to select there
    S.focus = (two_pane() and #R.entries > 0) and R or L
    S.focus_moved = true
  end
  if K.sel > 0 then
    if K.sel < K.top then K.top = K.sel
    elseif K.sel > K.top + K.rows - 1 then K.top = K.sel - K.rows + 1 end
  end
  K.top = clamp(K.top, 1, math.max(1, n - K.rows + 1))
  if new_inst and inst then          -- show how this instrument is mapped
    local mode, start = C.kit_infer(inst)
    K.custom = mode == nil
    S.silent = true
    if mode then prefs.kit_mode.value = mode end
    if start then prefs.kit_start.value = start end
    pcall(function()
      prefs.overlap.value = clamp(inst.sample_mapping_overlap_mode + 1, 1, 3)
    end)
    S.silent = false
    if C.kit_controls_active then C.kit_controls_active() end
  end
  if S.focus_moved then
    S.focus_moved = nil
    if S.vb then refresh_all() end
    pcall(sync_info)
  end
  if S.vb then refresh_panel(K) end
end

-- the next free key of a Drumkit
function C.kit_next_key(inst)
  local top = -1
  for _, smp in ipairs(inst.samples) do
    top = math.max(top, smp.sample_mapping.note_range[2])
  end
  local n = top < 0 and kit_note(1) or top + 1
  if prefs.white_keys.value then
    while n <= 119 and not C.WHITE_KEY[n % 12] do n = n + 1 end
  end
  return n
end

-- free sample slots left (Drumkit: keys left)
function C.kit_room()
  local _, inst = C.kit_index()
  if prefs.kit_mode.value ~= KIT_DRUM then
    return math.max(0, 120 - (inst and #inst.samples or 0))
  end
  local n, c = inst and C.kit_next_key(inst) or kit_note(1), 0
  while n <= 119 do
    c = c + 1
    n = n + 1
    if prefs.white_keys.value then
      while n <= 119 and not C.WHITE_KEY[n % 12] do n = n + 1 end
    end
  end
  return c
end

-- a name for an instrument the browser built, unless you gave it one
function C.kit_auto_name(inst, first_path)
  local name = inst.name
  local s1 = inst.samples[1]
  local auto = name == "" or (s1 and name == s1.name)
    or name:match("^Drumkit: ") or name:match("^Drum Kit: ")
    or name:match("^Distribute: ")
    or name:match("^Layer: ")
  if not auto or not s1 then return end
  local n = #inst.samples
  if n == 1 then inst.name = s1.name return end
  local mode = prefs.kit_mode.value
  if mode == KIT_DRUM then
    local old = name:match("^Drumkit: (.*)$") or name:match("^Drum Kit: (.*)$")
    local dir = first_path and parent_of(first_path)
    inst.name = "Drumkit: " .. (old or (dir and basename(dir)) or s1.name)
  else
    inst.name = (mode == KIT_DIST and "Distribute: " or "Layer: ") .. s1.name
                .. " +" .. (n - 1)
  end
end

-- Map every sample by the mode, in row order (the mode, its start note or
-- white keys changed). Joins the undo step of that change.
function C.kit_remap()
  local idx, inst = C.kit_index()
  if not inst or #inst.samples == 0 or S.undoing then return end
  if C.kit_sliced(inst) then return end
  local before, name_before = C.map_snap(inst), inst.name
  C.loud("Map the Multi-Sample")
  local mode, n, left = prefs.kit_mode.value, #inst.samples, 0
  for i, smp in ipairs(inst.samples) do
    pcall(function()
      if mode == KIT_DRUM then
        local note = kit_note(i)
        if note <= 119 then C.map_sample(smp, note, note, note)
        else left = left + 1 end
      elseif mode == KIT_DIST then
        local lo, hi = dist_range(i, n)
        C.map_sample(smp, lo, hi, lo)
      else
        C.map_sample(smp, 0, 119, 48)
      end
    end)
  end
  C.kit_auto_name(inst)
  K.custom = false
  local e = S.cur_entry
  if e then
    e.map = e.map or { idx = idx, before = before, name_before = name_before }
    e.map.after, e.map.name_after = C.map_snap(inst), inst.name
    e.restore = function(self, which)
      local i = C.inst_at(self.map.idx)
      C.map_restore(i, self.map[which])
      i.name = self.map["name_" .. which]
      renoise.song().selected_instrument_index = self.map.idx   -- show it
      K.idx = nil                       -- the panel reads its mapping again
    end
  end
  if left > 0 then
    set_status(left .. " samples have no key left above the start note")
  end
  K.sync(true)
end

-- Add files to the Multi-Sample (a new instrument if a preview one is
-- selected). Returns how many were added.
function C.kit_add_paths(paths)
  if #paths == 0 then return 0 end
  K.sync(true)                          -- the instrument selected right now
  local song = renoise.song()
  -- what to load for each file first (an edited one is prehear-loaded to
  -- save its copy), so the song changes below are one undo step
  local sources = {}
  local prepared, why = pcall(function()
    for i, path in ipairs(paths) do
      local src, _, props = C.source_for(path)
      sources[i] = { src = src, props = props }
    end
  end)
  if not prepared then set_status("Import stopped: " .. tostring(why)) return 0 end
  local idx, inst = C.kit_index()
  if inst and C.kit_sliced(inst) then
    set_status("This instrument is sliced - add samples to it in Renoise")
    return 0
  end
  C.loud(#paths == 1 and ("Add " .. basename(paths[1]))
         or ("Add " .. #paths .. " samples"))
  local made, count0 = false, #song.instruments
  if not idx then
    idx = new_instrument_slot()
    select_instrument(idx)
    inst, made = song:instrument(idx), true
  end
  local inserted = made and #song.instruments > count0
  release_all()
  local n0, before, name0 = #inst.samples, C.map_snap(inst), inst.name
  local mode, custom = prefs.kit_mode.value, K.custom
  -- a sample loaded the usual way (on all keys) becomes the kit's first key
  if mode == KIT_DRUM and not custom and n0 == 1 then
    local m = C.map_of(inst.samples[1])
    if m.lo == 0 and m.hi == 119 then
      local note = kit_note(1)
      pcall(C.map_sample, inst.samples[1], note, note, note)
    end
  end
  local loaded, failed, full = {}, 0, false
  for i, path in ipairs(paths) do
    local note
    if mode == KIT_DRUM or custom then
      note = C.kit_next_key(inst)
      if note > 119 then
        if not custom then full = true break end
        note = nil                        -- by hand: on all keys
      end
    end
    local src, props = sources[i].src, sources[i].props
    local smp = inst:insert_sample_at(#inst.samples + 1)
    smp = inst:sample(#inst.samples)
    if pcall(load_file_into_sample, smp, src) then
      C.apply_props(smp, props)
      apply_browser_settings(smp, path)
      smp.name = stem(path)
      if note then pcall(C.map_sample, smp, note, note, note)
      else pcall(C.map_sample, smp, 0, 119, 48) end
      loaded[#loaded + 1] = { path = path, src = src, props = props }
    else
      inst:delete_sample_at(#inst.samples)
      failed = failed + 1
    end
  end
  if mode == KIT_DIST and not custom then
    local n = #inst.samples
    for i, smp in ipairs(inst.samples) do
      local lo, hi = dist_range(i, n)
      pcall(C.map_sample, smp, lo, hi, lo)
    end
  end
  pcall(function()
    inst.sample_mapping_overlap_mode = clamp(prefs.overlap.value, 1, 3) - 1
  end)
  C.kit_auto_name(inst, loaded[1] and loaded[1].path)
  local n1 = #inst.samples
  if #loaded == 0 then                    -- nothing could be read: undo it
    pcall(C.map_restore, inst, before)
    inst.name = name0
    if inserted and #inst.samples == 0 then
      S.inst_busy = true
      local ok = pcall(function() song:delete_instrument_at(idx) end)
      S.inst_busy = false
      if not ok then inst.name = name0 end
    end
  end
  if #loaded > 0 then
    pcall(function() song.selected_sample_index = n1 end)
    local after, name1 = C.map_snap(inst), inst.name
    C.push_undo { song = true,
      name = #loaded == 1 and ("Add " .. basename(loaded[1].path))
             or ("Add " .. #loaded .. " samples"),
      undo = function()
        local i = C.inst_at(idx, n1)
        for k = n1, n0 + 1, -1 do i:delete_sample_at(k) end
        C.map_restore(i, before)
        i.name = name0
        if inserted and #i.samples == 0 then song:delete_instrument_at(idx)
        else select_instrument(idx) end
      end,
      redo = function()
        if inserted then song:insert_instrument_at(idx) end
        local i = C.inst_at(idx, n0)
        local ok, why = pcall(function()
          for _, l in ipairs(loaded) do
            i:insert_sample_at(#i.samples + 1)
            local smp = i:sample(#i.samples)
            load_file_into_sample(smp, l.src)
            C.apply_props(smp, l.props)
            apply_browser_settings(smp, l.path)
            smp.name = stem(l.path)
          end
        end)
        if not ok then
          for k = #i.samples, n0 + 1, -1 do i:delete_sample_at(k) end
          if inserted then song:delete_instrument_at(idx)
          else C.map_restore(i, before); i.name = name0 end
          error(why, 0)
        end
        C.map_restore(i, after)
        i.name = name1
        select_instrument(idx)
      end,
    }
  end
  if not prefs.show_kit.value then
    prefs.show_kit.value = true
    if not (C.reopen_window and C.reopen_window()) then apply_layout() end
  end
  K.sync(true)
  if full then
    set_status("No keys left above the start note - "
               .. #loaded .. " added"
               .. (failed > 0 and (", " .. failed .. " could not be read") or "")
               .. " (change 'from' or the mode)")
  elseif failed > 0 then
    set_status(string.format("Added %d, %d could not be read", #loaded, failed))
  end
  return #loaded, failed, full
end

-- the highlighted sample (or Shift selection, or folder) into the
-- Multi-Sample; 'Enter' with the panel open, 'Insert' always
local function add_highlighted_to_kit()
  if not dialog_open() then return end
  local P = S.focus
  if P == K then return end
  local e = P.entries[P.sel]
  if not e then return end
  local paths, what = {}, nil
  local sel = C.marked_files(P)
  if #sel > 1 then                      -- a Shift selection
    for _, m in ipairs(sel) do paths[#paths + 1] = entry_path(P, m) end
    what = #sel .. " selected samples"
  elseif e.is_dir then
    if e.up then return end
    local dir = e.here and S.path or e.full or join(S.path, e.name)
    paths = C.folder_samples(dir, C.kit_room())
    what = "the samples of " .. e.name
  else
    paths = { entry_path(P, e) }
  end
  local added, failed, full = C.kit_add_paths(paths)
  local _, inst = C.kit_index()
  if added > 0 and inst and not full and (failed or 0) == 0 then
    local where = ""
    if added == 1 and prefs.kit_mode.value == KIT_DRUM and not K.custom then
      local smp = inst.samples[#inst.samples]
      where = " on " .. note_name(smp.sample_mapping.note_range[1])
    end
    set_status(string.format("Added %s to %s%s (%d samples)",
      what or basename(paths[1]), short_inst_name(K.idx or 1), where,
      #inst.samples))
  end
  if added > 0 and prefs.insert_advance.value and not e.is_dir and #sel <= 1 then
    set_selection(P, P.sel + 1, true)
  end
end

-- the first samples of a folder (sub folders too when the samples pane
-- shows them), as many as there is room for
function C.folder_samples(dir, limit)
  local out = {}
  local deep = prefs.include_subfolders.value
  local function walk(d, depth)
    if #out >= limit then return end
    local dirs, files = list_dir(d)
    for _, f in ipairs(files) do
      if #out >= limit then return end
      out[#out + 1] = join(d, f)
    end
    if deep and depth < C.SCAN_MAX_DEPTH then
      for _, sub in ipairs(dirs) do walk(join(d, sub), depth + 1) end
    end
  end
  walk(dir, 0)
  return out
end

-- remove samples (row numbers) from the Multi-Sample instrument
function C.kit_remove(rows, name)
  local idx, inst = C.kit_index()
  if not inst or #rows == 0 then return end
  if C.kit_sliced(inst) then
    set_status("This instrument is sliced - remove its samples in Renoise")
    return
  end
  C.loud(name)
  release_all()
  table.sort(rows)
  local n0 = #inst.samples
  local snaps, done = {}, 0
  -- Preflight every backup before deleting the first sample.
  local saved, why = pcall(function()
    for k, r in ipairs(rows) do snaps[k] = C.snap_sample(inst:sample(r)) end
  end)
  if not saved then set_status("Remove stopped: " .. tostring(why)) return end
  for k = #rows, 1, -1 do
    local r = rows[k]
    local ok = pcall(function()
      inst:delete_sample_at(r)
    end)
    if not ok then
      for j = 1, k do snaps[j] = nil end
      break
    end
    done = done + 1
  end
  if done < #rows then          -- only what was removed can come back
    local kept_rows, kept_snaps = {}, {}
    for k = 1, #rows do
      if snaps[k] then
        kept_rows[#kept_rows + 1] = rows[k]
        kept_snaps[#kept_snaps + 1] = snaps[k]
      end
    end
    rows, snaps = kept_rows, kept_snaps
    if #rows == 0 then set_status("Could not remove the sample") return end
  end
  local n1 = #inst.samples
  C.push_undo { song = true,
    name = name,
    undo = function()
      local i = C.inst_at(idx, n1)
      for _, snap in ipairs(snaps) do
        if snap.file then C.verify_audio_file(snap.file, snap.audio) end
      end
      local inserted = {}
      local ok, err = pcall(function()
        for k, r in ipairs(rows) do
          i:insert_sample_at(r)
          inserted[#inserted + 1] = r
          C.restore_sample(i:sample(r), snaps[k])
        end
      end)
      if not ok then
        for k = #inserted, 1, -1 do i:delete_sample_at(inserted[k]) end
        error(err, 0)
      end
      select_instrument(idx)
    end,
    redo = function()
      local i = C.inst_at(idx, n0)
      for k = #rows, 1, -1 do i:delete_sample_at(rows[k]) end
      select_instrument(idx)
    end,
  }
  K.sync(true)
  sync_info()
  set_status(name .. " - Ctrl-Z puts " .. (#rows == 1 and "it" or "them")
             .. " back")
end

local function kit_remove_selected()
  K.sync(true)
  if K.sel == 0 or not K.entries[K.sel] then return end
  C.kit_remove({ K.sel }, "Remove " .. K.entries[K.sel].name)
end

local function kit_clear()
  local _, inst = C.kit_index()
  local rows = {}
  for i = 1, inst and #inst.samples or 0 do rows[i] = i end
  C.kit_remove(rows, "Remove all samples")
end

-- move the highlighted sample up / down; the keys stay in row order
local function kit_move(delta)
  local idx, inst = C.kit_index()
  local i, j = K.sel, K.sel + delta
  if not inst or i < 1 or j < 1 or j > #inst.samples then return end
  local function swap()
    local ins = C.inst_at(idx)
    local mi, mj = C.map_of(ins:sample(i)), C.map_of(ins:sample(j))
    ins:swap_samples_at(i, j)
    pcall(C.set_map, ins:sample(i), mi)
    pcall(C.set_map, ins:sample(j), mj)
  end
  C.loud("Move sample")
  local ok, err = pcall(swap)
  if not ok then set_status("Cannot move: " .. tostring(err)) return end
  renoise.song().selected_sample_index = j
  C.push_undo { song = true,
    name = "Move " .. (K.entries[i] and K.entries[i].name or "sample"),
    undo = function() swap() renoise.song().selected_sample_index = i end,
    redo = function() swap() renoise.song().selected_sample_index = j end,
  }
  K.sync(true)
end

-- 'New': an empty instrument to build the next Multi-Sample in
function C.kit_new()
  if not dialog_open() then return end
  local song = renoise.song()
  local prev, count = song.selected_instrument_index, #song.instruments
  local idx = new_instrument_slot("New instrument")
  local inserted = #song.instruments > count
  select_instrument(idx)
  if inserted then
    C.push_undo { song = true,
      name = "New instrument",
      undo = function()
        C.inst_at(idx, 0)
        song:delete_instrument_at(idx)
        song.selected_instrument_index = clamp(prev, 1, #song.instruments)
      end,
      redo = function()
        song:insert_instrument_at(idx)
        select_instrument(idx)
      end,
    }
  end
  if not prefs.show_kit.value then
    prefs.show_kit.value = true
    if not (C.reopen_window and C.reopen_window()) then apply_layout() end
  end
  K.sync(true)
  set_status(string.format("Instrument %02X is empty - 'Enter' adds the "
    .. "highlighted sample to it", idx - 1))
end

-- the instrument name field
function C.kit_rename(v)
  local idx, inst = C.kit_index()
  if not inst or inst.name == v then return end
  local old = inst.name
  C.loud("Instrument name")
  inst.name = v
  K.inst_name = v
  C.push_undo { song = true,
    name = "Instrument name",
    undo = function() C.inst_at(idx).name = old end,
    redo = function() C.inst_at(idx).name = v end,
  }
end

-- the key that plays row i (its lowest key, or its base note if in range)
function C.kit_row_note(i)
  local _, inst = C.kit_index()
  local smp = inst and inst.samples[i]
  if not smp then return C.PREVIEW_NOTE end
  local m = C.map_of(smp)
  return clamp(m.base, m.lo, m.hi)
end

-- rows of the Multi-Sample that play `note`
function C.kit_hits(note)
  local out = {}
  local _, inst = C.kit_index()
  if not inst then return out end
  for i, smp in ipairs(inst.samples) do
    local r = smp.sample_mapping.note_range
    if note >= r[1] and note <= r[2] then out[#out + 1] = i end
  end
  return out
end

function C.kit_glowing(idx)
  for _, rows in pairs(S.kit_lit) do
    for _, i in ipairs(rows) do if i == idx then return true end end
  end
  return false
end

-- waveform and details of Multi-Sample row i
function C.kit_show(i)
  local _, inst = C.kit_index()
  local smp = inst and inst.samples[i]
  if not smp then return end
  pcall(function()
    local buf = smp.sample_buffer
    if not U.watches or not U.watches[smp] then C.history_state() end
    if not buf.has_sample_data then
      S.wave, S.wave_sample, S.wave_instrument = nil, smp, inst
      S.kit_wave_dirty, S.wave_from_kit, S.wave_kit_row = false, true, i
      redraw_wave()
      S.info_path, S.info = "kit:" .. i .. ":empty", {}
      refresh_info_box()
      return
    end
    local key = "kit:" .. i .. ":" .. tostring(buf.number_of_frames)
    -- Cache the actual sample/instrument and invalidate on buffer changes.
    -- Repeated notes can reuse it, even with long stereo samples.
    if not (S.wave_from_kit and S.wave and S.wave.path == key
       and rawequal(S.wave_sample, smp) and rawequal(S.wave_instrument, inst)
       and S.wave.rate == buf.sample_rate and S.wave.channels == buf.number_of_channels
       and not S.kit_wave_dirty) then compute_wave(smp, key) end
    S.wave_sample, S.wave_instrument, S.kit_wave_dirty = smp, inst, false
    if S.wave then
      S.wave.loop_mode, S.wave.loop_start, S.wave.loop_end =
        smp.loop_mode, smp.loop_start, smp.loop_end
    end
    S.wave_from_kit = true
    S.wave_kit_row = i
    redraw_wave()
    S.info_path = key
    S.info = {
      format = "Sample", bits = buf.bit_depth, rate = buf.sample_rate,
      channels = buf.number_of_channels, frames = buf.number_of_frames,
      loop = smp.loop_mode > 1 and { mode = smp.loop_mode } or nil,
      interp = smp.interpolation_mode,
    }
    refresh_info_box()
  end)
  return smp
end

-- a key played the Multi-Sample: light its rows, show its waveform
function C.kit_played(id, note)
  local hits = C.kit_hits(note)
  S.kit_lit[id] = hits
  refresh_panel(K)
  local show = hits[1]
  for _, i in ipairs(hits) do if i == K.sel then show = i end end
  local smp = show and C.kit_show(show)
  if smp then start_playhead(id, note, nil, smp) end
end

-- the key was let go
function C.kit_released(id)
  if S.kit_lit[id] then
    S.kit_lit[id] = nil
    refresh_panel(K)
  end
end

-- play Multi-Sample row i (highlight, click, 'Enter')
function C.kit_play_row(i)
  local idx = C.kit_index()
  i = i or K.sel
  if not idx or not K.entries[i] then return end
  release_id("preview")
  local note = C.kit_row_note(i)
  trigger("preview", note, idx)
  C.kit_played("preview", note)
end

--------------------------------------------------------------------------------
-- Focus between panels
--------------------------------------------------------------------------------

local function panel_visible(P)
  if P == L then return true end
  if P == R then return two_pane() end
  return prefs.show_kit.value
end
C.panel_visible = panel_visible

local function set_focus(P)
  if not panel_visible(P) then return end
  if S.ctl_mode then
    S.focus = P
    C.leave_ctl_mode()
    return
  end
  if S.focus == P then return end
  S.focus = P
  refresh_all()
  sync_info()
  if P == K and K.sel > 0 then C.kit_show(K.sel) end
end
C.set_focus = set_focus

local ORDER = { L, R, K }

-- Keyboard focus on a control (a "stop"): see S.stops in build_ui
function C.stop_visible(st)
  if not prefs.show_controls.value and (C.cell_of_stop(st.id) or C.KIT_BOTTOM_STOPS[st.id]) then return false end
  if st.when and not st.when() then return false end
  local v = view(st.id)
  if not v then return false end
  local ok, vis = pcall(function() return v.visible end)
  return not ok or vis ~= false
end


-- light the focused control up, or back to normal. Controls that cannot
-- be coloured (popups, value boxes ...) sit in a frame (C.framed) that is
-- always there and only drawn while focused, so nothing ever moves.
function C.paint_stop(st, on)
  if not st then return end
  if st.id == "xfade_btn" then redraw_wave() end   -- shows what it fades
  if st.frame then
    local g = view(st.frame)
    if g then
      S.lit_frame = on and st.frame or (S.lit_frame ~= st.frame and S.lit_frame or nil)
      pcall(function() g:update() end)
      return
    end
  end
  local v = view(st.id)
  if v and st.act then                      -- a button: its own colour
    C.tint(v, on and C.FOCUS or C.button_rest(st.id))
  end
end

-- the current value of a control, as text ("" for buttons)
function C.stop_value(st)
  local v = view(st.id)
  local out = ""
  pcall(function()
    if st.show then out = st.show()
    elseif st.id == "kit_start" then out = note_name(prefs.kit_start.value)
    elseif st.id == "octave" then out = tostring(renoise.song().transport.octave)
    elseif st.id == "prehear_vol" then
      out = string.format("%d%%", math.floor(prefs.prehear_volume.value * 100 + 0.5))
    elseif st.id == "kit_white" then out = prefs.white_keys.value and "on" or "off"
    elseif v and v.items then out = v.items[v.value] end
  end)
  return out
end

function C.ctl_status(st, how)
  st = st or S.ctl
  if not st then return end
  local val = C.stop_value(st)
  if not how then
    if S.ctl_edit then
      how = (C.vertical(st) and "'Up' / 'Down'" or "'Left' / 'Right'")
            .. " change it, 'Enter' keeps it, 'Esc' puts it back"
    elseif st.get then
      how = "'Enter' to change it"
    else
      how = "'Enter' to press it"
    end
  end
  set_status(st.name .. (val ~= "" and (": " .. val) or "")
             .. (how ~= "" and ("  -  " .. how) or ""))
end

-- which arrows change a value: the ones that match its shape. A popup
-- opens downwards: 'Up' / 'Down'. Value boxes (with their arrows), the
-- volume bar and the mode switch lie across: 'Left' / 'Right'.
function C.vertical(st) return st.n ~= nil and not st.across end

-- one step of a value control: popups wrap round, numbers stop at the ends
function C.value_step(st, dir)
  if st.step then st.step(dir) return end
  local v = st.get()
  if st.n then
    v = (v - 1 + dir) % st.n + 1
  else
    v = clamp(v + dir * (st.delta or 1), st.min, st.max)
  end
  st.set(v)
end

-- key bindings for the controls: the same actions as in controls mode
function C.ctl_do(id, dir)
  if not dialog_open() then
    set_status("Open the Simple Browser first")
    return
  end
  for _, st in ipairs(S.stops or {}) do
    if st.id == id then
      if st.when and not st.when() then
        set_status((id == "kit_start" or id == "kit_white")
                   and ("'" .. st.name .. "' applies to Drumkit only")
                   or (st.name .. " is not available now"))
        return
      end
      local said = S.said
      if dir and st.get then C.value_step(st, dir)
      elseif st.act then st.act() end
      if S.said == said then C.ctl_status(st, "") end
      return
    end
  end
end

-- the controls that can be reached now, in reading order
function C.visible_stops()
  local out = {}
  for _, st in ipairs(S.stops or {}) do
    if C.stop_visible(st) then out[#out + 1] = st end
  end
  -- the sample panel's controls go row by row as the layout has them
  local panel, first = {}, nil
  for i, st in ipairs(out) do
    if C.cell_of_stop(st.id) then
      first = first or i
      panel[#panel + 1] = st
    end
  end
  if #panel > 1 then
    local g = C.geo()
    local pos = {}
    for _, st in ipairs(panel) do
      local x, y = C.cell_xy(st.id, g)
      pos[st] = { y = y or 0, x = x or 0 }
    end
    table.sort(panel, function(a, b)
      if pos[a].y ~= pos[b].y then return pos[a].y < pos[b].y end
      return pos[a].x < pos[b].x
    end)
    for k, st in ipairs(panel) do out[first + k - 1] = st end
  end
  return out
end

local function focus_stop(st)
  local old = S.ctl
  S.ctl = st                                   -- first: the waveform asks
  if old then C.paint_stop(old, false) end
  C.paint_stop(st, true)
  C.ctl_status()
end

function C.blur_ctl()
  if not S.ctl then return end
  C.paint_stop(S.ctl, false)
  S.ctl = nil
  if BM.states then BM.states() end   -- buttons back to their lit state
end

-- Caps Lock: into controls mode, on the control used last
function C.enter_ctl_mode()
  local list = C.visible_stops()
  if #list == 0 then return end
  local st = S.ctl_last
  if not (st and C.stop_visible(st)) then
    st = list[1]
    for _, x in ipairs(list) do if x.id == "loop" then st = x end end
  end
  S.ctl_mode = true
  refresh_all()                -- the lists show where browsing goes on
  focus_stop(st)
end

-- Caps Lock again (or a click into a list): back to browsing, where it was
-- A value being changed when something else happens: kept (leaving
-- controls mode, 'Tab', a rebuilt window) or put back ('Esc', 'Ctrl'+'Z').
function C.end_edit(keep)
  local st, edit = S.ctl, S.ctl_edit
  if not (st and edit) then return end
  S.ctl_edit = nil
  if not keep and st.set then pcall(st.set, edit.orig) end
  C.paint_stop(st, true)
end

function C.leave_ctl_mode()
  if not S.ctl_mode then return end
  C.end_edit(true)                             -- the value stays
  S.ctl_last = S.ctl
  S.ctl_mode = false
  C.blur_ctl()
  refresh_all()
  sync_info()
  set_status("Browsing")
end

function C.toggle_ctl_mode()
  if not dialog_open() then return end
  pcall(function() if S.dialog.focused == false then S.dialog:show() end end)
  if S.ctl_mode then C.leave_ctl_mode() else C.enter_ctl_mode() end
end

-- Tab / Shift+Tab: the next / previous list that has something in it
local function switch_focus(backwards)
  local cur = 1
  for i, P in ipairs(ORDER) do if P == S.focus then cur = i end end
  for step = 1, #ORDER - 1 do
    local i = backwards and (cur - step - 1) % #ORDER + 1
                         or (cur + step - 1) % #ORDER + 1
    local P = ORDER[i]
    if panel_visible(P) and #P.entries > 0 then
      set_focus(P)
      return
    end
  end
end

-- 'Tab' / 'Shift'+'Tab' in controls mode: the next / previous control in
-- reading order (S.stops), round and round. A value being changed is kept.
function C.ctl_tab(backwards)
  local list = C.visible_stops()
  if #list == 0 then return end
  -- reading order as laid out now: the browser column, then the
  -- Multi-Sample's; each top to bottom, left to right
  local g, pos = C.geo(), {}
  for _, st in ipairs(list) do
    local x, y = C.stop_xy(st)
    pos[st] = { col = x < g.kx - 2 and 1 or 2, y = y, x = x }
  end
  table.sort(list, function(a, b)
    local p, q = pos[a], pos[b]
    if p.col ~= q.col then return p.col < q.col end
    if math.abs(p.y - q.y) >= 12 then return p.y < q.y end
    return p.x < q.x
  end)
  C.end_edit(true)
  local cur = 0
  for i, x in ipairs(list) do if x == S.ctl then cur = i end end
  local i
  if cur == 0 then i = backwards and #list or 1
  else i = (cur - 1 + (backwards and -1 or 1)) % #list + 1 end
  focus_stop(list[i])
end

-- keys in controls mode; returns true when used
function C.ctl_key(name)
  local st = S.ctl
  if not st then return false end
  local edit = S.ctl_edit
  if edit then                                 -- changing a value
    local v = C.vertical(st)
    if (v and (name == "up" or name == "down"))
       or (not v and (name == "left" or name == "right")) then
      C.value_step(st, (name == "down" or name == "right") and 1 or -1)
    elseif name == "left" or name == "right" or name == "up"
           or name == "down" then
      return true                              -- the other arrows: nothing
    elseif name == "return" or name == "enter" then
      S.ctl_edit = nil                         -- keep it
    elseif name == "esc" then
      st.set(edit.orig)                        -- put it back
      S.ctl_edit = nil
    else
      return false
    end
    C.paint_stop(st, true)
    C.ctl_status()
    return true
  end
  if name == "left" or name == "right" or name == "up" or name == "down" then
    -- the control that way (round the window: see C.neighbour)
    local pick = C.neighbour(st, name)
    if pick then focus_stop(pick) else C.ctl_status() end
  elseif name == "return" or name == "enter" then
    if st.get then
      S.ctl_edit = { orig = st.get() }
      C.paint_stop(st, true)
      C.ctl_status()
    elseif st.act then
      local said = S.said
      st.act()
      if S.ctl then
        C.paint_stop(S.ctl, true)
        -- what it did, when it says so; else the control and its value
        if S.said == said then C.ctl_status(S.ctl, "") end
      end
    end
  else
    return false
  end
  return true
end

-- 'Enter' (replace: 'Shift'+'Enter') on the highlighted row
local function activate(replace)
  local P = S.focus
  if P == K then
    if not replace then C.kit_play_row() end
    return
  end
  local e = P.entries[P.sel]
  if not e then return end
  if e.is_dir then
    if replace then return end
    if e.here then
      if #R.entries > 0 then set_focus(R) end
    else
      enter_selected_dir()
    end
    return
  end
  if replace then
    load_into_selected(entry_path(P, e))
  elseif prefs.show_kit.value then       -- building a Multi-Sample
    add_highlighted_to_kit()
  else
    local sel = C.marked_files(P)
    if #sel > 1 then
      for _, m in ipairs(sel) do load_as_new_instrument(entry_path(P, m)) end
      set_status(string.format("Loaded %d samples as new instruments", #sel))
    else
      load_as_new_instrument(entry_path(P, e))
    end
  end
end

-- the selected (marked) files of a panel, in list order
function C.marked_files(P)
  local out = {}
  if not P.marked then return out end
  for _, e in ipairs(P.entries) do
    if P.marked[e] and not e.is_dir then out[#out + 1] = e end
  end
  return out
end

-- Shift+click / Shift+Up/Down: select from the anchor row to `idx`
function C.mark_range(P, idx)
  P.marked = {}
  local a = P.anchor or P.sel
  if a < 1 then a = idx end
  for i = math.min(a, idx), math.max(a, idx) do
    local e = P.entries[i]
    if e and not e.is_dir then P.marked[e] = true end
  end
end

function C.clear_marks(P)
  P.marked, P.anchor = nil, nil
end

local function on_row_click(P, row)
  local idx = P.top + row - 1
  local e = P.entries[idx]
  if not e then return end
  C.want_sample = nil
  set_focus(P)
  local shift = false
  pcall(function() shift = renoise.app().key_modifier_flags.shift end)
  if shift and P ~= K and not e.is_dir then
    C.mark_range(P, idx)
    set_selection(P, idx, false, true)
    set_status(#C.marked_files(P) .. " samples selected - 'Enter' loads them, "
               .. "'Insert' adds them to the Multi-Sample")
    return
  end
  if P.marked then C.clear_marks(P) end
  P.anchor = idx
  -- a quick second click on the same sample: load it, as 'Enter' does (a
  -- slow one plays it again, as a single click does)
  local last = S.last_click
  local t = now()
  S.last_click = { P = P, e = e, t = t }
  if last and last.P == P and last.e == e and P ~= K and not e.is_dir
     and t - last.t < C.DOUBLE_CLICK_S and idx == P.sel then
    S.last_click = nil                    -- a third click starts afresh
    remove_timer(preview_timer)
    activate(false)
    return
  end
  if idx == P.sel then
    if e.is_dir then activate(false) else replay() end
  else
    set_selection(P, idx, true)
  end
end

local function choose_root()
  release_all()
  local p = renoise.app():prompt_for_path("Choose sample root folder")
  if p and p ~= "" then
    p = norm(p)
    prefs.root_folder.value = p
    S.missing = nil
    if not dialog_open() then return end   -- used next time it opens
    S.root = p
    clear_scan_cache()
    R.dir = nil
    open_dir(p)
  end
end


-- 'Right' in the folders pane: into the samples of the highlighted folder
-- (or open it when it has none)
local function enter_samples()
  local e = L.entries[L.sel]
  if not S.find then
    remove_timer(contents_timer)
    show_contents_of(contents_target())
  end
  if #R.entries > 0 or R.scanning then
    set_focus(R)
    if #R.entries > 0 then set_selection(R, math.max(R.sel, 1), true, true) end
  elseif e and e.is_dir and not e.here and not e.up then
    enter_selected_dir()
  end
end

function C.has_subfolders(dir)
  local dirs = list_dir(dir)
  return #dirs > 0
end

-- path a row stands for (folder rows: that folder)
local function row_path(P, e)
  if e.full then return e.full end
  if e.up then return parent_of(S.path) end
  if e.here then return S.path end
  return join(S.path, e.name)
end

local function reveal(P, e)
  if not e then return end
  local path = row_path(P, e)
  local folder = e.is_dir and path or parent_of(path)
  pcall(function() renoise.app():open_path(folder) end)
end

local function reveal_highlighted()
  if dialog_open() then reveal(S.focus, S.focus.entries[S.focus.sel]) end
end

-- right-click on a row
-- right-click press: focus that pane and highlight the row
function C.row_pick(P, row)
  local idx = P.top + row - 1
  if not P.entries[idx] then return end
  set_focus(P)
  if P.sel ~= idx then set_selection(P, idx, false, true) end
end

local function row_menu(P, row)
  local idx = P.top + row - 1
  local e = P.entries[idx]
  if not e then return end
  C.row_pick(P, row)
  if P == K then
    pcall(function() renoise.app():show_menu(S.dialog, {
      { name = "Play", invoke = function() C.kit_play_row(idx) end },
      { name = "Write note at cursor", invoke = function() C.load_to_pattern() end },
      { name = "---Move up   (Shift-Up)", active = idx > 1,
        invoke = function() kit_move(-1) end },
      { name = "Move down   (Shift-Down)", active = idx < #K.entries,
        invoke = function() kit_move(1) end },
      { name = "---Remove sample   (Del)", invoke = kit_remove_selected },
    }) end)
    return
  end
  local path = row_path(P, e)
  local items = {}
  local sel = C.marked_files(P)
  if #sel > 1 and P.marked[e] then          -- right-click on a selection
    items[#items + 1] = { name = "Load " .. #sel .. " samples as new "
      .. "instruments", invoke = function() activate(false) end }
    items[#items + 1] = { name = "Load " .. #sel .. " + write notes at cursor",
      invoke = function() C.load_to_pattern() end }
    items[#items + 1] = { name = "Add " .. #sel .. " to Multi-Sample ("
      .. C.kit_room() .. ")", invoke = add_highlighted_to_kit }
  elseif not e.is_dir then
    items[#items + 1] = { name = "Load as new instrument",
      invoke = function() load_as_new_instrument(path) end }
    items[#items + 1] = { name = "Load + write note at cursor",
      invoke = function() C.load_to_pattern() end }
    items[#items + 1] = { name = "Replace selected sample",
      invoke = function() load_into_selected(path) end }
    items[#items + 1] = { name = "---Add to Multi-Sample (" .. C.kit_room() .. ")",
      invoke = add_highlighted_to_kit }
  elseif not e.up then
    items[#items + 1] = { name = "Add contents to Multi-Sample ("
      .. C.kit_room() .. ")", invoke = add_highlighted_to_kit }
  end
  if e.place then
    if not same_path(e.full, C.places()[1]) then
      items[#items + 1] = { name = "---Remove folder path",
        invoke = function() C.remove_place(e.full) end }
    end
  elseif P ~= K and not e.up and not e.here then
    items[#items + 1] = { name = "---Hide from browser",
      invoke = function() C.hide(path) end }
  end
  -- leaves the tool, so it comes last
  items[#items + 1] = { name = (#items > 0 and "---" or "") .. "Show in "
    .. C.FILE_BROWSER, invoke = function() reveal(P, e) end }
  pcall(function() renoise.app():show_menu(S.dialog, items) end)
end

function C.after_hidden_change()
  clear_scan_cache()
  R.dir = nil
  if dialog_open() then
    local e = L.entries[L.sel]
    if S.at_places then C.open_places(e and e.full)
    else open_dir(S.path, e and e.name or nil) end
  end
end

function C.hide(path)
  C.hidden[C.hide_key(path)] = norm(path)
  C.save_hidden()
  set_status("Hidden: " .. path .. "  (folder icon > Hidden items brings it back)")
  C.after_hidden_change()
end

function C.unhide(path)
  C.hidden[C.hide_key(path)] = nil
  C.save_hidden()
  C.after_hidden_change()
end

function C.unhide_all()
  C.hidden = {}
  C.save_hidden()
  C.after_hidden_change()
end

-- the nearest folder of `path` that is there (nil: none - e.g. a drive
-- that is not connected)
function C.nearest_existing(path)
  local p = norm(path or "")
  while p ~= "" do
    if dir_exists(p) then return p end
    local up = parent_of(p)
    if not up or same_path(up, p) then return nil end
    p = up
  end
  return nil
end

-- Rescan: read the folders again (and look for a missing root again)
function C.rescan()
  clear_scan_cache()
  R.dir = nil
  local root = norm(prefs.root_folder.value)
  if S.missing and dir_exists(S.missing) then        -- it is back
    S.missing = nil
    S.root = root
    open_dir(root)
    set_status("Found the root folder again: " .. root)
    return
  end
  if S.at_places then C.open_places()
  else open_dir(C.nearest_existing(S.path) or S.root) end
  set_status("Folders read again" .. (S.missing and (" - still missing: "
             .. S.missing) or ""))
end

-- The folder icon at the start of the folder pane's header: where browsing
-- starts and which folders it sees. A menu for the mouse, a list window
-- for the keyboard - the same entries.
function C.folder_rows()
  local rows = {
    { label = "Root home", action = true, set = function() go_root() end },
    { label = "Set root folder...", action = true, set = choose_root },
    { label = "Add folder path...", sep = true, action = true,
      set = function() C.add_place() end },
  }
  local paths = C.extra_places()
  if #paths > 0 then
    rows[#rows + 1] = { label = "Remove folder path", menu = function()
      local items = {}
      for _, p in ipairs(paths) do
        items[#items + 1] = { name = C.menu_name(p),
                              invoke = function() C.remove_place(p) end }
      end
      return items
    end }
  end
  local list = {}
  for _, p in pairs(C.hidden) do list[#list + 1] = p end
  table.sort(list)
  if #list > 0 then
    rows[#rows + 1] = { label = "Hidden items", menu = function()
      local items = { { name = "Show all again",
                        invoke = function() C.unhide_all() end } }
      for i, p in ipairs(list) do
        items[#items + 1] = { name = (i == 1 and "---" or "") .. C.menu_name(p),
                              invoke = function() C.unhide(p) end }
      end
      return items
    end }
  end
  rows[#rows + 1] = { label = "Rescan folders", sep = true, action = true,
                      set = function() C.rescan() end }
  rows[#rows + 1] = { label = "Show in " .. C.FILE_BROWSER, action = true,
    set = function()
      pcall(function() renoise.app():open_path(S.at_places and S.root or S.path) end)
    end }
  return rows
end

-- the folder icon, clicked: the same entries as a menu under it
function C.folder_menu()
  local items = {}
  for _, r in ipairs(C.folder_rows()) do
    local sep = (r.sep and #items > 0) and "---" or ""
    if r.menu then
      for i, it in ipairs(r.menu()) do
        items[#items + 1] = { name = (i == 1 and sep or "") .. r.label .. ":"
                                     .. it.name:gsub("^%-%-%-", ""),
                              invoke = it.invoke }
      end
    else
      items[#items + 1] = { name = sep .. r.label, invoke = r.set }
    end
  end
  pcall(function() renoise.app():show_menu(S.dialog, items, view("folder_btn")) end)
end

-- the folder icon, by keyboard (controls mode)
function C.folder_dialog()
  C.later(function() C.list_dialog("Folders", C.folder_rows) end)
end

-- Find ("type to find"): letters go into the search while it is typing.
-- What you type shows in the header of the pane the results fill.
function F.start()
  if not dialog_open() then return end
  -- started from Renoise (key binding): the typing has to reach the browser
  pcall(function() if S.dialog.focused == false then S.dialog:show() end end)
  local P = F.pane()
  if S.find then                  -- already searching: keep typing / refine
    S.find.typing = true
    refresh_panel(P)
    return
  end
  local scope = prefs.find_root.value and S.root or S.path
  release_id("preview")
  stop_scan()
  remove_timer(contents_timer)
  local cache = S.find_cache and same_path(S.find_cache.dir, scope)
                and S.find_cache
  S.find = { query = "", typing = true, dir = scope,
             paths = cache and cache.paths or {},
             lower = cache and cache.lower or {},
             back = { sel = L.sel, top = L.top } }   -- the list to return to
  if P == R then R.dir, R.depth = scope, -1 end
  P.sel, P.top = 0, 1
  if P == L then C.clear_marks(L) end
  if not cache then
    scan_job = { dir = scope, find = true, files = S.find.paths,
                 lower = S.find.lower,
                 truncated = false, max_depth = C.SCAN_MAX_DEPTH,
                 stack = { { path = scope, rel = "", depth = 0 } } }
    R.scanning = true
    restart_timer(scan_timer, 30)   -- leaves Renoise room to breathe
  end
  F.apply(true)
  refresh_all()
  if BM.states then BM.states() end
end

-- forget the search (no redraw)
function F.drop()
  remove_timer(F.retype)
  remove_timer(F.timer)
  if scan_job and scan_job.find then stop_scan() end
  S.find = nil
  L.truncated, R.truncated = false, false
  if BM.states then BM.states() end
end

function F.stop()
  if not S.find then return end
  local P, back = F.pane(), S.find.back
  F.drop()
  if P == L then                 -- the list shows its folder again
    open_dir(S.path)
    if back and back.sel >= 1 and back.sel <= #L.entries then
      L.top = clamp(back.top, 1, max_top(L))
      set_selection(L, back.sel, false, true)
    end
  else
    R.dir = nil
    apply_layout()   -- back to the highlighted folder's samples
  end
end

function F.commit()
  local P = F.pane()
  S.find.typing = false
  if renoise.tool():has_timer(F.retype) then   -- search the final text now
    remove_timer(F.retype)
    F.apply(true)
  end
  if #P.entries > 0 then
    -- into the results: this is the one key that also ends controls mode
    if S.ctl_mode then C.leave_ctl_mode() end
    set_focus(P)
    set_selection(P, 1, true, true)
  end
  refresh_panel(P)
end

-- the spyglass: start a search, refine a finished one, or end one
function C.find_click()
  if S.find and not S.find.typing then F.start()   -- refine
  elseif S.find then F.stop()
  else F.start() end
end

-- returns true when the key was used by the search field
function F.key(key, m)
  local name = key.name
  if name == "esc" then F.stop() return true end
  if name == "return" or name == "enter" or name == "up" or name == "down" then
    F.commit()
    return true
  end
  if name == "back" then
    local chars = utf8_chars(S.find.query)
    table.remove(chars)
    S.find.query = table.concat(chars)
  else
    local ch = key.character
    if not ch or ch == "" or m.control or m.alt or m.meta
       or ch:find("[%z\1-\31\127]")
       or table.concat(utf8_chars(ch)) ~= ch then
      return false
    end
    S.find.query = S.find.query .. ch
  end
  -- show the text right away, search once typing pauses
  restart_timer(F.retype, 120)
  refresh_panel(F.pane())
  return true
end


--------------------------------------------------------------------------------
-- Layout (panels shown / hidden)
--------------------------------------------------------------------------------
-- The window, two panes (single pane: one list, the same rows narrower):
--
--   [1..8 bookmarks]                       [Options] [Help]  [panes] [Multi]
--   [folder][  path             ][n/m]  [find][  samples      ][n/m]
--   [ list                          ]   [ list                        ]
--   [ waveform                                                         ]
--   [ Loop  snap  crossfade         |  Interp                          ]  one
--   [ prehear          |  Octave         |  Sync                       ] panel
--   format: ...  (details)
--
-- Single pane: the same, narrower. The Multi-Sample panel sits on the
-- right with its own three-column grid under its list.

local function spacing()
  return renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
end

-- outer width of the folder (+ samples) panes (each list frame adds 2 px)
function C.left_width()
  local w = PANEL_WIDTH + 2
  if two_pane() then w = w + spacing() + PANEL_WIDTH + 2 end
  return w
end

-- the right edge everything above and below the lists lines up with: the
-- last list's (its scrollbar column hangs outside)
function C.edge()
  return C.left_width() - SCROLLBAR_WIDTH
end

C.BM_W, C.BM_SP = 18, 2            -- bookmark squares (Renoise's preset digits)
C.OPT_W, C.HELP_W = 56, 56         -- the Options / Help buttons (equal)
-- The sample panel under the waveform. One pane: two columns, five rows.
-- Left: level and time (Volume, Panning, Loop + crossfade, and Renoise's
-- two Beatsync rows: [on] [length in lines] [T], and the mode). Right:
-- pitch, then the end of the sampler (Octave, Semitone, Fine tune,
-- Interpolation) and the last stage, Output.
--   Volume [spk][vol]   Octave
--   Panning [C]         Semitone [0 st]
--   Loop [Fwd][x]       Fine tune [0]
--   Beatsync [ ][16][T] Interpolation
--   Mode [Repitch]      Output
-- Two panes (more room across, so two rows fewer):
--   Volume   Octave     Beatsync [ ][16][T]  Interpolation
--   Panning  Semitone   Mode                 Output
--   Loop     Fine tune
-- Labels start flush on the left in a column of their own, the controls
-- start flush after it; every control block is the same width (C.CW). Every
-- width is fixed, so it looks the same anywhere.
C.LAYOUT = {
  one = { { "prehear", "oct" }, { "pan", "semi" }, { "loop", "fine" },
          { "sync", "interp" }, { "mode", "output" } },
}
-- two panes: four columns, three rows (the Multi-Sample list is two rows
-- shorter to match): level and loop, pitch, Beatsync, the sampler's end
C.LAYOUT.two = {
  { "prehear", "oct", "sync", "interp" },
  { "pan", "semi", "mode", "output" },
  { "loop", "fine" },
}
C.LABELS = { prehear = "Volume", oct = "Octave", output = "Output",
             loop = "Loop", interp = "Interpolation", sync = "Beatsync",
             semi = "Semitone", fine = "Fine tune", pan = "Panning",
             mode = "Mode" }
C.LABEL_PX = { prehear = 50, oct = 50, output = 50, loop = 36, interp = 78,
               sync = 58, semi = 50, fine = 58, pan = 52, mode = 36 }
C.MODE_ITEMS = { "Repitch", "Percussion", "Texture" }   -- Beatsync's modes
C.OUTPUT_ITEMS = { "Master", "Track" }     -- where the prehear plays
C.ROW_H = C.ROW_HEIGHT + 4                 -- a row of framed controls

function C.grid_rows() return C.LAYOUT[two_pane() and "two" or "one"] end

-- the label column of column c: as wide as its widest label
function C.label_w(c)
  local w = 0
  for _, row in ipairs(C.grid_rows()) do
    if row[c] then w = math.max(w, C.LABEL_PX[row[c]]) end
  end
  return w
end

-- every control block (2 px round each control included): what the
-- single pane leaves after its two label columns, in two equal halves
function C.label_max(rows, c)
  local w = 0
  for _, row in ipairs(rows) do
    if row[c] then w = math.max(w, C.LABEL_PX[row[c]]) end
  end
  return w
end
C.CW = math.floor((PANEL_WIDTH + 2 - SCROLLBAR_WIDTH - 2
                   - (C.label_max(C.LAYOUT.one, 1) + 4)
                   - (C.label_max(C.LAYOUT.one, 2) + 4)) / 2)
local CW = C.CW
-- the controls of a cell, after its label: { view id, width (2 px round) }
C.CELL_ITEMS = {
  prehear = { { "speaker", 28 }, { "prehear_vol", CW - 28 } },
  loop = { { "loop", CW - 28 }, { "xfade_btn", 28 } },
  oct = { { "octave", CW } }, interp = { { "interp", CW } },
  output = { { "output", CW } },
  sync = { { "sync", 24 }, { "slen", CW - 48 }, { "sync_t", 24 } },
  mode = { { "mode", CW } },
  semi = { { "semi", CW } }, fine = { { "fine", CW } },
  pan = { { "pan", CW } },
}
C.KIT_BOTTOM_STOPS = { kit_mode = true, kit_start = true, kit_white = true,
  kit_overlap = true, kb_new = true, kb_remove = true, kb_clear = true }

-- the waveform's height
function C.wave_h()
  return WAVE_HEIGHT
end

-- where each cell goes: plan[k] = { row, col, x, w }, x inside the panel
function C.grid_plan()
  local rows = C.grid_rows()
  local inner = C.edge() - 2
  local n = #rows[1]
  local widths = {}
  if n > 2 then                         -- two panes: each column as wide as
    local used = 0                      -- it needs, the rest shared out
    for c = 1, n do
      widths[c] = C.label_w(c) + 4 + CW
      used = used + widths[c]
    end
    local more = math.floor((inner - used) / n)
    for c = 1, n do widths[c] = widths[c] + more end
    widths[n] = widths[n] + (inner - used - more * n)
  else                                  -- one pane: the first just fits
    local c1 = C.label_w(1) + 4 + CW
    widths = { c1, inner - c1 }
  end
  local plan = {}
  for r, row in ipairs(rows) do
    local x = 1
    for c, k in ipairs(row) do
      plan[k] = { row = r, col = c, x = x, w = widths[c] }
      x = x + widths[c]
    end
  end
  return plan
end

-- put the cells in their rows for this layout (a moved view keeps its
-- state), and size the columns and labels
function C.place_cells()
  local G = S.cells
  if not G then return end
  local mode = two_pane() and "two" or "one"
  if S.layout_mode ~= mode then
    local ok = pcall(function()
      for k, where in pairs(S.where or {}) do
        local from = view(where)
        if from then from:remove_child(G[k]) end
      end
      S.where = {}
      for r, row in ipairs(C.LAYOUT[mode]) do
        local into = view("srow" .. r)
        for _, k in ipairs(row) do
          into:add_child(G[k])
          S.where[k] = "srow" .. r
        end
      end
    end)
    if ok then S.layout_mode = mode end
  end
  for r = 4, 5 do                      -- the rows this layout has
    local row = view("srow" .. r)
    if row then row.visible = r <= #C.LAYOUT[mode] end
  end
  for k, p in pairs(C.grid_plan()) do
    local cell = view("cell_" .. k)
    if cell then cell.width = p.w end
    local lbl = view("lbl_" .. k)
    if lbl then lbl.width = C.label_w(p.col) end
  end
end

-- Match the visible waveform and sample-panel height. Hidden controls need
-- neither their extra rows nor padding in the Multi-Sample column.
function C.kit_shape()
  local more = prefs.show_controls.value and (#C.grid_rows() - 3) or 0
  local rows = VISIBLE_ROWS + (prefs.show_waveform.value and KIT_EXTRA or 0) + more
  local extra = more * (C.ROW_H - C.ROW_HEIGHT)
  return rows, extra
end

function C.apply_kit_rows()
  local rows, extra = C.kit_shape()
  local max = VISIBLE_ROWS + KIT_EXTRA + 2
  K.rows = rows
  pcall(function()
    for i = 1, max do
      local r = view("krowc" .. i)
      if r then r.visible = i <= rows end
    end
    local sp = view("kextra")
    if sp then
      if extra > 0 then sp.height = extra end
      sp.visible = extra > 0
    end
    local h = rows * C.ROW_HEIGHT + 2 + extra
    local space, sb = view("ksbspace"), view("ksb")
    if space then space.height = h end
    if sb then sb.height = h end
  end)
  K.top = clamp(K.top, 1, math.max(1, #K.entries - K.rows + 1))
  if K.sel > 0 then
    if K.sel < K.top then K.top = K.sel
    elseif K.sel >= K.top + K.rows then K.top = K.sel - K.rows + 1 end
  end
end

-- is this control one of the sample panel's cells?
function C.cell_of_stop(id)
  for _, items in pairs(C.CELL_ITEMS) do
    for _, it in ipairs(items) do
      if it[1] == id then return true end
    end
  end
  return false
end

-- the whole window's content width (the status line's)
function C.full_width()
  local w = C.left_width()
  if prefs.show_kit.value then w = w + spacing() + KIT_WIDTH end
  return w
end

function C.top_row_layout()
  local top = view("row_a")
  if top then top.width = C.edge() end
  C.place_cells()
end

-- the waveform spans the folder (+ samples) panes, stopping before the
-- last scrollbar
local function wave_frame_width()
  return C.edge()
end


-- Where each control sits (its centre, in px from the window's content
-- corner), worked out from the same numbers that lay the window out. The
-- arrow keys of controls mode go to the nearest control in that direction.
function C.geo()
  local SP, H, F = spacing(), C.ROW_HEIGHT, C.FRAME
  local g = { two = two_pane(), E = C.edge(), lw = C.left_width() }
  g.y_top = H / 2                                 -- the top row
  g.y_head = H + SP + F + H / 2                   -- the pane headers
  local list_top = H + SP + (H + 2 * F) + 2
  local list_bottom = list_top + VISIBLE_ROWS * C.ROW_HEIGHT + 2
  g.y_wave = list_bottom + SP + (C.wave_h() + 2) / 2
  local RH = C.ROW_H                              -- one row of the panels
  local wave_space = prefs.show_waveform.value and (SP + C.wave_h() + 2) or 0
  local top = list_bottom + wave_space + SP   -- the sample panel
  g.y_tb = { top + 1 + RH / 2, top + 1 + RH * 1.5, top + 1 + RH * 2.5,
             top + 1 + RH * 3.5, top + 1 + RH * 4.5 }
  local ktop = top + (prefs.show_controls.value and (#C.grid_rows() - 3) * RH or 0)
  g.y_kmode = ktop + 1 + RH / 2
  g.y_kset = ktop + 1 + RH * 1.5
  g.y_kbtn = ktop + 1 + RH * 2.5
  g.kx = g.lw + SP                                -- the Multi-Sample column
  g.kw = KIT_WIDTH - SCROLLBAR_WIDTH + 2
  return g
end

-- a control of the sample panel: x, y of its centre (nil when not one)
function C.cell_xy(id, g)
  for k, p in pairs(C.grid_plan()) do
    local x = p.x + C.label_w(p.col) + 4
    for _, it in ipairs(C.CELL_ITEMS[k]) do
      if it[1] == id then return x + it[2] / 2, g.y_tb[p.row] end
      x = x + it[2]
    end
  end
end

-- centre of a control: x, y (px from the window's content corner)
function C.stop_xy(st)
  local g, id = C.geo(), st.id
  local SP = spacing()
  local right = g.E - (C.OPT_W + C.HELP_W + 2 * C.ICON_W + 3 * SP)
  local top = {
    btn_options = right + C.OPT_W / 2,
    btn_help = right + C.OPT_W + SP + C.HELP_W / 2,
    pane_btn = right + C.OPT_W + C.HELP_W + 2 * SP + C.ICON_W / 2,
    multi_btn = right + C.OPT_W + C.HELP_W + C.ICON_W + 3 * SP + C.ICON_W / 2,
  }
  if top[id] then return top[id], g.y_top end
  local head = {
    folder_btn = C.FRAME + C.ICON_W / 2,
    find_btn_l = C.FRAME + C.ICON_W + 4 + C.ICON_W / 2,
    find_btn_r = PANEL_WIDTH + 2 + SP + C.FRAME + C.ICON_W / 2,
    kit_keyjazz = g.kx + C.FRAME + C.ICON_W / 2,
    kit_name = g.kx + g.kw / 2,
  }
  if head[id] then return head[id], g.y_head end
  local cx, cy = C.cell_xy(id, g)
  if cx then return cx, cy end
  -- the Multi-Sample panel: three equal columns inside its border
  -- (labels' widths estimated: "from", "White keys", "Overlap")
  local inner = g.kw - 2
  local third = math.floor(inner / 3)
  local last = inner - 2 * third
  local kit = {
    kit_mode = { g.kw / 2, g.y_kmode },
    kit_start = { 1 + 30 + 35, g.y_kset },
    kit_white = { 1 + third + 66 + 11, g.y_kset },
    kit_overlap = { 1 + 2 * third + 50 + 35, g.y_kset },
    kb_new = { 1 + third / 2, g.y_kbtn },
    kb_remove = { 1 + third * 1.5, g.y_kbtn },
    kb_clear = { 1 + 2 * third + last / 2, g.y_kbtn },
  }
  if kit[id] then return g.kx + kit[id][1], kit[id][2] end
  return 0, 0
end

-- The control to go to from `st` with an arrow key - never nothing: the
-- arrows go round the window, like a clock's hand.
--   left / right: the nearest control level with it; when there is none,
--     the nearest one that way on another row, if it lies clearly more
--     that way than up or down - going round: right prefers the rows
--     below, left the rows above. Past the last one:
--     right goes on to the first control of the row below (from the
--     bottom: the top), left to the last of the row above.
--   up / down: the nearest row that way, in either column (browser or
--     Multi-Sample), with a control within reach across, and on it the
--     control most directly above / below. Past the edge: round to the
--     other end (down from the bottom: the top row).
function C.neighbour(st, dir)
  local x, y = C.stop_xy(st)
  local all = {}
  for _, c in ipairs(C.visible_stops()) do
    if c ~= st then
      local cx, cy = C.stop_xy(c)
      all[#all + 1] = { c = c, x = cx, y = cy }
    end
  end
  if #all == 0 then return nil end
  local LEVEL = 12                              -- px: the same row
  -- the rows (sorted top to bottom), each its controls left to right
  local rows = {}
  for _, o in ipairs(all) do
    local row
    for _, r in ipairs(rows) do if math.abs(r.y - o.y) < LEVEL then row = r end end
    if not row then row = { y = o.y } rows[#rows + 1] = row end
    row[#row + 1] = o
  end
  table.sort(rows, function(a, b) return a.y < b.y end)
  for _, r in ipairs(rows) do table.sort(r, function(a, b) return a.x < b.x end) end
  local half_kit = C.geo().kw / 2
  local function nearest_x(row)              -- a wide control: its edge
    local best, bd
    for _, o in ipairs(row) do
      local d = math.max(0, math.abs(o.x - x) - (o.c.wide and half_kit or 0))
      if not bd or d < bd then best, bd = o.c, d end
    end
    return best
  end
  if dir == "left" or dir == "right" then
    local sign = dir == "right" and 1 or -1
    local level, other, ls, os
    for _, o in ipairs(all) do
      local ahead = (o.x - x) * sign
      if ahead > 0.5 then
        local dy = o.y - y
        if math.abs(dy) < LEVEL then
          if not ls or ahead < ls then level, ls = o.c, ahead end
        else
          -- going round: right likes the rows below, left those above
          local with = (dy * sign > 0) and 2 or 3
          local score = ahead + with * math.abs(dy)
          if not os or score < os then other, os = o.c, score end
        end
      end
    end
    if level then return level end
    -- the nearest one on another row, if it lies more that way than up or
    -- down (else the hand goes on round)
    -- (from a control as wide as its panel: from its edge)
    if other then
      local ox, oy = C.stop_xy(other)
      local half = st.wide and C.geo().kw / 2 or 0
      if math.abs(ox - x) - half > 1.5 * math.abs(oy - y) then return other end
    end
    -- round: the next row's first control / the previous row's last
    if dir == "right" then
      for _, r in ipairs(rows) do if r.y > y + LEVEL - 1 then return r[1].c end end
      return rows[1][1].c
    end
    for i = #rows, 1, -1 do
      if rows[i].y < y - LEVEL + 1 then return rows[i][#rows[i]].c end
    end
    return rows[#rows][#rows[#rows]].c
  end
  -- up / down: the next row that way with a control within reach across
  -- (a row only on the far side of the window is passed over), then on
  -- round from the other end
  local REACH = 240
  local order = {}
  if dir == "down" then
    for _, r in ipairs(rows) do if r.y > y + LEVEL - 1 then order[#order + 1] = r end end
    for _, r in ipairs(rows) do if r.y <= y + LEVEL - 1 then order[#order + 1] = r end end
  else
    for i = #rows, 1, -1 do
      if rows[i].y < y - LEVEL + 1 then order[#order + 1] = rows[i] end
    end
    for i = #rows, 1, -1 do
      if rows[i].y >= y - LEVEL + 1 then order[#order + 1] = rows[i] end
    end
  end
  for _, r in ipairs(order) do
    local c = nearest_x(r)
    local cx = C.stop_xy(c)
    local d = math.abs(cx - x) - (c.wide and half_kit or 0)
    if d <= REACH then return c end
  end
  return nearest_x(order[1])
end

-- "from" and "White keys" only apply to Drumkit: greyed otherwise (a
-- control is made inactive; a label has no such state, it gets the
-- "disabled" text style)
function C.kit_controls_active()
  local drum = prefs.kit_mode.value == KIT_DRUM
  for _, id in ipairs { "kit_start", "kit_white" } do
    local v = view(id)
    if v then pcall(function() v.active = drum end) end
  end
  for _, id in ipairs { "kit_from", "lbl_white" } do
    local v = view(id)
    if v then pcall(function() v.style = drum and "normal" or "disabled" end) end
  end
end

-- width of a pane header's text: the list's width minus the count, the
-- icons in front (`icons`) and the gaps
function C.head_w(P, icons)
  return P.width - SCROLLBAR_WIDTH - C.COUNT_W - 4 - 2 * C.FRAME
         - icons * (C.ICON_W + 4)
end

apply_layout = function()
  if not S.vb then return end
  local show_c = two_pane()
  local show_k = prefs.show_kit.value
  local w = wave_frame_width()

  local rp = view("right_panel")
  if rp then rp.visible = show_c end
  for _, id in ipairs { "kit_col", "kit_panel" } do
    local v = view(id)
    if v then v.visible = show_k end
  end
  local wave = view("wave_frame")
  if wave then wave.visible = prefs.show_waveform.value end
  for _, id in ipairs { "sample_panel", "kit_opts" } do
    local v = view(id)
    if v then v.visible = prefs.show_controls.value end
  end
  local bottom = view("bottom_left")
  if bottom then bottom.visible = (wave ~= nil and prefs.show_waveform.value) or prefs.show_controls.value end
  C.top_row_layout()
  local info = view("info")
  if info then
    info.width = C.full_width()
    C.size_info()
  end
  if S.wave_view then
    S.wave_view.width = w - 2   -- inside the 1 px frame
    S.wave_view.height = C.wave_h()
    if S.playhead_view then S.playhead_view.height = C.wave_h() end
    redraw_wave()
  end

  if show_c then
    schedule_contents(true)
  else
    if not S.find then stop_scan() end   -- a search may be filling the list
    remove_timer(contents_timer)
    R.dir = nil
  end
  -- the search icon sits in the header of the pane it fills; the folder
  -- icon starts the folder pane's header
  for _, P in ipairs { L, R } do
    local btn, head = view("find_btn_" .. P.key), view(P.key .. "head")
    local on = (P == R) == show_c
    if btn then btn.visible = on end
    if head then   -- the count stays flush right either way
      local icons = (on and 1 or 0) + (P == L and 1 or 0)
      head.width = C.head_w(P, icons)
    end
  end
  if not panel_visible(S.focus) then S.focus = L end
  C.apply_kit_rows()
  if show_k then K.sync(true) end
  C.kit_controls_active()
  refresh_all()
end

-- Options: single pane (folders + samples in one list) or two panes
local function toggle_contents()
  if S.find then F.drop() end    -- its results belong to the other layout
  prefs.show_contents.value = not prefs.show_contents.value
  if BM.states then BM.states() end
  if dialog_open() then
    R.dir = nil
    open_dir(S.path)
    apply_layout()
  end
end

-- The browser's options, defined ONCE. Both the "Options" window and
-- Tools > Simple Browser > Options are built from this list, so they always
-- match. sep = a divider line before the entry; items = a choice of values
-- (the window: 'Left' / 'Right'; the Tools menu: a sub menu).
-- Section names also group the Tools menu and Help. They are display-only:
-- keyboard selection still moves directly between actionable options.
function C.theme_editor()
  if C.theme_dlg and C.theme_dlg.visible then C.theme_dlg:show() return end
  if C.theme_close then C.theme_close() end
  C.theme_dlg = nil
  local vb = renoise.ViewBuilder()
  local draft = {
    back = prefs.list_background.value, back_hex = prefs.list_custom_hex.value,
    text = prefs.list_text_colour.value, text_hex = prefs.list_text_hex.value,
    selected = prefs.list_selected_hex.value, marked = prefs.list_marked_hex.value,
  }
  local target, updating = 1, false
  local themes = C.themes_read(prefs.list_user_themes.value)
  local chosen = prefs.list_theme_name.value or ""
  local rows, custom_rows, swatches, sliders, values = {}, {}, {}, {}, {}
  local background, text_mode, adjust, custom_target, channels
  local main_page, custom_page, dialog, close_watch
  local parent = C.opt_dlg
  local saved, name, save, delete, hint, replace_name
  local select_target, sync
  local function find_theme(label)
    for i, theme in ipairs(themes) do
      if theme.name:lower() == label:lower() then return i end
    end
  end
  local function active_theme()
    local i = find_theme(chosen)
    return i and C.theme_equal(draft, themes[i]) and i or nil
  end
  local function back_colour()
    return draft.back == 5 and (C.hex_rgb(draft.back_hex) or { 32, 32, 36 })
      or C.LIST_BACK_COLORS[draft.back] or DEFAULT_COLOR
  end
  local function palette()
    return target == 2 and {
      { "White", "FFFFFF" }, { "Black", "010101" }, { "Grey", "A0A0A0" },
      { "Cream", "FFF0C0" }, { "Blue", "A8D8FF" }, { "Green", "B8EDB8" }, { "Pink", "FFC4DD" },
    } or {
      { "Dark", "1C1C20" }, { "Grey", "505054" }, { "Light", "E0E0E4" },
      { "Blue", "293F55" }, { "Green", "304B3C" }, { "Brown", "514033" }, { "Purple", "493951" },
    }
  end
  local function current_rgb()
    if target == 1 then return C.row_rgb(back_colour()) end
    if target == 2 then return C.row_text(back_colour(), false, draft.text, C.hex_rgb(draft.text_hex)) end
    return C.row_rgb(target == 3 and (C.hex_rgb(draft.selected) or C.FOCUS)
      or (C.hex_rgb(draft.marked) or C.MARK))
  end
  sync = function()
    updating = true
    local items = { "Current colours" }
    for _, theme in ipairs(themes) do items[#items + 1] = theme.name end
    saved.items, saved.value = items, (active_theme() or 0) + 1
    delete.active = active_theme() ~= nil
    background.value, text_mode.value, adjust.value = draft.back, draft.text, target
    custom_target.value = target
    C.style_row(rows[1], back_colour(), false, draft.text, C.hex_rgb(draft.text_hex))
    C.style_row(rows[2], C.hex_rgb(draft.selected) or C.FOCUS, true)
    C.style_row(rows[3], C.hex_rgb(draft.marked) or C.MARK, true)
    C.style_row(custom_rows[1], back_colour(), false, draft.text, C.hex_rgb(draft.text_hex))
    C.style_row(custom_rows[2], C.hex_rgb(draft.selected) or C.FOCUS, true)
    C.style_row(custom_rows[3], C.hex_rgb(draft.marked) or C.MARK, true)
    local rgb = current_rgb()
    for i = 1, 3 do sliders[i].value, values[i].value = rgb[i], rgb[i] end
    for i, preset in ipairs(palette()) do
      swatches[i].text = preset[1]
      C.style_row(swatches[i], C.hex_rgb(preset[2]), true)
    end
    updating = false
  end
  select_target = function(value)
    if updating then return end
    target = value
    sync()
  end
  local function set_colour(rgb)
    local hex = string.format("%02X%02X%02X", unpack(rgb))
    if target == 1 then draft.back, draft.back_hex = 5, hex
    elseif target == 2 then draft.text, draft.text_hex = 4, hex
    elseif target == 3 then draft.selected = hex
    else draft.marked = hex end
    sync()
  end
  local function show_custom(show)
    -- Both pages are sized before opening. Switching never grows the dialog
    -- beneath Renoise's fixed prompt-button area.
    -- Hide first in both directions: briefly showing both pages can make a
    -- native rack grow and retain that larger minimum window size.
    main_page.visible = false
    custom_page.visible = false
    if show then custom_page.visible = true else main_page.visible = true end
  end
  local function finish(apply)
    if apply then
      prefs.list_background.value, prefs.list_custom_hex.value = draft.back, draft.back_hex
      prefs.list_text_colour.value, prefs.list_text_hex.value = draft.text, draft.text_hex
      prefs.list_selected_hex.value, prefs.list_marked_hex.value = draft.selected, draft.marked
      prefs.list_user_themes.value = C.themes_write(themes)
      local i = active_theme()
      prefs.list_theme_name.value = i and themes[i].name or ""
      refresh_all()
    end
    if close_watch then
      pcall(function() renoise.tool().app_idle_observable:remove_notifier(close_watch) end)
    end
    if dialog and dialog.visible then dialog:close() end
    if rawequal(C.theme_dlg, dialog) then C.theme_dlg, C.theme_close = nil, nil end
    if parent and parent.visible and rawequal(parent, C.opt_dlg) then
      if C.opt_refresh then C.opt_refresh() end
      parent:show()
    end
  end
  saved = vb:popup { id = "theme_saved", width = 176, items = { "Current colours" }, value = 1,
    notifier = function(v)
      if updating then return end
      local theme = themes[v - 1]
      chosen = theme and theme.name or ""
      if theme then draft = C.theme_copy(theme) end
      name.value = ""
      sync()
    end }
  delete = vb:button { id = "theme_delete", width = 80, text = "Delete", active = false,
    tooltip = "Remove the selected saved theme. Apply confirms the change; Cancel restores it.",
    notifier = function()
      local i = active_theme()
      if not i then return end
      table.remove(themes, i)
      chosen = ""
      sync()
    end }
  save = vb:button { id = "theme_save", width = 80, text = "Save",
    notifier = function()
      -- Text fields commit on Return/focus loss, not on every keystroke.
      name.edit_mode = false
      local label = C.theme_name(name.value)
      if not label then
        hint.text = "Enter a different theme name."
        name.edit_mode = true
        return
      end
      local i = find_theme(label)
      if i and replace_name ~= label:lower() then
        replace_name = label:lower()
        save.text = "Replace"
        hint.text = "Name exists. Click Replace to update it."
        return
      end
      local theme = C.theme_copy(draft)
      theme.name = label
      themes[i or (#themes + 1)] = theme
      chosen = label
      name.value = ""
      sync()
    end }
  name = vb:textfield { id = "theme_name", width = 176, value = "",
    tooltip = "Name the current colours, then click Save. Apply saves all changes.",
    notifier = function()
      replace_name = nil
      save.text = "Save"
      if hint then hint.text = "Apply saves your themes and colours." end
    end }
  background = vb:popup { id = "theme_background", width = 260, items = C.LIST_BACK_ITEMS,
    value = draft.back, notifier = function(v)
      if not updating then draft.back = v; target = 1; sync() end
    end }
  text_mode = vb:popup { id = "theme_text", width = 260, items = C.LIST_TEXT_ITEMS,
    value = draft.text, notifier = function(v)
      if not updating then draft.text = v; target = 2; sync() end
    end }
  adjust = vb:popup { id = "theme_target", width = 176,
    items = { "Background", "Text", "Selected row", "Marked rows" }, value = 1,
    notifier = select_target }
  local reset = vb:button { id = "theme_reset", width = 80, text = "Reset colour",
    tooltip = "Use Renoise's colour for this background, or automatic text contrast.",
    notifier = function()
      if target == 1 then draft.back = 1
      elseif target == 2 then draft.text = 1
      elseif target == 3 then draft.selected = ""
      else draft.marked = "" end
      sync()
    end }
  local preview = vb:column { spacing = 2 }
  local custom_preview = vb:column { spacing = 2 }
  for i, label in ipairs({ "Normal: Sample name.wav", "Selected: Bass sample.wav", "Marked: Drum loop.wav" }) do
    local which = i == 1 and 1 or i + 1
    rows[i] = vb:button { id = "theme_preview_" .. i, width = 340, height = 24,
      text = label, align = "left", notifier = function() select_target(which) end }
    preview:add_child(rows[i])
    custom_rows[i] = vb:button { id = "theme_custom_preview_" .. i, width = 340, height = 24,
      text = label, align = "left", notifier = function() select_target(which) end }
    custom_preview:add_child(custom_rows[i])
  end
  local swatch_row = vb:row { spacing = 4 }
  for i = 1, 7 do
    swatches[i] = vb:button { id = "theme_swatch_" .. i, width = 44, height = 24,
      text = "", notifier = function() set_colour(C.hex_rgb(palette()[i][2])) end }
    swatch_row:add_child(swatches[i])
  end
  channels = vb:column { id = "theme_sliders", spacing = 4 }
  for i, name in ipairs({ "Red", "Green", "Blue" }) do
    local function update(v)
      if updating then return end
      local rgb = current_rgb()
      rgb = { rgb[1], rgb[2], rgb[3] }
      rgb[i] = math.floor(v + 0.5)
      set_colour(rgb)
    end
    sliders[i] = vb:slider { id = "theme_slider_" .. i, width = 200, height = 18,
      min = 0, max = 255, value = 0, steps = { 1, 16 }, notifier = update }
    values[i] = vb:valuebox { id = "theme_value_" .. i, width = 54,
      min = 0, max = 255, value = 0, notifier = update }
    channels:add_child(vb:row { spacing = 4, vb:text { width = 76, text = name }, sliders[i], values[i] })
  end
  hint = vb:text { id = "theme_hint", width = 340, text = "Apply saves your themes and colours." }
  main_page = vb:column { id = "theme_main_page", width = 340, spacing = 6,
    vb:row { spacing = 4, vb:text { width = 76, text = "Saved theme" }, saved, delete },
    vb:row { spacing = 4, vb:text { width = 76, text = "Save as" }, name, save },
    vb:row { spacing = 4, vb:text { width = 76, text = "Background" }, background },
    vb:row { spacing = 4, vb:text { width = 76, text = "Text" }, text_mode },
    vb:text { text = "Preview - click a row to edit its background." }, preview,
    vb:row { spacing = 4, vb:text { width = 76, text = "Colour" }, adjust, reset },
    swatch_row,
    vb:button { id = "theme_custom", width = 340, text = "Custom colour...",
      notifier = function() show_custom(true) end },
    vb:text { text = "Selected and marked text adjusts automatically." },
    hint,
    vb:row { spacing = 8,
      vb:button { id = "theme_apply", width = 166, text = "Apply", notifier = function() finish(true) end },
      vb:button { id = "theme_cancel", width = 166, text = "Cancel", notifier = function() finish(false) end },
    },
  }
  custom_target = vb:popup { id = "theme_custom_target", width = 260,
    items = { "Background", "Text", "Selected row", "Marked rows" }, value = 1, notifier = select_target }
  local gap = vb:space { height = 1 }
  custom_page = vb:column { id = "theme_custom_page", width = 340, spacing = 6,
    vb:text { text = "Custom colour", font = "bold" },
    vb:row { spacing = 4, vb:text { width = 76, text = "Colour" }, custom_target },
    custom_preview, channels,
    vb:text { text = "Close returns to the editor with your changes." }, gap,
    vb:button { id = "theme_custom_close", width = 340, text = "Close",
      notifier = function() show_custom(false) end },
  }
  local height = math.max(main_page.height, custom_page.height)
  gap.height = gap.height + height - custom_page.height
  main_page.height, custom_page.height = height, height
  custom_page.visible = false
  local content = vb:column { width = 352, height = height + 12,
    margin = 6, main_page, custom_page }
  sync()
  local function handler(_, key)
    if key.name == "esc" then
      if custom_page.visible then show_custom(false) else finish(false) end
      return nil
    end
    return key
  end
  dialog = C.show_dialog(TOOL_NAME .. " - Theme editor", content, handler)
  C.theme_dlg = dialog
  C.theme_close = function() finish(false) end
  close_watch = function() if not dialog.visible then finish(false) end end
  pcall(function() renoise.tool().app_idle_observable:add_notifier(close_watch) end)
end

-- Rebuild at the new content size so Renoise can shrink as well as grow.
-- Playback, sample edits and browser history survive C.reopen_window.
function C.toggle_layout(pref)
  local old = prefs[pref].value
  prefs[pref].value = not old
  if not dialog_open() then return end
  if C.reopen_window() then return end
  prefs[pref].value = old
  apply_layout()
  set_status("Could not change the browser layout")
end

C.OPTIONS = {
  -- top: the layout
  { label = "List background", section = "Appearance", items = C.LIST_BACK_ITEMS,
    get = function() return prefs.list_background.value end,
    put = function(v)
      -- Custom selects the saved colour. Editing is a separate action, so
      -- cycling always wraps without opening a dialog.
      prefs.list_background.value = v
      refresh_all()
    end },
  { label = "Theme editor...", action = true, keep_open = true, nonmodal = true,
    set = function() C.theme_editor() end },
  { label = "Single pane (folders and samples in one list)", section = "Layout",
    on = function() return not prefs.show_contents.value end,
    set = function() toggle_contents() end },
  { label = "Show waveform", keep_open = true,
    on = function() return prefs.show_waveform.value end,
    set = function() C.toggle_layout("show_waveform") end },
  { label = "Show controls", keep_open = true,
    on = function() return prefs.show_controls.value end,
    set = function() C.toggle_layout("show_controls") end },
  { label = "Show the Multi-Sample panel when the browser opens",
    on = function() return prefs.kit_default_open.value end,
    set = function()
      prefs.kit_default_open.value = not prefs.kit_default_open.value
    end },
  { label = "Adding to the Multi-Sample moves to the next sample",
    on = function() return prefs.insert_advance.value end,
    set = function()
      prefs.insert_advance.value = not prefs.insert_advance.value
    end },
  { label = "Default loop", section = "Playback and loops", items = LOOP_ITEMS,
    get = function() return prefs.default_loop.value end,
    put = function(v)
      prefs.default_loop.value = v
      C.reload_preview(S.loaded_path)      -- hear the new default now
      refresh_info_box()
    end },
  { label = "Remember default loop",
    on = function() return prefs.remember_default_loop.value end,
    set = function()
      prefs.remember_default_loop.value = not prefs.remember_default_loop.value
    end },
  { label = "Use loops stored in files",
    on = function() return prefs.file_loops.value end,
    set = function()
      prefs.file_loops.value = not prefs.file_loops.value
      C.reload_preview(S.loaded_path)
    end },
  { label = "Loop points snap to zero crossings",
    on = function() return prefs.snap_zero.value end,
    set = function() prefs.snap_zero.value = not prefs.snap_zero.value end },
  { label = "Prehear after changing Semitone, Fine tune, Panning, Sync",
    on = function() return prefs.audition_changes.value end,
    set = function()
      prefs.audition_changes.value = not prefs.audition_changes.value
    end },
  { label = "Keep Beatsync on / off between sessions",
    on = function() return prefs.sync_keep.value end,
    set = function() prefs.sync_keep.value = not prefs.sync_keep.value end },
  { label = "Reopen in the last folder", section = "Folder memory",
    on = function() return prefs.remember_location.value end,
    set = function()
      prefs.remember_location.value = not prefs.remember_location.value
    end },
  { label = "Reopen with the last folder highlighted",
    on = function() return prefs.remember_folder_sel.value end,
    set = function()
      prefs.remember_folder_sel.value = not prefs.remember_folder_sel.value
    end },
  { label = "Reopen with the last sample highlighted",
    on = function() return prefs.remember_sample_sel.value end,
    set = function()
      prefs.remember_sample_sel.value = not prefs.remember_sample_sel.value
    end },
  { label = "Folders remember last selection",
    on = function() return prefs.folder_memory.value end,
    set = function()
      prefs.folder_memory.value = not prefs.folder_memory.value
      C.mem = {}
    end },
  { label = "Samples pane includes sub folders", section = "Browsing and search",
    on = function() return prefs.include_subfolders.value end,
    set = function()
      prefs.include_subfolders.value = not prefs.include_subfolders.value
      if dialog_open() then
        R.dir = nil
        schedule_contents(true)
      end
    end },
  { label = "Find searches the whole folder path",
    on = function() return prefs.find_root.value end,
    set = function() prefs.find_root.value = not prefs.find_root.value end },
}

do
  local group
  for _, option in ipairs(C.OPTIONS) do
    group = option.section or group
    option.group = group
  end
end

-- a path as a menu entry (':' would make a sub menu in Renoise)
function C.menu_name(p)
  local parent = parent_of(p)
  local name = basename(p) .. (parent and ("  (in " .. basename(parent) .. ")")
                               or "")
  name = name:gsub(":", ".")
  return name
end

-- A list as a small window for the keyboard: 'Up' / 'Down' pick, 'Enter'
-- ticks or runs one, 'Left' / 'Right' change a value, 'Esc' closes it -
-- the same keys as everywhere else. Left-click cycles forwards, right-click
-- backwards. Rows: { label, on, set, action, keep_open,
-- items/get/put (a value), menu (a side menu), sep }. `make` builds the
-- rows (again after one changed the list).
function C.list_dialog(title, make, start_row)
  if C.opt_dlg and C.opt_dlg.visible then C.opt_dlg:close() end
  local vb = renoise.ViewBuilder()
  local rows = make()
  local sel, btns = clamp(start_row or 1, 1, math.max(1, #rows)), {}
  local function text(r)
    if r.items then
      return "        " .. r.label .. ":   < " .. r.items[r.get()] .. " >"
    elseif r.on and not r.action then
      return (r.on() and "[x]  " or "[  ]  ") .. r.label
    end
    return "        " .. r.label .. (r.menu and "  >" or "")
  end
  local function paint_rows()
    for i, b in ipairs(btns) do
      b.text = text(rows[i])
      C.tint(b, (i == sel) and C.FOCUS or DEFAULT_COLOR)
    end
  end
  local function back_to_browser()
    if C.opt_dlg and C.opt_dlg.visible then C.opt_dlg:close() end
    pcall(function() if S.dialog and S.dialog.visible then S.dialog:show() end end)
  end
  local function step(i, dir)
    local r = rows[i]
    r.put((r.get() - 1 + dir) % #r.items + 1)
    paint_rows()
  end
  local function choose(i)
    sel = i
    local r = rows[i]
    if r.items then step(i, 1) return end
    if r.menu then                           -- the list as a side menu
      paint_rows()
      local items = r.menu()
      for _, it in ipairs(items) do          -- afterwards: list updated
        local fn = it.invoke
        it.invoke = function() fn() C.list_dialog(title, make, i) end
      end
      pcall(function()
        renoise.app():show_menu(C.opt_dlg, items, btns[i])
      end)
      return
    end
    if r.action and not r.keep_open then     -- navigation actions leave this list
      back_to_browser()
      r.set()
      return
    end
    local parent = C.opt_dlg
    r.set()
    if r.rebuild then C.list_dialog(title, make, i) return end
    paint_rows()
    -- Modal editors return here; a nonmodal editor restores focus itself.
    if r.keep_open and not r.nonmodal and parent and parent.visible then parent:show() end
  end
  local right_pressed
  local function mouse(ev)
    if ev.button ~= "right" then
      if ev.type == "down" then right_pressed = nil end
      return ev
    end
    local row
    for _, h in ipairs(ev.hover_views or {}) do
      row = tonumber(tostring(h.id or ""):match("^list_option_(%d+)$"))
      if row then break end
    end
    if ev.type == "down" or ev.type == "double" then
      right_pressed = row and rows[row] and rows[row].items and row or nil
      if right_pressed then sel = right_pressed paint_rows() end
    elseif ev.type == "up" then
      local pressed = right_pressed
      right_pressed = nil
      -- Releasing on another row or on a heading cancels the click.
      if pressed and pressed == row then step(pressed, -1) end
    end
    -- Consume the full gesture so the native button cannot also fire its
    -- left-click notifier and undo the backwards step.
    return nil
  end
  local col = vb:column { spacing = 0, mouse_events = { "down", "up", "double" },
                         mouse_handler = mouse }
  local group
  for i, r in ipairs(rows) do
    if r.group and r.group ~= group then
      group = r.group
      if i > 1 then col:add_child(vb:space { height = 8 }) end
      col:add_child(vb:text { text = group, font = "bold", width = 340, height = 18 })
      col:add_child(vb:column { width = 340, height = 2, background = "border" })
      col:add_child(vb:space { height = 4 })
    elseif r.sep and i > 1 then
      col:add_child(vb:space { height = 6 })
    end
    local b = vb:button { id = "list_option_" .. i,
                          width = 340, height = C.ROW_HEIGHT, text = "",
                          tooltip = r.items and "Left-click / Right arrow: next value.\n"
                            .. "Right-click / Left arrow: previous value." or "",
                          notifier = function() choose(i) end }
    pcall(function() b.align = "left" end)
    btns[i] = b
    col:add_child(b)
  end
  paint_rows()
  local content = vb:column {
    margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN, col }
  local function handler(dlg, key)
    local m = key.modifier_flags or {}
    if C.undo_key(key, m) then paint_rows() return nil end
    if m.shift or m.control or m.alt or m.meta then return key end
    local name = key.name
    if name == "up" or name == "down" then
      sel = clamp(sel + (name == "down" and 1 or -1), 1, #rows)
      paint_rows()
    elseif (name == "left" or name == "right") and rows[sel] and rows[sel].items then
      step(sel, name == "right" and 1 or -1)
    elseif name == "return" or name == "enter" then
      if not key.repeated then choose(sel) end
    elseif name == "esc" then
      back_to_browser()
    else
      return key
    end
    return nil
  end
  C.opt_dlg = C.show_dialog(TOOL_NAME .. " - " .. title, content, handler)
  C.opt_refresh = paint_rows
  C.opt_title = title
  -- the keys go to it, also when it was opened from the browser's window
  -- (a click there leaves the keys with the browser until it is shown)
  local d = C.opt_dlg
  C.later(function() pcall(function() if d.visible then d:show() end end) end)
end

-- Renoise's dialog, with key repeat; an older Renoise without the key
-- options gets the plain call
function C.show_dialog(title, content, handler, release)
  local ok, d = pcall(function()
    return renoise.app():show_custom_dialog(title, content, handler,
      { send_key_repeat = true, send_key_release = release == true })
  end)
  if not ok then d = renoise.app():show_custom_dialog(title, content, handler) end
  return d
end

-- the Options window (`filter` / `title`: a part of it, e.g. prehear)
function C.options_dialog(filter, title, start_row)
  C.list_dialog(title or "Options", function()
    local rows = {}
    for _, o in ipairs(C.OPTIONS) do
      if not filter or filter(o) then rows[#rows + 1] = o end
    end
    return rows
  end, start_row)
end

-- the Options button and key binding: open; behind other windows: to the
-- front; in front: close (as Help does). `button`: a click on the Options
-- button (it takes the focus from Options): an open Options always closes
function C.toggle_options(button)
  local d = C.opt_dlg
  if d and d.visible and C.opt_title == "Options" then
    local ok, focused = pcall(function() return d.focused end)
    if ok and focused == false and not button then d:show() return end
    d:close()
    pcall(function() if S.dialog and S.dialog.visible then S.dialog:show() end end)
    return
  end
  C.options_dialog()
end

-- open it outside of a key handler / menu (Renoise is pickier there)
function C.later(fn)
  local function once()
    if renoise.tool():has_timer(once) then renoise.tool():remove_timer(once) end
    fn()
  end
  renoise.tool():add_timer(once, 1)
end

local function toggle_kit()
  prefs.show_kit.value = not prefs.show_kit.value
  -- built again and shown anew, so Renoise places it on the screen at its
  -- new width (growing in place could run off the screen's edge)
  if C.reopen_window and C.reopen_window() then return end
  apply_layout()
end

local function toggle_autoplay()
  prefs.autoplay.value = not prefs.autoplay.value
  -- the icon shows it while the browser is open
  if not dialog_open() then
    set_status("Auto-prehear " .. (prefs.autoplay.value and "on" or "off"))
  end
end

--------------------------------------------------------------------------------
-- Help window, in the style of Schism Tracker's F1 help: a boxed title,
-- headings ending in a full stop, and every entry a key padded to one
-- column, then what it does. One blank line between sections, none inside.
-- 80 columns by 25 rows, one text view per line (see HELP.toggle). The lists of options and key bindings are made from the
-- lists the tool itself uses, so they never go out of date.
--------------------------------------------------------------------------------

local HELP = {
  COLS = 80,      -- characters per line
  ROWS = 25,      -- lines shown at once: an 80 x 25 text screen
  KEY_W = 18,     -- the key column (descriptions start after it)
}

-- "   key               what it does"
function HELP.key(k, d, w)
  w = w or HELP.KEY_W
  return "   " .. k .. string.rep(" ", math.max(1, w - #k)) .. d
end

-- a description's next line, under the first
function HELP.more(d, w)
  return string.rep(" ", 3 + (w or HELP.KEY_W)) .. d
end

-- " Heading."
function HELP.head(t) return " " .. t .. "." end

-- the title in a box, centred
function HELP.title(name, cols)
  local inner = #name + 12
  local pad = string.rep(" ", math.floor(((cols or HELP.COLS) - inner - 2) / 2))
  local l = math.floor((inner - #name) / 2)
  return table.concat({
    pad .. "╔" .. string.rep("═", inner) .. "╗",
    pad .. "║" .. string.rep(" ", l) .. name
        .. string.rep(" ", inner - l - #name) .. "║",
    pad .. "╚" .. string.rep("═", inner) .. "╝" }, "\n")
end

-- the key bindings, as in Preferences > Keys: { scope, name, description
-- [, name shown] }; `skip = true` leaves one out (a numbered series shows
-- its first one as "... 1 ... 8")
function HELP.bindings(add, list, tool)
  local w = 0
  for _, b in ipairs(list) do
    if not b.skip then w = math.max(w, #(b[4] or b[2])) end
  end
  local scope
  for _, b in ipairs(list) do
    if not b.skip then
      if b[1] ~= scope then
        if scope then add("") end
        scope = b[1]
        add(HELP.head("Key Bindings (Preferences > Keys > " .. scope .. " > "
                      .. tool .. ")"))
      end
      local desc = (b[3] or ""):gsub("^%l", string.upper)
      add(HELP.key(b[4] or b[2], desc, w + 2))
    end
  end
end

-- height of one line of the "mono" font, measured
function HELP.line_h(vb)
  local h = 16
  pcall(function()
    local probe = vb:text { text = "0", font = "mono" }
    if probe.height and probe.height >= 8 and probe.height <= 40 then
      h = probe.height
    end
  end)
  return h
end

-- width of one character of the "mono" font, measured
function HELP.char_w(vb)
  local w = 7
  pcall(function()
    local probe = vb:text { text = string.rep("0", 100), font = "mono" }
    if probe.width and probe.width >= 300 and probe.width <= 2000 then
      w = probe.width / 100
    end
  end)
  return w
end

-- Open the help (or bring it to the front, or close it; `button`: a
-- click on a Help button, which always closes an open Help).
--   spec.name     the tool's name (window title and boxed title)
--   spec.text     function returning the help text
--   spec.credits  { { "plain text  ", "italic text" }, ... } under the text
--   spec.on_key   optional function(key, modifiers): true when it used a key
--   spec.owner    optional function: the tool's own window, if it is open
--                 (opened from it, Help hands the keys back to it on close)
-- Each line is a text view of its own: the window is exactly 80 columns by
-- 25 lines, and the arrow keys, PgUp / PgDn, Home / End, the mouse wheel
-- and the scroll bar beside it all move the same lines. Ctrl+C opens the
-- whole text as a text file, to copy from.
function HELP.toggle(spec, button)
  -- closing: back to the window Help was opened from, if it still is open
  local function close(dlg)
    dlg:close()
    spec.dialog = nil
    local back = spec.back and spec.owner and spec.owner()  -- (rebuilt: the
    spec.back = nil                                          -- new window)
    if back then pcall(function() back:show() end) end
  end
  local d = spec.dialog
  if d and d.visible then
    -- (a button's click takes the focus from Help: a click always closes)
    local ok, focused = pcall(function() return d.focused end)
    if ok and focused == false and not button then d:show() return end
    close(d)
    return
  end
  -- opened from the tool's own window (it has the keys): remember it
  spec.back = nil
  if spec.owner then
    local owner = spec.owner()
    if owner then
      local ok, focused = pcall(function() return owner.focused end)
      if not ok or focused ~= false then spec.back = true end
    end
  end
  local vb = renoise.ViewBuilder()
  local lh, cw = HELP.line_h(vb), HELP.char_w(vb)
  local text = spec.text()
  -- as wide as its widest line (80 columns at most): no space on the right
  local cols = 0
  for l in (text .. "\n"):gmatch("(.-)\n") do
    local n = 0
    for _ in l:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    if n > cols then cols = n end
  end
  cols = math.min(cols, HELP.COLS)
  local lines = {}                       -- the title centred on that width
  for l in (HELP.title(spec.heading or spec.name, cols) .. "\n\n" .. text .. "\n")
           :gmatch("(.-)\n") do
    lines[#lines + 1] = l
  end
  while lines[#lines] == "" do lines[#lines] = nil end
  local W = math.ceil(cw * cols)
  local rows = math.min(HELP.ROWS, #lines)
  local last = math.max(1, #lines - rows + 1)
  local top = 1
  local views = {}
  local page = vb:column { style = "border", margin = 4 }
  for i = 1, rows do
    views[i] = vb:text { text = lines[i] or "", font = "mono",
                         width = W, height = lh }
    page:add_child(views[i])
  end
  local bar
  local function scroll_to(t)
    t = math.max(1, math.min(math.floor(t), last))
    if t == top then return end
    top = t
    for i = 1, rows do views[i].text = lines[top + i - 1] or "" end
    if bar and bar.value ~= top - 1 then bar.value = top - 1 end
  end
  bar = vb:scrollbar {
    width = 16, height = rows * lh + 8, min = 0, max = #lines,
    pagestep = rows, step = 1, value = 0, visible = #lines > rows,
    notifier = function(v) scroll_to(v + 1) end,
  }
  -- the mouse wheel over the text, where this Renoise supports it
  local ok_area, area = pcall(function()
    return vb:row {
      mouse_events = { "wheel" },
      mouse_handler = function(ev)
        if ev.type == "wheel" then
          scroll_to(top + (ev.direction == "up" and -1 or 1) * 3)
          return nil
        end
        return ev
      end,
    }
  end)
  if not ok_area or not area then area = vb:row {} end
  area:add_child(page)
  area:add_child(bar)
  local full = W + 8 + 16
  local content = vb:column {
    margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN, spacing = 6, area,
  }
  for _, c in ipairs(spec.credits or {}) do
    content:add_child(vb:horizontal_aligner {
      mode = "right", width = full,
      vb:text { text = c[1] },
      vb:text { text = c[2], font = "italic" },
    })
  end
  local keys = {
    up = -1, down = 1, prior = -(rows - 1), pageup = -(rows - 1),
    ["next"] = rows - 1, pagedown = rows - 1,
    home = -#lines, ["end"] = #lines,
  }
  -- Ctrl+C: the whole text into a file, opened in your text editor
  local function as_text()
    local path = (renoise.tool().bundle_path or "") .. spec.name .. " Help.txt"
    local f = io.open(path, "wb")
    if not f then return end
    f:write(table.concat(lines, IS_WINDOWS and "\r\n" or "\n"))
    f:close()
    pcall(function() renoise.app():open_path(path) end)
  end
  local function handler(dlg, key)
    if key.name == "esc" then close(dlg) return nil end
    local m = key.modifier_flags or {}
    if spec.on_key and spec.on_key(key, m) then return nil end
    local lk = tostring(key.name):lower()
    if (m.control or m.meta) and lk == "c" then
      if not key.repeated then as_text() end
      return nil
    end
    local plain = not (m.shift or m.control or m.alt or m.meta)
    if plain and keys[key.name] then
      scroll_to(top + keys[key.name])
      return nil
    end
    return key
  end
  -- Renoise wants both key options as booleans; without them, plain
  local title = spec.title or (spec.name .. " - Help")
  local ok, dlg = pcall(function()
    return renoise.app():show_custom_dialog(title, content, handler,
      { send_key_repeat = true, send_key_release = false })
  end)
  if not ok or not dlg then
    dlg = renoise.app():show_custom_dialog(title, content, handler)
  end
  spec.dialog = dlg
end

function C.help_text()
  local out = {}
  local function add(...)
    for _, line in ipairs { ... } do out[#out + 1] = line end
  end
  local key, more, head = HELP.key, HELP.more, HELP.head
  local FB = C.FILE_BROWSER
  add(head("Quick Start"),
    "   Pick a folder with the arrow keys, step into its samples with Tab,",
    "   and press Enter to load one as a new instrument. With the",
    "   Multi-Sample panel open, Enter adds it to that instrument instead.",
    "   The window is described below clockwise: top, right, bottom, left.",
    "")
  add(head("Top"),
    key("1 - 8", "Bookmarks: click to go there; right-click (or"),
    more("Shift-click) saves the folder you are in"),
    key("Options", "Settings (also in Tools > Simple Browser > Options)"),
    key("Help", "This window; Ctrl-C (Mac: Cmd-C) in it opens its"),
    more("text to copy"),
    key("Two-column icon", "Two panes (folders | samples) or one list"),
    key("Multi icon", "Show / hide the Multi-Sample panel"),
    "")
  add(head("Right: Multi-Sample"),
    "   The selected instrument; it follows when you select another one (in",
    "   Renoise, or with Alt-Up / Down). Changing the mode maps all samples",
    "   again; keyzones made by hand stay as they are until then.",
    key("Keyboard icon", "Keyjazz: piano keys play the instrument from any"),
    more("pane, not the highlighted sample"),
    key("Name field", "Click it to type a name"),
    key("Enter, Insert", "Add the highlighted sample(s), each as a keyzone"),
    key("Shift-Up, Down", "Move the highlighted sample up / down; the keys"),
    more("stay in row order"),
    key("Right-click", "Play, write note at cursor, move, remove"),
    key("Drumkit", "One key each, from the start note"),
    key("Distribute", "Spread evenly over the keyboard"),
    key("Layer", "Every sample on every key"),
    key("from", "Drumkit's start note"),
    key("White keys", "Drumkit on white keys only"),
    key("Overlap", "Play All / Cycle / Random when samples share a key"),
    key("New", "A new, empty instrument for the next one"),
    key("Remove sample", "The highlighted one (Del or Backspace)"),
    key("Remove all", "Every sample of the instrument (Shift-Del)"),
    "")
  add(head("Bottom: Waveform and Sample Controls"),
    "   Each sample keeps its own loop, also when loaded. The file never",
    "   changes: after a trim, cut or crossfade an edited copy is loaded.",
    key("Click", "Play from that point; drag: select a part"),
    key("Drag loop flag", "Move that loop point"),
    key("Ctrl-Shift-L", "Loop the selection"),
    key("Right-click", "Loop, crossfade, trim, cut, snap to zero"),
    more("crossings, back to the file"),
    key("Rings", "Bottom right: one ring mono, two rings stereo"),
    key("Volume", "Speaker icon: auto-prehear on / off; the bar: the"),
    more("prehear volume"),
    key("Panning", "50 L .. Center .. 50 R of the highlighted sample"),
    key("Octave", "Renoise's global octave: the piano keys play from it"),
    key("Semitone", "Pitch of the highlighted sample: a file keeps it"),
    more("when loaded; a Multi-Sample row changes that sample"),
    key("Fine tune", "The same in Renoise's fine tune steps (-127 .. 127)"),
    key("Loop", "Off / Forward / Reverse / PingPong of this sample:"),
    more("Off until it has a loop (from the file, a loop flag,"),
    more("Ctrl-Shift-L or a crossfade), then Forward"),
    key("Crossfade icon", "Crossfade the loop; a selection becomes the loop"),
    more("first"),
    key("Beatsync", "Fit samples a beat or longer to the song tempo (the"),
    more("check box). The box is the length in lines: set your own"),
    more("(Off / 0: the browser's own choice; a Multi-Sample row:"),
    more("its Beatsync off)"),
    key("T", "Set Semitone and Fine tune so the sample lasts that"),
    more("many lines at the song tempo, as Renoise's T"),
    key("Mode", "Repitch / Percussion / Texture"),
    key("Interpolation", "None / Linear / Cubic / Sinc of every sample played"),
    more("and loaded"),
    key("Output", "Prehear on the Master track or the selected track"),
    "   The pitch, panning and Beatsync boxes play the sample again after",
    "   a change when Options > Prehear after changing ... is on.",
    "")
  add(head("Left: Folders and Samples"),
    key("Folder icon", "Root home, set root, folder paths, hidden items,"),
    more("rescan, show in " .. FB),
    key("Spyglass", "Find: type in that header, results in the pane"),
    key("[ this folder ]", "The samples of that folder itself"),
    key("Folder Paths", "The root and added folders: Left in the root"),
    more("lists them"),
    key("(... missing)", "The root is not there: folder icon > Rescan"),
    key("Right-click", "Load, load + write a note, add to Multi-Sample,"),
    more("hide, show in " .. FB),
    key("Double-click", "Load a sample, as Enter does"),
    key("Shift-click", "Select several samples"),
    "")
  add(head("Browsing Keys"),
    key("Up, Down", "Move (also PgUp, PgDn, Home, End)"),
    key("Right", "Into a folder or its samples, on to Multi-Sample"),
    key("Left", "Back to the folders, or up a folder (also"),
    more("Backspace)"),
    key("Tab, Shift-Tab", "Next / previous pane"),
    key("Enter", "Open a folder; load a sample as a new instrument"),
    more("(Multi-Sample panel open: add it to that instrument)"),
    key("Shift-Enter", "Replace the selected instrument's selected sample"),
    more("(also the key binding Replace Selected Sample; the"),
    more("instrument is renamed unless you named it)"),
    key("Insert", "Add a sample, a selection or a folder to the"),
    more("Multi-Sample (no Insert key, as on a Mac: bind"),
    more("Multi-Sample - Add Highlighted Sample)"),
    key("Shift-Up, Down", "Select several samples"),
    key("Alt-Up, Down", "Previous / next instrument (Mac: Option)"),
    key("Piano keys", "Play at the global octave (a key stops a prehear)"),
    key("Space, Esc, F1", "Work as usual in Renoise, as do your own keys"),
    key("Browser key", "Open; when Renoise has the keys: focus the"),
    more("browser again; else close (Preferences > Keys)"),
    key("Find key", "Type to search, Down goes in, Esc cancels; again:"),
    more("refine the search"),
    "")
  add(head("Controls Mode"),
    key("Caps Lock", "Into controls mode and back to browsing (or the"),
    more("Toggle Controls Mode key)"),
    key("Arrows", "The nearest control that way; past the edge they"),
    more("go on round the window"),
    key("Tab, Shift-Tab", "Next / previous control in reading order"),
    key("Enter", "Press a button; on a value: the arrows change it,"),
    more("Enter keeps it, Esc puts it back"),
    "")
  add(head("Find"),
    "   Searches file and folder names in the folder path you are in (or",
    "   only the current folder, see Options). Hidden items are skipped.",
    "   A-Z ignores case; accented and other characters match as typed.",
    key("kick 909", "Both words"),
    key("kick or snare", "Either word (also: kick | snare)"),
    key("-loop, not loop", "Leave out names with \"loop\""),
    key("\"tr 909\"", "The exact phrase, spaces included"),
    key("kick*.wav", "* any text, ? any one character"),
    key("Backspace", "Remove the last character"),
    "")
  add(head("Undo"),
    key("Ctrl-Z, Ctrl-Y", "Undo / redo (Mac: Cmd-Z, Cmd-Shift-Z) of settings,"),
    more("loops and sample edits, Multi-Sample changes and"),
    more("loads: one history while the browser is open."),
    more("While the browser has the keys, Ctrl-Z is its own"),
    more("undo, not Renoise's."),
    "")
  add(head("Options (Options window, also Tools > Simple Browser > Options)"))
  local option_group
  for _, o in ipairs(C.OPTIONS) do
    if o.group ~= option_group then
      option_group = o.group
      add("", "   " .. option_group)
    end
    if o.items then
      add(key(o.label, table.concat(o.items, " / "), 24))
    else
      add("   " .. o.label)
    end
  end
  add("")
  HELP.bindings(add, C.BINDINGS, TOOL_NAME)
  return table.concat(out, "\n")
end

C.HELP_SPEC = {
  name = TOOL_NAME,
  title = TOOL_NAME .. " " .. C.VERSION .. " - Help",
  heading = TOOL_NAME .. " " .. C.VERSION,
  text = function() return C.help_text() end,
  credits = {
    { "simple browser " .. C.VERSION .. "  ", "by phaos & claude" },
  },
  owner = function() return dialog_open() and S.dialog or nil end,
  on_key = function(key, m)                 -- the browser's undo, while open
    return dialog_open() and C.undo_key(key, m)
  end,
}
function C.toggle_help(button) HELP.toggle(C.HELP_SPEC, button) end


--------------------------------------------------------------------------------
-- Keyboard
--
-- The browser only keeps the keys it needs: unmodified arrows, Home/End,
-- PgUp/PgDn, Backspace, Tab, Enter, Insert/Del, Caps Lock, piano keys,
-- plus Shift+Enter, Shift+Tab, Shift+Up/Down, Alt+Up/Down and Shift+Del in
-- the Multi-Sample. Every other key - Space, Esc, F-keys, anything with
-- Ctrl/Cmd/Alt, your octave keys - goes back to Renoise, so transport,
-- edit mode and your key bindings keep working.
--------------------------------------------------------------------------------

local close_browser  -- forward declaration

-- keys that only mean something in a list
C.LIST_KEYS = { home = true, ["end"] = true, prior = true, next = true,
  pageup = true, pagedown = true, back = true, ins = true, insert = true,
  del = true, delete = true }

C.REPEATABLE = {
  up = true, down = true, prior = true, next = true,
  pageup = true, pagedown = true,
}

local function modifiers_of(key)
  local f = key.modifier_flags
  if f then
    return { shift = f.shift and true or false,
             control = f.control and true or false,
             alt = f.alt and true or false,
             meta = f.meta and true or false }
  end
  local m = key.modifiers or ""
  return { shift = m:find("shift") ~= nil, control = m:find("control") ~= nil,
           alt = m:find("alt") ~= nil, meta = m:find("command") ~= nil
                                            or m:find("meta") ~= nil }
end

local function is_key(name, ...)
  for _, n in ipairs { ... } do if name == n then return true end end
  return false
end

local function handle_key(dlg, key)
  local name = key.name

  -- key release: stop the note that this key started
  if key.state == "released" then
    release_id("key:" .. tostring(name))
    C.kit_released("key:" .. tostring(name))
    return nil
  end
  C.want_sample = nil      -- you took over: a pending restore must not jump

  local m = modifiers_of(key)
  local only_shift = m.shift and not (m.control or m.alt or m.meta)
  local only_alt = m.alt and not (m.control or m.shift or m.meta)
  local no_mods = not (m.shift or m.control or m.alt or m.meta)

  -- Ctrl+Z / Ctrl+Y (Cmd on a Mac; also Ctrl+Shift+Z): the browser's undo
  -- and redo - never the song's while the browser has the keys
  -- a value being changed: 'Ctrl'+'Z' puts it back, like 'Esc'
  if (m.control or m.meta) and S.ctl_edit
     and tostring(name):lower() == "z" and not m.shift then
    C.end_edit(false)
    C.ctl_status()
    return nil
  end
  if C.undo_key(key, m) then return nil end

  -- Ctrl+Shift+L, as in Renoise's sample editor: loop the selection
  if (m.control or m.meta) and m.shift and not m.alt
     and tostring(name):lower() == "l" and S.sel_range then
    if not key.repeated then C.loop_to_selection() end
    return nil
  end

  -- Caps Lock: browsing <-> controls mode
  -- (Renoise does not document this key's name: accept every spelling)
  if m.alt or m.control or m.meta then S.passed_at = now() end
  local lname = tostring(name):lower():gsub("[%s_%-]", "")
  if (lname:find("caps", 1, true) or lname == "capital")
     and not (m.alt or m.control or m.meta) then   -- Alt+Caps etc: Renoise
    if not key.repeated then C.toggle_ctl_mode() end
    return nil
  end

  -- typing a search: letters, Backspace, Enter, Esc go to the search
  if S.find and S.find.typing and F.key(key, m) then return nil end

  local P = S.focus

  -- Tab / Shift+Tab: the next / previous pane; in controls mode the next /
  -- previous control (held: repeats there)
  if name == "tab" and (no_mods or only_shift) then
    if S.ctl_mode then C.ctl_tab(only_shift)
    elseif not key.repeated then switch_focus(only_shift) end
    return nil
  end

  -- keyjazz: unmodified piano keys at the global octave. In the kit panel
  -- they play the kit instrument, elsewhere the highlighted sample.
  if key.note ~= nil and no_mods then
    if key.repeated then return nil end
    local note = key.note + renoise.song().transport.octave * 12
    local kit, kinst = C.kit_index()
    if (P == K or (prefs.kit_keyjazz.value and prefs.show_kit.value)) and kinst and #kinst.samples > 0 then
      release_id("preview")
      trigger("key:" .. tostring(name), note, kit)
      C.kit_played("key:" .. tostring(name), note)
    else
      release_id("preview")   -- a key cuts the prehear: a tap stops a loop
      ensure_selected_loaded()
      trigger("key:" .. tostring(name), note)
    end
    return nil
  end

  -- Alt+Up/Down: select instrument (skipping the preview instruments)
  if only_alt and (name == "up" or name == "down") then
    step_instrument(name == "up" and -1 or 1)
    return nil
  end

  -- controls mode (Caps Lock)
  if S.ctl_mode then
    if not no_mods then S.passed_at = now() return key end
    if key.repeated and is_key(name, "return", "enter", "esc") then
      return nil
    end
    if C.ctl_key(name) then return nil end
    if C.LIST_KEYS[name] then return nil end   -- nothing to move here
    return key                                 -- Space, Esc ... to Renoise
  end

  -- Shift+Enter: replace the selected instrument's selected sample slot
  if only_shift and is_key(name, "return", "enter") then
    if not key.repeated then activate(true) end
    return nil
  end

  -- kit editing with Shift
  if P == K and only_shift then
    if name == "up" then kit_move(-1) return nil end
    if name == "down" then kit_move(1) return nil end
    if is_key(name, "del", "delete", "back") then
      if not key.repeated then kit_clear() end
      return nil
    end
  end

  -- Shift+Up/Down in the folder / samples panes: extend the selection
  if P ~= K and only_shift and (name == "up" or name == "down") then
    if not P.anchor then P.anchor = P.sel end
    local idx = clamp(P.sel + (name == "up" and -1 or 1), 1, #P.entries)
    C.mark_range(P, idx)
    set_selection(P, idx, true, true)
    return nil
  end

  -- everything else with a modifier belongs to Renoise
  if not no_mods then S.passed_at = now() return key end

  if key.repeated and not C.REPEATABLE[name] then return nil end

  -- a plain move ends a selection and starts the next one from here
  if name == "up" or name == "down" or name == "home" or name == "end"
     or is_key(name, "prior", "pageup", "next", "pagedown") then
    C.clear_marks(P)
  end
  if name == "up" then
    set_selection(P, P.sel - 1, true)
  elseif name == "down" then
    set_selection(P, P.sel + 1, true)
  elseif name == "home" then
    set_selection(P, 1, true)
  elseif name == "end" then
    set_selection(P, #P.entries, true)
  elseif is_key(name, "prior", "pageup") then
    set_selection(P, P.sel - (P.rows - 1), true)
  elseif is_key(name, "next", "pagedown") then
    set_selection(P, P.sel + (P.rows - 1), true)
  elseif S.find and P == L and F.pane() == L
         and (name == "left" or name == "back") then
    F.stop()   -- out of the results, back to the folder
  elseif name == "left" then
    if P == K then
      set_focus((two_pane() and #R.entries > 0) and R or L)
    elseif P == R then
      set_focus(L)
    else
      go_up()
    end
  elseif name == "back" then
    if P == K then kit_remove_selected() else go_up() end
  elseif name == "right" then
    local e = P.entries[P.sel]
    if P == L and e and e.is_dir then
      -- two panes: into a folder that has sub folders, else into its
      -- samples ('Tab' always goes to the samples)
      if two_pane() and (e.here or not e.up
         and not C.has_subfolders(e.full or join(S.path, e.name))) then
        enter_samples()
      else
        enter_selected_dir()
      end
    elseif P == L and two_pane() and not e then
      enter_samples()
    elseif P ~= K and prefs.show_kit.value then
      -- a sample: on to the Multi-Sample (piano keys play the sample) - when
      -- it has samples; an empty list has nothing to select there
      if #K.entries > 0 then
        set_focus(K)
        if K.sel == 0 then set_selection(K, 1, false, true) end
      else
        set_status("The Multi-Sample is empty - 'Enter' or 'Insert' adds the "
                   .. "highlighted sample")
      end
    end
  elseif is_key(name, "return", "enter") then
    activate(false)
  elseif is_key(name, "ins", "insert") then
    add_highlighted_to_kit()
  elseif is_key(name, "del", "delete") then
    if P == K then kit_remove_selected() else return key end
  else
    return key   -- Space, Esc, F-keys, numpad ... stay with Renoise
  end
  return nil
end


--------------------------------------------------------------------------------
-- Dialog lifecycle
--------------------------------------------------------------------------------

local idle_watch  -- forward declaration

local function on_octave_changed()
  local v = view("octave")
  if v then
    local o = renoise.song().transport.octave
    if v.value ~= o then v.value = o end
  end
end

local function observe(obs, fn, add)
  pcall(function()
    if add then
      if not obs:has_notifier(fn) then obs:add_notifier(fn) end
    elseif obs:has_notifier(fn) then
      obs:remove_notifier(fn)
    end
  end)
end

-- the octave as an undoable setting (it lives in the song, so it is
-- watched while the browser is open)
C.octave_watch = C.make_watch("octave", "Octave",
  function() return renoise.song().transport.octave end,
  function(v) renoise.song().transport.octave = v end)

local function song_observables()
  local song = renoise.song()
  local list = { { song.transport.octave_observable, on_octave_changed },
                 { song.transport.octave_observable, C.octave_watch },
                 { song.instruments_observable, C.instruments_changed } }
  return list
end

local function cleanup()
  observe(renoise.tool().app_idle_observable, idle_watch, false)
  for _, t in ipairs { preview_timer, contents_timer, scan_timer,
                       playhead_timer, wave_timer, F.timer, F.retype } do
    remove_timer(t)
  end
  pcall(function()
    for _, o in ipairs(song_observables()) do observe(o[1], o[2], false) end
  end)

  release_all()
  remove_scratch()
  scan_job = nil
  S.loaded_path = nil
  S.sliced = false
  S.wave = nil
  S.wave_sample, S.wave_instrument, S.kit_wave_dirty = nil, nil, false
  S.wave_from_kit = false
  S.kit_lit = {}
  S.ops = {}                         -- sample changes end with the window
  C.clear_undo()                     -- and so does their history
  S.lit_frame = nil
  S.play = nil
  S.info_path, S.info = nil, nil
  S.dialog = nil
  S.ctl, S.ctl_mode, S.ctl_edit, S.ctl_last = nil, false, nil, nil
  S.find = nil                       -- a search does not outlive the window
  L.truncated = false
  pcall(function() if C.opt_dlg and C.opt_dlg.visible then C.opt_dlg:close() end end)
  pcall(function() if C.theme_close then C.theme_close() end end)
  S.vb = nil
  S.wave_view, S.playhead_view = nil, nil
  R.dir, R.entries, R.sel, R.top = nil, {}, 0, 1
  R.scanning, R.truncated = false, false
  -- Beatsync ends with the window too, unless you keep it (Options); its
  -- mode stays, for the next time it is turned on
  if not prefs.sync_keep.value and prefs.sync_tempo.value then
    S.silent = true                  -- not a change to undo
    prefs.sync_tempo.value = false
    S.silent = false
  end
end

close_browser = function()
  if S.dialog then
    pcall(function()
      if S.dialog.visible then S.dialog:close() end
    end)
  end
  cleanup()
end

-- There is no "dialog closed" callback, so poll for it (cheap boolean read).
idle_watch = function()
  if S.dialog and not S.dialog.visible then cleanup() return end
  if S.dialog then pcall(C.show_pitch) end
  -- the Multi-Sample follows the instrument selected in Renoise
  if S.dialog and prefs.show_kit.value then
    local ok, err = pcall(K.sync)
    if not ok then set_status("Multi-Sample: " .. tostring(err)) end
    if S.kit_wave_dirty and S.wave_from_kit and S.wave_kit_row then
      C.kit_show(S.wave_kit_row)
    end
  end
end

-- Build a view with optional extras (mouse handlers etc.); if this Renoise
-- build rejects them, fall back to the plain version.
local function try_view(fancy, plain)
  local ok, v = pcall(fancy)
  if ok and v then return v end
  if plain then
    local ok2, v2 = pcall(plain)
    if ok2 then return v2 end
  end
  return nil
end

-- A control in a frame that lights up when controls mode (Caps Lock) is
-- on it: the focus colour, the edit colour while its value changes - the
-- same theme colours a focused button gets. Popups, value boxes and the
-- like cannot be coloured themselves. The frame is always part of the
-- layout (C.FRAME px round the control) and simply drawn empty when not
-- focused, so focusing never moves anything.
C.FRAME = 2
function C.framed(vb, kind, props)
  local F = C.FRAME
  local w = props.width
  local h = props.height or C.ROW_HEIGHT
  local fid = "frame_" .. props.id
  local frame = w and try_view(function()
    return vb:canvas {
      id = fid, width = w + 2 * F, height = h + 2 * F, mode = "transparent",
      render = function(ctx)
        if S.lit_frame ~= fid then return end
        local cw, ch = ctx.size.width, ctx.size.height
        local editing = S.ctl_edit ~= nil and S.ctl ~= nil and S.ctl.id == props.id
        paint(ctx, "fill_color", editing and C.EDIT or C.FOCUS)
        ctx:fill_rect(0, 0, cw, F)
        ctx:fill_rect(0, ch - F, cw, F)
        ctx:fill_rect(0, 0, F, ch)
        ctx:fill_rect(cw - F, 0, F, ch)
      end,
    }
  end) or nil
  local control = vb[kind](vb, props)
  if not frame then return C.pad(vb, control) end
  return try_view(function()
    local st = vb:stack {}
    st:add_child(frame)
    st:add_child(control)
    control.origin = { x = F, y = F }
    return st
  end) or C.pad(vb, control)
end

-- the same room round a view that has no frame, so a row of framed and
-- plain views lines up
function C.pad(vb, v)
  return vb:column { margin = C.FRAME, v }
end

--------------------------------------------------------------------------------
-- List mouse helpers
--------------------------------------------------------------------------------

-- list row under the mouse (rows and Multi-Sample key cells)
function C.hover_row(P, ev)
  for _, h in ipairs(ev.hover_views or {}) do
    local id = tostring(h.id or "")
    local row = tonumber(id:match("^" .. P.key .. "row(%d+)$"))
             or (P == K and tonumber(id:match("^kkey(%d+)$")))
    if row then return row end
  end
  return nil
end

--------------------------------------------------------------------------------
-- "Drop on the pattern": load, then write a note at the edit cursor
--------------------------------------------------------------------------------

-- note `note` of instrument `idx` at the pattern editor's cursor; the
-- cursor then moves down by the edit step, as when typing a note
-- returns how to take it back / do it again (see C.note_put)
function C.write_note(idx, note, several)
  local song = renoise.song()
  local track = song.selected_track
  if track.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
    error("select a track (not a group, send or the master) first", 0)
  end
  C.loud("Write note")
  local col = song.selected_note_column_index
  if not col or col < 1 then col = 1 end
  if track.visible_note_columns < col then track.visible_note_columns = col end
  local nc = song.selected_line:note_column(col)
  local rec = { nc = nc, line = song.selected_line_index,
                old = { nc.note_value, nc.instrument_value },
                new = { clamp(note, 0, 119), idx - 1 } }
  nc.note_value = rec.new[1]
  nc.instrument_value = rec.new[2]
  local step = song.transport.edit_step or 0
  if several then step = math.max(1, step) end   -- one line each
  if step > 0 then
    song.selected_line_index = math.min(song.selected_line_index + step,
                                        song.selected_pattern.number_of_lines)
  end
  return rec
end

-- take a written note back (which = "old") or write it again ("new")
function C.note_put(rec, which)
  pcall(function()
    rec.nc.note_value = rec[which][1]
    rec.nc.instrument_value = rec[which][2]
    renoise.song().selected_line_index = rec.line
  end)
end

-- the highlighted sample(s) as new instruments, each with a note at the
-- cursor; in the Multi-Sample: a note of it, at the highlighted row's key
function C.load_to_pattern()
  if not dialog_open() then return end
  local P = S.focus
  local function base_note(idx)
    local note = 48
    pcall(function()
      note = renoise.song():instrument(idx):sample(1).sample_mapping.base_note
    end)
    return note
  end
  local ok, err = pcall(function()
    local song = renoise.song()
    if P == K then                  -- the Multi-Sample: its highlighted key
      local idx = C.kit_index()
      if not idx or #K.entries == 0 then error("the Multi-Sample is empty", 0) end
      local rec = C.write_note(idx, C.kit_row_note(K.sel))
      C.push_undo {
        name = "Write note",
        undo = function() C.note_put(rec, "old") end,
        redo = function() C.note_put(rec, "new") end,
      }
      set_status("Wrote " .. note_name(C.kit_row_note(K.sel)) .. " at the cursor")
      return
    end
    local files = C.marked_files(P)
    if #files < 2 then
      local e = P.entries[P.sel]
      if not e or e.is_dir then error("highlight a sample first", 0) end
      files = { e }
    end
    local done = 0
    for _, e in ipairs(files) do
      if load_as_new_instrument(entry_path(P, e)) then
        local idx = song.selected_instrument_index
        local rec = C.write_note(idx, base_note(idx), #files > 1)
        -- one step: the load and its note
        local e2 = C.undo_top()
        if e2 then
          local undo, redo = e2.undo, e2.redo
          e2.name = e2.name .. " + note"
          e2.undo = function(self) C.note_put(rec, "old") undo(self) end
          e2.redo = function(self) redo(self) C.note_put(rec, "new") end
        end
        done = done + 1
      end
    end
    if done == 0 then return end              -- "Load failed" says why
    set_status(string.format("Loaded %d sample%s and wrote %s at the cursor",
      done, done == 1 and "" or "s", done == 1 and "a note" or "notes"))
  end)
  if not ok then set_status("Load to pattern: " .. tostring(err)) end
end

local function build_panel(vb, P)
  local list_width = P.width - SCROLLBAR_WIDTH

  local function wheel(ev)
    if ev.type == "wheel" then
      if ev.direction == "up" then
        scroll_panel(P, P.top - C.WHEEL_ROWS)
      elseif ev.direction == "down" then
        scroll_panel(P, P.top + C.WHEEL_ROWS)
      end
      return nil
    end
    -- right-click: the row is highlighted on press, its menu opens on
    -- release (opened on the press, the release could close it again -
    -- above all while a pane change is still being drawn)
    if ev.button == "right" and (ev.type == "down" or ev.type == "up") then
      local row = C.hover_row(P, ev)
      if ev.type == "down" then
        S.menu_at = row and { P = P, row = row } or nil
        if row then C.row_pick(P, row) end
      elseif S.menu_at and S.menu_at.P == P then
        local at = S.menu_at
        S.menu_at = nil
        row_menu(P, at.row)
      end
      return nil
    end
    return ev
  end

  -- mouse wheel scrolling where supported; rows are added afterwards so a
  -- failed first attempt cannot leave duplicate view ids behind
  local list = try_view(
    function()
      return vb:column { spacing = 0, style = "border", margin = 1,
                         mouse_handler = wheel,
                         mouse_events = { "wheel", "down", "up" } }
    end,
    function()
      return vb:column { spacing = 0, style = "border", margin = 1 }
    end)
  -- the Multi-Sample list is always built for its most rows; two panes
  -- hide the last ones (C.apply_kit_rows)
  local built = (P == K) and (VISIBLE_ROWS + KIT_EXTRA + 2) or P.rows
  local shown, extra = built, 0
  if P == K then shown, extra = C.kit_shape() end
  for i = 1, built do
    local btn = vb:button {
      id       = P.key .. "row" .. i,
      width    = list_width - (P == K and C.KEY_W or 0),
      height   = C.ROW_HEIGHT,
      text     = "",
      notifier = function() on_row_click(P, i) end,
    }
    -- set after creation so an older API without these just skips them
    pcall(function() btn.align = "left" end)
    if P == K then
      -- [key] cell + name: the names all start at the same place
      pcall(function() btn.font = "bold" end)
      local key = vb:button {
        id = "kkey" .. i, width = C.KEY_W, height = C.ROW_HEIGHT, text = "",
        notifier = function() on_row_click(P, i) end,
      }
      pcall(function() key.font = "bold" end)
      list:add_child(vb:row { id = "krowc" .. i, visible = i <= shown, key, btn })
    else
      list:add_child(btn)
    end
  end
  -- the Multi-Sample list is one sample-panel row (C.ROW_H) longer than
  -- the rows alone: the last 4 px are room under the last row
  if P == K then
    list:add_child(vb:space { id = "kextra", height = math.max(1, extra), visible = extra > 0 })
  end
  local sb_height = shown * C.ROW_HEIGHT + 2 + extra

  local sb_slot = vb:column {
    vb:space { id = P.key .. "sbspace", width = SCROLLBAR_WIDTH,
               height = sb_height },
  }
  local sb = try_view(function()
    return vb:scrollbar {
      id       = P.key .. "sb",
      width    = SCROLLBAR_WIDTH,
      height   = sb_height,
      min      = 0,
      max      = 100,
      pagestep = 100,
      step     = 1,
      value    = 0,
      visible  = false,
      notifier = function(v)
        if S.updating_sb then return end
        scroll_panel(P, v + 1)
      end,
    }
  end)
  if sb then
    pcall(function() sb.background = "border" end)  -- dark, like the lists
    sb_slot:add_child(sb)
  end

  -- a header per pane, 2 px taller than a row on each side (the room a
  -- focused control's frame takes), so all lists start level
  local header
  if P == K then
    local kj = vb:button {
      id = "kit_keyjazz", width = C.ICON_W, height = 18, text = "Kj",
      tooltip = "Keyjazz the Multi-Sample: piano keys play this instrument "
             .. "from every pane, not the highlighted sample (lit = on)\n"
             .. "(key binding: Global > Simple Browser > Multi-Sample - "
             .. "Toggle Keyjazz)",
      notifier = function() C.toggle_kit_keyjazz() end,
    }
    if C.set_icon(kj, "keyjazz") then
      kj.text = ""
    end
    header = vb:row {
      C.pad(vb, kj),
      C.pad(vb, vb:text { id = "kit_num", text = "--", width = C.NUM_W,
                          font = "bold", tooltip = "Instrument number" }),
      C.framed(vb, "textfield", {
        id = "kit_name",
        width = list_width - (C.ICON_W + 4) - (C.NUM_W + 4) - (C.COUNT_W + 4) - 4,
        value = "",
        tooltip = "The selected instrument's name. Click to type: while "
               .. "typing, keys write text instead of playing notes.",
        notifier = function(v)
          if not S.updating_name then C.kit_rename(v) end
        end,
      }),
      C.pad(vb, vb:text { id = "kcount", text = "[0/0]", width = C.COUNT_W,
                          align = "right" }),
    }
  else
    -- L and R: the search icon starts the header where its text appears
    -- (only the pane that shows the results has it; see apply_layout);
    -- the folder pane starts with the folder icon
    local find_btn = vb:button {
      id = "find_btn_" .. P.key, width = C.ICON_W, height = 18, text = "F",
      visible = (P == R) == two_pane(),
      tooltip = "Find: type right here; 'Down' or 'Enter' goes into the "
             .. "results, 'Esc' ends the search.\n"
             .. "Click it again later to refine the search.\n"
             .. "(key binding: Global > Simple Browser > Find)",
      notifier = function() C.find_click() end,
    }
    if C.set_icon(find_btn, "find") then find_btn.text = "" end
    header = vb:row { margin = C.FRAME, spacing = 4 }
    if P == L then
      local fb = vb:button {
        id = "folder_btn", width = C.ICON_W, height = 18, text = "D",
        tooltip = "Folders: root home, set the root, folder paths, hidden "
               .. "items, rescan, show in " .. C.FILE_BROWSER .. "\n"
               .. "(key binding: Global > Simple Browser > Show Folder Menu)",
        notifier = function() C.folder_menu() end,
      }
      if C.set_icon(fb, "folder") then fb.text = "" end
      header:add_child(fb)
    end
    header:add_child(find_btn)
    header:add_child(vb:text { id = P.key .. "head", text = "",
                               width = C.head_w(P, P == L and 2 or 1) })
    header:add_child(vb:text { id = P.key .. "count", text = "[0/0]",
                               width = C.COUNT_W, align = "right" })
  end

  return vb:column {
    spacing = 2,
    header,
    vb:row { list, sb_slot },
  }
end

local function build_ui()
  local vb = renoise.ViewBuilder()
  S.vb = vb

  local MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
  local SP     = spacing()
  local H      = C.ROW_HEIGHT

  -- an icon button: Renoise's own icon (else ours from Images), text if
  -- neither loads
  local function icon_button(props, key, fallback)
    props.text = fallback
    local b = vb:button(props)
    if C.set_icon(b, key) then b.text = "" end
    return b
  end
  local function pad(v) return C.pad(vb, v) end

  ------------------------------------------------------------------ the top
  -- one row in every layout: bookmarks 1-8 on the left (like Renoise's
  -- view preset buttons), the window's buttons on the right
  local bm_row = try_view(function()
    return vb:row {
      spacing = C.BM_SP,
      mouse_events = { "down" },
      mouse_handler = function(ev)
        if ev.type == "down" and ev.button == "right" then
          for _, h in ipairs(ev.hover_views or {}) do
            local i = tonumber(tostring(h.id or ""):match("^bm(%d)$"))
            if i then BM.save(i) return nil end
          end
        end
        return ev
      end,
    }
  end, function() return vb:row { spacing = C.BM_SP } end)
  for i = 1, 8 do
    bm_row:add_child(vb:button {
      id = "bm" .. i, text = tostring(i), height = H, width = C.BM_W,
      notifier = function()
        local shift = false
        pcall(function() shift = renoise.app().key_modifier_flags.shift end)
        if shift then BM.save(i) else BM.go(i) end
      end,
    })
  end
  -- justified: the bookmarks flush left, the buttons flush right, over
  -- exactly the panes' width (C.top_row_layout), whatever size Renoise
  -- draws them
  local row_a = vb:horizontal_aligner {
    id = "row_a", mode = "justify", width = C.edge(),
    bm_row,
    vb:row {
      spacing = SP,
      vb:button {
        id = "btn_options", text = "Options", width = C.OPT_W, height = H,
        tooltip = "Browser settings: panes, Multi-Sample, default loop, "
               .. "folders and find\n(also in Tools > Simple Browser > "
               .. "Options)",
        notifier = function() C.toggle_options(true) end,
      },
      vb:button {
        id = "btn_help", text = "Help", width = C.HELP_W, height = H,
        tooltip = "How to use the browser + all keys\n"
               .. "(key binding: Global > Simple Browser > Show Help)",
        notifier = function() C.toggle_help(true) end,
      },
      icon_button({
        id = "pane_btn", width = C.ICON_W, height = H,
        tooltip = "Two panes (folders | samples) or one list (lit = two)\n"
               .. "(key binding: Global > Simple Browser > Toggle Single Pane)",
        notifier = function() toggle_contents() end,
      }, "panes", "2"),
      icon_button({
        id = "multi_btn", width = C.ICON_W, height = H,
        tooltip = "Multi-Sample panel: show / hide (lit = shown)\n"
               .. "(key binding: Global > Simple Browser > Multi-Sample - "
               .. "Toggle Panel)",
        notifier = toggle_kit,
      }, "multi", "M"),
    },
  }

  ------------------------------------------------- the sample panel (left)
  -- One boxed panel under the waveform (see C.LAYOUT; C.place_cells puts
  -- the cells in its rows). Every cell is a label, left-aligned in its
  -- column, then its control; cells sit at the left of their column, so
  -- the labels and the controls each start on a straight edge. Each control
  -- has 2 px around it (C.framed / C.pad), so the focus frame of controls
  -- mode never moves anything.
  S.cells = {}
  local function cell(k, ...)
    local r = vb:row {
      pad(vb:text { id = "lbl_" .. k, text = C.LABELS[k],
                    width = C.LABEL_PX[k], align = "left" }),
    }
    for _, v in ipairs { ... } do r:add_child(v) end
    S.cells[k] = vb:horizontal_aligner { id = "cell_" .. k, mode = "left",
                                         width = 100, r }
  end
  local W1 = C.CW - 4                       -- a control block, without its round
  -- left: hearing it
  cell("prehear",
    pad(icon_button({
      id = "speaker", width = C.ICON_W, height = H,
      tooltip = "Auto-prehear: play a sample as soon as it is highlighted\n"
             .. "(key binding: Global > Simple Browser > Prehear - "
             .. "Toggle Auto-Prehear)",
      notifier = toggle_autoplay,
    }, prefs.autoplay.value and "prehear_on" or "prehear_off", "P")),
    C.framed(vb, "minislider", {
      id = "prehear_vol", width = W1 - 28, height = H,
      min = 0, max = 1, default = 0.9, bind = prefs.prehear_volume,
      tooltip = "Prehear volume (double-click: back to default)",
    }))
  cell("oct", C.framed(vb, "valuebox", {
    id = "octave", width = W1, height = H, min = 0, max = 8,
    value = renoise.song().transport.octave,
    tooltip = "Renoise's global octave: the piano keys play from it. Your "
           .. "own octave keys work while the browser is open.",
    notifier = function(v)
      if renoise.song().transport.octave ~= v then
        renoise.song().transport.octave = v
      end
    end,
  }))
  cell("output", C.framed(vb, "popup", {
    id = "output", width = W1, height = H, items = C.OUTPUT_ITEMS,
    value = prefs.prehear_master.value and 1 or 2,
    tooltip = "Where the prehear plays: the Master track (as Renoise's own "
           .. "browser), or the selected track and its effects\n"
           .. "(key binding: Global > Simple Browser > Prehear - Toggle "
           .. "Master or Track)",
    notifier = function(v)
      if not S.updating_output then prefs.prehear_master.value = v == 1 end
    end,
  }))
  -- right: how the sample plays
  cell("loop",
    C.framed(vb, "popup", {
      id = "loop", width = W1 - 28, height = H, items = LOOP_ITEMS,
      value = 1,
      tooltip = "Loop of the highlighted sample - it keeps it when you "
             .. "load it. Making a loop (loop flags, Ctrl-Shift-L, "
             .. "crossfade) turns it on for that sample. New samples: "
             .. "Options > Default loop.\n"
             .. "(key binding: Global > Simple Browser > Cycle Loop Mode)",
      notifier = function(v)
        if not S.updating_loop then C.set_loop_mode(v) end
      end,
    }),
    pad(icon_button({
      id = "xfade_btn", width = C.ICON_W, height = H,
      tooltip = "Crossfade the loop, so it loops without a click. A "
             .. "waveform selection becomes the loop first.\n"
             .. "(key binding: Global > Simple Browser > Preview - "
             .. "Crossfade Loop)",
      notifier = function() C.do_xfade() end,
    }, "xfade", "X")))
  cell("interp", C.framed(vb, "popup", {
    id = "interp", width = W1, height = H,
    items = C.INTERP_ITEMS, bind = prefs.default_interp,
    tooltip = "Interpolation of every sample the browser plays and loads "
           .. "(Multi-Sample samples too).\n"
           .. "(key binding: Global > Simple Browser > Cycle "
           .. "Interpolation)",
  }))
  -- Beatsync, as in Renoise: on / off, the length in lines, the mode
  cell("sync",
    C.framed(vb, "checkbox", {
      id = "sync", width = 20, height = H, value = prefs.sync_tempo.value,
      tooltip = "Beatsync: samples a beat or longer are fitted to the song "
             .. "tempo (preview and load). A BPM in the file name, like "
             .. "'loop_120bpm', is used when present.\n"
             .. "(key binding: Global > Simple Browser > Toggle Beatsync)",
      notifier = function(v)
        if not S.updating_sync then prefs.sync_tempo.value = v end
      end,
    }),
    C.framed(vb, "valuebox", {
      id = "slen", width = C.CW - 52, height = H, min = 0, max = 512, value = 0,
      tostring = function(v) return v == 0 and C.sync_zero_text() or tostring(v) end,
      tonumber = function(t)
        t = t:lower()
        if t:match("^%s*[oa]") then return 0 end
        return tonumber(t:match("(%d+)"))
      end,
      tooltip = "Beatsync length of the highlighted sample, in lines (as in "
             .. "Renoise's sample properties). It shows the length Beatsync "
             .. "chose; change it to set your own - a file keeps it when you "
             .. "load it, a Multi-Sample row changes that sample. Auto / 0 "
             .. "goes back to the browser's own choice (a file) or turns "
             .. "its Beatsync off (Off, a Multi-Sample row). A file needs "
             .. "Beatsync on.\n"
             .. "(key bindings: Global > Simple Browser > Sync Length Up / "
             .. "Sync Length Down)",
      notifier = function(v)
        if not S.updating_pitch then C.set_pitch("synclen", v) end
      end,
    }),
    C.framed(vb, "button", {
      id = "sync_t", width = 20, height = H, text = "T",
      tooltip = "Set Semitone and Fine tune so the sample lasts exactly this "
             .. "many lines at the current tempo (Renoise's \"T\" button: "
             .. "an alternative to the Beatsync check box). Undo takes it "
             .. "back.\n"
             .. "(key binding: Global > Simple Browser > Beatsync - Set "
             .. "Pitch to Tempo)",
      notifier = function() C.tempo_tune() end,
    }))
  cell("mode", C.framed(vb, "popup", {
    id = "mode", width = W1, height = H, items = C.MODE_ITEMS,
    bind = prefs.sync_mode,
    tooltip = "Beatsync mode, as in Renoise's sample properties: Repitch / "
           .. "Time-Stretch (Percussion) / Time-Stretch (Texture).\n"
           .. "(key binding: Global > Simple Browser > Cycle Beatsync Mode)",
  }))
  -- the pitch of the highlighted sample (a file: kept when it is loaded; a
  -- Multi-Sample row: that sample itself), see C.pitch_target
  cell("semi", C.framed(vb, "valuebox", {
    id = "semi", width = W1, height = H, min = -120, max = 120, value = 0,
    tostring = function(v) return string.format("%d st", v) end,
    tonumber = function(s) return tonumber(s:match("^%s*([+-]?%d+)")) end,
    tooltip = "Semitone (transpose) of the highlighted sample: a file keeps "
           .. "it when you load it, a Multi-Sample row changes that sample. "
           .. "Prehear plays it at this pitch.\n"
           .. "(key bindings: Global > Simple Browser > Semitone Up / "
           .. "Semitone Down)",
    notifier = function(v)
      if not S.updating_pitch then C.set_pitch("transpose", v) end
    end,
  }))
  cell("fine", C.framed(vb, "valuebox", {
    id = "fine", width = W1, height = H, min = -127, max = 127, value = 0,
    tostring = function(v) return string.format("%d", v) end,
    tonumber = function(t) return tonumber(t:match("^%s*([+-]?%d+)")) end,
    tooltip = "Fine tune of the highlighted sample, as in Renoise's sample "
           .. "properties (-127 .. 127; 127 is almost a semitone).\n"
           .. "(key bindings: Global > Simple Browser > Fine Tune Up / "
           .. "Fine Tune Down)",
    notifier = function(v)
      if not S.updating_pitch then C.set_pitch("fine_tune", v) end
    end,
  }))
  cell("pan", C.framed(vb, "valuebox", {
    id = "pan", width = W1, height = H, min = -50, max = 50, value = 0,
    tostring = function(v) return C.pan_text(v) end,
    tonumber = function(t)
      t = t:lower()
      if t:match("^%s*c") then return 0 end
      local n = tonumber(t:match("(%d+)"))
      if not n then return nil end
      return t:find("l") and -n or n
    end,
    tooltip = "Panning of the highlighted sample, 50 L .. Center .. 50 R: a "
           .. "file keeps it when you load it, a Multi-Sample row changes "
           .. "that sample. Prehear plays it panned.\n"
           .. "(key bindings: Global > Simple Browser > Panning Left / "
           .. "Panning Right)",
    notifier = function(v)
      if not S.updating_pitch then C.set_pitch("panning", v) end
    end,
  }))
  local sample_panel = vb:column {
    id = "sample_panel", style = "group", margin = 1, visible = prefs.show_controls.value,
    vb:row { id = "srow1" }, vb:row { id = "srow2" }, vb:row { id = "srow3" },
    vb:row { id = "srow4" }, vb:row { id = "srow5" },
  }

  local panels = vb:row {
    spacing = SP,
    build_panel(vb, L),
    vb:column { id = "right_panel", visible = two_pane(), build_panel(vb, R) },
  }

  ------------------------------------------------------------- the waveform
  -- a static canvas plus a thin canvas moved as the playhead. Kept as
  -- references (no view ids) so fallbacks cannot clash.
  S.wave_view = try_view(function()
    return vb:canvas {
      width = wave_frame_width() - 2, height = C.wave_h(),
      mode = "plain", render = render_wave,
      tooltip = "Click: play from that point. Drag: select a part.\n"
             .. "Drag a loop flag (top of a loop line): move that loop point.\n"
             .. "Right-click: loop, crossfade, trim, cut, snap to zero "
             .. "crossings, back to the file (the file itself stays untouched)",
      mouse_handler = function(ev)
        local x = ev.position and ev.position.x or 0
        if ev.button == "right" then
          -- on release, like the lists' menus feel: the menu stays open
          if ev.type == "up" then C.wave_menu() end
        elseif ev.type == "down" then
          local w = S.wave_view and S.wave_view.width or 1
          -- on a loop flag (top of a loop line): drag that loop point
          local W, smp = S.wave, C.preview_smp()
          if W and smp and smp.loop_mode ~= 1 and (ev.position.y or 99) <= 10 then
            for _, which in ipairs { "start", "end" } do
              local f = which == "start" and smp.loop_start - 1 or smp.loop_end
              if math.abs(x - f / W.frames * w) <= 5 then
                S.wave_drag = { loop = which }
                return nil
              end
            end
          end
          S.wave_drag = { x0 = x }
          if S.sel_range then S.sel_range = nil redraw_wave() end
          if S.wave_from_kit then C.kit_play_from(x / math.max(1, w))
          else play_from(x / math.max(1, w)) end
        elseif ev.type == "drag" and S.wave_drag and S.wave_drag.loop then
          local f, smp = C.wave_frame(x), C.preview_smp()
          if f and smp then
            if prefs.snap_zero.value then
              f = C.zero_near(smp.sample_buffer, f, 0, 2000) or f
            end
            C.set_loop_point(S.wave_drag.loop, f)
          end
        elseif ev.type == "drag" and S.wave_drag then
          local d = S.wave_drag
          if math.abs(x - d.x0) >= 3 or d.on then
            if not d.on then d.on = true release_id("preview") end
            local a, b = C.wave_frame(d.x0), C.wave_frame(x)
            if a and b then
              S.sel_range = { math.min(a, b), math.max(a, b) }
              redraw_wave()
            end
          end
        elseif ev.type == "up" then
          if S.wave_drag and S.wave_drag.loop then
            C.commit_loop("Loop " .. S.wave_drag.loop)
          end
          S.wave_drag = nil
        end
        return nil
      end,
      mouse_events = { "down", "drag", "up" },
    }
  end, function()
    return vb:canvas {
      width = wave_frame_width() - 2, height = C.wave_h(),
      render = render_wave,
    }
  end)
  S.playhead_view = S.wave_view and try_view(function()
    return vb:canvas {
      width = 2, height = C.wave_h(), visible = false,
      render = render_playhead,
    }
  end) or nil
  local wave = nil
  if S.wave_view then
    wave = try_view(function()
      local st = vb:stack {}
      st:add_child(S.wave_view)
      if S.playhead_view then st:add_child(S.playhead_view) end
      return vb:column { id = "wave_frame", style = "border", margin = 1,
        visible = prefs.show_waveform.value, st }
    end)
    if not wave then S.wave_view, S.playhead_view = nil, nil end
  end

  local bottom_left = vb:column { id = "bottom_left", spacing = SP,
    visible = (wave ~= nil and prefs.show_waveform.value) or prefs.show_controls.value }
  if wave then bottom_left:add_child(wave) end
  bottom_left:add_child(sample_panel)

  -------------------------------------------- the Multi-Sample panel (right)
  -- The same kind of boxed panel under its list, level with the sample
  -- panel and as tall: three rows on a grid of three equal columns.
  --   [ Drumkit         | Distribute       | Layer            ]
  --   [ from [C-4]      | White keys [x]   | Overlap [Play All] ]
  --   [ [New]           | [Remove sample]  | [Remove all]       ]
  local kit_list = KIT_WIDTH - SCROLLBAR_WIDTH + 2     -- the list's frame
  local inner = kit_list - 2                           -- inside the box
  local third = math.floor(inner / 3)
  local thirds = { third, third, inner - 2 * third }
  local is_drum = prefs.kit_mode.value == KIT_DRUM
  local function kcell(i, ...)
    local r = vb:row {}
    for _, v in ipairs { ... } do r:add_child(v) end
    return vb:horizontal_aligner { mode = "left", width = thirds[i], r }
  end
  local function kbutton(i, props)
    props.width, props.height = thirds[i] - 2 * C.FRAME, H
    return pad(vb:button(props))
  end
  local kit_opts = vb:column {
    id = "kit_opts", style = "group", margin = 1, visible = prefs.show_controls.value,
    C.framed(vb, "switch", {
      id = "kit_mode", width = inner - 2 * C.FRAME, height = H,
      items = KIT_MODES, bind = prefs.kit_mode,
      tooltip = "How samples are put on the keys, as Renoise's keyzone "
             .. "buttons:\nDrumkit: one key each, from the start note.\n"
             .. "Distribute: spread evenly over the keyboard.\n"
             .. "Layer: every sample on every key.\n"
             .. "Changing it maps all samples of the instrument again.",
    }),
    vb:row {
      kcell(1, pad(vb:text { id = "kit_from", text = "from" }),
        C.framed(vb, "valuebox", {
          id = "kit_start", width = C.W.box, height = H, min = 0, max = 119,
          bind = prefs.kit_start, active = is_drum,
          tooltip = "Key of the first sample (Drumkit)",
          tostring = function(v) return note_name(v) end,
          tonumber = function(s) return parse_note(s) end,
        })),
      kcell(2, pad(vb:text { id = "lbl_white", text = "White keys" }),
        C.framed(vb, "checkbox", {
          id = "kit_white", bind = prefs.white_keys, width = C.W.check,
          height = H, active = is_drum,
          tooltip = "Drumkit: put samples on white keys only",
        })),
      kcell(3, pad(vb:text { id = "lbl_overlap", text = "Overlap" }),
        C.framed(vb, "popup", {
          id = "kit_overlap", width = C.W.popup, height = H,
          items = OVERLAP_ITEMS, bind = prefs.overlap,
          tooltip = "What a key does when several samples share it: play "
                 .. "all of them, cycle through them, or pick one at random",
        })),
    },
    vb:row {
      kbutton(1, {
        id = "kb_new", text = "New",
        tooltip = "Start a new, empty instrument: 'Enter' then adds samples "
               .. "to it\n(key binding: Global > Simple Browser > "
               .. "Multi-Sample - New Instrument)",
        notifier = function() C.kit_new() end,
      }),
      kbutton(2, {
        id = "kb_remove", text = "Remove sample",
        tooltip = "Remove the highlighted sample from the instrument (Del)\n"
               .. "(key binding: Global > Simple Browser > Multi-Sample - "
               .. "Remove Highlighted Sample)",
        notifier = kit_remove_selected,
      }),
      kbutton(3, {
        id = "kb_clear", text = "Remove all",
        tooltip = "Remove ALL samples from the instrument (Shift-Del)\n"
               .. "(key binding: Global > Simple Browser > Multi-Sample - "
               .. "Remove All Samples)",
        notifier = kit_clear,
      }),
    },
  }
  local kit_col = vb:column {
    id = "kit_col", visible = prefs.show_kit.value, spacing = SP,
    vb:text { id = "kit_label", text = "Multi-Sample", font = "bold",
              height = H },
    vb:column { id = "kit_panel", visible = prefs.show_kit.value,
                build_panel(vb, K) },
    kit_opts,
  }

  local browser_col = vb:column { spacing = SP, row_a, panels, bottom_left }

  S.where, S.layout_mode = {}, nil
  C.place_cells()

  ------------------------------------------------ keyboard: controls mode
  -- Caps Lock switches between browsing and the controls, as in an old DOS
  -- tracker (Schism Tracker, Impulse Tracker): the arrows go to the nearest
  -- control that way and on round the window (C.neighbour); 'Tab' /
  -- 'Shift'+'Tab' go through all of them in reading order. 'Enter'
  -- presses a button, ticks a box, or starts changing a value (with the
  -- arrows that match its shape - see C.vertical; 'Enter' keeps it, 'Esc'
  -- puts it back). Renoise cannot give a tool's controls keyboard focus,
  -- so the browser keeps track of it and lights the control (or its
  -- frame) up itself.
  local function kit_on() return prefs.show_kit.value end
  local function drum_on()       -- "from" and "White keys": Drumkit only
    return kit_on() and prefs.kit_mode.value == KIT_DRUM
  end
  local function pref_stop(t)                 -- a value kept in the prefs
    local o = prefs[t.pref]
    t.get = function() return o.value end
    t.set = function(v) o.value = v end
    return t
  end
  -- in reading order, which is the order of 'Tab': the browser column top
  -- to bottom, left to right, then the Multi-Sample column
  S.stops = {
    -- the top: the window's buttons
    { id = "btn_options", name = "Options",
      act = function() C.later(function() C.toggle_options(true) end) end },
    { id = "btn_help", name = "Help",
      act = function() C.later(function() C.toggle_help(true) end) end },
    { id = "pane_btn", name = "Two panes / one list",
      act = function() toggle_contents() end },
    { id = "multi_btn", name = "Multi-Sample panel", act = toggle_kit },
    -- the pane headers
    { id = "folder_btn", name = "Folders",
      act = function() C.folder_dialog() end },
    { id = "find_btn_l", name = "Find",
      act = function() C.find_click() end },
    { id = "find_btn_r", name = "Find",
      act = function() C.find_click() end },
    -- the sample panel, row by row
    { id = "speaker", name = "Auto-prehear", act = toggle_autoplay },
    pref_stop { id = "prehear_vol", pref = "prehear_volume",
      frame = "frame_prehear_vol", name = "Prehear volume",
      min = 0, max = 1, delta = 0.05 },
    { id = "octave", frame = "frame_octave", name = "Octave", min = 0, max = 8,
      get = function() return renoise.song().transport.octave end,
      set = function(v) renoise.song().transport.octave = v end },
    { id = "pan", frame = "frame_pan", name = "Panning", min = -50, max = 50,
      get = function() local _, p = C.pitch_target() return p and C.PITCH.panning.get(p) or 0 end,
      set = function(v) C.set_pitch("panning", v) end,
      show = function() return C.pitch_text("panning") end },
    { id = "semi", frame = "frame_semi", name = "Semitone", min = -120, max = 120,
      get = function() local _, p = C.pitch_target() return p and p.transpose or 0 end,
      set = function(v) C.set_pitch("transpose", v) end,
      show = function() return C.pitch_text("transpose") end },
    { id = "loop", frame = "frame_loop", name = "Loop", n = #LOOP_ITEMS,
      get = function()
        local smp = C.preview_smp()
        return smp and smp.loop_mode or 1
      end,
      set = function(v) C.set_loop_mode(v) end },
    { id = "xfade_btn", name = "Crossfade loop",
      act = function() C.do_xfade() end,
      show = function()
        if not C.preview_smp() then return "highlight a sample first" end
        if not C.xfade_possible() then
          return "select a part, or make a loop with audio before it"
        end
        return S.sel_range and "the selection" or "the loop"
      end },
    { id = "fine", frame = "frame_fine", name = "Fine tune", min = -127, max = 127,
      get = function() local _, p = C.pitch_target() return p and p.fine_tune or 0 end,
      set = function(v) C.set_pitch("fine_tune", v) end,
      show = function() return C.pitch_text("fine_tune") end },
    { id = "sync", frame = "frame_sync", name = "Beatsync",
      act = function() prefs.sync_tempo.value = not prefs.sync_tempo.value end,
      show = function() return prefs.sync_tempo.value and "on" or "off" end },
    { id = "slen", frame = "frame_slen", name = "Sync length", min = 0, max = 512,
      get = function() return C.pitch_value("synclen") end,
      set = function(v) C.set_pitch("synclen", v) end,
      show = function() return C.pitch_text("synclen") end },
    { id = "sync_t", frame = "frame_sync_t", name = "Pitch to tempo (T)",
      act = function() C.tempo_tune() end },
    pref_stop { id = "interp", pref = "default_interp", frame = "frame_interp",
      name = "Interpolation", n = #C.INTERP_ITEMS },
    pref_stop { id = "mode", pref = "sync_mode", frame = "frame_mode",
      name = "Beatsync mode", n = #C.MODE_ITEMS },
    { id = "output", frame = "frame_output", name = "Prehear output",
      n = #C.OUTPUT_ITEMS,
      get = function() return prefs.prehear_master.value and 1 or 2 end,
      set = function(v) prefs.prehear_master.value = v == 1 end },
    -- the Multi-Sample: its header, mode and settings, buttons
    { id = "kit_keyjazz", when = kit_on, name = "Multi-Sample keyjazz",
      act = function() C.toggle_kit_keyjazz() end },
    { id = "kit_name", frame = "frame_kit_name", when = kit_on,
      name = "Instrument name",
      act = function()
        local tf = view("kit_name")
        if tf then pcall(function() tf.edit_mode = true end) end
      end },
    pref_stop { id = "kit_mode", pref = "kit_mode", frame = "frame_kit_mode",
      when = kit_on, name = "Multi-Sample mode", wide = true,
      n = #KIT_MODES, across = true },          -- side by side: Left / Right
    pref_stop { id = "kit_start", pref = "kit_start", frame = "frame_kit_start",
      when = drum_on, name = "from", min = 0, max = 119 },
    { id = "kit_white", frame = "frame_kit_white", when = drum_on,
      name = "White keys",
      act = function() prefs.white_keys.value = not prefs.white_keys.value end },
    pref_stop { id = "kit_overlap", pref = "overlap", frame = "frame_kit_overlap",
      when = kit_on, name = "Overlap", n = #OVERLAP_ITEMS },
    { id = "kb_new", when = kit_on, name = "New instrument",
      act = function() C.kit_new() end },
    { id = "kb_remove", when = kit_on, name = "Remove sample",
      act = kit_remove_selected },
    { id = "kb_clear", when = kit_on, name = "Remove all",
      act = kit_clear },
  }

  -- the status line runs under everything, the whole window wide
  -- (multi-line, so a narrow window wraps it instead of growing wider)
  return vb:column {
    margin  = MARGIN,
    spacing = SP,
    vb:row { spacing = SP, browser_col, kit_col },
    vb:multiline_text {
      id = "info", text = "", font = "italic", width = C.full_width(),
      height = H,
    },
  }
end

-- Rebuild before showing when the window changes size, including hiding
-- sections: native windows may otherwise retain their previous minimum size.
-- Renoise places the new window on screen; then the old one closes.
function C.reopen_window()
  if not dialog_open() then return false end
  C.end_edit(true)
  local old = S.dialog
  local fields = { "vb", "wave_view", "playhead_view", "stops", "cells",
                   "where", "layout_mode" }
  local keep = {}
  for i, f in ipairs(fields) do keep[i] = S[f] end
  local ok = pcall(function()
    local content = build_ui()
    -- everything in place before it shows: nothing jumps afterwards
    apply_layout()
    BM.states()
    if BM.refresh then BM.refresh() end
    refresh_all()
    refresh_info_box()
    C.show_loop()
    pcall(C.tooltip_keys)
    S.dialog = C.show_dialog(TOOL_NAME, content, handle_key, true)
  end)
  if not ok then                     -- keep using the window we have
    for i, f in ipairs(fields) do S[f] = keep[i] end
    S.dialog = old
    return false
  end
  -- the controls were built anew: controls mode starts over
  S.ctl_mode, S.ctl, S.ctl_edit, S.ctl_last = false, nil, nil, nil
  S.lit_frame = nil
  redraw_wave()
  pcall(function() old:close() end)
  -- closing the old window can hand the focus to Renoise: take it back
  pcall(function() S.dialog:show() end)
  return true
end

-- Where browsing starts: the root (or, when it is not there - a drive not
-- connected, a moved folder - the nearest folder that is, with a warning
-- in the folder pane's header; folder icon > Rescan looks again).
function C.resolve_root()
  local root = norm(prefs.root_folder.value)
  S.missing = nil
  if root ~= "" and dir_exists(root) then return root end
  if root ~= "" then
    S.missing = root
    local near = C.nearest_existing(root)
    if not near then
      for _, p in ipairs(C.extra_places()) do
        if dir_exists(p) then near = p break end
      end
    end
    if not near then
      local home = os.getenv("HOME") or os.getenv("USERPROFILE")
      if home and dir_exists(home) then near = norm(home) end
    end
    if near then
      set_status("Root folder not found: " .. root .. " - browsing "
                 .. near .. " for now")
      return near
    end
  end
  local p = renoise.app():prompt_for_path("Choose sample root folder")
  if not p or p == "" then return nil end
  root = norm(p)
  prefs.root_folder.value = root
  S.missing = nil
  return root
end

function C.reset_default_loop()
  if not prefs.remember_default_loop.value then prefs.default_loop.value = 1 end
end

local function open_browser()
  local root = C.resolve_root()
  if not root then return end
  S.root = root
  C.reset_default_loop()

  -- resolve the start folder
  local start = root
  if prefs.remember_location.value then
    local last = norm(prefs.last_path.value)
    if last ~= "" and C.place_of(last) and dir_exists(last) then
      start = last
    end
  end

  -- the highlights of last time (read before open_dir writes over them)
  C.start_pick, C.want_sample = nil, nil
  local fsel = norm(prefs.last_folder_sel.value)
  if prefs.remember_folder_sel.value then
    if fsel ~= "" then
      if same_path(fsel, start) then
        C.start_pick = { dir = start, off = prefs.last_folder_off.value }
      elseif parent_of(fsel) and same_path(parent_of(fsel), start) then
        C.start_pick = { dir = start, name = basename(fsel),
                         off = prefs.last_folder_off.value }
      end
    end
  end
  local smp = prefs.last_sample.value
  if prefs.remember_sample_sel.value and smp ~= "" then
    C.want_sample = { path = smp, off = prefs.last_sample_off.value,
                      focus = prefs.last_focus.value == 2 }
  end

  S.loaded_path = nil
  S.held = {}
  S.focus = L
  S.ops = {}
  C.clear_undo()
  U.guard = C.history_state()
  R.dir, R.entries, R.sel, R.top = nil, {}, 0, 1
  K.sig, K.idx = nil, nil
  prefs.show_kit.value = prefs.kit_default_open.value
  clear_scan_cache()   -- folders may have changed since last time
  S.vals.octave = renoise.song().transport.octave

  local content = build_ui()
  pcall(C.tooltip_keys)        -- your own keys in the tooltips
  S.dialog = C.show_dialog(TOOL_NAME, content, handle_key, true)

  open_dir(start)
  apply_layout()
  BM.states()
  refresh_info_box()
  C.show_loop()

  observe(renoise.tool().app_idle_observable, idle_watch, true)
  for _, o in ipairs(song_observables()) do observe(o[1], o[2], true) end
end


-- Toggle: open when closed; close when open and focused; when open but
-- another Renoise window has focus, bring the browser back to front instead.
local function toggle_browser()
  if dialog_open() then
    local ok, focused = pcall(function() return S.dialog.focused end)
    -- a key the browser itself just handed on: it had the focus
    local from_browser = S.passed_at and now() - S.passed_at < 0.5
    S.passed_at = nil
    if ok and focused == false and not from_browser then
      S.dialog:show()
    else
      close_browser()
    end
    return
  end
  if S.dialog then cleanup() end
  open_browser()
end


--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

renoise.tool():add_menu_entry {
  name   = "Main Menu:Tools:Simple Browser:Open / Close",
  invoke = toggle_browser,
}
renoise.tool():add_menu_entry {
  name   = "Main Menu:Tools:Simple Browser:Help",
  invoke = function() C.toggle_help() end,
}
-- the same options as the Options window, in the same order (a choice of
-- values becomes a sub menu)
for _, o in ipairs(C.OPTIONS) do
  local base = "Main Menu:Tools:Simple Browser:Options:"
               .. o.group .. ":" .. o.label
  if o.items then
    for i, item in ipairs(o.items) do
      renoise.tool():add_menu_entry {
        name = (i == 1 and base or base:gsub("^%-%-%- ", "")) .. ":" .. item,
        selected = function() return o.get() == i end,
        invoke = function() o.put(i) end,
      }
    end
  else
    renoise.tool():add_menu_entry { name = base, selected = o.on, invoke = o.set }
  end
end
-- what the folder icon does, for when the browser is closed
renoise.tool():add_menu_entry {
  name = "--- Main Menu:Tools:Simple Browser:Set Root Folder...",
  invoke = choose_root }
renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:Simple Browser:Add Folder Path...",
  invoke = function() C.add_place() end }
renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:Simple Browser:Show All Hidden Items Again",
  invoke = function() C.unhide_all() end }

C.clear_edits()   -- edited copies from an earlier session

C.BINDINGS = {}       -- { scope, name, description } as registered

-- The keys you gave the browser's key bindings (Preferences > Keys), read
-- from Renoise's KeyBindings.xml next to the Scripts folder. Renoise
-- writes that file when it saves its preferences, so a new key shows up
-- from then on. { [binding name] = "key" }
function C.user_keys()
  local base = (renoise.tool().bundle_path or "")
    :match("^(.*)[/\\][Ss]cripts[/\\][Tt]ools[/\\]")
  if not base then return nil end
  local f = io.open(base .. SEP .. "KeyBindings.xml", "rb")
  if not f then return nil end
  local xml = f:read("*a")
  f:close()
  local function plain(t)
    return (t:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", "\"")
             :gsub("&apos;", "'"):gsub("&amp;", "&"))
  end
  local keys = {}
  for kb in xml:gmatch("<KeyBinding>(.-)</KeyBinding>") do
    local topic = kb:match("<Topic>%s*(.-)%s*</Topic>")
    local key = kb:match("<Key>%s*(.-)%s*</Key>")
    local name = kb:match("<Binding>%s*(.-)%s*</Binding>")
    if topic == TOOL_NAME and key and key ~= "" and name then
      -- a tool's binding starts with Renoise's "tool" mark (not a letter)
      name = plain(name):gsub("^[^%w]+", "")
      keys[name] = plain(key)
    end
  end
  return keys
end

-- tooltips that name a key binding show the key you gave it, or "noKey"
-- (as Renoise does). Run on every freshly built window.
function C.tooltip_keys()
  local keys = C.user_keys()
  if not keys or not S.vb then return end     -- KeyBindings.xml not found
  local pre = "Global > " .. TOOL_NAME .. " > "
  for _, v in pairs(S.vb.views) do
    pcall(function()
      local tip = v.tooltip
      if not tip or not tip:find(pre, 1, true) then return end
      tip = tip:gsub("%(key bindings?: " .. pre:gsub("%p", "%%%0") .. "(.-)%)",
        function(list)
          local names, got = {}, {}
          for name in (list .. " / "):gmatch("(.-)%s+/%s+") do
            names[#names + 1] = name
            got[#got + 1] = name .. ": " .. (keys[name] or "noKey")
          end
          if #names == 1 then return "(key: " .. (keys[list] or "noKey") .. ")" end
          return "(keys: " .. table.concat(got, ", ") .. ")"
        end)
      v.tooltip = tip
    end)
  end
end
local function bind(scope, name, desc, fn, repeats)
  C.BINDINGS[#C.BINDINGS + 1] = { scope, name, desc }
  renoise.tool():add_keybinding {
    name   = scope .. ":" .. TOOL_NAME .. ":" .. name,
    invoke = function(repeated) if repeats or not repeated then fn() end end,
  }
  return C.BINDINGS[#C.BINDINGS]
end
local GLOBAL = "Global"

-- grouped as they appear in Help and in Preferences > Keys
-- window
bind(GLOBAL, "Toggle Simple Browser", "open / focus again / close", toggle_browser)
bind(GLOBAL, "Toggle Controls Mode", "the browser's Caps Lock",
  function() C.toggle_ctl_mode() end)
bind(GLOBAL, "Show Help", "this window", function() C.toggle_help() end)
bind(GLOBAL, "Show Options", "open / close Options",
  function() C.toggle_options() end)
-- folders
bind(GLOBAL, "Show Folder Menu", "the folder icon's list", function()
  if dialog_open() then C.folder_dialog() end
end)
bind(GLOBAL, "Go to Root Folder", "root home", go_root)
bind(GLOBAL, "Set Root Folder", "choose the root folder", choose_root)
bind(GLOBAL, "Add Folder Path", "browse one more folder", function() C.add_place() end)
bind(GLOBAL, "Rescan Folders", "read the folders again", function()
  if dialog_open() then C.rescan() end
end)
bind(GLOBAL, "Toggle Single Pane", "two panes or one list", toggle_contents)
bind(GLOBAL, "Find", "search; again: refine", F.start)
bind(GLOBAL, "Show in " .. C.FILE_BROWSER, "the highlighted entry", reveal_highlighted)
for i = 1, 8 do
  local b = bind(GLOBAL, "Go to Bookmark " .. i, "go to that folder",
                 function() BM.go(i) end)
  if i == 1 then b[4] = "Go to Bookmark 1 ... 8" else b.skip = true end
end
for i = 1, 8 do
  local b = bind(GLOBAL, "Save Bookmark " .. i, "save this folder there",
                 function() BM.save(i) end)
  if i == 1 then b[4] = "Save Bookmark 1 ... 8" else b.skip = true end
end
-- playback settings
bind(GLOBAL, "Toggle Beatsync", "Beatsync on / off", function()
  prefs.sync_tempo.value = not prefs.sync_tempo.value
  set_status("Beatsync: " .. C.SYNC_ITEMS[C.sync_get()])
end)
bind(GLOBAL, "Beatsync - Set Pitch to Tempo", "Renoise's T button",
  function() if dialog_open() then C.tempo_tune() else set_status("Open the Simple Browser first") end end)
bind(GLOBAL, "Cycle Beatsync Mode", "Repitch / Percussion / Texture",
  function() if dialog_open() then C.cycle_sync_mode() else set_status("Open the Simple Browser first") end end)
bind(GLOBAL, "Cycle Loop Mode", "the highlighted sample",
  function() C.cycle_loop_mode(1) end)
bind(GLOBAL, "Cycle Loop Mode Backwards", "the same, the other way",
  function() C.cycle_loop_mode(-1) end)
bind(GLOBAL, "Semitone Up", "highlighted sample +1 st",
  function() C.ctl_do("semi", 1) end, true)
bind(GLOBAL, "Semitone Down", "highlighted sample -1 st",
  function() C.ctl_do("semi", -1) end, true)
bind(GLOBAL, "Fine Tune Up", "highlighted sample +1",
  function() C.ctl_do("fine", 1) end, true)
bind(GLOBAL, "Fine Tune Down", "highlighted sample -1",
  function() C.ctl_do("fine", -1) end, true)
bind(GLOBAL, "Panning Right", "highlighted sample +1",
  function() C.ctl_do("pan", 1) end, true)
bind(GLOBAL, "Panning Left", "highlighted sample -1",
  function() C.ctl_do("pan", -1) end, true)
bind(GLOBAL, "Sync Length Up", "highlighted sample +1 line",
  function() C.ctl_do("slen", 1) end, true)
bind(GLOBAL, "Sync Length Down", "highlighted sample -1 line",
  function() C.ctl_do("slen", -1) end, true)
-- prehear
bind(GLOBAL, "Prehear - Toggle Auto-Prehear", "play each sample as you move",
  toggle_autoplay)
bind(GLOBAL, "Prehear - Stop", "silence it", function() C.stop_preview() end)
bind(GLOBAL, "Prehear - Volume Up", "+5 %", function() C.ctl_do("prehear_vol", 1) end, true)
bind(GLOBAL, "Prehear - Volume Down", "-5 %", function() C.ctl_do("prehear_vol", -1) end, true)
bind(GLOBAL, "Prehear - Toggle Master or Track", "where the prehear plays", function()
  prefs.prehear_master.value = not prefs.prehear_master.value
  set_status("Prehear on " .. (prefs.prehear_master.value and "Master"
                               or "the selected track"))
end)
-- the highlighted sample
bind(GLOBAL, "Preview - Trim to Selection", "keep only the selection",
  function() C.edit_preview("trim") end)
bind(GLOBAL, "Preview - Cut Selection", "delete the selection",
  function() C.edit_preview("cut") end)
bind(GLOBAL, "Preview - Set Loop to Selection", "loop the selection",
  function() C.loop_to_selection() end)
bind(GLOBAL, "Preview - Toggle Snap to Zero Crossings", "loop points snap or not",
  function() C.toggle_snap() end)
bind(GLOBAL, "Preview - Crossfade Loop", "the selection, else the loop",
  function() C.do_xfade() end)
bind(GLOBAL, "Cycle Interpolation", "None / Linear / Cubic / Sinc",
  function() C.set_interp(prefs.default_interp.value % #C.INTERP_ITEMS + 1) end)
bind(GLOBAL, "Preview - Back to the File", "undo all the sample's edits",
  function() C.undo_edits() end)
-- loading
bind(GLOBAL, "Load and Write Note at Cursor", "load it + note at cursor",
  function() C.load_to_pattern() end)
bind(GLOBAL, "Replace Selected Sample", "swap the audio of the slot",
  function()
    if not dialog_open() or S.focus == K then return end
    local e = S.focus.entries[S.focus.sel]
    if e and not e.is_dir then activate(true) end
  end)
bind(GLOBAL, "Select Previous Sample Slot", "of the selected instrument",
  function() step_sample_slot(-1) end)
bind(GLOBAL, "Select Next Sample Slot", "of the selected instrument",
  function() step_sample_slot(1) end)
-- Multi-Sample
bind(GLOBAL, "Multi-Sample - Toggle Panel", "show / hide it", toggle_kit)
bind(GLOBAL, "Multi-Sample - New Instrument", "an empty one to build",
  function() C.kit_new() end)
bind(GLOBAL, "Multi-Sample - Add Highlighted Sample", "(Insert)", add_highlighted_to_kit)
bind(GLOBAL, "Multi-Sample - Remove Highlighted Sample", "(Del)", function()
  if dialog_open() then kit_remove_selected() end
end)
bind(GLOBAL, "Multi-Sample - Remove All Samples", "(Shift-Del)", function()
  if dialog_open() then kit_clear() end
end)
bind(GLOBAL, "Multi-Sample - Toggle Keyjazz", "piano keys play it anywhere",
  function() C.toggle_kit_keyjazz() end)
bind(GLOBAL, "Multi-Sample - Cycle Mode", "Drumkit / Distribute / Layer",
  function() C.ctl_do("kit_mode", 1) end)
bind(GLOBAL, "Multi-Sample - Start Note Up", "'from' one key up",
  function() C.ctl_do("kit_start", 1) end, true)
bind(GLOBAL, "Multi-Sample - Start Note Down", "'from' one key down",
  function() C.ctl_do("kit_start", -1) end, true)
bind(GLOBAL, "Multi-Sample - Toggle White Keys Only", "Drumkit on white keys",
  function() C.ctl_do("kit_white") end)
bind(GLOBAL, "Multi-Sample - Cycle Overlap", "Play All / Cycle / Random",
  function() C.ctl_do("kit_overlap", 1) end)


-- the controls' settings are undoable (see C.watch); the Multi-Sample ones
-- map the instrument again
local function kit_remap_if(drum_only)
  return function()
    C.kit_controls_active()
    if not drum_only or prefs.kit_mode.value == KIT_DRUM then C.kit_remap() end
    refresh_panel(K)
  end
end
C.watch_pref("prehear_volume", "Prehear volume")
C.watch_pref("autoplay", "Auto-prehear")
C.watch_pref("prehear_master", "Prehear on Master / Track")
-- Beatsync: two settings, one popup (C.sync_get), one undo step
do
  local f = C.make_watch("sync", "Beatsync", C.sync_get, C.sync_set,
                         function() apply_loop_mode() end)
  S.vals.sync = C.sync_get()
  prefs.sync_tempo:add_notifier(f)
  prefs.sync_mode:add_notifier(f)
  prefs.sync_tempo:add_notifier(function() C.show_sync() end)
  prefs.sync_mode:add_notifier(function() C.show_sync() end)
end
C.watch_pref("snap_zero", "Snap to zero crossings")
-- Interpolation: the preview sounds it at once
C.watch_pref("default_interp", "Interpolation", function()
  local smp = scratch_sample()
  if smp then
    C.quiet()
    pcall(function() smp.interpolation_mode = clamp(prefs.default_interp.value, 1, 4) end)
  end
  refresh_info_box()
end)
C.watch_pref("kit_keyjazz", "Multi-Sample keyjazz")
C.watch_pref("kit_mode", "Multi-Sample mode", kit_remap_if(false))
C.watch_pref("kit_start", "Multi-Sample start note", kit_remap_if(true))
C.watch_pref("white_keys", "White keys", kit_remap_if(true))
C.watch_pref("overlap", "Overlap", function()
  local idx, inst = C.kit_index()
  if not inst or S.undoing then return end
  local before = inst.sample_mapping_overlap_mode
  C.loud("Overlap")
  inst.sample_mapping_overlap_mode = clamp(prefs.overlap.value, 1, 3) - 1
  local e = S.cur_entry
  if e then
    e.ov = e.ov or { idx = idx, before = before }
    e.ov.after = inst.sample_mapping_overlap_mode
    e.restore = function(self, which)
      C.inst_at(self.ov.idx).sample_mapping_overlap_mode = self.ov[which]
      renoise.song().selected_instrument_index = self.ov.idx
      K.idx = nil
    end
  end
end)

-- after an undo / redo: everything shows what is now
function C.after_undo()
  if not dialog_open() then return end
  if prefs.show_kit.value then K.sync(true) end
  refresh_all()
  C.show_loop()
  C.kit_controls_active()
  BM.states()
  refresh_info_box()
end

function C.toggle_kit_keyjazz()
  prefs.kit_keyjazz.value = not prefs.kit_keyjazz.value
  if not dialog_open() then
    set_status("Multi-Sample keyjazz " .. (prefs.kit_keyjazz.value and "on" or "off")
      .. (prefs.show_kit.value and "" or " (acts while the Multi-Sample panel is open)"))
  end
end

-- the colour of a button when controls mode is not on it: lit while its
-- toggle is on
function C.button_rest(id)
  local lit = {
    multi_btn = prefs.show_kit.value,
    pane_btn = prefs.show_contents.value, find_btn_l = S.find ~= nil,
    find_btn_r = S.find ~= nil, kit_keyjazz = prefs.kit_keyjazz.value,
  }
  return lit[id] and C.LIT or DEFAULT_COLOR
end

-- toggles light up while on; the speaker and keyjazz icons switch
function BM.states()
  local kj = view("kit_keyjazz")
  if kj and kj.text == "" then
    C.set_icon(kj, "keyjazz")
  end
  local sp = view("speaker")
  if sp and sp.text == "" then   -- icon button: Renoise's prehear on / off
    C.set_icon(sp, prefs.autoplay.value and "prehear_on" or "prehear_off")
  elseif sp then
    C.tint(sp, prefs.autoplay.value and C.LIT or DEFAULT_COLOR)
  end
  for _, id in ipairs { "multi_btn", "pane_btn", "find_btn_l",
                        "find_btn_r", "kit_keyjazz" } do
    local b = view(id)
    if b then C.tint(b, C.button_rest(id)) end
  end
  if S.ctl then C.paint_stop(S.ctl, true) end   -- keep the focus visible
end

-- A new theme also changes highlighted row backgrounds and their contrast.
pcall(function()
  renoise.app().theme_observable:add_notifier(function() redraw_wave(); refresh_all() end)
end)

-- turning auto-preview off silences the running preview
-- the prehear volume reaches notes that are sounding (see C.prehear_gain)
prefs.prehear_volume:add_notifier(function() C.prehear_gain() end)

prefs.autoplay:add_notifier(function()
  if not prefs.autoplay.value then release_id("preview") end
  BM.states()
end)
prefs.show_kit:add_notifier(function() BM.states() end)
prefs.snap_zero:add_notifier(function() BM.states() end)
-- the Output popup follows its setting (key binding, undo)
prefs.prehear_master:add_notifier(function()
  local pop = view("output")
  local v = prefs.prehear_master.value and 1 or 2
  if pop and pop.value ~= v then
    S.updating_output = true
    pcall(function() pop.value = v end)
    S.updating_output = false
  end
end)
prefs.kit_keyjazz:add_notifier(function() BM.states() end)

-- A new/loaded song invalidates our scratch instruments: close and reset.
renoise.tool().app_new_document_observable:add_notifier(function()
  if S.dialog then close_browser() end
end)
