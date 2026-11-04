--------------------------------------------------------------------------------
-- Simple Notes Off  -  Renoise 3.5 / Lua API 6.2
--
-- Deletes note offs (OFF) and nothing else: notes, instruments, volume,
-- panning, delay and effects stay as they are. Only the note of an OFF is
-- cleared, so a volume or effect written next to it survives.
--
--   Delete Note Offs in Track             the selected track, this pattern
--   Delete Note Offs in Pattern           every track of this pattern
--   Delete Note Offs in Track (Whole Song) the selected track, every pattern
--   Delete Note Offs in Song              every track of every pattern
--
-- Bind the keys in Preferences > Keys > Pattern Editor > Simple Notes Off.
-- Undo works as for any pattern edit.
--------------------------------------------------------------------------------

local TOOL_NAME = "Simple Notes Off"
local NOTE_OFF, EMPTY = 120, 121

local function set_status(msg)
  renoise.app():show_status(TOOL_NAME .. ": " .. msg)
end

-- clear the note offs in one pattern track; how many
local function clear_pattern_track(pattern, t)
  local count = 0
  local ptrack = pattern.tracks[t]
  if ptrack.is_empty then return 0 end
  for l = 1, pattern.number_of_lines do
    local line = ptrack:line(l)
    if not line.is_empty then
      for _, nc in ipairs(line.note_columns) do
        if nc.note_value == NOTE_OFF then
          nc.note_value = EMPTY
          count = count + 1
        end
      end
    end
  end
  return count
end

local function is_sequencer(track)
  return track.type == renoise.Track.TRACK_TYPE_SEQUENCER
end

-- tracks: "selected" | "all";  patterns: "current" | "song"
local function delete_note_offs(tracks, patterns, label)
  local song = renoise.song()
  if not song then return end
  local track_list = {}
  if tracks == "selected" then
    if not is_sequencer(song.selected_track) then
      set_status("Select a track with notes (not a group, send or master)")
      return
    end
    track_list[1] = song.selected_track_index
  else
    for t, track in ipairs(song.tracks) do
      if is_sequencer(track) then track_list[#track_list + 1] = t end
    end
  end
  local pattern_list = {}
  if patterns == "current" then
    pattern_list[1] = song.selected_pattern
  else
    for _, p in ipairs(song.patterns) do pattern_list[#pattern_list + 1] = p end
  end

  pcall(function() song:describe_undo("Delete Note Offs - " .. label) end)
  local count = 0
  for _, p in ipairs(pattern_list) do
    for _, t in ipairs(track_list) do
      count = count + clear_pattern_track(p, t)
    end
  end
  if count == 0 then
    set_status("No note offs " .. label:lower())
  else
    set_status(string.format("%d note off%s deleted %s", count,
      count == 1 and "" or "s", label:lower()))
  end
end


--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

local COMMANDS = {
  { "Delete Note Offs in Track",
    function() delete_note_offs("selected", "current", "In the track") end },
  { "Delete Note Offs in Pattern",
    function() delete_note_offs("all", "current", "In the pattern") end },
  { "Delete Note Offs in Track (Whole Song)",
    function() delete_note_offs("selected", "song", "In the track, whole song") end },
  { "Delete Note Offs in Song",
    function() delete_note_offs("all", "song", "In the song") end },
}

for _, cmd in ipairs(COMMANDS) do
  local name, fn = cmd[1], cmd[2]
  renoise.tool():add_keybinding {
    name = "Pattern Editor:" .. TOOL_NAME .. ":" .. name,
    invoke = function(repeated) if not repeated then fn() end end,
  }
  renoise.tool():add_menu_entry {
    name = "Main Menu:Tools:" .. TOOL_NAME .. ":" .. name,
    invoke = fn,
  }
  renoise.tool():add_menu_entry {
    name = "Pattern Editor:" .. TOOL_NAME .. ":" .. name,
    invoke = fn,
  }
  pcall(function()
    renoise.tool():add_midi_mapping {
      name = "Tools:" .. TOOL_NAME .. ":" .. name,
      invoke = function(msg) if msg:is_trigger() then fn() end end,
    }
  end)
end
