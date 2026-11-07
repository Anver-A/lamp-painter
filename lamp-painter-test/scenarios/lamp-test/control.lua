-- Automated test for lamp-painter. Drives the mod's real event handlers through its debug
-- remote interface (selection events cannot be raised by script) and checks actual lamp state.
-- Phase 1: --test-scenario. Phase 2: --test-save on the autosave phase 1 leaves (save/load check).
-- Without a test arg (heavy-mode run) phase 2 runs and just logs instead of finishing.

local D = "lamp_painter_debug"
local TOOL, PICKER = "lamp-painter", "lamp-painter-picker"
local L = defines.mouse_button_type.left
local R = defines.mouse_button_type.right

local function P() return game.get_player(1) end
local function raise(name, ev) remote.call(D, "raise", name, ev) end
local function st() return remote.call(D, "state", 1) end
local function frame() return P().gui.screen.lamp_painter_frame end

local function check(cond, msg)
  if not cond then error("CHECK FAILED: " .. msg, 2) end
  storage.checks = (storage.checks or 0) + 1
end

local function near(a, b) return math.abs(a - b) < 0.006 end
local function same(c, d) return near(c.r, d.r) and near(c.g, d.g) and near(c.b, d.b) end
local WHITE, RED, GREEN, BLUE = {r=1,g=1,b=1}, {r=1,g=0,b=0}, {r=0,g=1,b=0}, {r=0,g=0,b=1}
local YELLOW = {r=1,g=1,b=0}

local function search(e, pred)
  if pred(e) then return e end
  for _, c in pairs(e.children) do
    local r = search(c, pred)
    if r then return r end
  end
end
local function el(name) return search(frame(), function(e) return e.name == name end) end
local function tagged(lp, i)
  return search(frame(), function(e) return e.tags.lp == lp and (i == nil or e.tags.i == i) end)
end

local function click(e, button)
  raise("on_gui_click", {player_index = 1, element = e, button = button or L,
                         alt = false, control = false, shift = false})
end

local function select(kind, ents, item)
  local ev = {player_index = 1, item = item or TOOL, entities = ents, tiles = {},
              area = {left_top = {x = -1000, y = -1000}, right_bottom = {x = 1000, y = 1000}},
              surface = P().surface}
  raise(kind, ev)
end

local function set_on(v)  -- clicking a radio button: the game ticks it, then raises the event
  local r = el("on_" .. v)
  r.state = true
  raise("on_gui_checked_state_changed", {player_index = 1, element = r})
end

