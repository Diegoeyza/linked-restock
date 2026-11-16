# Linked Restock

**A REFramework mod for Monster Hunter Wilds.** Links an armour build to an
item loadout and restocks it automatically — and it keeps working when you swap
your weapon, because the link is matched on the armour, the skills and the
charm, not on the weapon.

> **Status: v0.1.2 — probe-verified on the live build.** The probe confirmed the
> worn-gear source (`_EquipIndex.Index` → `_EquipBox`), the equipment categories
> and the apply call (`app.ItemMySetUtil.applyMySetToPouch`). In-game acceptance
> tests still have to be run once; see `docs/VERIFY.md`.

## The problem it solves

The existing Auto Restock mods decide which item set to restore by matching the
whole gear set, including the weapon. Wilds lets you carry two weapons and swap
between them at the tent or the Seirret, so after a mid-quest swap the weapon no
longer matches the saved build and the linked item loadout silently stops being
applied.

Linked Restock matches on what actually defines the build:

- the five armour pieces,
- the resolved skill levels (so a re-decorated set is a different build),
- the charm,
- and the weapon — with its type, id, element and attack/upgrade data — **unless
  you tick “Ignore weapons”**, in which case the weapon is not part of the
  identity at all. Five armour pieces, same skills, any weapon: it still matches.

## Features

- **Link any build to any item loadout.** Wear the build, pick the item set,
  press *Link current build*. No need to save an in-game loadout first, though
  saved loadouts are recognised and used for the label.
- **Ignore weapons.** One checkbox (global) plus a per-link match mode. Use it
  for the same armour with a fire set and a water set sharing one item loadout.
- **Match modes per link:** armour + skills + weapon, armour + skills,
  armour + charm, or armour pieces only.
- **Restock on quest accept and/or back in the hub.** Quest accept is the
  reliable moment (and the default) and waits one second so the game's own
  quest-pouch initialisation has happened; the hub trigger waits until the game
  is really out of the quest and two seconds more, so the return/arena flow
  cannot overwrite it.
- **Verified apply with fallbacks.** The game's own item-set call is tried
  first; if the pouch did not change, the next candidate runs, and the last
  resort is a pouch top-up from the item box. Nothing is created: the box is the
  hard limit.
- **Preview before writing.** A per-link preview lists every change
  (`Potion 2 → 5`) and names the items you are short of.
- **Missing-item reporting** in the panel and, optionally, as an on-screen
  notice.
- **Fallbacks when nothing matches:** per weapon type, then a default item set.
- **Export/import** of the link table (JSON) for backups or sharing.

## Install

1. Install REFramework for MH Wilds (`dinput8.dll` in the game folder).
2. Copy `reframework/linked_restock.lua` to
   `<game>\reframework\autorun\linked_restock.lua`.
   Steam path: `...\steamapps\common\MonsterHunterWilds\reframework\autorun\`
3. Launch the game → REFramework menu (Insert) → **Script Generated UI** →
   **Linked Restock**.

## Use

1. In the hub, equip the build you want to link.
2. Open *Linked Restock*, pick its item loadout in **New link → Item set**.
3. Choose the **Match** mode (leave it on *inherit* to follow the global
   Ignore-weapons checkbox), then press **Link current build**.
4. Tick **Quest accepted** and/or **Back in the hub**.
5. Press **Preview** on the link to see exactly what will change, then
   **Apply** to try it immediately.

The panel shows what the mod sees: the armour count, the charm, how many
skills, the weapon, and the game loadout the build belongs to. If it says
"not read yet" nothing has been equipped/loaded yet; press *Refresh*.

## How it works

- **Gear** comes from the save data: `_EquipIndex.Index` holds the equipment box
  position of the item worn in each slot, and `_EquipBox` holds those works. That
  is what you are actually wearing, so a mid-quest weapon swap is seen correctly.
- **Skills** are captured as jewels: each piece's `EquipmentAccessoryIdArray`
  plus `BowgunCustomizeId` (where a charm's rolled skills live). The skill-level
  array the game exposes on this build carries no readable levels, so the jewel
  state is the identity of "the same skills".
- **Item loadouts** are read from the save data
  (`_ItemMySet._Data[]._PouchItem[]`, `ItemIdFixed` + `Num`), with names from the
  game's own item table.
- **Applying** calls `app.ItemMySetUtil.applyMySetToPouch(index)` (or
  `apply(set)`), verifies the pouch afterwards, and falls back to topping the
  pouch up from the item box.
- **Triggers** poll `app.MissionManager:get_IsPlayingQuest()` twice a second. No
  hooks.

## Limits

- Applying an item set outside the item box depends on a game method whose exact
  name/signature is confirmed by the probe. Until then the pouch top-up path is
  what runs, and it handles everything except *removing* items the set does not
  list (the "exact set" behaviour of the in-game box).
- A hand-edited build (pieces changed without re-saving a loadout) may not match
  a saved loadout's link under the strict modes; use a looser mode or re-link.
- The mod never writes the item box beyond what the pouch takes, never touches
  other players, never edits game files, and makes no network calls.

## Development

- `tools/loadout_probe.lua` — read-only discovery probe (gear, item sets, apply
  candidates). Run it in the hub; it writes four JSON files to
  `reframework/data/`.
- `tests/` — offline tests under Lua 5.1 (150 assertions):
  - `logic_test.lua`: signature keys, match modes, link resolution,
    diff/preview, link normalisation.
  - `pipeline_test.lua`: the apply pipeline and trigger state machine against a
    fake REFramework save (game apply preferred, silent-call fallback to the
    box top-up, short box, already stocked, quest-accept/hub-return timing).
  - `gear_test.lua`: build capture from the live catalogue and the client's
    weapon-swap scenario end to end (strict match refuses, ignore-weapons
    matches, re-decorated build refuses, gear mode accepts).

  ```sh
  LUA=/path/to/lua5.1 ./tests/run.sh
  ```

- `./package.sh` builds `dist/linked-restock-<version>.zip` (flat) and
  `dist/LinkedRestock-<version>.zip` (game-folder layout).
- Syntax gate is a real Lua 5.1 compiler (`luac -p`), not a modern parser: the
  game's LuaJIT is 5.1, and 5.4-only syntax loads in some parsers but not in
  game.

## Credits

- REFramework by praydog.
- The save-data type names and field layout were confirmed against the community
  RSZ type dump used by the MH Wilds save editors.
- Build identity and the ignore-weapons rule come from the client's report about
  Auto Restock breaking after a mid-quest weapon swap.
