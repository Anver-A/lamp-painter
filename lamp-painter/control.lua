-- Lamp Painter: bulk lamp recolouring with live preview.
-- All mutable state lives in `storage`, so the mod is save/load and multiplayer safe.
--
-- Work model: selecting only queues the raw entity list. Each tick a fixed budget of work
-- captures lamps (remembering their original settings), previews colours, and runs queued
-- apply/restore jobs, so even tens of thousands of lamps never stall a single tick.

local TOOL = "lamp-painter"
local PICKER = "lamp-painter-picker"
local FRAME = "lamp_painter_frame"
local TAG = "lamp_painter_color"
-- Costs are in units of one lamp write (about 1-2 microseconds), measured in-game.
local BUDGET = 1500        -- work units per tick
local COST_WRITE = 1       -- one lamp write
local COST_JOB = 3         -- one queued apply/restore write including its bookkeeping
local COST_CAPTURE = 12    -- reading a lamp's originals and previewing it
local COST_OUTLINE = 18    -- drawing its outline (only the first OUTLINE_CAP lamps get one)
local SYNC_CAPTURE = 100   -- lamps captured immediately on selection, so small selections feel instant
local OUTLINE_CAP = 1500   -- per-lamp outlines above this fall back to area rectangles
local PRESET_CAP = 30
local OUTLINE_COLOR = {r = 1, g = 0.8, b = 0.1, a = 0.8}

-- always-on choices: key, value written to LuaEntity.always_on (nil = leave each lamp as it is)
local ON_OPTIONS = {{"keep", nil}, {"normal", false}, {"on", true}}
local function on_key(v) return (v == true and "on") or (v == false and "normal") or "keep" end

-- Copied from data/base/prototypes/entity/entities.lua, small-lamp signal_to_color_mapping
-- (that mapping is not readable at runtime).
local VANILLA = {
  {"signal-red",    {r = 1,   g = 0,   b = 0}},
  {"signal-green",  {r = 0,   g = 1,   b = 0}},
  {"signal-blue",   {r = 0,   g = 0,   b = 1}},
  {"signal-yellow", {r = 1,   g = 1,   b = 0}},
  {"signal-pink",   {r = 1,   g = 0,   b = 1}},
  {"signal-cyan",   {r = 0,   g = 1,   b = 1}},
  {"signal-white",  {r = 1,   g = 1,   b = 1}},
  {"signal-grey",   {r = 0.5, g = 0.5, b = 0.5}},
  {"signal-black",  {r = 0,   g = 0,   b = 0}},
}
local CHANNELS = {"r", "g", "b"}
local DEBUG = script.active_mods["lamp-painter-test"] ~= nil  -- timing logs during automated tests only

---------------------------------------------------------------------------
-- storage

local function init_storage()
  storage.players = storage.players or {}   -- [player_index] = {presets, pinned, session, last, carry}
  storage.owner = storage.owner or {}       -- [unit_number] = player_index holding the lamp
  storage.jobs = storage.jobs or {}         -- FIFO of apply/restore jobs
  storage.active = storage.active or {}     -- [player_index] = true while a session has tick work
end

local function pdata(pi)
  local d = storage.players[pi]
  if not d then
    d = {presets = {}, pinned = false}
    storage.players[pi] = d
  end
  return d
end

---------------------------------------------------------------------------
-- small helpers

local function copy_color(c)
  if not c then return nil end
  return {r = c.r or c[1] or 0, g = c.g or c[2] or 0, b = c.b or c[3] or 0}
end

local function copy_table(t)
  if not t then return nil end
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

local function to255(v) return math.floor(v * 255 + 0.5) end

local function hex_of(c)
  return string.format("#%02X%02X%02X", to255(c.r), to255(c.g), to255(c.b))
end

local function parse_hex(s)
  local h = s:match("^%s*#?(%x%x%x%x%x%x)%s*$")
  if not h then return nil end
  return {
    r = tonumber(h:sub(1, 2), 16) / 255,
    g = tonumber(h:sub(3, 4), 16) / 255,
    b = tonumber(h:sub(5, 6), 16) / 255,
  }
end

local function notify(player, text)
  if player and player.valid then
    player.create_local_flying_text{text = text, create_at_cursor = true}
  end
end

local function is_lamp(e)
  return e.valid and (e.type == "lamp" or (e.type == "entity-ghost" and e.ghost_type == "lamp"))
end

---------------------------------------------------------------------------
-- lamp records and writes

local function make_record(e)
  local ghost = e.type == "entity-ghost"
  local rec = {entity = e, unit = e.unit_number, ghost = ghost, orig_on = e.always_on,
               circuit_color = false, circuit_on = false}
  if ghost then
    rec.orig_tags = e.tags
    rec.orig_color = rec.orig_tags and copy_color(rec.orig_tags[TAG])
  else
    rec.orig_color = copy_color(e.color)
    local cb = e.get_control_behavior()
    if cb then
      local wired = e.get_circuit_network(defines.wire_connector_id.circuit_red)
                 or e.get_circuit_network(defines.wire_connector_id.circuit_green)
      rec.circuit_color = (wired and cb.use_colors) and true or false
      rec.circuit_on = ((wired and cb.circuit_enable_disable) or cb.connect_to_logistic_network) and true or false
    end
  end
  return rec
