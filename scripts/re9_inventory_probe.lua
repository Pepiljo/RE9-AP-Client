-- RE9 inventory probe script for REFramework.
-- Focus: identify the exact insertion path used by pickups.

local M = {}

local cfg = {
    verbose = true,
    trace_calls = false,
}

local state = {
    manager = nil,
    box_entry_idx = nil,
    method_hits = {},
}

local function log(msg)
    print(string.format("[RE9-INV-PROBE] %s", msg))
end

local function safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok and cfg.verbose then
        log("safe_call failed: " .. tostring(result))
    end
    return ok, result
end

local function get_inventory_manager()
    if state.manager ~= nil then
        return state.manager
    end

    local sm = sdk.get_managed_singleton("app.SceneManager")
    if sm == nil then
        return nil
    end

    local ok_scene, scene = safe_call(function()
        return sm:call("get_CurrentScene")
    end)

    if not ok_scene or scene == nil then
        ok_scene, scene = safe_call(function()
            return sm:call("getCurrentScene")
        end)
    end

    if not ok_scene or scene == nil then
        return nil
    end

    local ok_mgr, manager = safe_call(function()
        return scene:call("findGameObject(System.String)", "InventoryManager")
    end)

    if ok_mgr and manager ~= nil then
        state.manager = manager
    end

    return state.manager
end

local function get_entries(manager)
    local ok_dict, dict = safe_call(function()
        return manager:get_field("_Inventories")
    end)
    if not ok_dict or dict == nil then
        return nil
    end

    local ok_entries, entries = safe_call(function()
        return dict:get_field("_entries")
    end)

    if ok_entries then
        return entries
    end
    return nil
end

local function get_count(list_obj)
    if list_obj == nil then
        return 0
    end
    local ok, count = safe_call(function()
        return list_obj:call("get_Count")
    end)
    if ok and count ~= nil then
        return count
    end
    return 0
end

local function enumerate_inventories()
    local manager = get_inventory_manager()
    if manager == nil then
        return {}
    end

    local entries = get_entries(manager)
    if entries == nil then
        return {}
    end

    local out = {}
    for i = 0, 63 do
        local ok_entry, entry = safe_call(function()
            return entries:call("Get", i)
        end)
        if ok_entry and entry ~= nil then
            local inv = entry:get_field("value")
            if inv ~= nil then
                local next_key = inv:get_field("_NextKey") or 0
                local archive = get_count(inv:get_field("_ArchiveItems"))
                local panel = get_count(inv:get_field("_PanelItems"))
                local notif = get_count(inv:get_field("_NotificationItems"))

                table.insert(out, {
                    idx = i,
                    next_key = next_key,
                    archive = archive,
                    panel = panel,
                    notif = notif,
                    inv = inv,
                })
            end
        end
    end

    return out
end

local function find_box()
    local all = enumerate_inventories()
    local best = nil

    for _, it in ipairs(all) do
        if best == nil or it.next_key > best.next_key then
            best = it
        end
    end

    if best ~= nil then
        state.box_entry_idx = best.idx
        log(string.format("box candidate idx=%d nextKey=%d panel=%d", best.idx, best.next_key, best.panel))
    else
        log("no box candidate found")
    end

    return best
end

local function dump_inventories()
    local all = enumerate_inventories()
    log("----- inventory snapshot -----")
    for _, it in ipairs(all) do
        log(string.format(
            "idx=%d nextKey=%d archive=%d panel=%d notif=%d",
            it.idx,
            it.next_key,
            it.archive,
            it.panel,
            it.notif
        ))
    end
end

local function add_hit(name)
    local n = state.method_hits[name] or 0
    state.method_hits[name] = n + 1
end

local function install_hooks()
    if not cfg.trace_calls then
        log("trace_calls disabled, skipping hook installation")
        return
    end

    local candidates = {
        "app.InventoryManager:mergeOrAdd",
        "app.InventoryManager:testMergeOrAddImpl",
        "app.InventoryManager:expandItemData",
        "app.Inventory:mergeOrAdd",
        "app.Inventory:canMergeOrAdd",
    }

    for _, full_name in ipairs(candidates) do
        local t = sdk.find_type_definition(full_name:match("^([^:]+)"))
        if t ~= nil then
            local method_name = full_name:match(":(.+)$")
            local method = t:get_method(method_name)
            if method ~= nil then
                sdk.hook(method,
                    function(args)
                        add_hit(full_name)
                    end,
                    function(retval)
                        return retval
                    end
                )
                log("hooked " .. full_name)
            end
        end
    end
end

re.on_draw_ui(function()
    if imgui.tree_node("RE9 Inventory Probe") then
        changed, cfg.verbose = imgui.checkbox("Verbose logs", cfg.verbose)
        changed, cfg.trace_calls = imgui.checkbox("Trace inventory calls", cfg.trace_calls)

        if imgui.button("Dump inventories") then
            dump_inventories()
        end
        imgui.same_line()
        if imgui.button("Find chest candidate") then
            find_box()
        end

        if imgui.button("Install hooks") then
            install_hooks()
        end

        if state.box_entry_idx ~= nil then
            imgui.text("Chest idx: " .. tostring(state.box_entry_idx))
        end

        if next(state.method_hits) ~= nil then
            imgui.separator()
            imgui.text("Method hit counters:")
            for name, count in pairs(state.method_hits) do
                imgui.bullet_text(string.format("%s = %d", name, count))
            end
        end

        imgui.tree_pop()
    end
end)

M.find_box = find_box
M.dump_inventories = dump_inventories
M.enumerate_inventories = enumerate_inventories

return M
