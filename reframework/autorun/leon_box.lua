-- leon_box.lua
-- Injects AP-received items into the item box shop as purchasable entries.
-- Items appear in the shop UI, can be selected and "purchased" (for free),
-- and are granted to Leon's inventory via mergeOrAdd on buy failure.

local PREFIX = "[leon_box] "

local function log(...)
    local t = {}
    for _, v in ipairs({...}) do t[#t+1] = tostring(v) end
    print(PREFIX .. table.concat(t, " "))
end

local function try(fn)
    local ok, v = pcall(fn)
    return (ok and v ~= nil) and v or nil
end

local function find_method(td, name)
    for _, m in ipairs(try(function() return td:get_methods() end) or {}) do
        if try(function() return m:get_name() end) == name then return m end
    end
end

-- ============================================================
-- Type definitions
-- ============================================================
local shop_td      = sdk.find_type_definition("app.ShopManager")
local detail_td    = sdk.find_type_definition("app.ShopItemDetailData")
local stockdata_td = sdk.find_type_definition("app.ItemStockData")
local itemid_td    = sdk.find_type_definition("app.ItemID")
local sysarr_td    = sdk.find_type_definition("System.Array")
local shopid_td    = sdk.find_type_definition("app.ShopID")
local lineupkey_td = sdk.find_type_definition("app.ShopManager.ShopLineupKey")
local guid_td      = sdk.find_type_definition("System.Guid")
local shopinfo_td  = sdk.find_type_definition("app.ShopManager.ShopItemInfo")
local shopctx_td   = sdk.find_type_definition("app.ShopItemContext")

-- Cache System.Array.CreateInstance(Type, int) and Copy(Array, Array, int) at startup
local sysarr_create_m = nil
local sysarr_copy_m   = nil
if sysarr_td then
    for _, m in ipairs(try(function() return sysarr_td:get_methods() end) or {}) do
        local n = try(function() return m:get_name() end)
        if n == "CreateInstance" and not sysarr_create_m then
            if #(try(function() return m:get_param_names() end) or {}) == 2 then
                sysarr_create_m = m
            end
        elseif n == "Copy" and not sysarr_copy_m then
            if #(try(function() return m:get_param_names() end) or {}) == 3 then
                sysarr_copy_m = m
            end
        end
        if sysarr_create_m and sysarr_copy_m then break end
    end
end

-- ============================================================
-- Purge any injected entries left in ShopManager from a previous
-- script load (entries with _RawKey >= 9001 in _ShopItemTable
-- and their corresponding _ItemContextDB records).
-- ============================================================
-- Purge stale injected entries by zeroing their hashCode directly in the
-- Dictionary._entries array. Dictionary.Remove fails for value-type Guid keys
-- through the Lua wrapper, so we manipulate the internals instead.
local function purge_stale_entries()
    -- No-op: stale entries are filtered in getShopLineup hook via do_inject.
    -- Dictionary struct manipulation crashes; filter approach is safer.
end
-- (called on box open, not at startup — ShopManager may not exist yet at load time)

-- ============================================================
-- State
-- ============================================================
local box_open          = false
local inject_queue      = {}   -- item_id -> { stock, amount, price }
local inject_done       = {}   -- item_id -> true (injected this session)
local inject_cache      = {}   -- item_id -> ShopItemDetailData object
local injected_contexts = {}   -- _RawKey -> { ctx=ShopItemContext, inj=inj }
local inject_key_counter = 9000

-- ============================================================
-- Build a ShopItemDetailData for one queued item
-- ============================================================
local function build_item(inj_id, inj)
    local item = try(function() return detail_td:create_instance(true) end)
    if not item then return nil end

    -- ItemID
    local id_val = try(function() return itemid_td:get_field(inj_id):get_data(nil) end)
    if id_val then try(function() item:set_field("<ItemID>k__BackingField", id_val) end) end

    -- Stock fields
    try(function() item:set_field("<Stock>k__BackingField",         inj.stock) end)
    try(function() item:set_field("<SupplyCount>k__BackingField",   inj.stock) end)
    try(function() item:set_field("<IsDynamicItem>k__BackingField", true)      end)
    try(function() item:set_field("<FixedBuyPrice>k__BackingField", 0)         end)

    -- AmountData (ItemStockData): _ItemID string + _ItemIDCache app.ItemID + _Stock count
    local ad = try(function() return stockdata_td:create_instance(true) end)
    if ad then
        try(function() ad:set_field("_ItemID", inj_id) end)
        if id_val then try(function() ad:set_field("_ItemIDCache", id_val) end) end
        try(function() ad:set_field("_Stock", inj.amount) end)
        try(function() item:set_field("<AmountData>k__BackingField", ad) end)
    end

    -- ShopID = Common
    local shop_id_val = shopid_td and try(function()
        return shopid_td:get_field("Common"):get_data(nil)
    end)
    if shop_id_val then
        try(function() item:set_field("<ShopID>k__BackingField", shop_id_val) end)
    end

    -- Unique ShopLineupKey._RawKey (>= 9001 identifies our injected items)
    if lineupkey_td then
        local key_obj = try(function() return lineupkey_td:create_instance(true) end)
        if key_obj then
            inject_key_counter = inject_key_counter + 1
            try(function() key_obj:set_field("_RawKey", inject_key_counter) end)
            try(function() item:set_field("<Key>k__BackingField", key_obj) end)
        end
    end

    return item
end

-- ============================================================
-- Register an injected item in ShopManager's internal tables
-- Required for the purchase panel to display and for buy() to fire
-- ============================================================
local function register_in_internal_tables(detail_item, inj)
    local sm = sdk.get_managed_singleton("app.ShopManager")
    if not sm then log("register: no ShopManager") return end

    local newguid_m = guid_td and find_method(guid_td, "NewGuid")
    local new_guid  = newguid_m and try(function() return newguid_m:call(nil) end)
    if not new_guid then log("register: NewGuid failed") return end

    -- Borrow ForSaleItemGroup + PremiseItems from first dynamic entry
    local for_sale_group, premise_items = nil, nil
    local dyn_tbl = try(function() return sm:get_field("_DynamicShopItemTable") end)
    if dyn_tbl then
        local ents = try(function() return dyn_tbl:get_field("_entries") end)
        if ents then
            for i = 0, (try(function() return ents:get_Length() end) or 0) - 1 do
                local e  = try(function() return ents:call("GetValue", i) end)
                local hc = e and try(function() return e:get_field("hashCode") end) or -1
                if type(hc) == "number" and hc >= 0 then
                    local v = try(function() return e:get_field("value") end)
                    if v then
                        for_sale_group = try(function() return v:get_field("<ForSaleItemGroup>k__BackingField") end)
                        premise_items  = try(function() return v:get_field("<PremiseItems>k__BackingField") end)
                    end
                    break
                end
            end
        end
    end

    local key_obj  = try(function() return detail_item:get_field("<Key>k__BackingField") end)
    local ad       = try(function() return detail_item:get_field("<AmountData>k__BackingField") end)
    local shopid_v = shopid_td and try(function() return shopid_td:get_field("Common"):get_data(nil) end)

    -- ShopItemInfo (internal per-item record keyed by Guid in _ShopItemTable)
    local info = shopinfo_td and try(function() return shopinfo_td:create_instance(true) end)
    if not info then log("register: ShopItemInfo create failed") return end
    if key_obj        then try(function() info:set_field("<Key>k__BackingField",              key_obj)        end) end
    if new_guid       then try(function() info:set_field("<ContextID>k__BackingField",        new_guid)       end) end
    if shopid_v       then try(function() info:set_field("<ShopID>k__BackingField",           shopid_v)       end) end
    if ad             then try(function() info:set_field("<AmountData>k__BackingField",        ad)             end) end
    if for_sale_group then try(function() info:set_field("<ForSaleItemGroup>k__BackingField", for_sale_group) end) end
    if premise_items  then try(function() info:set_field("<PremiseItems>k__BackingField",     premise_items)  end) end
    try(function() info:set_field("<SupplyCount_Casual>k__BackingField",   inj.stock) end)
    try(function() info:set_field("<SupplyCount_Modern>k__BackingField",   inj.stock) end)
    try(function() info:set_field("<SupplyCount_Classic>k__BackingField",  inj.stock) end)
    try(function() info:set_field("<SupplyCount_Insanity>k__BackingField", inj.stock) end)
    try(function() info:set_field("<UniqueItem>k__BackingField",           false)     end)
    try(function() info:set_field("<DynamicItemPurpose>k__BackingField",   0)         end)

    local shop_tbl = try(function() return sm:get_field("_ShopItemTable") end)
    if shop_tbl then pcall(function() shop_tbl:call("Add", new_guid, info) end) end

    -- ShopItemContext (purchase availability record keyed by same Guid in _ItemContextDB)
    local ctx = shopctx_td and try(function() return shopctx_td:create_instance(true) end)
    if ctx then
        try(function() ctx:set_field("<IsValid>k__BackingField",          true)      end)
        if shopid_v then try(function() ctx:set_field("<ShopID>k__BackingField",    shopid_v) end) end
        if new_guid then try(function() ctx:set_field("<ContextID>k__BackingField", new_guid) end) end
        if ad       then try(function() ctx:set_field("<AmountData>k__BackingField",ad)       end) end
        try(function() ctx:set_field("<SupplyCount>k__BackingField",       inj.stock) end)
        try(function() ctx:set_field("<PurchaseCount>k__BackingField",     1)         end)
        try(function() ctx:set_field("<DynamicItemPurpose>k__BackingField",0)         end)
        try(function() ctx:set_field("<FixedBuyPrice>k__BackingField",     0)         end)

        local ctx_db = try(function() return sm:get_field("_ItemContextDB") end)
        if ctx_db then pcall(function() ctx_db:call("Add", new_guid, ctx) end) end

        local rk = key_obj and try(function() return key_obj:get_field("_RawKey") end)
        if type(rk) == "number" then
            injected_contexts[rk] = { ctx = ctx, inj = inj }
        end
    end

    -- Link detail data back so the purchase screen can render the item
    pcall(function() detail_item:set_field("_DetailData", info) end)

    -- Prime the context immediately
    local rim = shop_td and find_method(shop_td, "readyItemContextImpl")
    if rim then pcall(function() rim:call(sm, info) end) end
end

-- ============================================================
-- Grow a fixed C# array by one element
-- ============================================================
local function array_append(old_arr, new_item)
    local n = try(function() return old_arr:get_Length() end) or 0

    local new_arr = nil
    if sysarr_create_m then
        local rt = try(function() return detail_td:get_runtime_type() end)
        if rt then new_arr = try(function() return sysarr_create_m:call(nil, rt, n + 1) end) end
    end
    if not new_arr then
        new_arr = try(function() return sdk.create_managed_array(detail_td, n + 1) end)
    end
    if not new_arr then return nil end

    local copied = sysarr_copy_m and pcall(function() sysarr_copy_m:call(nil, old_arr, new_arr, n) end)
    if not copied then
        for i = 0, n - 1 do
            local it = try(function() return old_arr:call("GetValue", i) end)
            if it then try(function() new_arr:call("SetValue", it, i) end) end
        end
    end

    local ok = pcall(function() new_arr:call("SetValue", new_item, n) end)
    return ok and new_arr or nil
end

-- ============================================================
-- Filter + inject: strips stale injected entries (RawKey >= 9001
-- that aren't in the current inject_queue or have stock=0) then
-- appends fresh queued items.
-- ============================================================
local function do_inject(arr)
    if not arr then return arr end
    local n = try(function() return arr:get_Length() end) or 0

    -- Step 1: rebuild array, keeping only native items + still-valid injected items
    local keep   = {}   -- entries to keep
    local existing = {} -- item IDs already present after filter
    local needs_rebuild = false

    for i = 0, n - 1 do
        local entry = try(function() return arr:call("GetValue", i) end)
        if entry then
            local rk = try(function()
                return entry:get_field("<Key>k__BackingField"):get_field("_RawKey")
            end) or 0
            local id = try(function()
                return tostring(entry:get_field("<ItemID>k__BackingField"):call("ToString()"))
            end)

            -- Identify our injected items by AmountData type (app.ItemStockData).
            -- Real shop items use app.VariousItemData. RawKey >= 9001 also works
            -- for items we injected this session, but stale entries read rk=nil.
            local ad_type = try(function()
                return entry:get_field("<AmountData>k__BackingField"):get_type_definition():get_full_name()
            end)
            local is_ours = (ad_type == "app.ItemStockData")
            local keep_it = true

            if is_ours then
                -- Keep only if queued with stock > 0
                local inj = id and inject_queue[id]
                if not inj or inj.stock <= 0 then
                    keep_it = false
                    needs_rebuild = true
                end
            end

            if keep_it then
                keep[#keep+1] = entry
                if id then existing[id] = true end
            end
        end
    end

    -- Rebuild the array if we dropped anything
    if needs_rebuild then
        local rt  = try(function() return detail_td:get_runtime_type() end)
        local new_arr = (rt and sysarr_create_m)
            and try(function() return sysarr_create_m:call(nil, rt, #keep) end)
            or  try(function() return sdk.create_managed_array(detail_td, #keep) end)
        if new_arr then
            for i, entry in ipairs(keep) do
                pcall(function() new_arr:call("SetValue", entry, i - 1) end)
            end
            arr = new_arr
        end
    end

    -- Step 2: append queued items not already present
    if not next(inject_queue) then return arr end

    for inj_id, inj in pairs(inject_queue) do
        if not existing[inj_id] and inj.stock > 0 then
            local item = inject_cache[inj_id]
            if not item then
                item = build_item(inj_id, inj)
                inject_cache[inj_id] = item
            end
            if item then
                local new_arr = array_append(arr, item)
                if new_arr then
                    arr = new_arr
                    if not inject_done[inj_id] then
                        inject_done[inj_id] = true
                        log("Injected: " .. inj_id .. " x" .. inj.amount)
                        register_in_internal_tables(item, inj)
                    end
                else
                    log("Inject FAILED: " .. inj_id)
                end
            end
        end
    end
    return arr
end

-- ============================================================
-- UI — queue items for injection (placeholder for AP client wiring)
-- ============================================================
re.on_draw_ui(function()
    if imgui.button("Inject it60_00_104 x1") then
        inject_queue["it60_00_104"] = { stock = 1, amount = 1, price = 0 }
        log("Queued: it60_00_104 x1")
    end
end)

-- ============================================================
-- getShopLineup hook — inject our items into the returned array
-- ============================================================
local current_tab   = nil
local lineup_method = shop_td and find_method(shop_td, "getShopLineup")
if lineup_method then
    sdk.hook(lineup_method,
        function(args)
            local a3  = try(function() return sdk.to_managed_object(args[3]) end)
            current_tab = a3 and try(function() return a3:call("ToString()") end)
        end,
        function(retval)
            if current_tab ~= "Common" then return retval end
            local arr = try(function() return sdk.to_managed_object(retval) end)
            if not arr then return retval end
            local new_arr = do_inject(arr)
            if new_arr ~= arr then return sdk.to_ptr(new_arr) end
            -- Even if array object is same, contents may have changed (stale filtered in-place)
            return sdk.to_ptr(arr)
        end)
    log("Hooked ShopManager.getShopLineup")
end

-- ============================================================
-- readyShopContext hook — detect box open
-- ============================================================
local ctx_method = shop_td and find_method(shop_td, "readyShopContext")
if ctx_method then
    sdk.hook(ctx_method,
        function(args)
            if not box_open then
                box_open = true
                purge_stale_entries()
                log("BOX OPENED")
            end
        end, nil)
    log("Hooked ShopManager.readyShopContext")
end

-- ============================================================
-- releaseGimmick hook — detect box close, reset per-session state
-- ============================================================
local gm_td     = sdk.find_type_definition("app.GimmickManager")
local release_m = gm_td and find_method(gm_td, "releaseGimmick")
if release_m then
    sdk.hook(release_m,
        function(args)
            if box_open then
                box_open    = false
                inject_done = {}
                inject_cache = {}
                log("BOX CLOSED")
            end
        end, nil)
    log("Hooked GimmickManager.releaseGimmick")
end

-- ============================================================
-- readyItemContextImpl hook — re-force our injected item contexts
-- valid every frame (game resets them on each update tick)
-- ============================================================
local ctx_impl_method = shop_td and find_method(shop_td, "readyItemContextImpl")
if ctx_impl_method then
    local rim_ours_rawkey = nil
    sdk.hook(ctx_impl_method,
        function(args)
            rim_ours_rawkey = nil
            local info = try(function() return sdk.to_managed_object(args[3]) end)
            if not info then return end
            local key = try(function() return info:get_field("<Key>k__BackingField") end)
            local rk  = key and try(function() return key:get_field("_RawKey") end)
            if type(rk) == "number" and rk >= 9001 and injected_contexts[rk] then
                rim_ours_rawkey = rk
            end
        end,
        function(retval)
            local rk = rim_ours_rawkey
            rim_ours_rawkey = nil
            if not rk then return retval end
            local entry = injected_contexts[rk]
            if entry then
                local ctx  = entry.ctx
                local inj  = entry.inj
                local avail = inj.stock > 0
                try(function() ctx:set_field("<IsValid>k__BackingField",      avail)     end)
                try(function() ctx:set_field("<SupplyCount>k__BackingField",   inj.stock) end)
                try(function() ctx:set_field("<PurchaseCount>k__BackingField", avail and 1 or 0) end)
            end
            return retval
        end)
    log("Hooked ShopManager.readyItemContextImpl")
end

-- ============================================================
-- buy hook — grant item to inventory when buy() returns 0
--
-- buy() returns 0 for our injected items because they have no
-- valid shop catalog entry. The inventory object in args[3] is
-- confirmed to be Leon's correct inventory (same address as the
-- mergeOrAddImpl `this` pointer during a real purchase).
-- ============================================================
local buy_method = shop_td and find_method(shop_td, "buy")
if buy_method then
    local buy_inv_ref    = nil
    local buy_detail_ref = nil
    local buy_item_id    = nil

    sdk.hook(buy_method,
        function(args)
            buy_inv_ref    = try(function() return sdk.to_managed_object(args[3]) end)
            buy_detail_ref = try(function() return sdk.to_managed_object(args[4]) end)
            buy_item_id    = buy_detail_ref and try(function()
                return tostring(buy_detail_ref:get_field("<ItemID>k__BackingField"):call("ToString()"))
            end)
        end,
        function(retval)
            local v = try(function() return sdk.to_int64(retval) end)
            local inj_entry = inject_queue[buy_item_id]
            if buy_item_id and inj_entry and inj_entry.stock > 0 then
                -- buy() may succeed (non-zero) or fail (0) for injected items.
                -- Either way: grant if needed, then decrement stock.
                if v == 0 and buy_inv_ref then
                    -- buy failed — grant manually
                    local ad = buy_detail_ref and try(function()
                        return buy_detail_ref:get_field("<AmountData>k__BackingField")
                    end)
                    if ad then
                        local ok, err = pcall(function()
                            return buy_inv_ref:call(
                                "mergeOrAdd(app.ItemAmountData, System.Boolean, app.Inventory.AcquireItemOptions, app.ItemStockChangedEventType)",
                                ad, true, 0, 0)
                        end)
                        if not ok then log("Grant FAILED: " .. tostring(err)) end
                    end
                end

                -- Decrement stock regardless of buy() return value
                local new_stock = math.max(0, inj_entry.stock - 1)
                inj_entry.stock = new_stock
                local cached = inject_cache[buy_item_id]
                if cached then
                    try(function() cached:set_field("<Stock>k__BackingField",       new_stock) end)
                    try(function() cached:set_field("<SupplyCount>k__BackingField", new_stock) end)
                end
                log("Granted: " .. tostring(buy_item_id) .. " stock=" .. new_stock)
            end
            buy_inv_ref    = nil
            buy_detail_ref = nil
            buy_item_id    = nil
            return retval
        end)
    log("Hooked ShopManager.buy")
end

log("Ready.")
