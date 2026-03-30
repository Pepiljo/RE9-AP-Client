-- AP_client.lua
-- Main Archipelago client for Resident Evil Requiem (BIOHAZARD requiem)
-- Wires together: AP_REF/core.lua, randomizer/send_to_box.lua, randomizer/force_item.lua

local AP_REF        = require("AP_REF/core")
local ItemInjection = require("randomizer/send_to_box")

-- ============================================================
-- Game configuration
-- ============================================================
AP_REF.APGameName = "Resident Evil Requiem"

-- ============================================================
-- Item receive tracking (persisted across reconnects)
-- AP sends all items from index 0 on every reconnect,
-- so we track how many we have already processed.
-- ============================================================
local SAVE_FILE            = "AP_client_save.json"
local items_received_count = 0

local function save_state()
    json.dump_file(SAVE_FILE, { items_received_count = items_received_count }, 4)
end

local function load_state()
    local data = json.load_file(SAVE_FILE)
    if data and data.items_received_count then
        items_received_count = data.items_received_count
        print("[AP_client] Restored item index: " .. items_received_count)
    end
end

-- ============================================================
-- AP Callbacks
-- ============================================================
AP_REF.on_slot_connected = function(slot_data)
    print("[AP_client] Slot connected")
    load_state()
end

AP_REF.on_socket_connected = function()
    print("[AP_client] Socket connected")
end

AP_REF.on_socket_disconnected = function()
    print("[AP_client] Disconnected")
end

AP_REF.on_socket_error = function(msg)
    print("[AP_client] Socket error: " .. tostring(msg))
end

AP_REF.on_items_received = function(items)
    for _, item in ipairs(items) do
        -- AP resends all items from index 0 on reconnect; skip already-processed ones
        local idx = item.index
        if idx >= items_received_count then
            -- Resolve numeric AP item ID to the item name string
            local item_name
            if AP_REF.APClient then
                item_name = AP_REF.APClient:get_item_name(item.item, AP_REF.APGameName)
            end
            item_name = item_name or tostring(item.item)

            print(string.format("[AP_client] Received item #%d: %s", idx, item_name))

            local ok = ItemInjection.inject(item_name, 1)
            if not ok then
                print("[AP_client] WARNING: inject failed for: " .. item_name)
            end

            items_received_count = idx + 1
            save_state()
        end
    end
end

-- ============================================================
-- force_item hook
-- Intercepts in-world item pickups and replaces them with
-- the configured TARGET_ITEM in force_item.lua.
-- Edit TARGET_ITEM in randomizer/force_item.lua to control
-- which item is forced.
-- ============================================================
-- dofile("reframework/autorun/randomizer/force_item.lua")
dofile("reframework/autorun/randomizer/pickup.lua")

print("[AP_client] Loaded. Open the 'Archipelago Client for REFramework' window to connect.")
