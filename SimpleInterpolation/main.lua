--------------------------------------------------------------------------------
-- Simple Interpolation
--
-- Set the interpolation (and Anti-aliasing) of samples from the Tools menu,
-- the sample list, sample editor and instrument box menus, or your own keys
-- (Preferences > Keys > Global > Simple Interpolation):
--
--   Selected Sample      the sample selected in Renoise
--   Selected Instrument  every sample of the selected instrument
--   Whole Song           every sample of every instrument
--   New Samples          a default for every sample you load, record or
--                        drag in from now on, in place of Renoise's own
--
-- by phaos & claude
--------------------------------------------------------------------------------

local TOOL = "Simple Interpolation"
local MODES = { "None", "Linear", "Cubic", "Sinc" }   -- = INTERPOLATE_*

local prefs = renoise.Document.create("SimpleInterpolationPreferences") {
  new_mode = 0,          -- New Samples: 0 Renoise's default, else 1 - 4
  new_aa = false,        -- New Samples: Anti-aliasing on
}
renoise.tool().preferences = prefs

local function status(msg)
  renoise.app():show_status(TOOL .. ": " .. msg)
end

local function song()
  local ok, s = pcall(renoise.song)
  return ok and s or nil
end

--------------------------------------------------------------------------------
-- Selected Sample / Selected Instrument / Whole Song
--------------------------------------------------------------------------------

local SCOPES = { "Selected Sample", "Selected Instrument", "Whole Song" }