end

local function clone_record(r, e)
  return {entity = e or r.entity, unit = r.unit, ghost = r.ghost, orig_on = r.orig_on,
          orig_color = copy_color(r.orig_color), orig_tags = copy_table(r.orig_tags),
          circuit_color = r.circuit_color, circuit_on = r.circuit_on}
end

local function destroy_render(rec)
  if rec.outline and rec.outline.valid then rec.outline.destroy() end
  if rec.dot and rec.dot.valid then rec.dot.destroy() end
  rec.outline, rec.dot = nil, nil
end

-- kind: "preview", "commit" or "restore"; p supplies color, always_on and include_circuit.
-- A session whose colour the player has not touched yet (color_set == false) keeps each lamp's own colour.
local function write(rec, kind, p)
  local col = p.color
  if p.color_set == false then col = nil end
  local e = rec.entity
  if not e.valid then
    destroy_render(rec)
    return
  end
  if kind == "restore" then
    e.always_on = rec.orig_on
    if rec.ghost then
      e.tags = rec.orig_tags or {}
    elseif rec.orig_color then
      e.color = rec.orig_color
    end
    destroy_render(rec)
    return
  end
  local include = p.include_circuit
  if p.always_on ~= nil and (include or not rec.circuit_on) then
    e.always_on = p.always_on
  else
    e.always_on = rec.orig_on
  end
  if rec.ghost then
    if kind == "commit" then
      if col then
        local t = copy_table(rec.orig_tags) or {}
        t[TAG] = copy_color(col)
        e.tags = t
      end
      destroy_render(rec)
    elseif col and rec.dot and rec.dot.valid then
      rec.dot.color = col
    end
  else
    if col and (include or not rec.circuit_color) then
      e.color = col
    elseif rec.orig_color then
      e.color = rec.orig_color
    end
    if kind == "commit" then destroy_render(rec) end
  end
end

---------------------------------------------------------------------------
-- jobs: queued apply/restore work, FIFO, processed within the tick budget

local function job_params(s)
  return {color = s.color_set ~= false and copy_color(s.color) or nil, always_on = s.always_on, include_circuit = s.include_circuit}
end

