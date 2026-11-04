--------------------------------------------------------------------------------
-- Simple Transients  -  Renoise 3.5 / Lua API 6.2
--
-- Transient detection for the sample editor, the companion of Simple
-- Browser: step from hit to hit - drum hits in a loop, words in a recording
-- - move the selection's start and end transient by transient, and crop
-- single hits or parts of loops.
--
--   Next / Previous Transient   the cursor to the next / previous hit
--   Selection Start / End       an edge to the next / previous transient
--   Selection Both Edges        out / in by a transient on each side
--   Trim                        left of the cursor, right of it, to the
--                               selection
--   Prehear                     the selection, or from the cursor on
--   Panel                       the detection settings, Options, Help
--
-- NOTE ON KEYS
-- A tool cannot set default keys: bind them in Preferences > Keys >
-- Sample Editor > Simple Transients. Those only fire while the sample
-- editor has the keyboard focus. Help suggests a key set that is free in
-- your own key bindings (Renoise keeps Shift-arrows for its selection).
--
-- NOTE ON THE CURSOR
-- The scripting API shows tools the sample editor's selection, not
-- Renoise's dotted play cursor. So this tool's cursor is a selection one
-- frame long, and its selections are the editor's: Renoise's own play
-- selection, copy into new sample / new instrument act on them. A click
-- in the waveform only moves the dotted cursor (and clears the selection):
-- the tool stays where it was. Click, then Renoise's Shift-arrow, and
-- the tool goes on from there.
--------------------------------------------------------------------------------

local TOOL_NAME = "Simple Transients"
-- constants live in this table (keeps the main chunk under Lua 5.1's
-- limit of 200 local variables)
local C = {}
C.VERSION = "1.0.3"

C.HOP_MS        = 5       -- analysis resolution: one level per 5 ms
C.BUDGET_S      = 0.015   -- background analysis time per timer tick
C.TICK_MS       = 10
C.WAIT_S        = 0.35    -- a key press waits this long for an analysis
C.CACHE_SIZE    = 8       -- samples whose transients are remembered
C.ZC_MS         = 3       -- onsets look this far back for a zero crossing
C.PEAK_MS       = 25      -- "Peak": the loudest frame this soon after onset
C.AUTO_MAX_S    = 3       -- auto-prehear plays at most this much of a hit
C.FP_EVERY_S    = 0.5     -- how often the sample is checked for edits
C.PREFETCH_S    = 0.3     -- settle time before a newly selected sample is
                          -- analysed in the background

C.SENS_STEP     = 5       -- %  (key bindings, the panel's Up / Down)
C.THRESH_STEP   = 3       -- dB
C.SENS_MIN, C.SENS_MAX = 0, 100       -- %
C.THRESH_MIN, C.THRESH_MAX = 6, 90    -- dB below the loudest part
C.GAP_MIN, C.GAP_MAX = 10, 2000       -- ms

C.ROW_HEIGHT    = 18
-- the panel: one grid, every row as wide as the next
C.PANEL_W       = 460     -- inside width of the settings group
C.GAP           = 4       -- between controls
C.LABEL_W       = 96      -- the settings' names
C.VALUE_W       = 76      -- the settings' value boxes

-- Every colour comes from the loaded theme (the slot names of a .xrnc file,
-- lower case), as in Simple Browser, so the tool looks like the rest of
-- Renoise whatever theme is loaded.
C.FOCUS   = "selection_back"           -- the control the keys are on
-- used only if a Renoise version does not know the name above
C.FALLBACK = {
  selection_back = { 255, 143, 53 },
}
local DEFAULT_COLOR = { 0, 0, 0 }      -- {0,0,0} = theme default

-- a view's colour from the theme (RGB fallback if the name is unknown)
function C.tint(v, color)
  if type(color) == "string" then
    if pcall(function() v.color = color end) then return end
    color = C.FALLBACK[color] or DEFAULT_COLOR
  end
  pcall(function() v.color = color end)
end

C.SNAP_ITEMS = { "Onset", "Peak" }

local LOOP_OFF = 1


--------------------------------------------------------------------------------
-- Preferences
--------------------------------------------------------------------------------

local prefs = renoise.Document.create("SimpleTransientsPreferences") {
  prefs_version  = 1,
  sensitivity    = 60,     -- %: how small a jump in level counts as a hit
  threshold      = 40,     -- dB below the loudest part: quieter hits ignored
  min_gap_ms     = 50,     -- two transients are at least this far apart
  snap_mode      = 1,      -- index into C.SNAP_ITEMS
  zero_cross     = true,   -- onsets land on a zero crossing (no clicks)
  follow         = true,   -- scroll the sample editor along with the cursor
  wrap           = true,   -- past the last hit: back to the start
  snap_edges     = true,   -- selection edges move by transient (else fine)
  autoplay       = true,   -- prehear the hit when the cursor moves
  prehear_master = true,   -- prehear on the master track (Renoise default)
}
renoise.tool().preferences = prefs


--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- The cursor model, in "edges": an edge is the frame a part starts at, so
-- a selection of frames a..b has the edges a and b + 1, and the end of a
-- sample of n frames is edge n + 1. anchor == edge is a plain cursor.
local S = {
  ident   = nil,    -- "instrument:sample" the model belongs to
  anchor  = nil,
  edge    = nil,    -- the edge Next / Previous move
  shown   = nil,    -- { a, b }: the selection this tool put in the editor
  play    = nil,    -- the prehear voice
  pending = nil,    -- { key=, fn= }: an action waiting for the analysis
  dialog  = nil,    -- the panel
  vb      = nil,
}

local A = {          -- analysis
  caches = {},       -- key -> cache
  order  = {},       -- keys, oldest first
  job    = nil,      -- running background analysis
}
local M = {}         -- the commands (keys, menus, MIDI)
local P = {}         -- the panel


--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

-- Messages go to Renoise's own status bar.
local function set_status(msg)
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

-- A floating window with a key handler. Renoise wants BOTH key options as
-- booleans; if this build does not take them at all, open it without.
function C.show_dialog(title, content, handler)
  local ok, d = pcall(function()
    return renoise.app():show_custom_dialog(title, content, handler,
      { send_key_repeat = true, send_key_release = false })
  end)
  if ok and d then return d end
  return renoise.app():show_custom_dialog(title, content, handler)
end

-- 1.234 s  /  1:02.500
local function fmt_time(frames, rate)
  local s = math.max(0, frames) / math.max(1, rate)
  if s < 60 then return string.format("%.3f s", s) end
  local m = math.floor(s / 60)
  return string.format("%d:%06.3f", m, s - m * 60)
end

-- an edge (1 .. n + 1) as a time from the start of the sample
local function fmt_edge(edge, rate)
  return fmt_time(edge - 1, rate)
end

local function db(power)
  return 10 * math.log10(power + 1e-12)
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
-- The selected sample
--------------------------------------------------------------------------------

-- smp, buf, song - or nil and the reason
local function current()
  local song = renoise.song()
  local smp = song and song.selected_sample
  if not smp then return nil, "No sample selected" end
  local buf = smp.sample_buffer
  if not buf.has_sample_data then return nil, "The selected sample is empty" end
  return smp, buf, song
end

local function ident_of(song)
  return song.selected_instrument_index .. ":" .. song.selected_sample_index
end

-- A cheap fingerprint of the audio: length, format and ~60 probed frames.
-- It changes when the sample is edited (by us, by Renoise, by a tool).
local function fingerprint(buf)
  local n = buf.number_of_frames
  local step = math.max(1, math.floor(n / 61))
  local s = 0
  for f = 1, n, step do s = s + buf:sample_data(1, f) * (f % 7 + 1) end
  return string.format("%d:%d:%d:%.9g", n, buf.number_of_channels,
                       buf.sample_rate, s)
end

local function key_of(song, buf)
  return ident_of(song) .. "|" .. fingerprint(buf)
end

-- the editor's selection; a b; "whole" = nothing selected (Renoise then
-- reports the whole sample)
local function selection_of(buf)
  local r = buf.selection_range
  local a, b = r[1], r[2]
  return a, b, (a <= 1 and b >= buf.number_of_frames)
end

-- set the editor's selection (start before end at every step)
local function set_selection(buf, a, b)
  if pcall(function() buf.selection_range = { a, b } end) then return end
  pcall(function()
    if a > buf.selection_end then
      buf.selection_end = b
      buf.selection_start = a
    else
      buf.selection_start = a
      buf.selection_end = b
    end
  end)
end

-- Scroll a zoomed-in sample editor so `f` is in view (a third from the
-- left, so you see what comes next). Zoom stays as it is.
local function follow(buf, f)
  pcall(function()
    local n = buf.number_of_frames
    local len = buf.display_length
    if len >= n then return end                 -- whole sample in view
    local s = buf.display_start
    local margin = math.floor(len / 12)
    if f >= s + margin and f <= s + len - 1 - margin then return end
    -- Renoise's valid range for display_start is 1 .. n - len
    local ns = clamp(f - math.floor(len / 3), 1, math.max(1, n - len))
    if not pcall(function() buf.display_range = { ns, ns + len - 1 } end) then
      buf.display_start = ns
    end
  end)
end


--------------------------------------------------------------------------------
-- Transient detection
--
-- 1. Envelope (the slow part, runs in the background): for every 5 ms hop
--    the mean power and the mean power of the first difference (that is
--    the treble: hi-hats, consonants, clicks).
-- 2. Picking (instant, redone when a setting changes): a hop is a
--    transient candidate where the level jumps - the louder of the next two
--    hops against the three before - by at least the Sensitivity's dB, in
--    the full signal or in the treble. Hops quieter than Threshold below
--    the loudest part are ignored. Candidates must be a local maximum;
--    Min gap keeps the strongest of hits that are too close together.
-- 3. Placing (lazily, only around the cursor): the onset is found frame
--    by frame - the point that best splits the hit from what came before -
--    then moved back to the nearest zero crossing.
--    "Peak" puts the cursor on the loudest frame of the hit instead.
--------------------------------------------------------------------------------

-- Sensitivity (0 - 100 %) -> the jump in level a hit needs, in dB
function C.rise_for(sens)
  return 1.5 + (1 - clamp(sens, 0, 100) / 100) * 22.5
end

