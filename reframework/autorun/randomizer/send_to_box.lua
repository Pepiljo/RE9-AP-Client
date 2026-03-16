-- send_to_box.lua
-- RE9 Item Injection for Archipelago integration
-- Injects items directly into the item box inventory
-- Now with autocomplete item search by name

local PREFIX      = "[RE9 INJECT] "
local BOX_INDEX   = 2
local HOTKEY      = 0x77 -- F8

local last_hotkey    = false
local startup_frames = 60

-- UI state
local search_text = ""
local selected_item_id = ""
local selected_item_name = ""
local inject_qty = 1
local show_suggestions = false
local filtered_items = {}

-- Item database loaded from JSON
local item_db = {}        -- array of { id, name, category, ... }
local item_db_loaded = false

-- ============================================================
-- Helpers
-- ============================================================
local function log(...)
    local t = {}
    for _, v in ipairs({...}) do t[#t+1] = tostring(v) end
    print(PREFIX .. table.concat(t, " "))
end

local function try(fn)
    local ok, v = pcall(fn)
    return (ok and v ~= nil) and v or nil
end

local function item_id_to_name(id_obj)
    if not id_obj then return "nil" end
    local fields = try(function() return sdk.find_type_definition("app.ItemID"):get_fields() end) or {}
    for _, f in ipairs(fields) do
        local fval = try(function() return f:get_data(nil) end)
        if fval == id_obj then return try(function() return f:get_name() end) or "?" end
    end
    return "unknown"
end

-- ============================================================
-- Load item_list.json
-- ============================================================
local function load_item_db()
    if item_db_loaded then return end

    local paths = {
        "reframework/data/item_list.json",
        "item_list.json",
    }

    local content = nil
    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            content = f:read("*a")
            f:close()
            log("Loaded item DB from:", path)
            break
        end
    end

    if not content then
        log("ERROR: Could not find item_list.json")
        return
    end

    -- Simple JSON array parser for our known structure
    -- Each item: { "id": "...", "name": "...", "category": "...", ... }
    for id, name, category in content:gmatch(
        '"id"%s*:%s*"([^"]+)"%s*,%s*"name"%s*:%s*"([^"]+)"%s*,%s*"category"%s*:%s*"([^"]+)"'
    ) do
        item_db[#item_db+1] = {
            id = id,
            name = name,
            category = category,
            search_str = (name .. " " .. id .. " " .. category):lower(),
        }
    end

    table.sort(item_db, function(a, b) return a.name < b.name end)
    item_db_loaded = true
    log("Item DB:", #item_db, "items loaded")
end

-- ============================================================
-- Filter items by search string
-- ============================================================
local function filter_items(query)
    if query == "" then
        filtered_items = {}
        return
    end

    local q = query:lower()
    local results = {}

    for _, item in ipairs(item_db) do
        if item.search_str:find(q, 1, true) then
            results[#results+1] = item
            if #results >= 15 then break end
        end
    end

    filtered_items = results
end

-- ============================================================
-- Inventory access
-- ============================================================
local function get_box()
    local mgr = sdk.get_managed_singleton("app.InventoryManager")
    if not mgr then return nil end
    local elems = try(function()
        return mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
    end)
    if not elems then return nil end
    local entry = elems[BOX_INDEX + 1]
    return entry and (
        try(function() return entry:get_field("value") end) or
        try(function() return entry:get_field("_value") end) or
        try(function() return entry:get_field("Value") end)
    )
end

local function get_item_id_enum(item_name)
    local field = try(function()
        return sdk.find_type_definition("app.ItemID"):get_field(item_name)
    end)
    return field and try(function() return field:get_data(nil) end)
end

local function get_item_detail(item_name)
    local mgr = sdk.get_managed_singleton("app.ItemManager")
    if not mgr then return nil end
    local target_id = get_item_id_enum(item_name)
    if not target_id then return nil end

    local methods = try(function() return mgr:get_type_definition():get_methods() end) or {}
    for _, m in ipairs(methods) do
        if try(function() return m:get_name() end) == "tryGetItemDetail" then
            local ok, ret = pcall(function() return m:call(mgr, target_id) end)
            if ok and ret and try(function()
                return ret:get_type_definition():get_full_name()
            end) == "app.ItemDetailData" then
                return ret
            end
        end
    end

    local elems = try(function()
        return mgr:get_field("_ItemCatalog"):get_field("_Dict"):get_field("_entries"):get_elements()
    end) or {}
    for _, e in ipairs(elems) do
        local k = try(function() return e:get_field("key") end)
        if k and item_id_to_name(k) == item_name then
            local v = try(function() return e:get_field("value") end)
            return try(function() return v:get_field("_Value") end) or v
        end
    end
    return nil
end

local function get_box_capacity(detail)
    local scd = detail and try(function() return detail:get_field("_SlotCapacityData") end)
    return (scd and (
        try(function() return scd:get_field("_BaseItemBoxCapacity") end) or
        try(function() return scd:get_field("_BaseCapacity") end)
    )) or 99
end

local function find_panel_info(box, item_name)
    local elems = try(function()
        return box:get_field("_PanelItems"):get_field("_entries"):get_elements()
    end) or {}
    local best, best_room = nil, -1
    for _, e in ipairs(elems) do
        local info = try(function() return e:get_field("value") end)
        if info then
            local state = try(function() return info:get_field("_PanelState") end)
            local id    = state and try(function() return state:get_field("<ItemID>k__BackingField") end)
            if item_id_to_name(id) == item_name then
                local stock = try(function() return info:get_field("_Stock") end) or 0
                local cap   = try(function() return info:get_field("_StockCapacity") end) or 1
                if (cap - stock) > best_room then
                    best_room = cap - stock
                    best = info
                end
            end
        end
    end
    return best, best_room
end

local function set_stock(info, stock, cap)
    pcall(function() info:set_field("_StockCapacity", cap) end)
    pcall(function() info:set_field("_Stock", stock) end)
    local state = try(function() return info:get_field("_PanelState") end)
    if state then
        pcall(function() state:set_field("<StockCapacity>k__BackingField", cap) end)
        pcall(function() state:set_field("<Stock>k__BackingField", stock) end)
    end
end

-- ============================================================
-- addPanelImpl setup
-- ============================================================
local add_panel_method = nil
do
    local methods = try(function()
        return sdk.find_type_definition("app.Inventory"):get_methods()
    end) or {}
    local idx = 0
    for _, m in ipairs(methods) do
        if try(function() return m:get_name() end) == "addPanelImpl" then
            idx = idx + 1
            if idx == 1 then add_panel_method = m break end
        end
    end
end
log("addPanelImpl:", add_panel_method and "found" or "NOT FOUND")

local function create_slot_address()
    local td = sdk.find_type_definition("app.Inventory.SlotAddress")
    return td and (try(function() return td:create_instance(true) end)
               or  try(function() return td:create_instance() end))
end

-- ============================================================
-- UI refresh
-- ============================================================
local function refresh_ui(box)
    local mgr         = sdk.get_managed_singleton("app.InventoryManager")
    local stock_event = mgr and try(function() return mgr:get_field("StockChangedEvent") end)
    if not stock_event then return end
    local args_td   = sdk.find_type_definition("app.InventoryStockEventArgs")
    local event_args = args_td and (
        try(function() return args_td:create_instance(true) end) or
        try(function() return args_td:create_instance() end)
    )
    if not event_args then return end
    pcall(function()
        local methods = try(function() return stock_event:get_type_definition():get_methods() end) or {}
        for _, m in ipairs(methods) do
            if try(function() return m:get_name() end) == "Invoke" then
                m:call(stock_event, mgr, event_args)
                return
            end
        end
    end)
end

-- ============================================================
-- Main inject
-- ============================================================
local function inject_item(item_id, quantity)
    log("=== Injecting", item_id, "x" .. quantity, "===")

    local box = get_box()
    if not box then log("ERROR: box not found") return end

    local detail = get_item_detail(item_id)
    if not detail then log("ERROR: no ItemDetailData for", item_id) return end

    local true_cap  = get_box_capacity(detail)
    local remaining = quantity
    log("Box capacity for item:", true_cap)

    while remaining > 0 do
        local info, room = find_panel_info(box, item_id)
        if not info or room <= 0 then break end
        local cur  = try(function() return info:get_field("_Stock") end) or 0
        local cap  = try(function() return info:get_field("_StockCapacity") end) or 1
        if cap < true_cap then cap = true_cap end
        local add  = math.min(remaining, cap - cur)
        set_stock(info, cur + add, cap)
        log(string.format("Stacked: %d + %d = %d (cap=%d)", cur, add, cur + add, cap))
        remaining = remaining - add
    end

    while remaining > 0 do
        if not add_panel_method then log("ERROR: addPanelImpl not found") break end

        local slot = create_slot_address()
        if not slot then log("ERROR: SlotAddress creation failed") break end

        local before = #(try(function() return box:call("getPanelStates"):get_elements() end) or {})
        local ok, err = pcall(function() add_panel_method:call(box, slot, nil, detail, nil) end)
        local after  = #(try(function() return box:call("getPanelStates"):get_elements() end) or {})

        if not ok or after <= before then
            log("addPanelImpl failed:", tostring(err))
            break
        end

        local new_info, min_s = nil, math.huge
        local elems = try(function()
            return box:get_field("_PanelItems"):get_field("_entries"):get_elements()
        end) or {}
        for _, e in ipairs(elems) do
            local info  = try(function() return e:get_field("value") end)
            local state = info and try(function() return info:get_field("_PanelState") end)
            local id    = state and try(function() return state:get_field("<ItemID>k__BackingField") end)
            if item_id_to_name(id) == item_id then
                local s = try(function() return info:get_field("_Stock") end) or 0
                if s < min_s then min_s = s; new_info = info end
            end
        end

        if not new_info then log("WARNING: new panel not found") break end

        local add = math.min(remaining, true_cap)
        set_stock(new_info, add, true_cap)
        log(string.format("New panel: stock=%d cap=%d", add, true_cap))
        remaining = remaining - add
    end

    if remaining == 0 then
        log("*** SUCCESS: all", quantity, "injected ***")
    else
        log(string.format("WARNING: only %d/%d injected", quantity - remaining, quantity))
    end

    refresh_ui(box)
end

-- ============================================================
-- Load item DB on startup
-- ============================================================
load_item_db()

-- ============================================================
-- Hotkey
-- ============================================================
re.on_frame(function()
    if startup_frames > 0 then
        startup_frames = startup_frames - 1
        last_hotkey = imgui.is_key_down(HOTKEY)
        return
    end
    local down = imgui.is_key_down(HOTKEY)
    if down and not last_hotkey then
        if selected_item_id ~= "" then
            pcall(inject_item, selected_item_id, inject_qty)
        else
            log("No item selected!")
        end
    end
    last_hotkey = down
end)

-- ============================================================
-- UI with autocomplete
-- ============================================================
re.on_draw_ui(function()
    if imgui.tree_node("RE9 Item Injection") then

        -- Search input
        local changed, new_text = imgui.input_text("Search Item", search_text, 256)
        if changed then
            search_text = new_text
            filter_items(search_text)
            show_suggestions = true
            -- Clear selection if user is typing
            if search_text ~= selected_item_name then
                selected_item_id = ""
            end
        end

        -- Suggestions dropdown
        if show_suggestions and #filtered_items > 0 and search_text ~= selected_item_name then
            imgui.begin_child_window("suggestions", nil, 200, true)
            for _, item in ipairs(filtered_items) do
                local label = item.name .. "  [" .. item.category .. "]  (" .. item.id .. ")"
                if imgui.button(label) then
                    selected_item_id = item.id
                    selected_item_name = item.name
                    search_text = item.name
                    show_suggestions = false
                    filtered_items = {}
                end
            end
            imgui.end_child_window()
        end

        -- Quantity input
        local qty_changed, new_qty = imgui.drag_int("Quantity", inject_qty, 1, 1, 999)
        if qty_changed then
            inject_qty = new_qty
        end

        imgui.spacing()

        -- Selected item display
        if selected_item_id ~= "" then
            imgui.text("Selected: " .. selected_item_name .. " (" .. selected_item_id .. ")")
        else
            imgui.text("Selected: (none)")
        end

        imgui.spacing()

        -- Inject button
        local can_inject = selected_item_id ~= ""
        if can_inject then
            if imgui.button("Inject [F8]") then
                pcall(inject_item, selected_item_id, inject_qty)
            end
        else
            imgui.text("Select an item to inject")
        end

        imgui.spacing()
        imgui.text("Press F8 to inject selected item")

        imgui.tree_pop()
    end
end)

log("loaded - search and inject items")
