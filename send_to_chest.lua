-- RE9 ItemAmountData probe
-- 1) Inspect app.ItemAmountData type
-- 2) Inspect box:getNotificationItems()

local BOX_INDEX = 2

local function sfield(obj, name)
    local ok, v = pcall(function() return obj:get_field(name) end)
    if ok then return v end
    return nil
end

local function scall0(obj, method)
    local ok, v = pcall(function() return obj:call(method) end)
    if ok then return v end
    return nil
end

local function tdef(obj)
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if ok then return td end
    return nil
end

local function tname(obj)
    if not obj then return "nil" end
    local td = tdef(obj)
    if not td then return tostring(obj) end
    local ok, n = pcall(function() return td:get_full_name() end)
    if ok and n then return n end
    return tostring(obj)
end

local function get_box_inventory()
    local invmgr = sdk.get_managed_singleton("app.InventoryManager")
    if not invmgr then return nil end

    local invs = sfield(invmgr, "_Inventories")
    if not invs then return nil end

    local entries = sfield(invs, "_entries")
    if not entries then return nil end

    local len = scall0(entries, "get_Length()")
    if type(len) ~= "number" then return nil end
    if BOX_INDEX < 0 or BOX_INDEX >= len then return nil end

    local entry = entries:get_element(BOX_INDEX)
    if not entry then return nil end

    return sfield(entry, "value")
end

local function dump_type_definition(td, title)
    if not td then
        print(title .. ": <nil type definition>")
        return
    end

    local ok_name, full_name = pcall(function() return td:get_full_name() end)
    print("==================================================")
    print(title .. ": " .. tostring(ok_name and full_name or "<unknown>"))

    local ok_fields, fields = pcall(function() return td:get_fields() end)
    if ok_fields and fields then
        print("-- FIELDS --")
        for _, f in ipairs(fields) do
            local ok_fn, fname = pcall(function() return f:get_name() end)
            if ok_fn and fname then
                print("field:", fname)
            end
        end
    end

    local ok_methods, methods = pcall(function() return td:get_methods() end)
    if ok_methods and methods then
        print("-- METHODS --")
        for _, m in ipairs(methods) do
            local ok_mn, mname = pcall(function() return m:get_name() end)
            if ok_mn and mname then
                local lname = string.lower(mname)
                if lname:find("ctor", 1, true)
                or lname:find("create", 1, true)
                or lname:find("new", 1, true)
                or lname:find("item", 1, true)
                or lname:find("amount", 1, true)
                or lname:find("stock", 1, true)
                or lname:find("from", 1, true)
                or lname:find("set", 1, true)
                or lname:find("get", 1, true) then
                    local param_info = "params=?"
                    local ok_params, params = pcall(function() return m:get_parameters() end)
                    if ok_params and params then
                        local ok_count, count = pcall(function() return #params end)
                        if ok_count then
                            param_info = "params=" .. tostring(count)
                        end
                    end

                    print(string.format("%s  %s", mname, param_info))
                end
            end
        end
    end
end

local function dump_array(arr, label)
    if not arr then
        print(label .. " = nil")
        return
    end

    local len = scall0(arr, "get_Length()")
    print(string.format("%s len=%s type=%s", label, tostring(len), tname(arr)))

    if type(len) ~= "number" then
        return
    end

    for i = 0, len - 1 do
        local elem = arr:get_element(i)
        print(string.format("%s[%d] = %s type=%s", label, i, tostring(elem), tname(elem)))

        if elem then
            local td = tdef(elem)
            if td then
                local fields = td:get_fields()
                if fields then
                    for _, f in ipairs(fields) do
                        local fname = f:get_name()
                        local val = sfield(elem, fname)
                        print(string.format("    %s = %s (type=%s)", fname, tostring(val), tname(val)))
                    end
                end
            end
        end
    end
end

local function probe_item_amount_data()
    local td = sdk.find_type_definition("app.ItemAmountData")
    dump_type_definition(td, "app.ItemAmountData")

    local arr_td = sdk.find_type_definition("app.ItemAmountData[]")
    dump_type_definition(arr_td, "app.ItemAmountData[]")
end

local function probe_box_notifications()
    local box = get_box_inventory()
    if not box then
        print("box inventory not found")
        return
    end

    print("==================================================")
    print("BOX getNotificationItems() probe")

    local notif = scall0(box, "getNotificationItems")
    print("getNotificationItems ->", tostring(notif), "type=" .. tname(notif))
    dump_array(notif, "NotificationItems")
end

re.on_draw_ui(function()
    if imgui.button("Probe ItemAmountData Type") then
        probe_item_amount_data()
    end

    if imgui.button("Probe Box NotificationItems") then
        probe_box_notifications()
    end
end)
