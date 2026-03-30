-- speed_modifier.lua
-- Modifies the player's movement speed via REFramework.
-- Open the REFramework overlay and look for "Speed Modifier" in the menu.

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local cfg = {
    enabled    = false,
    multiplier = 2.0,
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local status      = "Idle."
local base_speeds = {}
local patched_objects = {}
local hooked      = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function safe_call(obj, method, ...)
    if not obj then return nil end
    local ok, r = pcall(function(...) return obj:call(method, ...) end, ...)
    return ok and r or nil
end

local function safe_get(obj, field)
    if not obj then return nil end
    local ok, v = pcall(function() return obj:get_field(field) end)
    return ok and v or nil
end

local function safe_set(obj, field, value)
    if not obj then return false end
    return pcall(function() obj:set_field(field, value) end)
end

--------------------------------------------------------------------------------
-- Player resolution via app.CharacterManager → PlayerContextList
--------------------------------------------------------------------------------

-- Returns the first element of an IEnumerable/IList managed collection, or nil
local function first_element(collection)
    if not collection then return nil end
    local enumerator
    if not pcall(function() enumerator = collection:call("GetEnumerator()") end) then return nil end
    if not enumerator then return nil end
    local moved = false
    if not pcall(function() moved = enumerator:call("MoveNext()") end) or not moved then return nil end
    local item
    pcall(function() item = enumerator:call("get_Current()") end)
    return item
end

-- Walk a chain of field names, returning the final value or nil on any failure
local function field_chain(obj, ...)
    local cur = obj
    for _, f in ipairs({...}) do
        cur = safe_get(cur, f)
        if cur == nil then return nil end
    end
    return cur
end

-- From a PlayerContext, try to resolve the underlying character object
local CONTEXT_TO_CHAR = {
    function(ctx) return safe_get(ctx, "_Character") end,
    function(ctx) return safe_get(ctx, "<Character>k__BackingField") end,
    function(ctx) return safe_call(ctx, "get_Character()") end,
    function(ctx) return safe_call(ctx, "getCharacter()") end,
    function(ctx) return safe_get(ctx, "_Player") end,
    function(ctx) return safe_get(ctx, "<Player>k__BackingField") end,
    function(ctx) return safe_get(ctx, "_Humanoid") end,
    function(ctx) return safe_get(ctx, "<Humanoid>k__BackingField") end,
    -- context itself may be the character
    function(ctx) return ctx end,
}

local function get_player()
    local mgr = sdk.get_managed_singleton("app.CharacterManager")
    if not mgr then return nil end

    local ctx = safe_get(mgr, "<PlayerContextFast>k__BackingField")
             or first_element(safe_get(mgr, "<PlayerContextList>k__BackingField"))
    if not ctx then return nil end

    -- Return the context itself plus its sub-units as additional targets
    -- (apply_speed will probe all of them for speed fields)
    return ctx
end

-- Returns a flat list of objects to probe for speed fields
local function get_speed_targets()
    local mgr = sdk.get_managed_singleton("app.CharacterManager")
    if not mgr then return {} end

    local ctx = safe_get(mgr, "<PlayerContextFast>k__BackingField")
             or first_element(safe_get(mgr, "<PlayerContextList>k__BackingField"))
    if not ctx then return {} end

    local common = safe_get(ctx, "<Common>k__BackingField")
    if not common then return {} end

    local updater = safe_get(common, "_Updater")
    if not updater then return {} end

    local movement_driver = safe_get(updater, "<MovementDriver>k__BackingField")
    if not movement_driver then return nil end

    local cfg_obj = safe_get(movement_driver, "<Config>k__BackingField")
    return cfg_obj and safe_get(cfg_obj, "_PlayerMovementConfig") or nil
end

-- Separate getter used by apply_speed
local function get_movement_driver()
    local mgr = sdk.get_managed_singleton("app.CharacterManager")
    if not mgr then return nil end
    local ctx = safe_get(mgr, "<PlayerContextFast>k__BackingField")
    if not ctx then return nil end
    local common  = safe_get(ctx, "<Common>k__BackingField")
    local updater = common and safe_get(common, "_Updater")
    return updater and safe_get(updater, "<MovementDriver>k__BackingField")
end

--------------------------------------------------------------------------------
-- Speed fields
--------------------------------------------------------------------------------
-- Fields on PlayerMovementConfigurationBase to scale
local SPEED_FIELDS = {
    "_WalkSpeed",
    "_SprintSpeed",
}

local function get_move_controller(player)
    local ctrl = safe_call(player, "getMoveController()")
              or safe_call(player, "get_MoveController()")
              or safe_get(player, "_MoveController")
              or safe_get(player, "MoveController")
    if ctrl then return ctrl end

    -- via Humanoid
    local human = safe_call(player, "getHumanoid()")
               or safe_call(player, "get_Humanoid()")
               or safe_get(player, "_Humanoid")
    if human then
        ctrl = safe_call(human, "getMoveController()")
            or safe_call(human, "get_MoveController()")
            or safe_get(human, "_MoveController")
        if ctrl then return ctrl end
    end

    return nil
end

local function apply_speed()
    local mov_cfg = get_speed_targets()
    if not mov_cfg then return false end

    local patched_any = false
    for _, field in ipairs(SPEED_FIELDS) do
        local val = safe_get(mov_cfg, field)
        if val ~= nil and type(val) == "number" and val > 0 then
            local key = tostring(mov_cfg) .. "|" .. field
            if not base_speeds[key] then
                -- Store original the first time only
                base_speeds[key] = val
                table.insert(patched_objects, { obj = mov_cfg, field = field, key = key })
            end
            -- Always write from the stored base × multiplier (no compounding)
            safe_set(mov_cfg, field, base_speeds[key] * cfg.multiplier)
            patched_any = true
        end
    end
    return patched_any
end

local function restore_speeds()
    for _, entry in ipairs(patched_objects) do
        local base = base_speeds[entry.key]
        if base then safe_set(entry.obj, entry.field, base) end
    end
    base_speeds     = {}
    patched_objects = {}
end

--------------------------------------------------------------------------------
-- Hook candidates
--------------------------------------------------------------------------------
local HOOK_CANDIDATES = {
    { "app.CharacterMoveController",     "update(System.Single)" },
    { "app.HumanoidMoveController",      "update(System.Single)" },
    { "app.PlayerMoveController",        "update(System.Single)" },
    { "app.CharacterController",         "update(System.Single)" },
    { "app.ch.HumanoidMoveController",   "onBeforeUpdate(System.Single)" },
    { "app.CharacterMoveControllerBase", "update(System.Single)" },
    { "app.MoveController",              "update(System.Single)" },
}

local function try_hooks()
    if hooked then return end
    for _, c in ipairs(HOOK_CANDIDATES) do
        local td = sdk.find_type_definition(c[1])
        if td then
            local method = td:get_method(c[2])
            if method then
                sdk.hook(method, function(args)
                    if not cfg.enabled then return end
                    local ok, self_obj = pcall(function()
                        return sdk.to_managed_object(args[2])
                    end)
                    if not ok or not self_obj then return end
                    for _, field in ipairs(SPEED_FIELDS) do
                        local val = safe_get(self_obj, field)
                        if val ~= nil and type(val) == "number" and val > 0 then
                            local key = tostring(self_obj) .. "|" .. field
                            if not base_speeds[key] then
                                base_speeds[key] = val
                            end
                            safe_set(self_obj, field, base_speeds[key] * cfg.multiplier)
                        end
                    end
                end, nil)
                status = string.format("Hooked %s::%s", c[1], c[2])
                log.info("[SpeedModifier] " .. status)
                hooked = true
                return
            end
        end
    end
    --log.info("[SpeedModifier] No hook found – using per-frame patch.")
end

--------------------------------------------------------------------------------
-- Per-frame update
--------------------------------------------------------------------------------
re.on_frame(function()
    if not cfg.enabled then return end
    if not hooked then try_hooks() end
    if hooked then return end

    local drv = get_movement_driver()
    if not drv then
        status = "Enabled – movement driver not found yet."
        return
    end

    local ok = apply_speed()
    status = ok
        and string.format("Active (per-frame) – x%.2f", cfg.multiplier)
        or  "Enabled – player found but no speed fields matched. Run Diagnostics."
end)

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

-- Print all fields of a managed object, walking the full type hierarchy
local function dump_fields_deep(obj, indent)
    if not obj then return end
    local td = obj:get_type_definition()
    while td do
        local ok, fields = pcall(function() return td:get_fields() end)
        if ok and fields then
            for i = 1, #fields do
                local fn = fields[i]:get_name()
                local val = safe_get(obj, fn)
                local val_str = tostring(val)
                if #val_str > 80 then val_str = val_str:sub(1, 80) .. "…" end
                print(indent .. fn .. " = " .. val_str)
            end
        end
        local ok2, parent = pcall(function() return td:get_parent_type() end)
        td = (ok2 and parent) or nil
    end
end

-- Try to enumerate via.Component list on a game object
local function dump_gameobject_components(obj, indent)
    if not obj then return end
    -- obj might be a component itself — try to get its game object
    local go = safe_call(obj, "get_GameObject()")
            or safe_call(obj, "getGameObject()")
    if not go then return end
    print(indent .. "[GameObject components]")
    local transform = safe_call(go, "get_Transform()")
    if not transform then return end
    local child = safe_call(transform, "get_Child()")
    -- Enumerate components via the component list
    local comp_list = safe_call(go, "get_Components()")
    if not comp_list then return end
    local ok, enum = pcall(function() return comp_list:call("GetEnumerator()") end)
    if not ok or not enum then return end
    while true do
        local moved = false
        if not pcall(function() moved = enum:call("MoveNext()") end) or not moved then break end
        local comp = nil
        pcall(function() comp = enum:call("get_Current()") end)
        if comp then
            local td = comp:get_type_definition()
            local tname = td and td:get_name() or "?"
            print(indent .. "  component: " .. tname)
            -- Dump fields of components with promising type names
            local tn = tname:lower()
            if tn:find("move") or tn:find("speed") or tn:find("locomot") or tn:find("motion") or tn:find("human") then
                dump_fields_deep(comp, indent .. "    ")
            end
        end
    end
end

-- Simple shallow field dump (kept for non-deep uses)
local function dump_fields(obj, indent)
    dump_fields_deep(obj, indent)
end

local function run_diagnostics()
    local function add(s)
        print(s)
        log.info("  " .. s)
    end

    print("[SpeedModifier] === DIAGNOSTICS START ===")
    log.info("[SpeedModifier] === DIAGNOSTICS START ===")

    -- ── CharacterManager ────────────────────────────────────────────────────
    add("=== app.CharacterManager ===")
    local mgr = sdk.get_managed_singleton("app.CharacterManager")
    if not mgr then
        add("  NOT FOUND")
    else
        add("  FOUND")

        -- PlayerContextFast (this is the valid context)
        add("  >> PlayerContextFast:")
        local fast = safe_get(mgr, "<PlayerContextFast>k__BackingField")
        if not fast then
            add("    nil")
        else
            add("    type: " .. tostring(fast:get_type_definition() and fast:get_type_definition():get_name()))

            -- Dig into each sub-unit
            local SUB_FIELDS = {
                "<Common>k__BackingField",
                "<TPSUnit>k__BackingField",
                "<FPSUnit>k__BackingField",
                "<Cp_A1Unit>k__BackingField",
            }
            for _, sub_field in ipairs(SUB_FIELDS) do
                local sub = safe_get(fast, sub_field)
                if sub then
                    local sub_tname = sub:get_type_definition() and sub:get_type_definition():get_name() or "?"
                    add("    >> " .. sub_field .. "  (type: " .. sub_tname .. ")")
                    dump_fields_deep(sub, "        ")
                    dump_gameobject_components(sub, "        ")
                end
            end

            -- Dig into Updater sub-objects for movement/speed data
            local common = safe_get(fast, "<Common>k__BackingField")
            local updater = common and safe_get(common, "_Updater")
            if updater then
                add("  >> _Updater sub-objects:")
                local UPDATER_SUB = {
                    "<MovementDriver>k__BackingField",
                    "<MotionSpeedController>k__BackingField",
                    "<MovementUnitControl>k__BackingField",
                    "<MoveBlackboardCore>k__BackingField",
                }
                for _, sf in ipairs(UPDATER_SUB) do
                    local sub = safe_get(updater, sf)
                    if sub then
                        local tname = sub:get_type_definition() and sub:get_type_definition():get_name() or "?"
                        add("    >> " .. sf .. "  (type: " .. tname .. ")")
                        dump_fields_deep(sub, "        ")

                        -- One more level into Config, MoveBlackboardUnit, DampingMoveSpeed
                        for _, sf2 in ipairs({ "<Config>k__BackingField", "<MoveBlackboardUnit>k__BackingField", "<DampingMoveSpeed>k__BackingField" }) do
                            local sub2 = safe_get(sub, sf2)
                            if sub2 then
                                local tname2 = sub2:get_type_definition() and sub2:get_type_definition():get_name() or "?"
                                add("        >> " .. sf2 .. "  (type: " .. tname2 .. ")")
                                dump_fields_deep(sub2, "            ")
                                -- For Config: also dump _PlayerMovementConfig
                                if sf2 == "<Config>k__BackingField" then
                                    local mov_cfg = safe_get(sub2, "_PlayerMovementConfig")
                                    if mov_cfg then
                                        local mcn = mov_cfg:get_type_definition() and mov_cfg:get_type_definition():get_name() or "?"
                                        add("            >> _PlayerMovementConfig  (type: " .. mcn .. ")")
                                        dump_fields_deep(mov_cfg, "                ")
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end  -- if fast
    end  -- if mgr

    -- ── Hook types ──────────────────────────────────────────────────────────
    add("=== Hook type search ===")
    for _, c in ipairs(HOOK_CANDIDATES) do
        local td = sdk.find_type_definition(c[1])
        add(string.format("  %s  %s", td and "FOUND" or "miss:", c[1]))
    end

    print("[SpeedModifier] === DIAGNOSTICS END ===")
    log.info("[SpeedModifier] === DIAGNOSTICS END ===")
    print("")
    print("")
    print("")
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("Speed Modifier") then return end

    imgui.text("Status: " .. status)
    imgui.spacing()

    local changed, new_enabled = imgui.checkbox("Enable speed modifier", cfg.enabled)
    if changed then
        cfg.enabled = new_enabled
        if not cfg.enabled then
            restore_speeds()
            status = "Disabled – speeds restored."
        else
            hooked = false
            status = "Enabled – searching…"
        end
    end

    local sc, new_mult = imgui.slider_float("Speed multiplier", cfg.multiplier, 0.1, 10.0, "%.2fx")
    if sc then
        cfg.multiplier = new_mult
        if not cfg.enabled then
            base_speeds     = {}
            patched_objects = {}
        end
    end

    imgui.spacing()
    imgui.separator()
    imgui.text_colored(Vector4f.new(0.6, 0.6, 0.6, 1.0), "1.0 = normal  |  2.0 = double  |  0.5 = half")

    imgui.spacing()
    if imgui.button("Run Diagnostics") then run_diagnostics() end

    imgui.tree_pop()
end)

log.info("[SpeedModifier] Loaded. Open REFramework menu → Speed Modifier.")
