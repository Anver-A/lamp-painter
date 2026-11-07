local lamp_icon = "__base__/graphics/icons/small-lamp.png"

-- Ghosts may be filtered by their own type or by their inner type depending on engine
-- rules, so both are whitelisted; control.lua keeps only real lamps and lamp ghosts.
local function mode(color)
  return {
    border_color = color,
    cursor_box_type = "entity",
    mode = {"buildable-type", "entity-ghost", "same-force"},
    entity_filter_mode = "whitelist",
    entity_type_filters = {"lamp", "entity-ghost"},
  }
end

data:extend{
  {
    type = "selection-tool",
    name = "lamp-painter",
    icon = lamp_icon,
    icon_size = 64,
    flags = {"only-in-cursor", "spawnable", "not-stackable"},
    hidden = true,
    stack_size = 1,
    order = "c[automated-construction]-l[lamp-painter]",
    draw_label_for_cursor_render = false,
    select = mode({r = 1, g = 0.8, b = 0.1, a = 1}),
    alt_select = mode({r = 0.2, g = 0.8, b = 1, a = 1}),
    reverse_select = mode({r = 1, g = 0.25, b = 0.25, a = 1}),
  },
  {
    type = "selection-tool",
    name = "lamp-painter-picker",
    icon = lamp_icon,
    icon_size = 64,
    flags = {"only-in-cursor", "not-stackable"},
    hidden = true,
    stack_size = 1,
    draw_label_for_cursor_render = false,
    select = mode({r = 1, g = 1, b = 1, a = 1}),
    alt_select = mode({r = 1, g = 1, b = 1, a = 1}),
  },
  {
    type = "custom-input",
    name = "lamp-painter-give",
    key_sequence = "ALT + L",
    action = "spawn-item",
    item_to_spawn = "lamp-painter",
  },
  {
    type = "shortcut",
    name = "lamp-painter-shortcut",
    order = "b[blueprints]-l[lamp-painter]",
    action = "spawn-item",
    item_to_spawn = "lamp-painter",
    associated_control_input = "lamp-painter-give",
    style = "blue",
    icon = lamp_icon,
    icon_size = 64,
    small_icon = lamp_icon,
    small_icon_size = 64,
  },
}
