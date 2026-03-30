local ZERO_GUID = "00000000-0000-0000-0000-000000000000"

local function try(fn)
    local ok, v = pcall(fn)
    return (ok and v ~= nil) and v or nil
end

local function get_scene_name()
    local stm = sdk.get_managed_singleton("app.SceneTransitionManager")
    if not stm then return "unknown" end
    local cs = try(function() return stm:get_field("<CurrentMainGameSceneName>k__BackingField") end)
           or  try(function() return stm:get_field("_CurrentMainGameSceneName_k__BackingField") end)
    local s = cs and tostring(cs) or ""
    return (s ~= "" and s ~= "nil") and s or "unknown"
end

local function get_stage_name()
    local esm = sdk.get_managed_singleton("app.EnvStageManager")
    if not esm then return "unknown" end
    local cs = try(function() return esm:get_field("_CurrentStageName") end)
    local s = cs and tostring(cs) or ""
    if s ~= "" and s ~= "nil" then return s end
    local active = try(function() return esm:get_field("_CurrentActiveStage") end)
    if active then
        local enumerator = try(function() return active:call("GetEnumerator()") end)
        if enumerator then
            local moved = try(function() return enumerator:call("MoveNext()") end)
            if moved then
                local item = try(function() return enumerator:call("get_Current()") end)
                local as = item and tostring(item) or ""
                if as ~= "" and as ~= "nil" then return as end
            end
        end
    end
    return "unknown"
end

local function capture_item(comp)
    local static_id = try(function()
        local g = comp:get_field("_StaticInstanceID")
        return g and tostring(g:call("ToString()")) or nil
    end) or ZERO_GUID

    local item_id = try(function()
        return tostring(comp:call("get_ItemID()"):call("ToString()"))
    end) or "unknown"

    local amount = try(function() return comp:get_field("_ItemAmount") end) or 1

    local go_name     = "unknown"
    local folder_path = "unknown"
    local x, y, z    = 0.0, 0.0, 0.0
    local go = try(function() return comp:call("get_GameObject()") end)
    if go then
        go_name     = try(function() return tostring(go:call("get_Name()")) end) or go_name
        folder_path = try(function() return tostring(go:call("get_Folder()"):call("get_Path()")) end) or folder_path
        local xform = try(function() return go:call("get_Transform()") end)
        if xform then
            local pos = try(function() return xform:call("get_UniversalPosition()") end)
            if pos then
                x = try(function() return pos:get_field("x") end) or 0.0
                y = try(function() return pos:get_field("y") end) or 0.0
                z = try(function() return pos:get_field("z") end) or 0.0
            end
        end
    end

    local key = (static_id ~= ZERO_GUID)   and static_id
             or (folder_path ~= "unknown") and ("fp::" .. folder_path .. "/" .. go_name)
             or ("noid::" .. item_id)

    local parent_name = "unknown"
    local ctx = try(function() return comp:get_field("_Context") end)
    if ctx then
        local parent_obj = try(function() return ctx:call("get_ParentObject()") end)
        if parent_obj then
            parent_name = try(function() return tostring(parent_obj:call("get_Name()")) end) or parent_name
        end
    end
    if parent_name == "unknown" and go then
        parent_name = try(function()
            return tostring(go:call("get_Transform()"):call("get_Parent()"):call("get_GameObject()"):call("get_Name()"))
        end) or parent_name
    end

    return {
        _key        = key,
        item_id     = item_id,
        amount      = amount,
        folder_path = folder_path,
        parent_name = parent_name,
        scene       = get_scene_name(),
        stage       = get_stage_name(),
        x = x, y = y, z = z,
    }
end

local function print_pickup(info)
    print("[pickup] -------------------------")
    print("[pickup] item_id:     " .. info.item_id)
    print("[pickup] amount:      " .. info.amount)
    print("[pickup] parent_name: " .. info.parent_name)
    print("[pickup] scene:       " .. info.scene)
    print("[pickup] stage:       " .. info.stage)
    print("[pickup] pos:         " .. string.format("(%.2f, %.2f, %.2f)", info.x, info.y, info.z))
    print("[pickup] folder_path: " .. info.folder_path)
    print("[pickup] key:         " .. info._key)
end

local item_core_td = sdk.find_type_definition("app.ItemCore")
if not item_core_td then
    print("[pickup] app.ItemCore not found")
    return
end

local pickup_method = nil
local onPickup_method = nil
for _, m in ipairs(item_core_td:get_methods()) do
    local n = try(function() return m:get_name() end)
    if n == "pickup"   then pickup_method   = m end
    if n == "onPickup" then onPickup_method = m end
end

if not pickup_method then
    print("[pickup] pickup method not found")
    return
end

-- Use onPickup for logging (fires with full context) and pickup for interception
sdk.hook(onPickup_method,
    function(args)
        local self = try(function() return sdk.to_managed_object(args[2]) end)
        if not self then return end
        local info = capture_item(self)
        print_pickup(info)
    end,
    function(retval)
        in_pickup = false
        return retval
    end
)

local inv_td = sdk.find_type_definition("app.Inventory")
local mergeOrAdd_method = nil
if inv_td then
    for _, m in ipairs(inv_td:get_methods()) do
        if try(function() return m:get_name() end) == "mergeOrAdd" then
            mergeOrAdd_method = m
            break
        end
    end
end

local in_pickup = false

sdk.hook(pickup_method,
    function(args)
        in_pickup = true
    end,
    nil
)

if mergeOrAdd_method then
    sdk.hook(mergeOrAdd_method,
        function(args)
            if not in_pickup then return end
            local arr = try(function() return sdk.to_managed_object(args[3]) end)
            if not arr then return end
            local count = try(function() return arr:get_Count() end)
            if not count then return end
            for i = 0, count - 1 do
                local entry = try(function() return arr:get_Item(i) end)
                if entry then
                    entry:set_field("_Stock", 0)
                end
            end
        end,
        nil
    )
    print("[pickup] hooked app.Inventory.mergeOrAdd")
else
    print("[pickup] WARNING: mergeOrAdd not found, items will still be added to inventory")
end

print("[pickup] hooked app.ItemCore.onPickup")
