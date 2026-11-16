# Changelog

## 0.1.2 — correct the equipment-slot offset

Reported in game: a worn saved loadout showed as "not one of the saved
loadouts" and weapon names were off by one, which means the works read out of
`_EquipBox` were the neighbours of the equipped items.

- `_EquipIndex.Index` may be a 0-based position, a 1-based one, or one below the
  position. The mod now reads all three offsets and picks one by structure:
  the five armour slots must carry armour parts 0..4 exactly once (each part is a
  slot), the charm slot should equal `_CharmEquipped.MainCharm`, and the armour
  key set should equal one of the saved loadouts. A shifted read fails those
  checks even though the item *categories* still line up.
- Weapon labels: resolved through `list[wid + 1]` first (the HuntDumper v0.9.3
  rule; `FreeVal1` is 0-based into a 1-based list), typed-id match only as a
  fallback, de-duplicated, at most two names.
- Diagnostics now show the slot layout (`W A A A A A C W o . . .`) and the chosen
  offset with its score.
- Probe: dumps `equip_slots` for all three offsets plus the weapon catalogue
  around the ids in use, so a naming mismatch can be read off directly.

## 0.1.1 — probe-verified gear and apply paths

Built from `linked_restock_probe_*.json` on the live build (2026-11-15).

- **Gear now comes from the save data**, not the catalogue:
  `app.PlayerManager:get_Catalog()` returns a prefab/asset holder with no armour
  lists on this build, so the probe retired that path. The worn gear is
  `cEquipParam._EquipIndex.Index[1..15]` (equipment box position per slot) into
  `cEquipParam._EquipBox`; the index base is detected by requiring slot 1 to be
  a weapon and slots 2..6 armour (scores 11/11 on a full set).
- **Category normalisation**: `cEquipWork.Category_Gender` is a bitset (0/1
  armour, 13 weapon, 21 charm) while `cMysetEquipWork.Category` is a plain enum
  (0 armour, 1 weapon, 2 charm, 3 other). Both map to one vocabulary, so loadout
  names and live gear produce comparable keys.
- **Skills are captured as jewels, not skill levels**: `cHunterSkill.__EquipDataHolderRef._EquipSkillDataArray`
  exposes 128 entries with no readable level on this build. The identity now
  uses each piece's `EquipmentAccessoryIdArray` plus `BowgunCustomizeId` (which
  is also where a charm's rolled skills live), so re-decorating and charm
  re-rolls are still part of the build.
- **Apply path confirmed**: `app.ItemMySetUtil.applyMySetToPouch(System.Int32)`
  (static), plus `app.ItemMySetUtil.apply(cItemMySet)`. Both are tried before
  the generic name scan, with the pouch read-back deciding.
- **Item sets**: the game keeps a fixed 64-slot array; only sets with a name or
  contents are listed (3 real sets on the probe save), and the stored link keeps
  the original index the apply call expects.
- Panel: "N jewel slots" instead of a skill count; the diagnostics show the slot
  layout score.
- Tests: 155 assertions (logic 80, pipeline 44, gear 31); `gear_test.lua` now
  mirrors the probe's slot layout and asserts the confirmed apply call runs.

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
  resolution, diff/preview, normalisation) — 155 assertions under Lua 5.1.
