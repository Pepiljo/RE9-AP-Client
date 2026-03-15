# RE9 Inventory Reverse-Engineering: Next Steps

This repo now contains two REFramework Lua helpers:

- `scripts/re9_inventory_probe.lua`
- `scripts/re9_item_injector.lua`

## What they do

### 1) `re9_inventory_probe.lua`

- Enumerates `app.InventoryManager._Inventories` through `_entries`.
- Dumps each inventory with `_NextKey`, `_ArchiveItems`, `_PanelItems`, and `_NotificationItems` counts.
- Identifies the **item box candidate** as the inventory with the highest `_NextKey`.
- Optionally hooks likely insertion methods for hit counting during live pickup events.

### 2) `re9_item_injector.lua`

- Imports probe logic.
- Locates chest inventory via probe heuristics.
- Attempts insertion through manager-first method names (then inventory-level fallback).
- Supports `dry_run` mode to avoid altering save state while verifying call paths.

## Recommended live workflow

1. Load both scripts in REFramework.
2. Open inventory UI in-game and click **Dump inventories**.
3. Click **Find chest candidate** and verify index remains stable.
4. Enable trace in probe and click **Install hooks**.
5. Pick up one known item and observe hit counters.
6. Update `re9_item_injector.lua` method signatures to match exactly what fired.
7. Disable `dry_run` and run controlled test injections.

## Key decision rule

Treat method signatures that fire during real pickups as source of truth.
If direct `Inventory.addItem` succeeds but state does not change, keep manager-level insertion as canonical path.
