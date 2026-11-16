# Linked Restock

**A REFramework mod for Monster Hunter Wilds.** Links an armour build to an
item loadout and restocks it automatically — and it keeps working when you swap
your weapon, because the link is matched on the armour, the skills and the
charm, not on the weapon.

> **Status: v0.1.18 — probe-verified on the live build.** The probe confirmed the
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

- **Link any build to any item loadout.** Pick a saved armour set and an item
  set from two dropdowns and press *Link selected armour set* — no need to wear
  it. Or wear the build and press *Link current build* to capture the weapon's
  roll data too.
- **One item loadout per build.** Ticking a link switches off every other link
  that would claim the same build, so a link row is unambiguous; keep the
  alternates in the list and tick the one you want.
- **A long link list stays out of the way.** *Links* is a collapsible section
  (closed by default, header shows `N saved, M on`) with its own scroll region
  and a **Find** box, so hundreds of links do not push the rest of the panel
  off the screen.
- **One matching switch.** Links always compare the most granular identity —
  armour pieces, skills, charm and weapon — and a single **Ignore weapons**
  checkbox drops the weapon for every link at once. There is no per-link mode to
  configure twice.
- **Restock on quest accept and/or back in the hub.** Quest accept waits one
  second so the game's own quest-pouch initialisation has happened. The hub
  trigger is state-based, not edge-based: it arms as soon as a quest has been
  seen (loading the script mid-quest counts) and fires once the game has been
  steadily out of a quest for the configured delay with
  `get_IsActiveQuest()` false, so a missed poll or the results screen cannot
  swallow it. The panel's **Quest:** line shows which of those states you are in.
- **Verified apply with fallbacks.** Applying by hand uses the game's own
  item-set call first and falls back to a pouch top-up from the item box.
  Automatic restocks use the top-up only: they write save data and never call
  into the game, because doing that while a quest is being torn down crashed the
  client. Nothing is created — the box is the hard limit. The target is re-read
  before every attempt, and a failed automatic restock is re-run a few times,
  never inside a quest.
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

1. Open *Linked Restock* → **New link**.
2. Pick the saved **armour set** and the **item set** from the two dropdowns,
   then press **Link selected armour set**. Nothing has to be worn: the link is
   built from the saved loadout and matches on armour pieces + charm type.
   Wearing the build and pressing **Link current build** instead captures the
   weapon's roll data, which lets the link be stricter.
3. Leave **Match** on *inherit* to follow the global Ignore-weapons checkbox,
   or pick a mode explicitly.
4. Tick **Quest accepted** and/or **Back in the hub**.
5. Press **Preview** on the link to see exactly what will change, then
   **Apply** to try it immediately.

Both dropdowns list every slot the save has. A set is shown as `Name (18)`, or
as `Slot #7 (18 items)` when its name cannot be read, so a set the mod cannot
name is never unreachable; empty slots come last as `Slot #9 (empty)`. The line
under the item-set dropdown repeats the chosen slot and item count. If a set you
just created is missing, press **Reload lists** (the lists are cached for a
second).

The panel is live: it re-reads the worn gear twice a second and prints
**Matched now:** for the build you are wearing, plus a verdict on every link row
(`matches the worn build`, or `no match - differs: armour pieces, charm`), so a
loadout switch is visible without pressing anything or waiting for a trigger. If it says
"not read yet" nothing has been equipped/loaded yet; press *Refresh*.

## The two ways to apply an item set

- **The game's own call** (`app.ItemMySetUtil.applyMySetToPouch`). It applies the
  item set exactly as the game would: the same items, counts and slot order, and
  it removes what the set does not contain. It is what **Apply now** and a link's
  **Apply** use. It must not be called while the game is tearing a quest down —
  that crashed the client — so it is never used by the automatic triggers unless
  you tick **Game call on automatic restock**.
- **A save-data top-up.** The mod raises pouch counts and fills empty slots from
  the item box, and never calls into the game. It reaches the same item counts,
  but leaves items in the pouch that the set does not list, and cannot reorder
  slots. The automatic triggers do this first, immediately, so the pouch is never
  left short.

With **Exact game apply after the hub settles** on (the default), the automatic
trigger then runs the game's own call a little later, once the mod can see that
the quest is fully over and the hub is loaded: no active quest, no active quest
data, no quest director, readable item data, stable for ~10 s. The Diagnostics
line `hub settled: N/20` shows that gate counting.

Nothing is ever created: the item box is the hard limit in both paths.

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
- `tests/` — offline tests under Lua 5.1 (159 assertions):
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
