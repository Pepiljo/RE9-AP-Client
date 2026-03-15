# RE9-AP-Client

Archipelago client research and REFramework Lua tooling for **Resident Evil Requiem (RE9)**.

## Current focus

This repository currently targets the inventory injection pipeline needed for Archipelago-style item delivery.

## Included scripts

- `scripts/re9_inventory_probe.lua`
  - Enumerates internal inventories via `_Inventories._entries`
  - Dumps per-inventory counts
  - Finds chest candidate using `_NextKey` heuristic
  - Can hook likely merge/add methods for call-hit discovery

- `scripts/re9_item_injector.lua`
  - Builds on probe data
  - Chooses chest inventory candidate
  - Tries manager-first insertion signatures and inventory-level fallback
  - Supports `dry_run` mode for safe probing

## Docs

- `docs/reverse-engineering-next-steps.md` for the recommended live reverse-engineering workflow.