-- the samples a scope means, and how to say so
local function targets(scope)
  local s, list = song(), {}
  if not s then return list, "" end
  if scope == "Selected Sample" then
    local smp = s.selected_sample
    if smp then list[1] = smp end
    return list, "Selected sample"
  end
  local insts = scope == "Selected Instrument" and { s.selected_instrument }
                or s.instruments
  for _, inst in ipairs(insts) do
    for _, smp in ipairs(inst.samples) do list[#list + 1] = smp end
  end
  local what = scope == "Selected Instrument" and "Selected instrument"
               or "Whole song"
  return list, string.format("%s (%d sample%s)", what, #list,
                             #list == 1 and "" or "s")
end

-- the interpolation all of them share (nil: none, or mixed)
local function common(scope)
  local list, m = targets(scope), nil
  for _, smp in ipairs(list) do
    if m and smp.interpolation_mode ~= m then return nil end
    m = smp.interpolation_mode
  end
  return m
end

local function all_aa(scope)
  local list = targets(scope)
  if #list == 0 then return false end
  for _, smp in ipairs(list) do
    if not smp.oversample_enabled then return false end
  end
  return true
end

-- change every sample of a scope: one undo step
local function change(scope, what_of, fn)
  local list, what = targets(scope)
  if #list == 0 then
    status(scope == "Selected Sample" and "No sample selected"
           or "No samples")
    return
  end
  pcall(function() song():describe_undo(TOOL .. ": " .. what_of) end)
  for _, smp in ipairs(list) do pcall(fn, smp) end
  status(what .. ": " .. what_of)
end

local function set_mode(scope, mode)
  change(scope, MODES[mode], function(smp) smp.interpolation_mode = mode end)
end

local function cycle(scope)
  local list = targets(scope)
  local m = common(scope) or (list[1] and list[1].interpolation_mode) or 3
  set_mode(scope, m % #MODES + 1)
end

local function toggle_aa(scope)
  local on = not all_aa(scope)
  change(scope, "Anti-aliasing " .. (on and "on" or "off"),
         function(smp) smp.oversample_enabled = on end)
end

--------------------------------------------------------------------------------
-- New Samples
--
-- A sample is new when audio arrives in an empty slot, or a file is loaded
-- over one (its audio and its name change together). It gets the default
-- only where it still has Renoise's own setting, so a sample that comes
-- with its own (a duplicate, an instrument file, another tool's choice) is
-- left alone. Renoise's own setting is read from the empty slots it makes.
--------------------------------------------------------------------------------

local W = { song = nil, insts = {}, fresh = {} }
local RENOISE = { mode = 3, aa = false }       -- what an empty slot has

local function apply_new(smp)
  local m, aa = prefs.new_mode.value, prefs.new_aa.value
  if m > 0 and smp.interpolation_mode == RENOISE.mode and m ~= RENOISE.mode then
    smp.interpolation_mode = m
  end
  if aa and smp.oversample_enabled == RENOISE.aa and not RENOISE.aa then
    smp.oversample_enabled = true
  end
end

local function learn(smp)                       -- an empty slot: Renoise's own
  if smp and not smp.sample_buffer.has_sample_data then
    RENOISE.mode = smp.interpolation_mode
    RENOISE.aa = smp.oversample_enabled
  end
end

local function unwatch(list)
  for _, w in ipairs(list) do
    pcall(function() w[1]:remove_notifier(w[2]) end)
  end
end

local function watch_sample(list, smp)
  local st = { data = smp.sample_buffer.has_sample_data, name = smp.name }
  local function on_buffer()
    local data = smp.sample_buffer.has_sample_data
    if data and (not st.data or smp.name ~= st.name) then
      pcall(apply_new, smp)
      st.fresh = false
    elseif data then                 -- new audio, same name so far: a file
      st.fresh = true                -- loaded over it gets its name next
      W.fresh[#W.fresh + 1] = st
    end
    st.data, st.name = data, smp.name
  end
  local function on_name()
    if st.fresh then st.fresh = false pcall(apply_new, smp) end
    st.name = smp.name
  end
  smp.sample_buffer_observable:add_notifier(on_buffer)
  smp.name_observable:add_notifier(on_name)
  list[#list + 1] = { smp.sample_buffer_observable, on_buffer }
  list[#list + 1] = { smp.name_observable, on_name }
end

local function watch_instrument(inst)
  local w = { samples = {} }
  local function samples()
    unwatch(w.samples)
    w.samples = {}
    for _, smp in ipairs(inst.samples) do watch_sample(w.samples, smp) end
  end
  w.fn = function(ev)
    if ev.type == "insert" then learn(inst.samples[ev.index]) end
    samples()
  end
  inst.samples_observable:add_notifier(w.fn)
  w.obs = inst.samples_observable
  samples()
  return w
end

local function unwatch_all()
  for _, w in ipairs(W.insts) do
    unwatch(w.samples)
    pcall(function() w.obs:remove_notifier(w.fn) end)
  end
  W.insts = {}
end

local function watch_all()
  unwatch_all()
  local s = song()
  if not s then return end
  for _, inst in ipairs(s.instruments) do
    local ok, w = pcall(watch_instrument, inst)
    if ok then W.insts[#W.insts + 1] = w end
  end
end

local function on_instruments(ev)
  if ev.type == "insert" then
    local inst = song().instruments[ev.index]
    if inst then learn(inst.samples[1]) end
  end
  watch_all()
end

local function attach()
  local s = song()
  if not s then return end
  if W.song then
    pcall(function() W.song.instruments_observable:remove_notifier(on_instruments) end)
  end
  W.song = s
  s.instruments_observable:add_notifier(on_instruments)
  watch_all()
end

renoise.tool().app_new_document_observable:add_notifier(attach)
renoise.tool().app_release_document_observable:add_notifier(function()
  unwatch_all()
  if W.song then
    pcall(function() W.song.instruments_observable:remove_notifier(on_instruments) end)
  end
  W.song = nil
end)
-- a file loaded over a sample: its name follows within the same moment
renoise.tool().app_idle_observable:add_notifier(function()
  if #W.fresh > 0 then
    for _, st in ipairs(W.fresh) do st.fresh = false end
    W.fresh = {}
  end
end)
attach()

local function set_new(m)
  prefs.new_mode.value = m
  status("New samples: " .. (m == 0 and "Off (Renoise's default)" or MODES[m]))
end

local function toggle_new_aa()
  prefs.new_aa.value = not prefs.new_aa.value
  status("New samples: Anti-aliasing " .. (prefs.new_aa.value and "on"
         or "as Renoise sets it"))
end

--------------------------------------------------------------------------------
-- Menus and key bindings
--------------------------------------------------------------------------------

local function entry(name, invoke, selected)
  renoise.tool():add_menu_entry { name = name, invoke = invoke,
                                  selected = selected }
end

-- one scope's entries under `base`: the four modes, then Anti-aliasing
local function scope_menu(base, scope)
  for i, m in ipairs(MODES) do
    entry(base .. scope .. ":" .. m,
          function() set_mode(scope, i) end,
          function() return common(scope) == i end)
  end
  entry("--- " .. base .. scope .. ":Anti-aliasing",
        function() toggle_aa(scope) end,
        function() return all_aa(scope) end)
end

-- Tools menu: everything
local TOOLS = "Main Menu:Tools:" .. TOOL .. ":"
entry(TOOLS .. "New Samples:Off (Renoise's Default)", function() set_new(0) end,
      function() return prefs.new_mode.value == 0 end)
for i, m in ipairs(MODES) do
  entry((i == 1 and "--- " or "") .. TOOLS .. "New Samples:" .. m,
        function() set_new(i) end,
        function() return prefs.new_mode.value == i end)
end
entry("--- " .. TOOLS .. "New Samples:Anti-aliasing On", toggle_new_aa,
      function() return prefs.new_aa.value end)
for _, scope in ipairs(SCOPES) do scope_menu(TOOLS, scope) end

-- right-click menus where the samples are
for _, place in ipairs { "Sample List", "Sample Editor" } do
  local base = place .. ":" .. TOOL .. ":"
  scope_menu(base, "Selected Sample")
  scope_menu(base, "Selected Instrument")
end
do
  local base = "Instrument Box:" .. TOOL .. ":"
  scope_menu(base, "Selected Instrument")
  scope_menu(base, "Whole Song")
end

-- key bindings
local function bind(name, fn)
  renoise.tool():add_keybinding {
    name = "Global:" .. TOOL .. ":" .. name,
    invoke = function(repeated) if not repeated then fn() end end,
  }
end
for _, scope in ipairs(SCOPES) do
  for i, m in ipairs(MODES) do
    bind(scope .. " - " .. m, function() set_mode(scope, i) end)
  end
  bind(scope .. " - Cycle", function() cycle(scope) end)
  bind(scope .. " - Toggle Anti-aliasing", function() toggle_aa(scope) end)
end
bind("New Samples - Cycle", function()
  set_new((prefs.new_mode.value + 1) % (#MODES + 1))
end)