local function lamps(a, b)
  local r = {}
  for i = a, b do r[#r + 1] = storage.t.lamps[i] end
  return r
end
local function all_color(list, c, label)
  for i, e in ipairs(list) do check(same(e.color, c), label .. " lamp " .. i .. " colour " .. serpent.line(e.color)) end
end
local function all_on(list, v, label)
  for i, e in ipairs(list) do check(e.always_on == v, label .. " lamp " .. i .. " always_on " .. tostring(e.always_on)) end
end
local function set_slider(ch, v)
  local s = el("slider_" .. ch)
  s.slider_value = v
  raise("on_gui_value_changed", {player_index = 1, element = s})
end
local function cursor_name()
  local cs = P().cursor_stack
  return cs and cs.valid_for_read and cs.name or nil
end

---------------------------------------------------------------------------
local phase1 = {
  function() -- setup
    local s = P().surface
    local f = P().force
    local t = {lamps = {}, ghosts = {}}
    for i = 1, 9 do t.lamps[i] = s.create_entity{name = "small-lamp", position = {20 + i * 2, 20}, force = f} end
    for i = 1, 2 do
      t.ghosts[i] = s.create_entity{name = "entity-ghost", inner_name = "small-lamp", position = {20 + i * 2, 24}, force = f}
    end
    -- lamp coloured by circuit signals
    t.cc_lamp = s.create_entity{name = "small-lamp", position = {40, 20}, force = f}
    local cc1 = s.create_entity{name = "constant-combinator", position = {42, 20}, force = f}
    t.cc_lamp.get_wire_connector(defines.wire_connector_id.circuit_red, true)
      .connect_to(cc1.get_wire_connector(defines.wire_connector_id.circuit_red, true))
    t.cc_lamp.get_or_create_control_behavior().use_colors = true
    -- lamp switched on/off by circuit
    t.on_lamp = s.create_entity{name = "small-lamp", position = {40, 24}, force = f}
    local cc2 = s.create_entity{name = "constant-combinator", position = {42, 24}, force = f}
    t.on_lamp.get_wire_connector(defines.wire_connector_id.circuit_green, true)
      .connect_to(cc2.get_wire_connector(defines.wire_connector_id.circuit_green, true))
    t.on_lamp.get_or_create_control_behavior().circuit_enable_disable = true
    t.chest = s.create_entity{name = "wooden-chest", position = {46, 20}, force = f}
    storage.t = t
    check(#t.lamps == 9 and t.ghosts[2] and t.cc_lamp and t.on_lamp and t.chest, "setup created entities")
    return 1
  end,

  function() -- select everything (non-lamp chest must be filtered out)
    local t = storage.t
    local ents = lamps(1, 9)
    for _, g in ipairs(t.ghosts) do ents[#ents + 1] = g end
    ents[#ents + 1] = t.cc_lamp
    ents[#ents + 1] = t.on_lamp
    ents[#ents + 1] = t.chest
    select("on_player_selected_area", ents)
    local s = st()
    check(s.lamps == 13, "13 lamps selected, got " .. s.lamps)
    check(frame() ~= nil, "window opened")
    check(P().opened == frame(), "window is player.opened")
    local loc = frame().location
    check(loc.x < 100 and loc.y < 150, "window opens top-left, got " .. loc.x .. "," .. loc.y)
    check(el("pin").type == "sprite-button" and not el("pin").toggled, "pin button in title bar, off")
    click(el("pin"))
    check(el("pin").toggled and P().opened == nil, "pin on: toggled, window no longer player.opened")
    raise("on_gui_closed", {player_index = 1, element = frame(), gui_type = defines.gui_type.custom})
    check(frame() ~= nil and st().lamps == 13, "pinned window survives a close event (Esc/E)")
    click(el("pin"))
    check(not el("pin").toggled and P().opened == frame(), "pin off: window is player.opened again")
    check(s.outlines == 13, "13 outlines drawn, got " .. s.outlines)
    check(el("warn").visible, "circuit warning visible")
    check(el("circuit").visible, "include-circuit checkbox visible")
    return 1
  end,

  function() -- sliders -> red
    set_slider("g", 0)
    set_slider("b", 0)
    check(el("hex").text == "#FF0000", "hex shows #FF0000, got " .. el("hex").text)
    check(el("num_g").text == "0", "num_g shows 0")
    return 2
  end,
  function()
    local t = storage.t
    all_color(lamps(1, 9), RED, "slider preview")
    check(same(t.cc_lamp.color, WHITE), "circuit-coloured lamp left alone")
    check(same(t.on_lamp.color, RED), "circuit-on/off lamp still recoloured")
    check(t.ghosts[1].tags == nil, "ghost tags untouched during preview")
    return 0
  end,

  function() -- always on switch
    set_on("on")
    return 2
  end,
  function()
    local t = storage.t
    all_on(lamps(1, 9), true, "switch preview")
    check(t.ghosts[1].always_on == true, "ghost always_on previewed")
    check(t.on_lamp.always_on == false, "circuit on/off lamp keeps always_on")
    return 0
  end,

  function() -- vanilla preset
    click(tagged("vanilla", 2))
    return 2
  end,
  function()
    all_color(lamps(1, 9), GREEN, "vanilla green")
    return 0
  end,

  function() -- hex entry
    local h = el("hex")
    h.text = "#0080FF"
    raise("on_gui_text_changed", {player_index = 1, element = h, text = h.text})
    return 2
  end,
  function()
    all_color(lamps(1, 3), {r = 0, g = 128/255, b = 1}, "hex")
    check(el("slider_g").slider_value == 128, "slider follows hex")
    return 0
  end,

  function() -- numeric entry
    local n = el("num_g")
    n.text = "200"
    raise("on_gui_text_changed", {player_index = 1, element = n, text = n.text})
    return 2
  end,
  function()
    all_color(lamps(1, 3), {r = 0, g = 200/255, b = 1}, "numeric")
    return 0
  end,

  function() -- include circuit lamps
    local c = el("circuit")
    c.state = true
    raise("on_gui_checked_state_changed", {player_index = 1, element = c})
    return 2
  end,
  function()
    local t = storage.t
    check(same(t.cc_lamp.color, {r = 0, g = 200/255, b = 1}), "circuit lamp recoloured when included")
    check(t.on_lamp.always_on == true, "circuit on/off lamp switched when included")
    local c = el("circuit")
    c.state = false
    raise("on_gui_checked_state_changed", {player_index = 1, element = c})
    return 2
  end,
  function()
    local t = storage.t
    check(same(t.cc_lamp.color, WHITE), "circuit lamp restored when unticked")
    check(t.on_lamp.always_on == false, "circuit on/off lamp restored when unticked")
    return 0
  end,

  function() -- presets: save, use, delete
    click(el("save_preset"))
    check(st().presets == 1, "preset saved")
    click(tagged("vanilla", 1)) -- red
    click(el("preset_1"))
    check(same(st().color, {r = 0, g = 200/255, b = 1}), "preset restores colour")
    click(el("preset_1"), R)
    check(st().presets == 0, "right-click deletes preset")
    click(el("save_preset"))
    check(st().presets == 1 and el("preset_1") ~= nil, "preset re-saved")
    return 2
  end,

  function() -- cancel restores everything
    click(el("cancel"))
    check(frame() == nil, "window closed on cancel")
    return 3
  end,
  function()
    local t = storage.t
    all_color(lamps(1, 9), WHITE, "cancel")
    all_on(lamps(1, 9), false, "cancel")
    check(t.ghosts[1].always_on == false and t.ghosts[1].tags == nil, "ghost restored on cancel")
    local s = st()
    check(s.owners == 0 and s.jobs == 0, "locks and jobs cleared after cancel")
    return 0
  end,

  function() -- select 1-5, shift-add 6-9 + ghosts, right-drag remove 1-2
    select("on_player_selected_area", lamps(1, 5))
    click(tagged("vanilla", 1))
    local add = lamps(6, 9)
    add[#add + 1] = storage.t.ghosts[1]
    add[#add + 1] = storage.t.ghosts[2]
    select("on_player_alt_selected_area", add)
    check(st().lamps == 11, "shift-drag adds, got " .. st().lamps)
    select("on_player_reverse_selected_area", lamps(1, 2))
    check(st().lamps == 9, "right-drag removes, got " .. st().lamps)
    return 3
  end,
  function()
    all_color(lamps(1, 2), WHITE, "removed lamps restored")
    all_color(lamps(3, 9), RED, "remaining lamps previewed")
    return 0
  end,

  function() -- apply commits
    click(el("apply"))
    check(frame() == nil, "window closed on apply")
    return 3
  end,
  function()
    local t = storage.t
    all_color(lamps(1, 2), WHITE, "apply untouched")
    all_color(lamps(3, 9), RED, "apply committed")
    local tags = t.ghosts[1].tags
    check(tags and tags.lamp_painter_color and same(tags.lamp_painter_color, RED), "ghost carries colour tag")
    local s = st()
    check(s.owners == 0 and s.has_last, "locks released, undo snapshot kept")
    -- build the ghost: colour must arrive on the real lamp
    local _, built = t.ghosts[1].revive{raise_revive = true}
    check(built and same(built.color, RED), "revived ghost lamp is red")
    t.built = built
    return 1
  end,

  function() -- undo last paint
    select("on_player_selected_area", lamps(3, 5))
    click(el("undo"))
    check(frame() == nil, "undo closes window")
    return 3
  end,
  function()
    local t = storage.t
    all_color(lamps(1, 9), WHITE, "undo")
    check(t.ghosts[2].tags == nil or t.ghosts[2].tags.lamp_painter_color == nil, "ghost tag removed by undo")
    check(not st().has_last, "undo snapshot consumed")
    return 0
  end,

  function() -- eyedropper
    storage.t.lamps[9].color = BLUE
    select("on_player_selected_area", lamps(1, 3))
    click(el("pick"))
    check(cursor_name() == PICKER, "picker in cursor, got " .. tostring(cursor_name()))
    check(P().opened ~= frame(), "window not modal while picking")
    select("on_player_selected_area", {storage.t.lamps[9]}, PICKER)
    check(same(st().color, BLUE), "picked colour is blue")
    check(cursor_name() == TOOL, "painter back in cursor")
    check(P().opened == frame(), "window modal again")
    return 2
  end,
  function()
    all_color(lamps(1, 3), BLUE, "picked colour previewed")
    raise("on_gui_closed", {player_index = 1, element = frame(), gui_type = defines.gui_type.custom})
    check(frame() == nil, "closing window cancels")
    return 3
  end,
  function()
    all_color(lamps(1, 3), WHITE, "close restored")
    storage.t.lamps[9].color = WHITE
    return 0
  end,

  function() -- large selection: work must be spread across ticks
    local s, f = P().surface, P().force
    local made = 0
    for x = 0, 199 do
      for y = 0, 99 do
        if s.create_entity{name = "small-lamp", position = {200 + x, 200 + y}, force = f} then made = made + 1 end
      end
    end
    local big = s.find_entities_filtered{type = "lamp", area = {{199, 199}, {401, 301}}}
    storage.t.big_n = #big
    check(#big == 20000, "20000 lamps created, got " .. #big)
    local prof = helpers.create_profiler()
    select("on_player_selected_area", big)
    prof.stop()
    log({"", "LP-PERF selection of 20000 lamps took ", prof})
    local st1 = st()
    check(st1.lamps + st1.pending == 20000, "20000 selected or queued, got " .. st1.lamps .. "+" .. st1.pending)
    check(st1.lamps <= 100, "selection handler only captures a small first slice, got " .. st1.lamps)
    check(st1.area_objs == 1, "area box drawn for big selection")
    click(tagged("vanilla", 1))
    return 1
  end,
  function()
    local s = P().surface
    local n = 0
    for _, e in pairs(s.find_entities_filtered{type = "lamp", area = {{199, 199}, {401, 301}}}) do
      if same(e.color, RED) then n = n + 1 end
    end
    local b = remote.call(D, "batch")
    log("LP-PERF after 1 tick " .. n .. " of 20000 lamps recoloured (batch " .. b .. ")")
    check(n > 0 and n <= b, "first tick recolours at most one batch, got " .. n)
    -- cost of one batch of writes, measured with the same API calls
    local list = s.find_entities_filtered{type = "lamp", area = {{199, 199}, {401, 301}}, limit = b}
    local prof = helpers.create_profiler()
    for _, e in pairs(list) do e.color = WHITE end -- same cost; keeps uncaptured lamps white
    prof.stop()
    log({"", "LP-PERF one batch of " .. b .. " colour writes took ", prof})
    return 260
  end,
  function()
    local st2 = st()
    check(st2.lamps == 20000 and st2.pending == 0, "all 20000 captured, got " .. st2.lamps .. "+" .. st2.pending)
    check(st2.outlines <= 1500, "outlines capped at 1500, got " .. st2.outlines)
    local n = 0
    for _, e in pairs(P().surface.find_entities_filtered{type = "lamp", area = {{199, 199}, {401, 301}}}) do
      if same(e.color, RED) then n = n + 1 end
    end
    check(n == 20000, "all 20000 recoloured after spreading, got " .. n)
    click(el("cancel"))
    return 60
  end,
  function()
    local n = 0
    for _, e in pairs(P().surface.find_entities_filtered{type = "lamp", area = {{199, 199}, {401, 301}}}) do
      if same(e.color, WHITE) then n = n + 1 end
    end
    check(n == 20000, "all 20000 restored after cancel, got " .. n)
    check(st().owners == 0 and st().jobs == 0, "big job finished")
    return 0
  end,

  function() -- big Apply pressed while lamps are still loading: finishes in the background
    local big = P().surface.find_entities_filtered{type = "lamp", area = {{199, 199}, {401, 301}}}
    select("on_player_selected_area", big)
    click(tagged("vanilla", 3)) -- blue
    check(st().pending > 0, "still loading when Apply is pressed")
    click(el("apply"))
    check(frame() == nil, "window closes immediately on Apply")
    check(st().committing, "apply continues in the background")
    return 300
  end,
  function()
    local n = 0
    for _, e in pairs(P().surface.find_entities_filtered{type = "lamp", area = {{199, 199}, {401, 301}}}) do
      if same(e.color, BLUE) then n = n + 1 end
    end
    check(n == 20000, "background apply committed all 20000, got " .. n)
    local s = st()
    check(not s.committing and s.jobs == 0 and s.owners == 0, "background apply finished cleanly")
    check(s.has_last, "undo snapshot for big apply")
    select("on_player_selected_area", lamps(1, 1))
    click(el("undo"))
    return 60
  end,
  function()
    local n = 0
    for _, e in pairs(P().surface.find_entities_filtered{type = "lamp", area = {{199, 199}, {401, 301}}}) do
      if same(e.color, WHITE) then n = n + 1 end
    end
    check(n == 20000, "undo restored all 20000, got " .. n)
    check(same(storage.t.lamps[1].color, WHITE), "small lamp restored too")
    check(st().owners == 0 and st().jobs == 0, "undo job finished")
    return 0
  end,

  function() -- a fresh selection shows the lamps' own colour and changes nothing until a control is used
    local ls = lamps(1, 3)
    ls[1].color, ls[2].color, ls[3].color = GREEN, RED, GREEN
    for _, e in ipairs(ls) do e.always_on = false end
    ls[3].always_on = true
    select("on_player_selected_area", ls)
    return 5
  end,
  function()
    local ls = lamps(1, 3)
    check(el("hex").text == "#00FF00", "window shows first lamp's colour, got " .. el("hex").text)
    check(el("on_keep").state and not el("on_on").state and not el("on_normal").state, "mode starts at Leave as is")
    check(same(ls[1].color, GREEN) and same(ls[2].color, RED), "no auto-preview: lamps keep own colours")
    click(el("apply"))
    return 5
  end,
  function()
    local ls = lamps(1, 3)
    check(same(ls[1].color, GREEN) and same(ls[2].color, RED) and same(ls[3].color, GREEN),
          "Apply with nothing changed leaves lamps alone")
    select("on_player_selected_area", ls)
    set_on("on")
    return 5
  end,
  function()
    local ls = lamps(1, 3)
    check(ls[1].always_on and ls[2].always_on, "switch-only change previews always-on")
    check(el("on_on").state and not el("on_keep").state, "only Always on is selected")
    set_on("normal")
    return 2
  end,
  function()
    local ls = lamps(1, 3)
    check(not ls[1].always_on and not ls[3].always_on, "Always on -> Normal turns it off")
    check(el("on_normal").state and not el("on_on").state, "only Normal is selected")
    set_on("keep")
    return 2
  end,
  function()
    local ls = lamps(1, 3)
    check(not ls[1].always_on and ls[3].always_on and el("on_keep").state,
          "Leave as is puts back each lamp's own setting")
    set_on("on")
    return 2
  end,
  function()
    local ls = lamps(1, 3)
    check(same(ls[1].color, GREEN) and same(ls[2].color, RED), "switch-only change keeps mixed colours")
    click(el("apply"))
    return 5
  end,
  function()
    local ls = lamps(1, 3)
    check(ls[2].always_on and same(ls[2].color, RED), "switch-only Apply: always on, colour kept")
    for _, e in ipairs(ls) do e.color = WHITE; e.always_on = false end
    return 0
  end,

  function() -- leave an edit open for the save/load phase
    select("on_player_selected_area", lamps(1, 3))
    click(tagged("vanilla", 4)) -- yellow
    return 2
  end,
  function()
    all_color(lamps(1, 3), YELLOW, "pre-save preview")
    log("LP-TEST phase1 passed, checks=" .. storage.checks)
    storage.done1 = true
    game.auto_save("lamp-painter-phase1")
    return 2
  end,
}

local phase2 = {
  function() -- after reload: edit still open and working
    local s = st()
    check(s.lamps == 3, "session survived save/load, lamps " .. s.lamps)
    check(same(s.color, YELLOW), "colour survived save/load")
    check(frame() ~= nil, "window survived save/load")
    all_color(lamps(1, 3), YELLOW, "preview survived save/load")
    click(tagged("vanilla", 3)) -- blue
    return 2
  end,
  function()
    all_color(lamps(1, 3), BLUE, "preview works after load")
    click(el("cancel"))
    return 3
  end,
  function()
    all_color(lamps(1, 3), WHITE, "cancel works after load")
    return 0
  end,

  function() -- death cancels (real event)
    select("on_player_selected_area", lamps(1, 3))
    click(tagged("vanilla", 1))
    return 2
  end,
  function()
    all_color(lamps(1, 3), RED, "pre-death preview")
    P().character.die()
    return 3
  end,
  function()
    all_color(lamps(1, 3), WHITE, "death restored")
    check(frame() == nil, "window gone after death")
    return 0
  end,

  function() -- leaving cancels
    select("on_player_selected_area", lamps(4, 6))
    click(tagged("vanilla", 1))
    return 2
  end,
  function()
    all_color(lamps(4, 6), RED, "pre-leave preview")
    raise("on_pre_player_left_game", {player_index = 1, reason = defines.disconnect_reason.quit})
    return 3
  end,
  function()
    all_color(lamps(4, 6), WHITE, "leaving restored")
    check(st().owners == 0 and st().jobs == 0, "nothing left locked")
    log("LP-TEST phase2 passed, checks=" .. storage.checks)
    if script.test_arg == "phase2" then
      script.finish_test(true)
    else
      log("LP-HEAVY scripted run complete at tick " .. game.tick)
    end
    return 1000
  end,
}

script.on_event(defines.events.on_tick, function(e)
  if e.tick < 3 then return end
  storage.wait = storage.wait or 0
  if e.tick < storage.wait then return end
  local list
  if storage.done1 and script.test_arg == "phase1" then
    script.finish_test(true)
    return
  end
  if storage.done1 then
    list = phase2
    storage.i2 = storage.i2 or 1
    local f = list[storage.i2]
    if not f then return end
    storage.i2 = storage.i2 + 1
    storage.wait = e.tick + f()
  else
    list = phase1
    storage.i1 = storage.i1 or 1
    local f = list[storage.i1]
    if not f then return end
    storage.i1 = storage.i1 + 1
    storage.wait = e.tick + f()
  end
end)
