--------------------------------------------------------------------------------
-- Simple Xfade  -  Renoise 3.5 / Lua API 6.2
--
-- An equal power crossfade loop, as afta8's xfade pow, from one key:
-- select the part to loop in the sample editor and press Crossfade.
--
-- The selection becomes the loop. The audio just before it is faded in
-- (sin) over the end of the loop, which fades out (cos), so the last frame
-- of the loop leads straight into its first one. The fade is as long as
-- the loop, or as long as the audio before it when that is shorter. With
-- nothing selected, the sample's own loop is crossfaded.
--
-- Crossfade Instrument does the same for every sample of the selected
-- instrument: the selection of the selected sample (the same frames) becomes
-- the loop of each of them. With nothing selected, each sample's own loop is
-- crossfaded. Samples it cannot do (empty, slices, shorter than the
-- selection, no audio before the loop) are skipped and counted.
--
-- Bind the keys in Preferences > Keys > Sample Editor > Simple Xfade (also
-- in the sample editor's right-click menu, Tools > Simple Xfade, and as MIDI
-- mappings). Undo works as for Renoise's own sample edits.
--------------------------------------------------------------------------------

local TOOL_NAME = "Simple Xfade"

local LOOP_OFF, LOOP_FORWARD = 1, 2

-- no settings any more; the document stays so a settings file of an
-- earlier version (with its slider) still loads
local prefs = renoise.Document.create("SimpleXfadePreferences") {
  loop_pos    = 50.0,   -- no longer used
  show_region = true,   -- no longer used
}
renoise.tool().preferences = prefs


--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function set_status(msg)
  renoise.app():show_status(TOOL_NAME .. ": " .. msg)
end

local function fmt_time(frames, rate)
  local s = math.max(0, frames) / math.max(1, rate)
  if s < 60 then return string.format("%.3f s", s) end
  local m = math.floor(s / 60)
  return string.format("%d:%06.3f", m, s - m * 60)
end

-- smp, buf - or nil and the reason
local function current()
  local song = renoise.song()
  local smp = song and song.selected_sample
  if not smp then return nil, "No sample selected" end
  local buf = smp.sample_buffer
  if not buf.has_sample_data then return nil, "The selected sample is empty" end
  return smp, buf
end

-- the sample editor's selection: a, b - or nil when nothing is selected
-- (Renoise then reports the whole sample) or it is a single frame
local function selection(buf)
  local n = buf.number_of_frames
  local ok, r = pcall(function() return buf.selection_range end)
  if not ok or not r or not r[1] or not r[2] then return nil end
  local a, b = r[1], r[2]
  if b <= a or (a <= 1 and b >= n) then return nil end
  return a, b
end

local function is_slice(buf)
  local ro = false
  pcall(function() ro = buf.read_only end)
  return ro
end


--------------------------------------------------------------------------------
-- The crossfade of one sample
--------------------------------------------------------------------------------