function A.remember(c)
  if not A.caches[c.key] then A.order[#A.order + 1] = c.key end
  A.caches[c.key] = c
  while #A.order > C.CACHE_SIZE do
    A.caches[table.remove(A.order, 1)] = nil
  end
end

function A.progress()
  local j = A.job
  if not j then return 100 end
  return math.floor(100 * j.k / math.max(1, j.hops))
end

function A.start(buf, key)
  local n = buf.number_of_frames
  local H = math.max(32, math.floor(buf.sample_rate * C.HOP_MS / 1000 + 0.5))
  A.job = {
    key = key, buf = buf, n = n, rate = buf.sample_rate,
    chs = math.min(2, buf.number_of_channels),
    H = H, hops = math.ceil(n / H), k = 0,
    p = {}, q = {}, last = { 0, 0 }, shown_at = now(),
  }
  restart_timer(A.tick, C.TICK_MS)
end

-- one slice of the envelope; true when the whole sample is done
function A.step(j, budget)
  local buf, H, n, chs = j.buf, j.H, j.n, j.chs
  local p, q, last = j.p, j.q, j.last
  local t_end = now() + budget
  local k = j.k
  while k < j.hops do
    k = k + 1
    local a = (k - 1) * H + 1
    local b = math.min(n, k * H)
    local sp, sq = 0, 0
    for c = 1, chs do
      local prev = last[c]
      for f = a, b do
        local v = buf:sample_data(c, f)
        local d = v - prev
        sp = sp + v * v
        sq = sq + d * d
        prev = v
      end
      last[c] = prev
    end
    local cnt = (b - a + 1) * chs
    p[k], q[k] = sp / cnt, sq / cnt
    if k % 8 == 0 and now() >= t_end then break end
  end
  j.k = k
  return k >= j.hops
end

function A.finish(j)
  local maxp = 0
  for k = 1, #j.p do if j.p[k] > maxp then maxp = j.p[k] end end
  A.remember { key = j.key, n = j.n, rate = j.rate, H = j.H,
               p = j.p, q = j.q, maxp = maxp, refined = {} }
  A.job = nil
  remove_timer(A.tick)
end

-- run the job for up to `budget` seconds; true when it is done
function A.run(budget)
  local j = A.job
  if not j then return true end
  local ok, done = pcall(A.step, j, budget)
  if not ok then                    -- the sample went away under us
    A.job = nil
    remove_timer(A.tick)
    return true
  end
  if done then A.finish(j) end
  return done
end

A.tick = function()
  local j = A.job
  if not j then remove_timer(A.tick) return end
  local done = A.run(C.BUDGET_S)
  if done then
    local pend = S.pending
    S.pending = nil
    if pend and pend.key == j.key then
      local smp, buf, song = current()
      if smp and key_of(song, buf) == pend.key then pend.fn(smp, buf, song) end
    end
    P.refresh(true)
  elseif now() - j.shown_at > 0.5 then
    j.shown_at = now()
    if S.pending then set_status("Finding transients... " .. A.progress() .. "%") end
    P.refresh(false)
  end
end

-- the transient candidates (coarse positions) for the current settings
function A.pick(c)
  local p, q, H = c.p, c.q, c.H
  local K = #p
  local rise_min = C.rise_for(prefs.sensitivity.value)
  local floor_db = db(c.maxp) - prefs.threshold.value
  local function pre(t, k)            -- mean of the three hops before k, dB
    local s, cnt = 0, 0
    for j = math.max(1, k - 3), k - 1 do s = s + t[j] cnt = cnt + 1 end
    return db(s / cnt)
  end
  local rise = { [1] = 0 }
  for k = 2, K do
    local r = 0
    local post = db(math.max(p[k], p[k + 1] or 0))
    if post >= floor_db then
      local postq = db(math.max(q[k], q[k + 1] or 0))
      r = math.max(post - pre(p, k), postq - pre(q, k))
    end
    rise[k] = r
  end
  -- local maxima that jump far enough
  local cands = {}
  for k = 2, K do
    local r = rise[k]
    if r >= rise_min then
      local top = true
      for j = math.max(2, k - 2), math.min(K, k + 2) do
        if j ~= k and (rise[j] > r or (rise[j] == r and j < k)) then
          top = false
          break
        end
      end
      if top then cands[#cands + 1] = { k = k, r = r } end
    end
  end
  -- Min gap: the strongest hits first, then whatever still fits in between
  table.sort(cands, function(x, y)
    if x.r ~= y.r then return x.r > y.r end
    return x.k < y.k
  end)
  local gap = math.max(1, math.floor(prefs.min_gap_ms.value / 1000
                                     * c.rate / H + 0.5))
  local taken, ks = {}, {}
  for _, cd in ipairs(cands) do
    local free = true
    for j = cd.k - gap + 1, cd.k + gap - 1 do
      if taken[j] then free = false break end
    end
    if free then taken[cd.k] = true ks[#ks + 1] = cd.k end
  end
  table.sort(ks)
  local points = {}
  for i, k in ipairs(ks) do points[i] = (k - 1) * H + 1 end
  c.points = points
  c.refined, c.ref_next = {}, 1
end

-- Bring a cache up to the current settings (cheap when nothing changed).
function A.fresh(c)
  local ps = prefs.sensitivity.value .. "/" .. prefs.threshold.value
             .. "/" .. prefs.min_gap_ms.value
  if c.p and c.pick_sig ~= ps then
    A.pick(c)
    c.pick_sig = ps
  end
  local rs = prefs.snap_mode.value .. "/" .. tostring(prefs.zero_cross.value)
  if c.ref_sig ~= rs then
    c.refined, c.ref_next = {}, 1
    c.ref_sig = rs
  end
  return c
end

-- the cache of the selected sample (nil while it is not analysed yet)
function A.current(song, buf)
  local c = A.caches[key_of(song, buf)]
  if c then return A.fresh(c) end
  return nil
end

-- Exact position of a transient near the coarse position `f`.
-- The onset is the change point: the frame that best splits ~40 ms around
-- the hit into a quieter part before and a louder part after (in the full
-- signal or in the treble, whichever changes more). That finds the start
-- of a hit on top of a pad or of the previous hit's tail as well as after
-- silence.
function A.refine(buf, f, H)
  local n = buf.number_of_frames
  local chs = math.min(2, buf.number_of_channels)
  local rate = buf.sample_rate
  local peak_frames = math.floor(C.PEAK_MS / 1000 * rate)
  local L = math.max(32, math.floor(rate * 0.003))
  local a = math.max(1, f - 4 * H)
  local e = math.min(n, f + 3 * H + L)              -- the range examined
  local b = math.min(n, e + peak_frames)             -- frames read
  local mono, mag = {}, {}
  for i = a, b do
    local s, mx = 0, 0
    for c = 1, chs do
      local v = buf:sample_data(c, i)
      s = s + v
      if v < 0 then v = -v end
      if v > mx then mx = v end
    end
    mono[i], mag[i] = s / chs, mx
  end
  -- running sums of the power of the signal (S1) and of its treble (S2)
  local a0 = a + 1
  local S1, S2 = { [a] = 0 }, { [a] = 0 }
  for i = a0, e do
    local v, d = mono[i], mono[i] - mono[i - 1]
    S1[i] = S1[i - 1] + v * v
    S2[i] = S2[i - 1] + d * d
  end
  local f0, best = nil, 0
  local t_lo = math.max(a0 + L, f - H)
  local t_hi = math.min(e - L + 1, f + 3 * H)
  local N = e - a0 + 1
  local eps = 1e-14
  for _, Sx in ipairs { S1, S2 } do
    local total = Sx[e] - Sx[a]
    local base = N * math.log(total / N + eps)
    for t = t_lo, t_hi do
      local n1, n2 = t - a0, e - t + 1
      local s1 = Sx[t - 1] - Sx[a]
      local m1, m2 = s1 / n1 + eps, (total - s1) / n2 + eps
      if m2 > m1 then
        local gain = base - n1 * math.log(m1) - n2 * math.log(m2)
        if gain > best then best, f0 = gain, t end
      end
    end
  end
  if not f0 then return clamp(f, 1, n) end
  if prefs.snap_mode.value == 2 then
    -- "Peak": the loudest frame of the hit
    local last = math.min(b, f0 + peak_frames)
    local top, at = -1, f0
    for i = f0, last do if mag[i] > top then top, at = mag[i], i end end
    return at
  end
  if prefs.zero_cross.value then
    -- onto the nearest zero crossing before it
    local stop = math.max(a + 1, f0 - math.floor(C.ZC_MS / 1000 * rate))
    for i = f0, stop, -1 do
      local x, y = mono[i - 1], mono[i]
      if y == 0 or (x < 0) ~= (y < 0) then
        if math.abs(x) < math.abs(y) then return i - 1 end
        return i
      end
    end
  end
  return f0
end

-- exact position of transient i (computed once, then remembered)
function A.pos(c, buf, i)
  local r = c.refined[i]
  if not r then
    r = A.refine(buf, c.points[i], c.H)
    c.refined[i] = r
  end
  return r
end

-- first transient after edge `ref`: position, index
function A.next_after(c, buf, ref)
  local pts = c.points
  local lo, hi = 1, #pts + 1       -- first point >= ref - 2 hops
  local lim = ref - 2 * c.H
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if pts[mid] < lim then lo = mid + 1 else hi = mid end
  end
  for i = lo, #pts do
    local r = A.pos(c, buf, i)
    if r > ref then return r, i end
  end
  return nil
end

-- last transient before edge `ref`: position, index
function A.prev_before(c, buf, ref)
  local pts = c.points
  local lo, hi = 0, #pts           -- last point <= ref + 4 hops
  local lim = ref + 4 * c.H
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if pts[mid] <= lim then lo = mid else hi = mid - 1 end
  end
  for i = lo, 1, -1 do
    local r = A.pos(c, buf, i)
    if r < ref then return r, i end
  end
  return nil
end

-- how many transients lie in edges lo .. hi - 1 (for messages: exact
-- where known, else the coarse position)
function A.count_in(c, lo, hi)
  local n = 0
  for i, f in ipairs(c.points) do
    f = c.refined[i] or f
    if f >= lo and f < hi then n = n + 1 end
  end
  return n
end

-- Runs fn(smp, buf, song) as soon as the selected sample's transients are
-- known: right away when they are, after a short wait for a short sample,
-- else when the background analysis is done.
function A.with(fn)
  local smp, buf, song = current()
  if not smp then set_status(buf) return end
  local key = key_of(song, buf)
  if A.caches[key] then fn(smp, buf, song) return end
  if not A.job or A.job.key ~= key then A.start(buf, key) end
  if A.run(C.WAIT_S) and A.caches[key] then
    fn(smp, buf, song)
    P.refresh(true)
    return
  end
  S.pending = { key = key, fn = fn }
  set_status("Finding transients... " .. A.progress() .. "%")
end

-- After our own trim: the transients that are left, moved along, so the
-- cursor keeps working while the new length is analysed in the background.
function A.shifted(old_key, shift, total, song, buf)
  local c = A.caches[old_key]
  if A.job then A.job = nil remove_timer(A.tick) end
  local key = key_of(song, buf)
  if c and c.points then
    local pts, ref = {}, {}
    for i, f in ipairs(c.points) do
      local nf = f - shift
      if nf > 1 and nf <= total then
        pts[#pts + 1] = nf
        local r = c.refined[i] and c.refined[i] - shift
        if r and r > 1 and r <= total then ref[#pts] = r end
      end
    end
    A.remember { key = key, n = total, rate = c.rate, H = c.H,
                 points = pts, refined = ref, ref_sig = c.ref_sig }
  end
  A.start(buf, key)
end


--------------------------------------------------------------------------------
-- The cursor model
--------------------------------------------------------------------------------

local function span()
  return math.min(S.anchor, S.edge), math.max(S.anchor, S.edge)
end

-- Bring the model up to date with the editor: the user may have clicked or
-- dragged in it, cleared the selection, or picked another sample.
-- (Renoise's own dotted play cursor is not visible to tools; the selection
-- is all the API shows.)
local function sync(song, buf)
  local n = buf.number_of_frames
  local id = ident_of(song)
  if S.ident ~= id then
    S.ident, S.anchor, S.edge, S.shown = id, nil, nil, nil
  end
  local a, b, whole = selection_of(buf)
  local ours = S.shown and a == S.shown[1] and b == S.shown[2]
  if not (ours and S.anchor) then
    if whole then
      -- selection cleared (a click): stay where we were - the dotted
      -- cursor it moved is not visible to tools
      if not S.anchor then S.anchor, S.edge = 1, 1 end
    elseif a == b then
      S.anchor, S.edge = a, a        -- clicked: from there
    else
      S.anchor, S.edge = a, b + 1    -- a selection made in the editor
    end
  end
  S.anchor = clamp(S.anchor, 1, n + 1)
  S.edge = clamp(S.edge, 1, n + 1)
end

-- show the model in the editor
local function show(buf)
  local n = buf.number_of_frames
  local lo, hi = span()
  local a, b
  if lo == hi then
    a = math.min(lo, n)
    b = a
  else
    a, b = lo, math.min(hi - 1, n)
  end
  set_selection(buf, a, b)
  local ra, rb = selection_of(buf)
  S.shown = { ra, rb }
  if prefs.follow.value then follow(buf, math.min(S.edge, n)) end
  P.refresh(false)
end

-- "Transient 5 of 24 - 1.250 s" / "Selected 0.500 s - 2.000 s (...)"
local function report(c, buf, idx, prefix)
  local rate = buf.sample_rate
  local lo, hi = span()
  local msg
  if lo ~= hi then
    local hits = c and A.count_in(c, lo, hi) or 0
    msg = string.format("Selected %s - %s  (%s, %d transient%s)",
      fmt_edge(lo, rate), fmt_edge(hi, rate),
      fmt_time(hi - lo, rate), hits, hits == 1 and "" or "s")
  elseif idx then
    msg = string.format("Transient %d of %d - %s", idx, #c.points,
                        fmt_edge(S.edge, rate))
  else
    msg = "Cursor at " .. fmt_edge(S.edge, rate)
  end
  set_status((prefix or "") .. msg)
end


--------------------------------------------------------------------------------
-- Prehear, straight from the sample editor: the selection, or from the
-- cursor to the end (auto-prehear: just the hit, at most a few seconds).
-- Renoise plays a selection, so while it sounds the part that plays is
-- selected, and the cursor comes back afterwards. (Renoise's own Play
-- Selection works on the tool's selections as well.)
--------------------------------------------------------------------------------

function M.stop_prehear()
  local p = S.play
  S.play = nil
  if not p then return false end
  pcall(function()
    renoise.song():trigger_sample_note_off(p.ii, p.si, p.track, p.note)
  end)
  return true
end

-- auto: the hit at the cursor (auto-prehear); else the key / button. Like
-- Renoise's own play keys it always starts over; Prehear - Stop stops.
function M.prehear(auto)
  local smp, buf, song = current()
  if not smp then set_status(buf) return end
  sync(song, buf)
  M.stop_prehear()
  local n, rate = buf.number_of_frames, buf.sample_rate
  local lo, hi = span()
  local a, b, restore
  if hi > lo then
    a, b = lo, math.min(n, hi - 1)            -- the selection
  else
    a, b, restore = math.min(lo, n), n, true  -- from the cursor on
    if auto then                              -- just the hit
      local c = A.current(song, buf)
      local nx = c and A.next_after(c, buf, a)
      b = math.min(nx and nx - 1 or n, a + math.floor(C.AUTO_MAX_S * rate))
    end
  end
  if b <= a then return end
  local ii, si = song.selected_instrument_index, song.selected_sample_index
  local track = prefs.prehear_master.value and (song.sequencer_track_count + 1)
                or song.selected_track_index
  local note = 48
  pcall(function() note = smp.sample_mapping.base_note end)
  if restore then
    set_selection(buf, a, b)
    local ra, rb = selection_of(buf)
    S.shown = { ra, rb }
  end
  local ok = pcall(function()
    song:trigger_sample_note_on(ii, si, track, note, 1.0, true)
  end)
  if not ok then
    if restore then show(buf) end
    if not auto then set_status("Prehear failed (needs Renoise 3.5)") end
    return
  end
  local speed = 1
  pcall(function() speed = 2 ^ ((smp.transpose + smp.fine_tune / 128) / 12) end)
  S.play = { ii = ii, si = si, track = track, note = note, restore = restore,
             t_end = now() + (b - a + 1) / rate / speed }
  P.refresh(false)
end


--------------------------------------------------------------------------------
-- Moving
--------------------------------------------------------------------------------

-- Where a selection edge can go next: right_of(f) / left_of(f) give the
-- next stop after / before edge f - a transient (or the start / end of the
-- sample), or with Snap Selection to Transients off a fine step (1 % of
-- what the sample editor shows).
function C.edge_stops(c, buf)
  local n = buf.number_of_frames
  local snap = prefs.snap_edges.value
  local step = 1
  pcall(function() step = math.max(1, math.floor(buf.display_length / 100)) end)
  local function right_of(f)
    if snap then return A.next_after(c, buf, f) or (f <= n and n + 1 or nil) end
    return f <= n and math.min(n + 1, f + step) or nil
  end
  local function left_of(f)
    if snap then return A.prev_before(c, buf, f) or (f > 1 and 1 or nil) end
    return f > 1 and math.max(1, f - step) or nil
  end
  return right_of, left_of
end

-- Move one edge of the selection: which = "start" or "end", dir = 1 (to
-- the right) or -1 (to the left). With nothing selected, to the right
-- selects the hit at the cursor, to the left the hit before it. A
-- selection keeps at least one hit (or step) and never wraps.
function M.edge(which, dir)
  A.with(function(smp, buf, song)
    sync(song, buf)
    local c = A.current(song, buf)
    if not c then return end
    local lo, hi = span()
    local snap = prefs.snap_edges.value
    local right_of, left_of = C.edge_stops(c, buf)
    if lo == hi then                          -- a cursor: start a selection
      which = dir > 0 and "end" or "start"
    end
    local target
    if which == "end" then
      target = dir > 0 and right_of(hi) or left_of(hi)
      if target and target <= lo then target = nil end   -- keep one hit
    else
      target = dir > 0 and right_of(lo) or left_of(lo)
      if target and target >= hi and hi > lo then target = nil end
    end
    if not target then
      set_status((lo == hi or (which == "end") == (dir > 0))
        and (dir > 0 and "The selection reaches the end of the sample"
                     or "The selection reaches the start of the sample")
        or "One hit left - the selection can not get smaller")
      return
    end
    -- the edge that moved is the one followed on screen
    if which == "end" then S.anchor, S.edge = lo, target
    else S.anchor, S.edge = hi, target end
    M.stop_prehear()
    show(buf)
    report(c, buf, nil)
    if snap and prefs.autoplay.value then M.prehear(false) end
  end)
end

-- Both edges at once: dir = 1 out - one transient
-- more on each side (an edge already at the start / end of the sample
-- stays), dir = -1 in - one less on each side, while a hit is left. From a
-- cursor, out selects the hit before it and the hit at it.
function M.both(dir)
  A.with(function(smp, buf, song)
    sync(song, buf)
    local c = A.current(song, buf)
    if not c then return end
    local lo, hi = span()
    local right_of, left_of = C.edge_stops(c, buf)
    local nlo, nhi
    if dir > 0 then
      nlo, nhi = left_of(lo) or lo, right_of(hi) or hi
      if nlo == lo and nhi == hi then
        set_status("The selection is the whole sample") return
      end
    else
      if hi == lo then set_status("Nothing selected") return end
      nlo, nhi = right_of(lo), left_of(hi)
      if not nlo or not nhi or nhi <= nlo then
        set_status("Too small to take a hit off both sides") return
      end
    end
    S.anchor, S.edge = nlo, nhi
    M.stop_prehear()
    show(buf)
    report(c, buf, nil)
    if prefs.snap_edges.value and prefs.autoplay.value then M.prehear(false) end
  end)
end

-- dir: 1 = next, -1 = previous. Lets go of a selection; wraps when the
-- option is on (past the last hit: the start; before the start: the last).
function M.move(dir)
  A.with(function(smp, buf, song)
    sync(song, buf)
    local c = A.current(song, buf)
    if not c then return end
    local n = buf.number_of_frames
    local lo, hi = span()
    local target, idx, wrapped
    do
      local wrap = prefs.wrap.value and #c.points > 0
      if dir > 0 then
        target, idx = A.next_after(c, buf, (lo == hi) and lo or hi - 1)
        if not target and wrap then target, wrapped = 1, true end
        if not target then
          set_status(#c.points == 0
            and "No transients found - try a higher Sensitivity"
            or "No more transients after the cursor")
          return
        end
      else
        target, idx = A.prev_before(c, buf, lo)
        if not target and lo > 1 then target = 1 end
        if not target and wrap then
          target, idx = A.prev_before(c, buf, n + 1)
          wrapped = true
        end
        if not target then set_status("At the start of the sample") return end
      end
      S.anchor, S.edge = target, target
    end
    M.stop_prehear()
    show(buf)
    report(c, buf, idx, wrapped and (dir > 0 and "Back to the start - "
                                     or "Round to the last hit - "))
    if prefs.autoplay.value then M.prehear(true) end
  end)
end


--------------------------------------------------------------------------------
-- Trims. The sample is rebuilt from the part that is kept; loop points and
-- slice markers move along. Undo works as for Renoise's own sample edits.
--------------------------------------------------------------------------------

-- keep frames ka .. kb of the sample
local function rebuild(smp, buf, ka, kb)
  local chs = buf.number_of_channels
  local total = kb - ka + 1
  local rate, bits = buf.sample_rate, buf.bit_depth
  local data = {}
  for c = 1, chs do
    local t, i = {}, 0
    for f = ka, kb do i = i + 1 t[i] = buf:sample_data(c, f) end
    data[c] = t
  end
  local lm, ls, le = smp.loop_mode, smp.loop_start, smp.loop_end
  local markers, had_markers = {}, #smp.slice_markers > 0
  for _, m in ipairs(smp.slice_markers) do
    if m >= ka and m <= kb then markers[#markers + 1] = m - ka + 1 end
  end
  if not buf:create_sample_data(rate, bits, chs, total) then
    error("not enough memory for the new sample", 0)
  end
  buf:prepare_sample_data_changes()
  for c = 1, chs do
    local t = data[c]
    for f = 1, total do buf:set_sample_data(c, f, t[f]) end
  end
  buf:finalize_sample_data_changes()
  -- the loop: what is left of it, or off when it was cut away
  pcall(function()
    local nls, nle = clamp(ls - ka + 1, 1, total), clamp(le - ka + 1, 1, total)
    if lm ~= LOOP_OFF and le >= ka and ls <= kb and nle > nls then
      smp.loop_start = 1
      smp.loop_end = nle
      smp.loop_start = nls
      smp.loop_mode = lm
    else
      smp.loop_mode = LOOP_OFF
    end
  end)
  if had_markers then
    pcall(function()
      for i = #smp.slice_markers, 1, -1 do
        smp:delete_slice_marker(smp.slice_markers[i])
      end
      for _, m in ipairs(markers) do smp:insert_slice_marker(m) end
    end)
  end
  return total
end

-- which: "left" | "right" | "selection"
function M.trim(which)
  local smp, buf, song = current()
  if not smp then set_status(buf) return end
  if buf.read_only then
    set_status("This is a slice - trim the sliced sample (the first one)")
    return
  end
  sync(song, buf)
  local n, rate = buf.number_of_frames, buf.sample_rate
  local lo, hi = span()
  local ka, kb
  if which == "left" then
    if lo <= 1 then set_status("Nothing left of the cursor") return end
    ka, kb = lo, n
  elseif which == "right" then
    if hi > n then set_status("Nothing right of the cursor") return end
    ka, kb = 1, hi - 1
  else
    if hi - lo < 2 then
      set_status("Select a part first: Selection End to Next Transient"
                 .. " (or drag in the sample editor)")
      return
    end
    ka, kb = lo, hi - 1
    if ka <= 1 and kb >= n then
      set_status("The selection is the whole sample")
      return
    end
  end
  if kb - ka + 1 < 2 then set_status("Nothing would be left") return end

  M.stop_prehear()
  local old_key = key_of(song, buf)
  local ok, res = pcall(rebuild, smp, buf, ka, kb)
  if not ok then set_status("Trim failed: " .. tostring(res)) return end
  local total = res

  local shift = ka - 1
  if which == "selection" then
    S.anchor, S.edge = 1, 1
  else
    S.anchor = clamp(S.anchor - shift, 1, total + 1)
    S.edge = clamp(S.edge - shift, 1, total + 1)
  end
  A.shifted(old_key, shift, total, song, buf)
  show(buf)
  local removed = n - total
  if which == "left" then
    set_status("Trimmed left of the cursor - " .. fmt_time(removed, rate)
               .. " removed")
  elseif which == "right" then
    set_status("Trimmed right of the cursor - " .. fmt_time(removed, rate)
               .. " removed")
  else
    set_status("Trimmed to the selection - " .. fmt_time(total, rate)
               .. " left")
  end
end


--------------------------------------------------------------------------------
-- Settings by key
--------------------------------------------------------------------------------

local function count_message(prefix)
  local smp, buf, song = current()
  if not smp then set_status(prefix) return end
  A.with(function(smp2, buf2, song2)
    local c = A.current(song2, buf2)
    local n = c and #c.points or 0
    set_status(prefix .. (prefix == "Found" and " " or " - ") .. n
               .. " transient" .. (n == 1 and "" or "s"))
  end)
end

-- (the panel's sliders leave fractions behind: steps land on whole numbers)
function M.step_sensitivity(d)
  prefs.sensitivity.value = clamp(math.floor(prefs.sensitivity.value + 0.5)
                                  + d * C.SENS_STEP, C.SENS_MIN, C.SENS_MAX)
  count_message("Sensitivity " .. prefs.sensitivity.value .. " %")
end

function M.step_threshold(d)
  prefs.threshold.value = clamp(math.floor(prefs.threshold.value + 0.5)
                                + d * C.THRESH_STEP, C.THRESH_MIN, C.THRESH_MAX)
  count_message("Threshold -" .. prefs.threshold.value .. " dB")
end

-- Find Transients: analyse the selected sample from scratch with the
-- current settings (it also happens by itself; this forces it)
function M.find()
  local smp, buf, song = current()
  if not smp then set_status(buf) return end
  local key = key_of(song, buf)
  A.caches[key] = nil
  for i = #A.order, 1, -1 do                -- and out of the cache's order
    if A.order[i] == key then table.remove(A.order, i) end
  end
  if A.job and A.job.key == key then A.job = nil end
  count_message("Found")
end

function M.toggle_snap_edges()
  prefs.snap_edges.value = not prefs.snap_edges.value
  set_status(prefs.snap_edges.value
    and "Snap selection to transients: on - the edges move hit by hit"
    or "Snap selection to transients: off - the edges move in fine steps")
end

function M.toggle_autoplay()
  prefs.autoplay.value = not prefs.autoplay.value
  if not prefs.autoplay.value then M.stop_prehear() end
  set_status("Auto-prehear " .. (prefs.autoplay.value and "on" or "off"))
end


--------------------------------------------------------------------------------
-- Idle: things that cannot be event driven
--   - a prehear of a hit ended: the cursor comes back
--   - the selected sample changed or was edited: analyse it in the background
--   - the panel shows what changed
--------------------------------------------------------------------------------

local idle_state = { fp_t = 0, key = nil, key_t = 0 }

local function idle()
  local smp, buf, song = current()
  if not smp then
    if dialog_open() then P.refresh(false) end
    return
  end

  -- prehear ended
  local p = S.play
  if p and now() >= p.t_end then
    S.play = nil
    if p.restore and S.shown and S.anchor and S.ident == ident_of(song) then
      local a, b = selection_of(buf)
      if a == S.shown[1] and b == S.shown[2] then show(buf) end
    end
  end

  -- the sample changed: analyse it once it is settled
  local t = now()
  if t - idle_state.fp_t >= C.FP_EVERY_S or idle_state.ident ~= ident_of(song) then
    idle_state.fp_t = t
    idle_state.ident = ident_of(song)
    local key = key_of(song, buf)
    if key ~= idle_state.key then
      idle_state.key, idle_state.key_t = key, t
    end
  end
  local key = idle_state.key
  if key and not A.caches[key] and not (A.job and A.job.key == key)
     and t - idle_state.key_t >= C.PREFETCH_S then
    local w = renoise.app().window
    if dialog_open() or w.active_middle_frame
       == renoise.ApplicationWindow.MIDDLE_FRAME_INSTRUMENT_SAMPLE_EDITOR then
      A.start(buf, key)
    end
  end

  if dialog_open() then P.refresh(false) end
end

local function idle_safe()
  pcall(idle)
end
renoise.tool().app_idle_observable:add_notifier(idle_safe)


--------------------------------------------------------------------------------
-- Which keys to suggest for the selection edges. Shift+arrows belong to
-- Renoise (not assignable) and the common modifiers are often taken, so the
-- tool reads your own key bindings (KeyBindings.xml - Renoise writes it
-- when it quits) and suggests the first set that is free in both the Global
-- and the Sample Editor section. A set: a modifier with
--   Left / Right            selection end to previous / next transient
--   + Shift  Left / Right   selection start to previous / next transient
--   Up / Down               both edges out / in
--------------------------------------------------------------------------------

C.MAC = os.platform() == "MACINTOSH"
C.WIN = os.platform() == "WINDOWS"
C.KEY_SCHEMES = C.MAC
  and { { "Control", "Option" }, { "Option" }, { "Control" }, { "Command", "Option" } }
  or  { { "Control", "Alt" }, { "Alt" }, { "Control" } }
C.MOD_ORDER = { Control = 1, Command = 2, Alt = 3, Option = 3, Shift = 4 }
C.MOD_SHOW = { Control = "Ctrl", Command = "Cmd", Alt = "Alt",
               Option = "Option", Shift = "Shift" }

-- "Shift + Control + Tab" -> "Control + Shift + Tab" (one spelling per key)
function C.norm_key(k)
  local parts = {}
  for p in (k .. " + "):gmatch("(.-)%s*%+%s*") do
    if p ~= "" then parts[#parts + 1] = p end
  end
  local key = table.remove(parts)
  table.sort(parts, function(a, b)
    return (C.MOD_ORDER[a] or 9) < (C.MOD_ORDER[b] or 9)
  end)
  parts[#parts + 1] = key
  return table.concat(parts, " + ")
end

function C.keybindings_path()
  local paths = {}
  local b = (renoise.tool().bundle_path or ""):gsub("[/\\]+$", "")
  -- the tool lives in <Renoise prefs>/Scripts/Tools/<tool>
  local up = b:match("^(.*)[/\\][^/\\]+[/\\][^/\\]+[/\\][^/\\]+$")
  if up then paths[#paths + 1] = up .. (C.WIN and "\\" or "/") .. "KeyBindings.xml" end
  local v = tostring(renoise.RENOISE_VERSION or ""):match("(%d+%.%d+%.%d+)")
  if v then
    if C.WIN then
      local home = os.getenv("APPDATA")
      if home then paths[#paths + 1] = home .. "\\Renoise\\V" .. v .. "\\KeyBindings.xml" end
    elseif C.MAC then
      paths[#paths + 1] = (os.getenv("HOME") or "") .. "/Library/Preferences/Renoise/V"
                          .. v .. "/KeyBindings.xml"
    else
      paths[#paths + 1] = (os.getenv("HOME") or "") .. "/.config/Renoise/V"
                          .. v .. "/KeyBindings.xml"
    end
  end
  for _, path in ipairs(paths) do
    local f = io.open(path, "r")
    if f then f:close() return path end
  end
  return nil
end

-- key -> what has it, for the Global and Sample Editor sections (this
-- tool's own bindings left out); nil when the file can not be read
function C.used_keys()
  local path = C.keybindings_path()
  local f = path and io.open(path, "r")
  if not f then return nil end
  local xml = f:read("*a")
  f:close()
  local used = {}
  for cat in xml:gmatch("<Category>(.-)</Category>") do
    local id = cat:match("<Identifier>(.-)</Identifier>")
    if id == "Global" or id == "Sample Editor" then
      for kb in cat:gmatch("<KeyBinding>(.-)</KeyBinding>") do
        local key = kb:match("<Key>(.-)</Key>")
        local topic = kb:match("<Topic>(.-)</Topic>") or ""
        if key and topic ~= TOOL_NAME then
          used[C.norm_key(key)] = id .. ": " .. topic .. ": "
                                  .. (kb:match("<Binding>(.-)</Binding>") or "")
        end
      end
    end
  end
  return used
end

-- the keys of a set, in KeyBindings.xml spelling
function C.scheme_keys(mods)
  local function k(extra, key)
    local parts = {}
    for _, m in ipairs(mods) do parts[#parts + 1] = m end
    if extra then parts[#parts + 1] = extra end
    parts[#parts + 1] = key
    return C.norm_key(table.concat(parts, " + "))
  end
  return {
    end_l = k(nil, "Left"), end_r = k(nil, "Right"),
    start_l = k("Shift", "Left"), start_r = k("Shift", "Right"),
    out = k(nil, "Up"), inn = k(nil, "Down"),
  }
end

-- Ctrl-Alt-Left etc., as Simple Browser writes keys
function C.show_key(k)
  local out = {}
  for p in (k .. " + "):gmatch("(.-)%s*%+%s*") do
    if p ~= "" then out[#out + 1] = C.MOD_SHOW[p] or p end
  end
  return table.concat(out, "-")
end

-- The set to suggest: { mods=, keys=, free=true|false|nil (nil: your key
-- bindings could not be read), clashes={...} }. Worked out once a session
-- (the file only changes when Renoise quits).
function C.scheme()
  if C.scheme_cache then return C.scheme_cache end
  local used = C.used_keys()
  local best
  for _, mods in ipairs(C.KEY_SCHEMES) do
    local keys = C.scheme_keys(mods)
    local clashes = {}
    if used then
      for _, name in ipairs { "end_l", "end_r", "start_l", "start_r", "out", "inn" } do
        if used[keys[name]] then
          clashes[#clashes + 1] = C.show_key(keys[name]) .. " is " .. used[keys[name]]
        end
      end
    end
    local cand = { mods = mods, keys = keys, clashes = clashes,
                   free = used and #clashes == 0 or nil }
    if not used or #clashes == 0 then best = cand break end
    if not best or #clashes < #best.clashes then best = cand end
  end
  if used and best.free == nil then best.free = false end
  -- Tab / Shift-Tab / Shift-` are suggested too: say so if they are taken
  -- (the ` key is looked up under each name a keyboard layout may give it)
  for _, k in ipairs { { "Tab" }, { "Shift + Tab" },
                       { "Shift + `", "Shift + ~", "Shift + Grave",
                         "Shift + Backquote", "Shift + Tilde" } } do
    for _, spelling in ipairs(k) do
      if used and used[spelling] then
        best.clashes[#best.clashes + 1] = (k[1] == "Shift + `" and "Shift-`"
          or C.show_key(spelling)) .. " is " .. used[spelling]
        best.free = false
        break
      end
    end
  end
  C.scheme_cache = best
  return best
end

--------------------------------------------------------------------------------
-- Options, defined ONCE. Both the panel's "Options" menu and
-- Tools > Simple Transients > Options are built from this list, so they
-- always match - and they hold everything the panel does. sep = a divider
-- line before the entry; on = a check mark; values = what Help shows.
--------------------------------------------------------------------------------

local function toggler(name)
  return function() prefs[name].value = not prefs[name].value end
end

-- a detection setting: "Enter Value", the current value in it
local function setting(name, pref, min, max)
  return function()
    C.value_prompt({ name = name, min = min, max = max,
      set = function(v) prefs[pref].value = v end },
      tostring(prefs[pref].value))
  end
end

C.OPTIONS = {
  { label = "Find Transients", set = function() M.find() end },
  { label = "Sensitivity...", sep = true,
    values = C.SENS_MIN .. " - " .. C.SENS_MAX .. " %",
    set = setting("Sensitivity (%)", "sensitivity", C.SENS_MIN, C.SENS_MAX) },
  { label = "Threshold...",
    values = C.THRESH_MIN .. " - " .. C.THRESH_MAX .. " dB down",
    set = setting("Threshold (dB below the loudest part)", "threshold",
                  C.THRESH_MIN, C.THRESH_MAX) },
  { label = "Min gap...",
    values = C.GAP_MIN .. " - " .. C.GAP_MAX .. " ms",
    set = setting("Min gap (ms)", "min_gap_ms", C.GAP_MIN, C.GAP_MAX) },
  { label = "Snap to Onset", values = "Onset / Peak",
    on = function() return prefs.snap_mode.value == 1 end,
    set = function() prefs.snap_mode.value = 1 end },
  { label = "Snap to Peak", help = false,
    on = function() return prefs.snap_mode.value == 2 end,
    set = function() prefs.snap_mode.value = 2 end },
  { label = "Onsets snap to zero crossings",
    on = function() return prefs.zero_cross.value end,
    set = toggler("zero_cross") },
  { label = "Snap selection to transients",
    on = function() return prefs.snap_edges.value end,
    set = function() M.toggle_snap_edges() end },
  { label = "Wrap around (past the last hit: back to the start)", sep = true,
    on = function() return prefs.wrap.value end,
    set = toggler("wrap") },
  { label = "Scroll the sample editor along with the cursor",
    on = function() return prefs.follow.value end,
    set = toggler("follow") },
  { label = "Auto-prehear", sep = true,
    on = function() return prefs.autoplay.value end,
    set = function() M.toggle_autoplay() end },
  { label = "Prehear on Master",
    on = function() return prefs.prehear_master.value end,
    set = function() prefs.prehear_master.value = true end },
  { label = "Prehear on Selected Track",
    on = function() return not prefs.prehear_master.value end,
    set = function() prefs.prehear_master.value = false end },
}

-- entries for a dialog menu (renoise.app():show_menu)
function C.option_menu_items()
  local items = {}
  for _, o in ipairs(C.OPTIONS) do
    items[#items + 1] = {
      name = ((o.sep and #items > 0) and "---" or "") .. o.label,
      selected = o.on and o.on() or false, invoke = o.set,
    }
  end
  return items
end


--------------------------------------------------------------------------------
-- View helpers (the panel)
--------------------------------------------------------------------------------

local function view(id)
  return S.vb and S.vb.views[id] or nil
end

-- Assign a theme colour, falling back to RGB if the name is unknown.
local function paint(ctx, prop, theme, rgb)
  if not pcall(function() ctx[prop] = theme end) then
    ctx[prop] = rgb or C.FALLBACK[theme] or { 128, 128, 128 }
  end
end


--------------------------------------------------------------------------------
-- Commands: the sample editor's right-click menu.
--------------------------------------------------------------------------------

C.COMMANDS = {
  { "Next Transient", function() M.move(1) end },
  { "Previous Transient", function() M.move(-1) end },
  { "Selection Start to Previous Transient", function() M.edge("start", -1) end,
    sep = true },
  { "Selection Start to Next Transient", function() M.edge("start", 1) end },
  { "Selection End to Previous Transient", function() M.edge("end", -1) end },
  { "Selection End to Next Transient", function() M.edge("end", 1) end },
  { "Selection Both Edges Out", function() M.both(1) end },
  { "Selection Both Edges In", function() M.both(-1) end },
  { "Trim Left of Cursor", function() M.trim("left") end, sep = true },
  { "Trim Right of Cursor", function() M.trim("right") end },
  { "Trim to Selection", function() M.trim("selection") end },
  { "Prehear", function() M.prehear(false) end, sep = true },
  { "Stop Prehear", function() M.stop_prehear() end },
  { "Find Transients", function() M.find() end, sep = true },
  { "Show / Hide Panel", function() P.toggle() end },
}


local IS_WINDOWS = C.WIN               -- (as Simple Browser names it)

--------------------------------------------------------------------------------
-- Help window, in the style of Schism Tracker's F1 help: a boxed title,
-- headings ending in a full stop, and every entry a key padded to one
-- column, then what it does. One blank line between sections, none inside.
-- 80 columns by 25 rows, one text view per line (see HELP.toggle). The lists of options and key bindings are made from the
-- lists the tool itself uses, so they never go out of date.
-- This block is copied unchanged from Simple Browser; keep it the same in
-- both tools.
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
  for l in (HELP.title(spec.name, cols) .. "\n\n" .. text .. "\n")
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
  local title = spec.name .. " - Help"
  local ok, dlg = pcall(function()
    return renoise.app():show_custom_dialog(title, content, handler,
      { send_key_repeat = true, send_key_release = false })
  end)
  if not ok or not dlg then
    dlg = renoise.app():show_custom_dialog(title, content, handler)
  end
  spec.dialog = dlg
end

local toggle_help_dialog

C.BINDINGS = {}       -- { scope, name, description } as registered
C.MIDI = {}           -- the MIDI mappings' names, for Help

function C.help_text()
  local out = {}
  local function add(...)
    for _, line in ipairs { ... } do out[#out + 1] = line end
  end
  local head = HELP.head
  -- words in lines of at most `w` characters
  local function wrap(text, w)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
      if line ~= "" and #line + 1 + #word > w then
        lines[#lines + 1] = line
        line = word
      else
        line = line == "" and word or (line .. " " .. word)
      end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
  end
  local TEXT_W = 73                    -- as wide as Simple Browser's text
  -- a paragraph, 3 in
  local function para(t)
    for _, l in ipairs(wrap(t, TEXT_W - 3)) do add("   " .. l) end
  end
  -- HELP.key, its description wrapped onto HELP.more lines
  local function it(k, t, w)
    w = w or HELP.KEY_W
    for i, l in ipairs(wrap(t, TEXT_W - 3 - w)) do
      add(i == 1 and HELP.key(k, l, w) or HELP.more(l, w))
    end
  end
  local sc = C.scheme()
  local sk = sc.keys
  local function pair(k, other) return C.show_key(k) .. " / " .. other end
  -- the width of the Key Bindings name column, for the suggested keys
  local nw = 0
  for _, b in ipairs(C.BINDINGS) do nw = math.max(nw, #b[2]) end
  nw = nw + 2

  add(head("Quick Start"))
  para("Finds the transients of the sample in the sample editor - drum "
    .. "hits in a loop, words in a recording - so you can step from hit to "
    .. "hit, move the selection's edges transient by transient, and crop "
    .. "single hits or parts of loops. Bind the keys in Preferences > Keys "
    .. "> Sample Editor > " .. TOOL_NAME .. " (the main commands are also in the "
    .. "sample editor's right-click menu); suggested:")
  it("Next Transient", "Tab", nw)
  it("Previous Transient", "Shift-`", nw)
  it("Selection End to Next Transient (2nd)", "Shift-Tab", nw)
  it("Selection End to Previous / Next", pair(sk.end_l, "Right"), nw)
  it("Selection Start to Previous / Next", pair(sk.start_l, "Right"), nw)
  it("Selection Both Edges Out / In", pair(sk.out, "Down"), nw)
  if sc.free then
    para("These are free in your key bindings, as Renoise last saved them.")
  elseif sc.free == false then
    para("Some of these are taken in your key bindings:")
    for _, cl in ipairs(sc.clashes) do it("", cl) end
  else
    para("Your key bindings could not be read: check for clashes in Keys.")
  end
  add("")

  add(head("Stepping and Selecting"))
  para("A selection ends one frame before a transient, so it loops "
    .. "cleanly; a plain step lets go of it. Renoise keeps Shift-arrows for "
    .. "its own selection (not assignable); Renoise's own Play Selection "
    .. "plays it.")
  it("Next, Previous", "The cursor to the next / previous transient; with "
    .. "Wrap around, past the last one: back to the start")
  it("Selection End", "The selection's end to the next / previous "
    .. "transient, out or in. Nothing selected: Next selects the hit at "
    .. "the cursor, Previous the one before it")
  it("Selection Start", "The same for the selection's start")
  it("Both Edges", "Out / In: a transient more / less on each side")
  it("Click", "The tool stays where it was (it cannot see the dotted "
    .. "cursor); click, then Shift-arrow, and it goes on from there")
  add("")

  add(head("Cropping"))
  para("With a selection, left and right mean left and right of it. "
    .. "Renoise's own Copy into New Sample / Instrument use the selection "
    .. "too.")
  it("Trim Left", "Delete everything before the cursor")
  it("Trim Right", "Delete from the cursor on (the cursor's hit too)")
  it("Trim to Selection", "Keep only the selection")
  add("")

  add(head("Prehear"))
  it("Play", "The selection, or from the cursor to the end")
  it("Stop", "Silence it")
  it("Auto-prehear", "Play each hit as you step (Options)")
  it("Master, Track", "Where it plays (Options)")
  add("")

  add(head("Panel (Toggle Panel key, also Tools > " .. TOOL_NAME .. ")"))
  para("The detection settings; everything here is also in Options. "
    .. "The panel's keys are below.")
  it("Find Transients", "Analyse the sample again (also done by itself)")
  it("Sensitivity", "How small a jump in level counts as a hit")
  it("Threshold", "Ignore hits this far below the loudest part")
  it("Min gap", "Transients at least this far apart; the stronger hit "
    .. "wins (speech: raise it)")
  it("Snap to", "Onset: the start of the hit, the place to cut; Peak: its "
    .. "loudest point")
  it("Zero crossings", "Onsets move back to one: no clicks")
  it("Snap selection", "Selection edges move by transient; Off: in fine "
    .. "steps")
  it("Options", "Settings (also in Tools > " .. TOOL_NAME .. " > Options)")
  it("Help", "This window; Ctrl-C (Mac: Cmd-C) in it opens its text to copy")
  add("")

  add(head("Panel Keys"))
  it("Up, Down", "The control above / below (Tab, Shift-Tab: next / "
    .. "previous in reading order)")
  it("Left, Right", "Change a slider by 1 (Ctrl x2, Shift x4, Alt x8) or a "
    .. "switch; on a button: the next one")
  it("Home, End", "A slider's lowest / highest value")
  it("0 - 9", "Type a slider's value")
  it("Enter", "Press a button, flip a switch")
  it("Esc", "Close the panel")
  para("The highlighted control is where the keys go (a clicked button "
    .. "takes them). Other keys work as usual in Renoise.")
  add("")

  add(head("Options (Options button, also Tools > " .. TOOL_NAME
           .. " > Options)"))
  for _, o in ipairs(C.OPTIONS) do
    if o.help ~= false then
      local label = o.values and o.label:gsub("%.%.%.$", ""):gsub(" Onset$", "")
                    or o.label
      if o.values then it(label, o.values, 24) else add("   " .. label) end
    end
  end
  add("")

  local list = {}
  for _, b in ipairs(C.BINDINGS) do
    local desc = b[3] or ""
    if type(desc) == "function" then desc = desc() end
    list[#list + 1] = { b[1], b[2], desc }
  end
  HELP.bindings(add, list, TOOL_NAME)
  if #C.MIDI > 0 then
    add("")
    add(head("MIDI Mappings (Tools > " .. TOOL_NAME .. ")"))
    para(table.concat(C.MIDI, ", "))
  end
  return table.concat(out, "\n")
end

C.HELP_SPEC = {
  name = TOOL_NAME,
  text = function() return C.help_text() end,
  credits = {
    { "simple transients " .. C.VERSION .. "  ", "by phaos & claude" },
  },
  owner = function() return dialog_open() and S.dialog or nil end,
}
toggle_help_dialog = function(button) HELP.toggle(C.HELP_SPEC, button) end


--------------------------------------------------------------------------------
-- Panel: the detection settings on one grid - every row as wide as the
-- next: a setting is its name, a slider and its value box, or its name and
-- a switch - then Options and Help, and a line about the sample.
--------------------------------------------------------------------------------

-- update the info line
function P.refresh(force)
  if not dialog_open() then return end
  local info = view("info")
  if not info then return end
  local smp, buf, song = current()
  if not smp then
    info.text = buf or ""
    return
  end
  local c = A.current(song, buf)
  local rate, n = buf.sample_rate, buf.number_of_frames
  local parts = { smp.name ~= "" and smp.name or "(unnamed sample)",
                  fmt_time(n, rate) }
  if A.job and not c then
    parts[#parts + 1] = "finding transients... " .. A.progress() .. "%"
  elseif c and c.points then
    parts[#parts + 1] = #c.points .. " transient" .. (#c.points == 1 and "" or "s")
  end
  if S.anchor and S.ident == ident_of(song) then
    local lo, hi = span()
    if lo == hi then
      parts[#parts + 1] = "cursor " .. fmt_edge(lo, rate)
    else
      parts[#parts + 1] = "selected " .. fmt_edge(lo, rate) .. " - "
        .. fmt_edge(hi, rate)
    end
  end
  local text = table.concat(parts, "  -  ")
  if force or info.text ~= text then info.text = text end
end


--------------------------------------------------------------------------------
-- Panel keys: the keyboard moves from control to control, as in a Renoise
-- dialog (and Schism Tracker):
--   Up Down, Tab / Shift-Tab        from control to control
--   Left Right on a slider          change it, by 1; Ctrl x2, Shift x4,
--                                   Alt x8
--   Home / End on a slider          its lowest / highest value
--   a digit on a slider             type the value
--   Left Right on a switch          the other choice
--   Left Right in a row of buttons  the next button
--   Enter                           press a button, flip a switch (on a
--                                   slider: nothing)
--   Esc                             close the panel
-- Everything else goes to Renoise.
--------------------------------------------------------------------------------

-- A slider or switch sits in a frame that lights up, in the theme's focus
-- colour, while the keys are on it - the colour a focused button gets, as
-- in Simple Browser (sliders and switches cannot be coloured themselves).
-- The frame is always part of the layout (C.FRAME px round the control) and
-- simply drawn empty otherwise, so moving the focus never moves anything.
C.FRAME = 2
function C.framed(vb, kind, props)
  local F = C.FRAME
  local fid = "frame_" .. props.id
  local ok, frame = pcall(function()
    return vb:canvas {
      id = fid, width = props.width + 2 * F,
      height = (props.height or C.ROW_HEIGHT) + 2 * F, mode = "transparent",
      render = function(ctx)
        if S.lit_frame ~= fid then return end
        local cw, ch = math.floor(ctx.size.width), math.floor(ctx.size.height)
        paint(ctx, "fill_color", C.FOCUS)
        ctx:fill_rect(0, 0, cw, F)
        ctx:fill_rect(0, ch - F, cw, F)
        ctx:fill_rect(0, 0, F, ch)
        ctx:fill_rect(cw - F, 0, F, ch)
      end,
    }
  end)
  local control = vb[kind](vb, props)
  if not ok or not frame then return C.pad(vb, control) end
  local ok2, st = pcall(function()
    local st = vb:stack {}
    st:add_child(frame)
    st:add_child(control)
    control.origin = { x = F, y = F }
    return st
  end)
  return ok2 and st or C.pad(vb, control)
end

-- the same room round a view that has no frame, so every row lines up
function C.pad(vb, v)
  return vb:column { margin = C.FRAME, v }
end

-- light the control the keys are on up, or back to normal
function C.paint_stop(st, on)
  if not st then return end
  local g = view("frame_" .. st.id)
  if g then
    local fid = "frame_" .. st.id
    S.lit_frame = on and fid or (S.lit_frame ~= fid and S.lit_frame or nil)
    pcall(function() g:update() end)
  elseif st.act then                          -- a button: its own colour
    local v = view(st.id)
    if v then C.tint(v, on and C.FOCUS or DEFAULT_COLOR) end
  end
end

function C.ctl_status()
  local st = S.ctl
  if not st then return end
  if st.n then
    set_status(st.name .. ": " .. st.show() .. "  -  Left / Right or Enter change it")
  elseif st.get then
    set_status(st.name .. ": " .. st.show()
               .. "  -  Left / Right change it, or type a value")
  else
    set_status(st.name .. "  -  Enter presses it")
  end
end

local function focus_stop(st)
  if not st then return end
  if S.ctl then C.paint_stop(S.ctl, false) end
  S.ctl, S.last_ctl = st, st.id
  S.row_last = S.row_last or {}
  S.row_last[st.row] = st
  C.paint_stop(st, true)
  C.ctl_status()
end

-- change a value by `n` units: switches wrap round, numbers stop at the ends
function C.value_step(st, n)
  if st.n then
    st.set((st.get() - 1 + n) % st.n + 1)
  else
    st.set(clamp(st.get() + n, st.min, st.max))
  end
  C.ctl_status()
end

-- "Enter Value", as in Schism Tracker: a small prompt (a typed digit, or
-- the current value, already in it). Opened from a timer: Renoise is
-- pickier about prompts opened straight from a key handler or a menu.
function C.value_prompt(st, first)
  local function open()
    remove_timer(open)
    local vb = renoise.ViewBuilder()
    local typed = first or ""
    local tf = vb:textfield { width = 140, text = typed,
                              notifier = function(t) typed = t end }
    pcall(function() tf.edit_mode = true end)
    local content = vb:column {
      margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN, spacing = 6,
      vb:text { text = string.format("%s (%d - %d)", st.name, st.min, st.max) },
      tf,
    }
    local label = renoise.app():show_custom_prompt("Enter Value", content,
                                                   { "OK", "Cancel" })
    if label ~= "OK" then                      -- Cancel, or closed
      if dialog_open() then pcall(function() S.dialog:show() end) end
      return
    end
    local v = tonumber((tf.text or typed or ""):match("[%d%.]+") or "")
    if not v then
      set_status("Not a number: " .. tostring(tf.text))
      return
    end
    st.set(clamp(math.floor(v + 0.5), st.min, st.max))
    if dialog_open() then pcall(function() S.dialog:show() end) end
    C.ctl_status()
  end
  renoise.tool():add_timer(open, 1)
end

function P.key(dlg, key)
  local m = key.modifier_flags or {}
  local name = key.name
  local plain = not (m.shift or m.control or m.alt or m.meta)
  local only_shift = m.shift and not (m.control or m.alt or m.meta)
  local st = S.ctl

  if name == "esc" and plain then dlg:close() return nil end
  if not st then return key end
  local function go(dir)                     -- reading order, round
    local pos = 1
    for i, x in ipairs(S.stops) do if x == st then pos = i end end
    focus_stop(S.stops[(pos - 1 + dir) % #S.stops + 1])
  end

  if name == "tab" and (plain or only_shift) then
    go(only_shift and -1 or 1)
  elseif (name == "up" or name == "down") and plain then
    -- straight up / down: the control right above / below this one (on a
    -- tie the one used last there, else the left one); from a control as
    -- wide as the panel: the one used last in that row, else its first
    local rows = 0
    for _, x in ipairs(S.stops) do rows = math.max(rows, x.row) end
    local want = (st.row - 1 + (name == "down" and 1 or -1)) % rows + 1
    local pick, best = nil, nil
    if st.x == 0.5 and S.row_last and S.row_last[want] then
      pick = S.row_last[want]
    else
      for _, x in ipairs(S.stops) do
        if x.row == want then
          local d = st.x == 0.5 and x.col - 1 or math.abs(x.x - st.x)
          if not best or d < best - 1e-9
             or (math.abs(d - best) < 1e-9 and S.row_last
                 and S.row_last[want] == x) then
            pick, best = x, d
          end
        end
      end
    end
    focus_stop(pick)
  elseif name == "left" or name == "right" then
    local dir = name == "right" and 1 or -1
    if st.n then                               -- a switch
      C.value_step(st, dir)
    elseif st.get then                         -- a slider
      local n = 1
      if m.alt or m.meta then n = n * 8 end
      if m.shift then n = n * 4 end
      if m.control then n = n * 2 end
      C.value_step(st, dir * n)
    elseif plain then                          -- a button: the next one
      local row = {}
      for _, x in ipairs(S.stops) do if x.row == st.row then row[#row + 1] = x end end
      local pos = 1
      for i, x in ipairs(row) do if x == st then pos = i end end
      focus_stop(row[(pos - 1 + dir) % #row + 1])
    else
      return key
    end
  elseif (name == "home" or name == "end") and plain and st.get and not st.n then
    st.set(name == "home" and st.min or st.max)
    C.ctl_status()
  elseif (name == "return" or name == "enter") and plain then
    if key.repeated then return nil end
    if st.act then                             -- a button: press it
      st.act()
      if S.ctl then C.paint_stop(S.ctl, true) end
    elseif st.n then                           -- a switch: flip it
      C.value_step(st, 1)
    end                                        -- a slider: nothing
  elseif plain and st.get and not st.n and key.character
         and key.character:match("^%d$") then
    C.value_prompt(st, key.character)
  else
    return key           -- everything else: Renoise (transport, your keys)
  end
  return nil
end


--------------------------------------------------------------------------------
-- Panel layout
--------------------------------------------------------------------------------

-- Min gap on its slider: logarithmic, C.GAP_MIN .. C.GAP_MAX
function C.gap_to_slider(ms)
  return math.log(ms / C.GAP_MIN) / math.log(C.GAP_MAX / C.GAP_MIN)
end
function C.slider_to_gap(v)
  return math.floor(C.GAP_MIN * (C.GAP_MAX / C.GAP_MIN) ^ v + 0.5)
end

function P.build()
  local vb = renoise.ViewBuilder()
  S.vb = vb
  S.ctl, S.row_last, S.lit_frame = nil, nil, nil

  local W, GAP, H = C.PANEL_W, C.GAP, C.ROW_HEIGHT
  local CTRL_W = W - C.LABEL_W - C.VALUE_W - 2 * GAP   -- a slider
  local WIDE_W = W - C.LABEL_W - GAP                   -- a switch

  local function pct(v) return string.format("%d %%", v) end
  local function dbs(v) return string.format("-%d dB", v) end
  local function ms(v) return string.format("%d ms", v) end
  local num = function(t) return tonumber((t or ""):match("[%d%.]+") or "") end
  local function pref(name)
    return function() return prefs[name].value end,
           function(v) prefs[name].value = v end
  end
  local function on_off(name)
    return function() return prefs[name].value and 2 or 1 end,
           function(v) prefs[name].value = v == 2 end
  end
  local g_sens, s_sens = pref("sensitivity")
  local g_thr, s_thr = pref("threshold")
  local g_gap, s_gap = pref("min_gap_ms")
  local g_snap, s_snap = pref("snap_mode")
  local g_zero, s_zero = on_off("zero_cross")
  local g_sel, s_sel = on_off("snap_edges")
  local function off_on(g) return function() return g() == 2 and "On" or "Off" end end

  -- every button and setting in reading order: where the keys go.
  -- A button: act; a slider: get / set, min / max; a switch: n choices
  S.stops = {
    { id = "find_btn", row = 1, name = "Find Transients", act = M.find },
    { id = "sens", row = 2, name = "Sensitivity", get = g_sens, set = s_sens,
      min = C.SENS_MIN, max = C.SENS_MAX, show = function() return pct(g_sens()) end },
    { id = "thresh", row = 3, name = "Threshold", get = g_thr, set = s_thr,
      min = C.THRESH_MIN, max = C.THRESH_MAX, show = function() return dbs(g_thr()) end },
    { id = "gap", row = 4, name = "Min gap", get = g_gap, set = s_gap,
      min = C.GAP_MIN, max = C.GAP_MAX, show = function() return ms(g_gap()) end },
    { id = "snap", row = 5, name = "Snap to", n = #C.SNAP_ITEMS,
      get = g_snap, set = s_snap, show = function() return C.SNAP_ITEMS[g_snap()] end },
    { id = "zero", row = 6, name = "Zero crossings", n = 2,
      get = g_zero, set = s_zero, show = off_on(g_zero) },
    { id = "snapsel", row = 7, name = "Snap selection", n = 2,
      get = g_sel, set = s_sel, show = off_on(g_sel) },
    { id = "options_btn", row = 8, name = "Options", act = function()
        pcall(function()
          renoise.app():show_menu(S.dialog, C.option_menu_items(), view("options_btn"))
        end)
      end },
    { id = "help_btn", row = 8, name = "Help", act = function() toggle_help_dialog(true) end },
  }
  local by_id = {}
  for _, st in ipairs(S.stops) do by_id[st.id] = st end
  -- where each control sits across the panel (0 .. 1): a row's controls
  -- share its width equally
  local in_row = {}
  for _, st in ipairs(S.stops) do
    in_row[st.row] = (in_row[st.row] or 0) + 1
    st.col = in_row[st.row]
  end
  for _, st in ipairs(S.stops) do st.x = (st.col - 0.5) / in_row[st.row] end

  -- a click works as a key does: the keys go on from that control
  local function btn(id, text, width, extra)
    local props = { id = id, text = text, width = width, height = H,
                    notifier = function()
                      focus_stop(by_id[id])
                      by_id[id].act()
                    end }
    for k, v in pairs(extra or {}) do props[k] = v end
    return vb:button(props)
  end
  local F2 = 2 * C.FRAME                       -- a frame's room in a cell
  local function label(text)
    return C.pad(vb, vb:text { text = text, width = C.LABEL_W - F2, height = H })
  end

  -- a setting: name | slider | value box
  local function slider_row(id, name, slider_props, box_props)
    slider_props.id, slider_props.width, slider_props.height = id, CTRL_W - F2, H
    box_props.width, box_props.height = C.VALUE_W - F2, H
    return vb:row { spacing = GAP, label(name),
                    C.framed(vb, "slider", slider_props),
                    C.pad(vb, vb:valuebox(box_props)) }
  end
  -- a choice: name | switch over the slider and value box
  local function switch_row(id, name, items)
    local st = by_id[id]
    return vb:row { spacing = GAP, label(name), C.framed(vb, "switch", {
      id = id, width = WIDE_W - F2, height = H, items = items, value = st.get(),
      notifier = function(v) if v ~= st.get() then st.set(v) end end }) }
  end

  -- the Min gap slider is logarithmic: it and the pref follow each other
  local gap_slider_props = {
    min = 0, max = 1, value = C.gap_to_slider(prefs.min_gap_ms.value),
    notifier = function(v)
      if S.gap_sync then return end
      S.gap_sync = true
      prefs.min_gap_ms.value = clamp(C.slider_to_gap(v), C.GAP_MIN, C.GAP_MAX)
      S.gap_sync = false
    end,
  }

  local detection = vb:column {
    style = "group", margin = C.GAP * 2, spacing = GAP,
    C.pad(vb, btn("find_btn", "Find Transients", W - F2,
                  { font = "bold", height = H + 6 })),
    slider_row("sens", "Sensitivity",
      { min = C.SENS_MIN, max = C.SENS_MAX, bind = prefs.sensitivity },
      { min = C.SENS_MIN, max = C.SENS_MAX, bind = prefs.sensitivity,
        tostring = pct, tonumber = num }),
    slider_row("thresh", "Threshold",
      { min = C.THRESH_MIN, max = C.THRESH_MAX, bind = prefs.threshold },
      { min = C.THRESH_MIN, max = C.THRESH_MAX, bind = prefs.threshold,
        tostring = dbs, tonumber = num }),
    slider_row("gap", "Min gap", gap_slider_props,
      { min = C.GAP_MIN, max = C.GAP_MAX, bind = prefs.min_gap_ms,
        tostring = ms, tonumber = num }),
    switch_row("snap", "Snap to", C.SNAP_ITEMS),
    switch_row("zero", "Zero crossings", { "Off", "On" }),
    switch_row("snapsel", "Snap selection", { "Off", "On" }),
  }

  local OUTER = W + 4 * C.GAP                  -- a group's width, margins in
  local half = math.floor((OUTER - GAP) / 2)
  return vb:column {
    margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN,
    spacing = GAP * 2,
    detection,
    vb:row { spacing = GAP,
      btn("options_btn", "Options", half),
      btn("help_btn", "Help", OUTER - GAP - half) },
    vb:text { id = "info", text = "", width = OUTER, align = "center" },
  }
end

-- the keys start on the control used last (first time: Find Transients)
function P.focus_start()
  local pick = S.stops[1]
  for _, st in ipairs(S.stops) do if st.id == S.last_ctl then pick = st end end
  focus_stop(pick)
end

-- keep the switches and the log slider in step with the prefs (the keys,
-- Options, the value boxes)
prefs.snap_mode:add_notifier(function()
  local v = view("snap")
  if v and v.value ~= prefs.snap_mode.value then v.value = prefs.snap_mode.value end
end)
prefs.snap_edges:add_notifier(function()
  local v = view("snapsel")
  local want = prefs.snap_edges.value and 2 or 1
  if v and v.value ~= want then v.value = want end
end)
prefs.zero_cross:add_notifier(function()
  local v = view("zero")
  local want = prefs.zero_cross.value and 2 or 1
  if v and v.value ~= want then v.value = want end
end)
prefs.min_gap_ms:add_notifier(function()
  local v = view("gap")
  if v and not S.gap_sync then
    S.gap_sync = true
    v.value = clamp(C.gap_to_slider(prefs.min_gap_ms.value), 0, 1)
    S.gap_sync = false
  end
end)

-- Toggle: open when closed; close when open and focused; when open but
-- Renoise has the focus, bring the panel back to front instead.
function P.toggle()
  if dialog_open() then
    local ok, focused = pcall(function() return S.dialog.focused end)
    if ok and focused == false then
      S.dialog:show()
    else
      S.dialog:close()
    end
    return
  end
  local content = P.build()
  S.dialog = C.show_dialog(TOOL_NAME, content, P.key)
  P.refresh(true)
  P.focus_start()
end

-- a setting changed: the panel shows the new transients
for _, name in ipairs { "sensitivity", "threshold", "min_gap_ms",
                        "snap_mode", "zero_cross" } do
  prefs[name]:add_notifier(function() P.refresh(true) end)
end


--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

renoise.tool():add_menu_entry {
  name   = "Main Menu:Tools:Simple Transients:Show / Hide Panel",
  invoke = function() P.toggle() end,
}
renoise.tool():add_menu_entry {
  name   = "Main Menu:Tools:Simple Transients:Help",
  invoke = function() toggle_help_dialog() end,
}
-- the same options as the panel's Options button, in the same order
for _, o in ipairs(C.OPTIONS) do
  renoise.tool():add_menu_entry {
    name = (o.sep and "--- " or "")
           .. "Main Menu:Tools:Simple Transients:Options:" .. o.label,
    selected = o.on,
    invoke = o.set,
  }
end

-- the sample editor's right-click menu: the commands
for _, cmd in ipairs(C.COMMANDS) do
  renoise.tool():add_menu_entry {
    name = (cmd.sep and "--- " or "")
           .. "Sample Editor:Simple Transients:" .. cmd[1],
    invoke = cmd[2], selected = cmd.on,
  }
end
-- Tools cannot add buttons to Renoise's own GUI; the panel also opens from
-- these right-click menus, and from a MIDI button (see below)
for _, where in ipairs { "Sample Editor Ruler", "Sample List",
                         "Sample Navigator", "Instrument Box" } do
  renoise.tool():add_menu_entry {
    name = where .. ":Simple Transients...",
    invoke = function() P.toggle() end,
  }
end

-- `repeats`: holding the key keeps going (moving, settings)
local function bind(scope, name, desc, fn, repeats)
  C.BINDINGS[#C.BINDINGS + 1] = { scope, name, desc }
  renoise.tool():add_keybinding {
    name   = scope .. ":" .. TOOL_NAME .. ":" .. name,
    invoke = function(repeated) if repeats or not repeated then fn() end end,
  }
end

-- grouped as they appear in Help and in Preferences > Keys
local SE = "Sample Editor"
bind(SE, "Next Transient", "(Tab)",
     function() M.move(1) end, true)
bind(SE, "Previous Transient", "(a free key, e.g. Shift-`)",
     function() M.move(-1) end, true)
bind(SE, "Selection Start to Previous Transient", function() return "(" .. C.show_key(C.scheme().keys.start_l) .. ")" end,
     function() M.edge("start", -1) end, true)
bind(SE, "Selection Start to Next Transient", function() return "(" .. C.show_key(C.scheme().keys.start_r) .. ")" end,
     function() M.edge("start", 1) end, true)
bind(SE, "Selection End to Previous Transient", function() return "(" .. C.show_key(C.scheme().keys.end_l) .. ")" end,
     function() M.edge("end", -1) end, true)
bind(SE, "Selection End to Next Transient", function() return "(" .. C.show_key(C.scheme().keys.end_r) .. ")" end,
     function() M.edge("end", 1) end, true)
-- a second key for it, as Renoise does with "(2nd)" bindings
bind(SE, "Selection End to Next Transient (2nd)", "(Shift-Tab)",
     function() M.edge("end", 1) end, true)
bind(SE, "Selection Both Edges Out", function() return "(" .. C.show_key(C.scheme().keys.out) .. ")" end,
     function() M.both(1) end, true)
bind(SE, "Selection Both Edges In", function() return "(" .. C.show_key(C.scheme().keys.inn) .. ")" end,
     function() M.both(-1) end, true)
bind(SE, "Snap Selection to Transients", "On / off (off: fine steps)",
     function() M.toggle_snap_edges() end)
bind(SE, "Edit - Trim Left of Cursor", "Delete before the cursor",
     function() M.trim("left") end)
bind(SE, "Edit - Trim Right of Cursor", "Delete from the cursor on",
     function() M.trim("right") end)
bind(SE, "Edit - Trim to Selection", "Keep only the selection",
     function() M.trim("selection") end)
bind(SE, "Prehear - Play", "The selection / from the cursor", function() M.prehear(false) end)
bind(SE, "Prehear - Stop", "Silence it", function() M.stop_prehear() end)
bind(SE, "Prehear - Toggle Auto-Prehear", "Play each hit as you step", function() M.toggle_autoplay() end)
bind(SE, "Detection - Find Transients", "Analyse the sample again", function() M.find() end)
bind(SE, "Detection - Sensitivity Up", "+5 %: more transients", function() M.step_sensitivity(1) end, true)
bind(SE, "Detection - Sensitivity Down", "-5 %: fewer transients", function() M.step_sensitivity(-1) end, true)
bind(SE, "Detection - Threshold Up", "+3 dB: quieter hits too", function() M.step_threshold(1) end, true)
bind(SE, "Detection - Threshold Down", "-3 dB: only louder hits", function() M.step_threshold(-1) end, true)
bind("Global", "Toggle Panel", "Show / hide the panel", function() P.toggle() end)
bind("Global", "Show Help", "This window", function() toggle_help_dialog() end)


-- MIDI: a controller button can open the panel or move the cursor
for _, mm in ipairs {
  { "Toggle Panel", function() P.toggle() end },
  { "Next Transient", function() M.move(1) end },
  { "Previous Transient", function() M.move(-1) end },
  { "Selection End to Next Transient", function() M.edge("end", 1) end },
  { "Find Transients", function() M.find() end },
} do
  if pcall(function()
    renoise.tool():add_midi_mapping {
      name = "Tools:" .. TOOL_NAME .. ":" .. mm[1],
      invoke = function(msg) if msg:is_trigger() then mm[2]() end end,
    }
  end) then C.MIDI[#C.MIDI + 1] = mm[1] end
end

-- A new/loaded song: forget everything about the old one.
renoise.tool().app_new_document_observable:add_notifier(function()
  if dialog_open() then pcall(function() S.dialog:close() end) end
  A.caches, A.order, A.job, S.pending = {}, {}, nil, nil
  remove_timer(A.tick)
  S.ident, S.anchor, S.edge, S.shown, S.play = nil, nil, nil, nil, nil
  idle_state.key, idle_state.ident = nil, nil
end)
