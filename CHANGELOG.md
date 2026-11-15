# Changelog

## 0.1.0 — first build

First release: an armour-linked item-loadout restocker built around the
weapon-swap problem.

- Links a build to an item loadout; identifies the build by armour pieces,
  resolved skill levels, the charm and (optionally) the weapon.
- **Ignore weapons**: global checkbox plus per-link match modes
  (`full`, `no_weapon`, `gear`, `armor`), so a second weapon no longer breaks
  the link.
- Match modes are inherited from the global switch unless a link overrides it.
- Restock triggers: quest accepted (default, plus a 1 s settle so the game's
  quest-pouch initialisation has happened) and back in the hub (only once the
  game reports it is out of the quest, plus 2 s).
- Apply pipeline: the game's own item-set call (candidates ranked by name),
  verified by reading the pouch back, with a clamped pouch top-up from the item
  box as the last resort. Nothing is ever created.
- Preview per link: every change (`Potion 2 → 5`) plus the items the box cannot
  cover; missing items are named in the panel and in the optional on-screen
  notice.
- Fallbacks when no link matches: per weapon type, then a default item set.
- Link table export/import to `reframework/data/linked_restock_links.json`.
- Diagnostics panel: gear source, item-set count, pouch/box size, skill source,
  ranked apply candidates.
- `tools/loadout_probe.lua`: read-only discovery probe for gear, item sets,
  apply candidates and item names.
- Offline test suite for the pure logic (signature keys, mode selection, link
  resolution, diff/preview, normalisation) — 150 assertions under Lua 5.1.