-- A job takes over a list of records together with its unit_number -> position index, so
-- handing 20 000 lamps to a job is O(1). Per-lamp bookkeeping happens when each lamp is written.
local function queue_job(pi, kind, recs, index, p)
  if #recs == 0 then return end
  local job = {pi = pi, kind = kind, recs = recs, index = index, skip = {}, i = 1}
  if p then
    job.color, job.always_on, job.include_circuit = p.color, p.always_on, p.include_circuit
  end
  storage.jobs[#storage.jobs + 1] = job
end

-- Is lamp u still waiting in a job of player pi other than `except`?
local function pending_elsewhere(pi, u, except)
  for _, j in ipairs(storage.jobs) do
    if j ~= except and j.pi == pi then
      local pos = j.index[u]
      if pos and pos >= j.i and not j.skip[pos] then return true end
    end
  end
  return false
end

local function run_job(job, budget)
  local recs = job.recs
  local first = job.i
  local last = math.min(#recs, first + math.max(1, math.floor(budget / COST_JOB)) - 1)
  for k = first, last do
    local rec = recs[k]
    if job.skip[k] then
      -- claimed by a newer selection, which now owns this lamp
    elseif rec.entity.valid then
      local u = rec.unit
      local owner = storage.owner[u]
      if owner == nil or owner == job.pi then
        write(rec, job.kind, job)
        if not pending_elsewhere(job.pi, u, job) then storage.owner[u] = nil end
      end
    else
      destroy_render(rec)
    end
  end
  job.i = last + 1
  return (last - first + 1) * COST_JOB, job.i > #recs
end

-- Takes a lamp for player pi. If the lamp still has queued writes from this player, those are
-- cancelled and the record of its true end state is used, so originals are never captured
-- half-way through a restore or apply. Returns nil if another player holds the lamp.
local function claim(pi, e)
  local u = e.unit_number
  local owner = storage.owner[u]
  if owner and owner ~= pi then return nil end
  local latest, latest_job
  for _, j in ipairs(storage.jobs) do
    if j.pi == pi then
      local pos = j.index[u]
      if pos and pos >= j.i and not j.skip[pos] then
        j.skip[pos] = true
        destroy_render(j.recs[pos])
        latest, latest_job = j.recs[pos], j
      end
    end
  end
  local rec
  if latest and latest_job.kind == "restore" then
    rec = clone_record(latest, e)
  else
    if latest then write(latest, "commit", latest_job) end
    rec = make_record(e)
  end
  storage.owner[u] = pi
  return rec
end

---------------------------------------------------------------------------
-- sessions

local function new_session(surface_index, carry)
  return {
    surface_index = surface_index,
    lamps = {},
    index = {},        -- unit_number -> position in lamps
    outlined = {},     -- records that have an outline or ghost dot (at most OUTLINE_CAP)
    queue = {},        -- raw entity lists waiting to be captured: {list, i}
    pending = 0,       -- entities still in queue
    areas = {},
    area_objs = {},
    color = {r = 1, g = 1, b = 1},  -- replaced by the first captured lamp's own colour
    color_set = false,               -- true once the player picks a colour; until then lamps keep theirs
    seeded = false,
    always_on = nil,                 -- "Leave as is" until the player picks Normal or Always on
    include_circuit = carry and carry.include_circuit or false,
    cursor = 1,        -- preview pass position; > #lamps when idle
    busy = 0,
    n_ghost = 0,
    n_circuit = 0,
  }
end

-- Returns true when it drew something (so the caller can charge the cost).
local function draw_rec(pi, s, rec)
  if #s.lamps > OUTLINE_CAP then return false end
  local e = rec.entity
  if not e.valid then return false end
  local drew = false
  local surface = e.surface
  if not (rec.outline and rec.outline.valid) then
    local box = e.selection_box
    rec.outline = rendering.draw_rectangle{
      color = OUTLINE_COLOR, width = 1, filled = false,
      left_top = box.left_top, right_bottom = box.right_bottom,
      surface = surface, players = {pi},
    }
    drew = true
  end
  if rec.ghost and not (rec.dot and rec.dot.valid) then
    rec.dot = rendering.draw_circle{
      color = s.color, radius = 0.3, filled = true,
      target = e.position, surface = surface, players = {pi},
    }
    drew = true
  end
  if drew then s.outlined[#s.outlined + 1] = rec end
  return drew
end

local function clear_outlines(s)
  for _, rec in ipairs(s.outlined) do
    if rec.outline and rec.outline.valid then rec.outline.destroy() end
    rec.outline = nil
  end
  s.outlined = {}
end

local function redraw_areas(pi, s)
  for _, o in pairs(s.area_objs) do
    if o.valid then o.destroy() end
  end
  s.area_objs = {}
  if #s.lamps + s.pending <= OUTLINE_CAP then return end
  local surface = game.get_surface(s.surface_index)
  for _, a in pairs(s.areas) do
    s.area_objs[#s.area_objs + 1] = rendering.draw_rectangle{
      color = OUTLINE_COLOR, width = 3, filled = false,
      left_top = a.left_top, right_bottom = a.right_bottom,
      surface = surface, players = {pi},
    }
  end
end

local function count_rec(s, rec, sign)
  if rec.ghost then s.n_ghost = s.n_ghost + sign end
  if rec.circuit_color or rec.circuit_on then s.n_circuit = s.n_circuit + sign end
end

local function enqueue(s, entities)
  if #entities == 0 then return end
  s.queue[#s.queue + 1] = {list = entities, i = 1}
  s.pending = s.pending + #entities
end

-- Captures queued entities into the session, previewing each one. Returns work units used.
local function capture(pi, s, budget)
  local used = 0
  while used < budget and #s.queue > 0 do
    local q = s.queue[1]
    local list = q.list
    while used < budget and q.i <= #list do
      local e = list[q.i]
      q.i = q.i + 1
      s.pending = s.pending - 1
      used = used + COST_CAPTURE
      if is_lamp(e) and e.surface_index == s.surface_index and not s.index[e.unit_number] then
        local rec = claim(pi, e)
        if rec then
          s.lamps[#s.lamps + 1] = rec
          s.index[rec.unit] = #s.lamps
          count_rec(s, rec, 1)
          if draw_rec(pi, s, rec) then used = used + COST_OUTLINE end
          if not s.color_set and not s.seeded and rec.orig_color then
            s.color, s.seeded = copy_color(rec.orig_color), true
          end
          if s.color_set or s.always_on ~= nil then write(rec, "preview", s) end
        else
          s.busy = s.busy + 1
        end
      end
    end
    if q.i > #list then table.remove(s.queue, 1) end
  end
  return used
end

-- Hands every lamp in the session to a restore job (O(1) plus outline cleanup).
local function retire_all(pi, s)
  clear_outlines(s)
  queue_job(pi, "restore", s.lamps, s.index)
  s.lamps, s.index = {}, {}
  s.n_ghost, s.n_circuit = 0, 0
end

-- Removes the given lamps (O(number removed)) and restores them.
local function retire_units(pi, s, entities)
  local out, out_index = {}, {}
  for _, e in pairs(entities) do
    local u = e.valid and e.unit_number
    local pos = u and s.index[u]
    if pos then
      local rec = s.lamps[pos]
      local tail = s.lamps[#s.lamps]
      s.lamps[pos] = tail
      s.index[tail.unit] = pos
      s.lamps[#s.lamps] = nil
      s.index[u] = nil
      count_rec(s, rec, -1)
      if rec.outline and rec.outline.valid then rec.outline.destroy() end
      rec.outline = nil
      out[#out + 1] = rec
      out_index[u] = #out
    end
  end
  queue_job(pi, "restore", out, out_index)
end

local function queue_preview(pi, s)
  s.touched = true  -- from now on every lamp is rewritten, including back to its own settings
  s.cursor = 1
  storage.active[pi] = true
end

local function close_window(pi)
  local d = storage.players[pi]
  local player = game.get_player(pi)
  if not (d and player and player.valid) then return end
  local f = player.gui.screen[FRAME]
  if f then
    d.closing = true
    f.destroy()
    d.closing = nil
  end
  local stack = player.cursor_stack
  if stack and stack.valid_for_read and stack.name == PICKER then player.clear_cursor() end
end

-- Final step of Apply, once every selected lamp has been captured.
local function commit_now(pi, d, s)
  for _, o in pairs(s.area_objs) do
    if o.valid then o.destroy() end
  end
  clear_outlines(s)
  queue_job(pi, "commit", s.lamps, s.index, job_params(s))
  d.last = {recs = s.lamps, index = s.index}
  d.committing = nil
end

-- Ends the session. kind = "commit" or "restore".
local function end_session(pi, kind)
  local d = storage.players[pi]
  local s = d and d.session
  if not s then return end
  d.session = nil
  close_window(pi)
  if kind == "commit" and not s.color_set and s.always_on == nil then
    kind = "restore"  -- nothing was changed
  end
  if kind == "commit" then
    if s.pending > 0 then
      -- keep capturing in the background; on_tick commits once everything is captured
      d.committing = s
      storage.active[pi] = true
    else
      storage.active[pi] = nil
      commit_now(pi, d, s)
    end
    return
  end
  storage.active[pi] = nil
  for _, o in pairs(s.area_objs) do
    if o.valid then o.destroy() end
  end
  clear_outlines(s)
  queue_job(pi, "restore", s.lamps, s.index)
end

-- Finishes a background Apply immediately (used before a new selection by the same player).
local function flush_commit(pi)
  local d = storage.players[pi]
  local s = d and d.committing
  if not s then return end
  capture(pi, s, math.huge)
  commit_now(pi, d, s)
end

---------------------------------------------------------------------------
-- GUI

local function find(el, name)
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local r = find(c, name)
    if r then return r end
  end
end

local function sized(el, w)
  el.style.width = w
  return el
end

local function swatch(parent, name, color, w, h, tags, tooltip)
  local bar = parent.add{type = "progressbar", name = name, value = 1, tags = tags, tooltip = tooltip}
  bar.style.width = w
  bar.style.height = h
  bar.style.bar_width = h
  bar.style.color = color
  return bar
end

local function rebuild_presets(player, f)
  local d = pdata(player.index)
  local t = find(f, "presets")
  t.clear()
  for i, c in ipairs(d.presets) do
    swatch(t, "preset_" .. i, c, 28, 28, {lp = "preset", i = i}, {"lamp-painter.preset-tooltip"})
  end
  t.add{type = "button", name = "save_preset", caption = {"lamp-painter.save-preset"},
        tags = {lp = "save_preset"}, style = "mini_button_aligned_to_text_vertically"}
end

local function build_gui(player)
  local f = player.gui.screen.add{type = "frame", name = FRAME, direction = "vertical"}
  local d = pdata(player.index)
  if d.location then
    f.location = d.location
  else
    local k = player.display_scale
    f.location = {x = math.floor(12 * k), y = math.floor(60 * k)}  -- top-left, clear of the top-left buttons
  end

  local bar = f.add{type = "flow", direction = "horizontal"}
  bar.drag_target = f
  bar.add{type = "label", style = "frame_title", caption = {"lamp-painter.title"}, ignored_by_interaction = true}
  local drag = bar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.style.right_margin = 4
  bar.add{type = "sprite-button", name = "pin", style = "frame_action_button", sprite = "utility/track_button_white",
          auto_toggle = false, toggled = d.pinned, tooltip = {"lamp-painter.keep-open"}, tags = {lp = "pin"}}
  bar.add{type = "sprite-button", name = "close", style = "frame_action_button",
          sprite = "utility/close", tooltip = {"lamp-painter.close"}, tags = {lp = "cancel"}}

  local shell = f.add{type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  local inner = shell.add{type = "flow", direction = "vertical"}
  inner.style.vertical_spacing = 8
  inner.add{type = "label", name = "count"}
  local warn = inner.add{type = "label", name = "warn"}
  warn.style.font_color = {r = 1, g = 0.6, b = 0.2}
  warn.style.single_line = false
  warn.style.maximal_width = 330

  local top = inner.add{type = "flow", direction = "horizontal"}
  top.style.vertical_align = "center"
  top.style.horizontal_spacing = 8
  swatch(top, "swatch", {r = 1, g = 1, b = 1}, 64, 28)
  sized(top.add{type = "textfield", name = "hex", tags = {lp = "hex"}, tooltip = {"lamp-painter.hex-tooltip"}}, 90)
  top.add{type = "button", name = "pick", caption = {"lamp-painter.pick"}, tooltip = {"lamp-painter.pick-tooltip"},
          tags = {lp = "pick"}}

  local t = inner.add{type = "table", column_count = 3}
  t.style.vertical_align = "center"
  for _, ch in ipairs(CHANNELS) do
    t.add{type = "label", caption = ch:upper()}
    sized(t.add{type = "slider", name = "slider_" .. ch, minimum_value = 0, maximum_value = 255, value_step = 1,
                discrete_values = true, value = 255, tags = {lp = "slider", ch = ch}}, 220)
    sized(t.add{type = "textfield", name = "num_" .. ch, numeric = true, allow_decimal = false,
                allow_negative = false, text = "255", tags = {lp = "num", ch = ch}}, 52)
  end

  inner.add{type = "label", style = "caption_label", caption = {"lamp-painter.vanilla"}}
  local vt = inner.add{type = "table", column_count = 9}
  for i, v in ipairs(VANILLA) do
    vt.add{type = "sprite-button", style = "slot_button", sprite = "virtual-signal/" .. v[1],
           tooltip = hex_of(v[2]), tags = {lp = "vanilla", i = i}}
  end

  inner.add{type = "label", style = "caption_label", caption = {"lamp-painter.presets"}}
  local pt = inner.add{type = "table", name = "presets", column_count = 10}
  pt.style.vertical_align = "center"

  local on = inner.add{type = "flow", direction = "horizontal"}
  on.style.vertical_align = "center"
  on.add{type = "label", caption = {"lamp-painter.always-on"}}
  on.style.horizontal_spacing = 12
  for _, o in ipairs(ON_OPTIONS) do
    on.add{type = "radiobutton", name = "on_" .. o[1], state = o[1] == "keep", caption = {"lamp-painter." .. o[1]},
           tooltip = o[1] == "keep" and {"lamp-painter.unchanged-tooltip"} or nil, tags = {lp = "on", v = o[1]}}
  end

  inner.add{type = "checkbox", name = "circuit", state = false, caption = {"lamp-painter.include-circuit"},
            tags = {lp = "circuit"}}

  local buttons = f.add{type = "flow", direction = "horizontal", style = "dialog_buttons_horizontal_flow"}
  buttons.add{type = "button", name = "undo", caption = {"lamp-painter.undo"}, tooltip = {"lamp-painter.undo-tooltip"},
              tags = {lp = "undo"}}
  local fill = buttons.add{type = "empty-widget", style = "draggable_space"}
  fill.style.horizontally_stretchable = true
  fill.style.height = 32
  fill.drag_target = f
  buttons.add{type = "button", name = "cancel", style = "red_back_button", caption = {"lamp-painter.cancel"},
              tags = {lp = "cancel"}}
  buttons.add{type = "button", name = "apply", style = "confirm_button", caption = {"lamp-painter.apply"},
              tags = {lp = "apply"}}

  rebuild_presets(player, f)
  return f
end

-- Updates the counts line and warnings only (cheap; called while lamps are still being captured).
local function refresh_counts(player)
  local d = pdata(player.index)
  local s = d.session
  local f = player.gui.screen[FRAME]
  if not (s and f) then return end
  local count = {"lamp-painter.count", #s.lamps, s.n_ghost}
  if s.pending > 0 then count = {"", count, " ", {"lamp-painter.loading", s.pending}} end
  find(f, "count").caption = count
  local parts = {""}
  if s.n_circuit > 0 then parts[#parts + 1] = {"lamp-painter.warn-circuit", s.n_circuit} end
  if s.busy > 0 then
    if #parts > 1 then parts[#parts + 1] = "\n" end
    parts[#parts + 1] = {"lamp-painter.warn-busy", s.busy}
  end
  local warn = find(f, "warn")
  warn.caption = parts
  warn.visible = #parts > 1
  local cb = find(f, "circuit")
  cb.visible = s.n_circuit > 0
  cb.state = s.include_circuit
end

-- skip: name of the field the player is typing in, so its text is not overwritten mid-edit
local function refresh(player, skip)
  local d = pdata(player.index)
  local s = d.session
  local f = player.gui.screen[FRAME]
  if not (s and f) then return end
  refresh_counts(player)
  find(f, "swatch").style.color = s.color
  if skip ~= "hex" then find(f, "hex").text = hex_of(s.color) end
  for _, ch in ipairs(CHANNELS) do
    find(f, "slider_" .. ch).slider_value = to255(s.color[ch])
    if skip ~= "num_" .. ch then find(f, "num_" .. ch).text = tostring(to255(s.color[ch])) end
  end
  local cur = on_key(s.always_on)
  for _, o in ipairs(ON_OPTIONS) do find(f, "on_" .. o[1]).state = o[1] == cur end
  find(f, "pin").toggled = d.pinned
  find(f, "undo").enabled = d.last ~= nil
end

local function open_gui(player)
  local d = pdata(player.index)
  local f = player.gui.screen[FRAME] or build_gui(player)
  refresh(player)
  if not d.pinned and player.opened ~= f then
    player.opened = f
  end
end

---------------------------------------------------------------------------
-- actions

local function set_color(player, color, skip)
  local s = pdata(player.index).session
  if not s then return end
  s.color = copy_color(color)
  s.color_set = true
  refresh(player, skip)
  queue_preview(player.index, s)
end

local finish

local function handle_selection(player, ev, mode)
  local pi = player.index
  local d = pdata(pi)
  flush_commit(pi)
  local s = d.session
  if s and s.surface_index ~= ev.surface.index then
    d.carry = job_params(s)
    end_session(pi, "restore")
    s = nil
  end

  if mode == "remove" then
    if not s then return end
    if s.pending > 0 then capture(pi, s, math.huge) end
    retire_units(pi, s, ev.entities)
    if #s.lamps == 0 then
      end_session(pi, "restore")
      return
    end
    if #s.lamps <= OUTLINE_CAP then
      for _, rec in ipairs(s.lamps) do draw_rec(pi, s, rec) end
    end
    redraw_areas(pi, s)
    refresh(player)
    return
  end

  local any = false
  for _, e in pairs(ev.entities) do
    if is_lamp(e) then any = true break end
  end
  if not any then
    notify(player, {"lamp-painter.no-lamps"})
    return
  end

  if s and mode == "replace" then
    -- the old selection is restored; lamps that are reselected get their originals back via claim()
    retire_all(pi, s)
    s.queue, s.pending, s.areas, s.busy = {}, 0, {}, 0
    if not s.color_set then s.seeded = false end
  end
  if not s then
    s = new_session(ev.surface.index, d.carry)
    d.session = s
  end
  s.areas[#s.areas + 1] = {left_top = ev.area.left_top, right_bottom = ev.area.right_bottom}
  enqueue(s, ev.entities)
  capture(pi, s, SYNC_CAPTURE * (COST_CAPTURE + COST_OUTLINE))
  storage.active[pi] = true
  if #s.lamps == 0 and s.pending == 0 then
    notify(player, {"lamp-painter.warn-busy", s.busy})
    finish(pi, "restore")
    return
  end
  redraw_areas(pi, s)
  open_gui(player)
end

local function handle_pick(player, ev)
  local d = pdata(player.index)
  local s = d.session
  local target
  for _, e in pairs(ev.entities) do
    if is_lamp(e) then target = e break end
  end
  if s and target then
    local color
    local pos = target.unit_number and s.index[target.unit_number]
    if pos then
      color = s.lamps[pos].orig_color
    elseif target.type == "entity-ghost" then
      local tags = target.tags
      color = tags and tags[TAG]
    else
      color = target.color
    end
    if color then
      set_color(player, color)
      notify(player, {"lamp-painter.picked"})
    else
      notify(player, {"lamp-painter.no-ghost-colour"})
    end
  end
  player.clear_cursor()
  if s then
    local cs = player.cursor_stack
    if cs then cs.set_stack{name = TOOL, count = 1} end
    open_gui(player)
  end
end

local function start_pick(player)
  local d = pdata(player.index)
  local f = player.gui.screen[FRAME]
  if f and player.opened == f then
    d.closing = true
    player.opened = nil
    d.closing = nil
  end
  local cs = player.cursor_stack
  if cs and player.clear_cursor() then
    cs.set_stack{name = PICKER, count = 1}
  end
end

function finish(pi, kind)
  local d = storage.players[pi]
  if d and d.session then
    d.carry = job_params(d.session)
    end_session(pi, kind)
  end
end

local function undo_last(player)
  local pi = player.index
  local d = pdata(pi)
  finish(pi, "restore")
  flush_commit(pi)
  local last = d.last
  d.last = nil
  if not last then
    notify(player, {"lamp-painter.nothing-to-undo"})
    return
  end
  -- Queued after the restore above, so FIFO order puts back the pre-paint state last.
  -- Lamps another player is editing by then are skipped when the job reaches them.
  queue_job(pi, "restore", last.recs, last.index)
  notify(player, {"lamp-painter.undone"})
end

---------------------------------------------------------------------------
-- event handlers

local handlers = {}

handlers[defines.events.on_player_selected_area] = function(ev)
  local player = game.get_player(ev.player_index)
  if not player then return end
  if ev.item == TOOL then
    handle_selection(player, ev, "replace")
  elseif ev.item == PICKER then
    handle_pick(player, ev)
  end
end

handlers[defines.events.on_player_alt_selected_area] = function(ev)
  local player = game.get_player(ev.player_index)
  if not player then return end
  if ev.item == TOOL then
    handle_selection(player, ev, "add")
  elseif ev.item == PICKER then
    handle_pick(player, ev)
  end
end

handlers[defines.events.on_player_reverse_selected_area] = function(ev)
  local player = game.get_player(ev.player_index)
  if player and ev.item == TOOL then handle_selection(player, ev, "remove") end
end

local function toggle_pin(player, el)
  local d = pdata(player.index)
  d.pinned = not d.pinned
  el.toggled = d.pinned
  local f = player.gui.screen[FRAME]
  d.closing = true
  if d.pinned and f and player.opened == f then
    player.opened = nil
  elseif not d.pinned and f then
    player.opened = f
  end
  d.closing = nil
end

local click_actions = {
  pin = toggle_pin,
  cancel = function(player) finish(player.index, "restore") end,
  apply = function(player) finish(player.index, "commit") end,
  undo = undo_last,
  pick = start_pick,
  vanilla = function(player, el) set_color(player, VANILLA[el.tags.i][2]) end,
  save_preset = function(player)
    local d = pdata(player.index)
    if not d.session then return end
    if #d.presets >= PRESET_CAP then
      notify(player, {"lamp-painter.presets-full"})
      return
    end
    d.presets[#d.presets + 1] = copy_color(d.session.color)
    rebuild_presets(player, player.gui.screen[FRAME])
  end,
  preset = function(player, el, ev)
    local d = pdata(player.index)
    local c = d.presets[el.tags.i]
    if not c then return end
    if ev.button == defines.mouse_button_type.right then
      table.remove(d.presets, el.tags.i)
      rebuild_presets(player, player.gui.screen[FRAME])
    else
      set_color(player, c)
    end
  end,
}

handlers[defines.events.on_gui_click] = function(ev)
  local el = ev.element
  if not (el and el.valid and el.tags.lp) then return end
  local action = click_actions[el.tags.lp]
  local player = game.get_player(ev.player_index)
  if action and player then action(player, el, ev) end
end

handlers[defines.events.on_gui_value_changed] = function(ev)
  local el = ev.element
  if not (el and el.valid and el.tags.lp == "slider") then return end
  local player = game.get_player(ev.player_index)
  local s = player and pdata(player.index).session
  if not s then return end
  local c = copy_color(s.color)
  c[el.tags.ch] = el.slider_value / 255
  set_color(player, c, el.name)
end

handlers[defines.events.on_gui_text_changed] = function(ev)
  local el = ev.element
  if not (el and el.valid) then return end
  local player = game.get_player(ev.player_index)
  local s = player and pdata(player.index).session
  if not s then return end
  if el.tags.lp == "num" then
    local v = tonumber(el.text)
    if not v then return end
    local c = copy_color(s.color)
    c[el.tags.ch] = math.max(0, math.min(255, math.floor(v))) / 255
    set_color(player, c, el.name)
  elseif el.tags.lp == "hex" then
    local c = parse_hex(el.text)
    if c then set_color(player, c, "hex") end
  end
end

handlers[defines.events.on_gui_confirmed] = function(ev)
  local el = ev.element
  if not (el and el.valid and (el.tags.lp == "hex" or el.tags.lp == "num")) then return end
  local player = game.get_player(ev.player_index)
  if player then refresh(player) end
end

handlers[defines.events.on_gui_checked_state_changed] = function(ev)
  local el = ev.element
  if not (el and el.valid) then return end
  local player = game.get_player(ev.player_index)
  if not player then return end
  local d = pdata(player.index)
  if el.tags.lp == "circuit" and d.session then
    d.session.include_circuit = el.state
    queue_preview(player.index, d.session)
  elseif el.tags.lp == "on" and d.session then
    local s = d.session
    for _, o in ipairs(ON_OPTIONS) do
      if o[1] == el.tags.v then s.always_on = o[2] end
    end
    refresh(player)  -- radio buttons: exactly one selected
    queue_preview(player.index, s)
  end
end

handlers[defines.events.on_gui_location_changed] = function(ev)
  local el = ev.element
  if el and el.valid and el.name == FRAME then
    pdata(ev.player_index).location = el.location
  end
end

handlers[defines.events.on_gui_closed] = function(ev)
  local el = ev.element
  if not (el and el.valid and el.name == FRAME) then return end
  local d = pdata(ev.player_index)
  if d.closing or d.pinned then return end
  finish(ev.player_index, "restore")
end

local function cancel_for(ev) finish(ev.player_index, "restore") end
handlers[defines.events.on_player_died] = cancel_for
handlers[defines.events.on_pre_player_left_game] = cancel_for
handlers[defines.events.on_player_changed_surface] = cancel_for

handlers[defines.events.on_player_removed] = function(ev)
  finish(ev.player_index, "restore")
  flush_commit(ev.player_index)
  storage.players[ev.player_index] = nil
  storage.active[ev.player_index] = nil
end

-- Ghosts cannot hold a lamp colour, so the colour rides in the ghost's tags until it is built.
local function on_built(ev)
  local e = ev.entity
  if not (e and e.valid and e.type == "lamp") then return end
  local c = ev.tags and ev.tags[TAG]
  if c then e.color = copy_color(c) end
end
handlers[defines.events.on_built_entity] = on_built
handlers[defines.events.on_robot_built_entity] = on_built
handlers[defines.events.on_space_platform_built_entity] = on_built
handlers[defines.events.script_raised_revive] = on_built

local function tick_work(tick)
  local budget = BUDGET
  local prof = DEBUG and #storage.jobs > 0 and helpers.create_profiler()
  -- 1) queued apply/restore jobs, oldest first
  while budget > 0 and #storage.jobs > 0 do
    local job = storage.jobs[1]
    local used, done = run_job(job, budget)
    budget = budget - used
    if done then table.remove(storage.jobs, 1) end
  end
  if prof then
    prof.stop()
    log({"", "LP-SPLIT jobs ", tick, " ", prof})
  end
  -- 2) per-player capture of new selections, then preview passes
  for pi in pairs(storage.active) do
    if budget <= 0 then return end
    local d = storage.players[pi]
    local s = d and d.session
    local c = d and d.committing
    if c then
      -- background Apply: capture the rest, then commit
      budget = budget - capture(pi, c, budget)
      if c.pending == 0 then
        commit_now(pi, d, c)
        if not s then storage.active[pi] = nil end
      end
    end
    if not s then
      if not c then storage.active[pi] = nil end
    elseif budget > 0 then
      local had_pending = s.pending > 0
      if had_pending then budget = budget - capture(pi, s, budget) end
      if budget > 0 and s.cursor <= #s.lamps and not s.touched then
        s.cursor = #s.lamps + 1
      end
      if budget > 0 and s.cursor <= #s.lamps then
        local first = s.cursor
        local last = math.min(#s.lamps, first + math.floor(budget / COST_WRITE) - 1)
        for k = first, last do write(s.lamps[k], "preview", s) end
        budget = budget - (last - first + 1) * COST_WRITE
        s.cursor = last + 1
      end
      if had_pending and (s.pending == 0 or tick % 15 == 0) then
        local player = game.get_player(pi)
        if player then
          if s.pending == 0 then redraw_areas(pi, s) end
          if s.pending == 0 and #s.lamps == 0 then
            notify(player, {"lamp-painter.warn-busy", s.busy})
            finish(pi, "restore")
          else
            refresh_counts(player)
          end
        end
      end
      if d.session and not d.committing and s.pending == 0 and s.cursor > #s.lamps then
        storage.active[pi] = nil
      end
    end
  end
end

handlers[defines.events.on_tick] = function(ev)
  if #storage.jobs > 0 or next(storage.active) then tick_work(ev.tick) end
end

---------------------------------------------------------------------------
-- lifecycle

script.on_init(init_storage)

script.on_configuration_changed(function(data)
  init_storage()
  -- Only a change to this mod can leave an old-layout window behind; other mod changes keep edits open.
  if not data.mod_changes["lamp-painter"] then return end
  for pi, d in pairs(storage.players) do
    if d.session then finish(pi, "restore") end
    local player = game.get_player(pi)
    local f = player and player.gui.screen[FRAME]
    if f then f.destroy() end
  end
end)

---------------------------------------------------------------------------
-- test hooks (only when the companion test mod is active)

if script.active_mods["lamp-painter-test"] then
  local tick_handler = handlers[defines.events.on_tick]
  handlers[defines.events.on_tick] = function(ev)
    if #storage.jobs == 0 and not next(storage.active) then return end
    local prof = helpers.create_profiler()
    tick_handler(ev)
    prof.stop()
    log({"", "LP-TICK ", ev.tick, " ", prof})
  end

  remote.add_interface("lamp_painter_debug", {
    raise = function(name, ev)
      ev.name = defines.events[name]
      ev.tick = game.tick
      local clicked = name == "on_gui_click" and ev.element and ev.element.valid and ev.element.name
      local prof = helpers.create_profiler()
      handlers[defines.events[name]](ev)
      prof.stop()
      if clicked then log({"", "LP-CLICK ", clicked, " ", prof}) end
      if ev.entities and #ev.entities > 1000 then
        log({"", "LP-PERF mod handler for ", name, " with ", #ev.entities, " entities: ", prof})
      end
    end,
    state = function(pi)
      local d = storage.players[pi]
      local s = d and d.session
      local owners = 0
      for _ in pairs(storage.owner) do owners = owners + 1 end
      local outlines = 0
      if s then
        for _, r in ipairs(s.lamps) do
          if r.outline and r.outline.valid then outlines = outlines + 1 end
        end
      end
      return {
        lamps = s and #s.lamps or 0,
        pending = s and s.pending or 0,
        color = s and s.color,
        always_on = s and s.always_on,
        busy = s and s.busy or 0,
        jobs = #storage.jobs,
        owners = owners,
        committing = d and d.committing ~= nil or false,
        presets = d and #d.presets or 0,
        has_last = d and d.last ~= nil or false,
        outlines = outlines,
        area_objs = s and #s.area_objs or 0,
      }
    end,
    batch = function() return math.floor(BUDGET / COST_WRITE) end,
  })
end

for id, fn in pairs(handlers) do
  script.on_event(id, fn)
end

if script.active_mods["lamp-painter-test"] then
  -- Strict globals: any read or write of an undeclared global raises an error during tests.
  local allowed = {game = true, storage = true, rendering = true, prototypes = true, helpers = true,
                   settings = true, remote = true, commands = true, script = true, defines = true,
                   log = true, serpent = true, table_size = true, localised_print = true,
                   __DebugAdapter = true, __Profiler = true}
  setmetatable(_ENV, {
    __newindex = function(t, k, v)
      if allowed[k] then rawset(t, k, v) return end
      error("lamp-painter: write to undeclared global '" .. tostring(k) .. "'", 2)
    end,
    __index = function(_, k)
      if allowed[k] then return nil end
      error("lamp-painter: read of undeclared global '" .. tostring(k) .. "'", 2)
    end,
  })
end