-- Make frames ls .. le the loop of a sample and crossfade it. Returns the
-- fade length, or nil and why: "slice", "short" (the loop reaches past the
-- end of this sample), "loop" (too short to fade), "before" (no audio before
-- it) or "error" (and the message).
local function crossfade_sample(smp, buf, ls, le)
  if is_slice(buf) then return nil, "slice" end
  if le > buf.number_of_frames then return nil, "short" end
  if le - ls < 2 then return nil, "loop" end
  local fade = math.min(le - ls + 1, ls - 1)
  if fade < 2 then return nil, "before" end

  -- frames d = le - fade + 1 .. le (the loop's end) fade out, frames
  -- s = ls - fade .. ls - 1 (just before the loop) fade in over them; the
  -- two ranges never overlap, so it is done in place
  local sin, cos, half_pi = math.sin, math.cos, math.pi / 2
  local d0, s0 = le - fade + 1, ls - fade
  local ok, err = pcall(function()
    buf:prepare_sample_data_changes()
    for ch = 1, buf.number_of_channels do
      for i = 0, fade - 1 do
        local t = (i + 1) / fade * half_pi
        local d, s = d0 + i, s0 + i
        buf:set_sample_data(ch, d,
          buf:sample_data(ch, d) * cos(t) + buf:sample_data(ch, s) * sin(t))
      end
    end
    buf:finalize_sample_data_changes()
  end)
  if not ok then return nil, "error", tostring(err) end

  -- the loop (start before end at every step)
  pcall(function()
    smp.loop_start = 1
    smp.loop_end = le
    smp.loop_start = ls
    smp.loop_mode = LOOP_FORWARD
  end)
  return fade
end


--------------------------------------------------------------------------------
-- Crossfade: the selected sample
--------------------------------------------------------------------------------

local function crossfade()
  local smp, buf = current()
  if not smp then set_status(buf) return end
  if is_slice(buf) then
    set_status("This is a slice - crossfade the sliced sample (the first one)")
    return
  end

  -- the loop: the selection, else the sample's own loop
  local ls, le = selection(buf)
  local what = "the selection"
  if not ls then
    if smp.loop_mode == LOOP_OFF then
      set_status("Select the part to loop in the sample editor first")
      return
    end
    ls, le, what = smp.loop_start, smp.loop_end, "the loop"
  end

  local fade, why, err = crossfade_sample(smp, buf, ls, le)
  if not fade then
    if why == "loop" then
      set_status("Nothing to fade - " .. what .. " is too short")
    elseif why == "before" then
      set_status("Nothing to fade - " .. what .. " needs audio before it")
    else
      set_status("Crossfade failed: " .. tostring(err or why))
    end
    return
  end

  local rate = buf.sample_rate
  set_status(string.format("Loop %s - %s, crossfade %s",
    fmt_time(ls - 1, rate), fmt_time(le, rate), fmt_time(fade, rate)))
end


--------------------------------------------------------------------------------
-- Crossfade Instrument: every sample of the selected instrument
--------------------------------------------------------------------------------

local SKIP = {   -- why a sample was skipped, in the order they are reported
  { "empty",  "empty" },
  { "slice",  "slice" },
  { "noloop", "no loop" },
  { "short",  "shorter than the selection" },
  { "loop",   "loop too short" },
  { "before", "no audio before the loop" },
  { "error",  "failed" },
}

local function crossfade_instrument()
  local smp, buf = current()
  if not smp then set_status(buf) return end
  local inst = renoise.song().selected_instrument
  if not inst then set_status("No instrument selected") return end

  -- the selected sample's selection, as frames, for every sample; with
  -- nothing selected each sample uses its own loop
  local ls, le = selection(buf)
  local total, done, skipped = #inst.samples, 0, {}
  local function skip(why) skipped[why] = (skipped[why] or 0) + 1 end

  for _, s in ipairs(inst.samples) do
    local b = s.sample_buffer
    if not b.has_sample_data then
      skip("empty")
    else
      local a, z = ls, le
      if not a and s.loop_mode ~= LOOP_OFF then
        a, z = s.loop_start, s.loop_end
      end
      if not a then
        skip("noloop")
      else
        local fade, why = crossfade_sample(s, b, a, z)
        if fade then done = done + 1 else skip(why) end
      end
    end
  end

  local notes = {}
  for _, r in ipairs(SKIP) do
    if skipped[r[1]] then
      notes[#notes + 1] = skipped[r[1]] .. " " .. r[2]
    end
  end
  local extra = #notes > 0 and (" - skipped: " .. table.concat(notes, ", ")) or ""

  if done == 0 then
    set_status("Nothing crossfaded in the instrument" .. extra)
  elseif ls then
    set_status(string.format("Crossfaded %d of %d samples, frames %d - %d%s",
      done, total, ls, le, extra))
  else
    set_status(string.format("Crossfaded the loops of %d of %d samples%s",
      done, total, extra))
  end
end


--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

local COMMANDS = {
  { "Crossfade", crossfade },
  { "Crossfade Instrument", crossfade_instrument },
}

for _, cmd in ipairs(COMMANDS) do
  local name, fn = cmd[1], cmd[2]
  renoise.tool():add_menu_entry {
    name = "Main Menu:Tools:" .. TOOL_NAME .. ":" .. name,
    invoke = fn,
  }
  renoise.tool():add_menu_entry {
    name = "Sample Editor:" .. TOOL_NAME .. ":" .. name,
    invoke = fn,
  }
  renoise.tool():add_keybinding {
    name = "Sample Editor:" .. TOOL_NAME .. ":" .. name,
    invoke = function(repeated) if not repeated then fn() end end,
  }
  pcall(function()
    renoise.tool():add_midi_mapping {
      name = "Tools:" .. TOOL_NAME .. ":" .. name,
      invoke = function(msg) if msg:is_trigger() then fn() end end,
    }
  end)
end
