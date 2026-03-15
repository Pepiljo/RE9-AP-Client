-- RE9 item injector scaffold.
-- Uses the chest candidate found by _NextKey heuristic and tries manager-driven insertion paths.

local probe = require("re9_inventory_probe")

local Injector = {}

local cfg = {
    dry_run = true,
    default_amount = 1,
}

local function log(msg)
    print(string.format("[RE9-INJECT] %s", msg))
end

local function safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    return ok, result
end

local function find_manager()
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

    if ok_mgr then
        return manager
    end
    return nil
end

local function get_box_inventory()
    local box = probe.find_box()
    if box == nil then
        return nil
    end
    return box.inv
end

local function call_first_available(target, method_names, ...)
    for _, name in ipairs(method_names) do
        local ok, result = safe_call(function()
            return target:call(name, ...)
        end)
        if ok then
            return true, name, result
        end
    end
    return false, nil, nil
end

function Injector.send_to_box(item_id, amount)
    amount = amount or cfg.default_amount

    local manager = find_manager()
    local box_inv = get_box_inventory()

    if manager == nil or box_inv == nil then
        log("manager or chest inventory unavailable")
        return false
    end

    log(string.format("request item=%s amount=%d dry_run=%s", tostring(item_id), amount, tostring(cfg.dry_run)))

    if cfg.dry_run then
        return true
    end

    local ok, method_name = call_first_available(manager,
        {
            "mergeOrAdd(app.Inventory,System.String,System.Int32)",
            "mergeOrAdd(app.Inventory,System.String)",
            "addItem(app.Inventory,System.String,System.Int32)",
            "addItemData(app.Inventory,System.String,System.Int32)",
        },
        box_inv,
        item_id,
        amount
    )

    if ok then
        log("manager insert path worked via " .. method_name)
        return true
    end

    local ok_inv, inv_method = call_first_available(box_inv,
        {
            "mergeOrAdd(System.String,System.Int32)",
            "addItem(System.String,System.Int32,app.WeaponGunSaveData)",
            "addItem(System.String,System.Int32)",
        },
        item_id,
        amount,
        nil
    )

    if ok_inv then
        log("inventory insert path worked via " .. inv_method)
        return true
    end

    log("all insertion paths failed")
    return false
end

re.on_draw_ui(function()
    if imgui.tree_node("RE9 Item Injector") then
        changed, cfg.dry_run = imgui.checkbox("Dry run", cfg.dry_run)
        changed, cfg.default_amount = imgui.drag_int("Default amount", cfg.default_amount, 1, 1, 999)

        if imgui.button("Send test item to chest") then
            Injector.send_to_box("TestItem", cfg.default_amount)
        end

        imgui.tree_pop()
    end
end)

return Injector
