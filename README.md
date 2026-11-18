# Linked Restock

**Repository:** <https://github.com/Diegoeyza/linked-restock> ·
[Releases](https://github.com/Diegoeyza/linked-restock/releases) ·
[Changelog](CHANGELOG.md) ·
[Verification checklist](docs/VERIFY.md)

**A REFramework mod for Monster Hunter Wilds.** Links an armour build to an
item loadout and restocks it automatically — and it keeps working when you swap
your weapon, because the link is matched on the armour, the skills and the
charm, not on the weapon.

> **Status: v0.1.48 — verified on the live build.** Restocks are save-data writes;
> no game method is called anywhere, so the item-set apply that crashed the client
> three times is not in the file at all. The pouch the game plays with was proven
> to be the same array the mod writes (`ItemUtil.getItemPouch` returns the same
> pointer). Reload the script after updating and check the title in the panel.

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
  swallow it. The hub trigger also asks the game whether you are actually in the
  hub: `getActiveStageType()` returns -1 when no field stage is loaded, which is
  the hub scene. That check self-calibrates and drops itself for the session if it
  never matches, so it can never silently stop restocking. The panel's **Quest:**
  line shows which of those states you are in.
- **Restock by save-data writes, never by calling the game.** Extras — stacks the
  set does not list, and any count above the set's — go back to the item box, then
  the pouch is topped up from it, then the result is verified by re-reading the
  pouch. The game's own item-set apply is not in the mod at all: it threw on empty
  sets and crashed the client twice *after* returning "ok". Nothing is created —
  the box is the hard limit. A failed restock is retried a few times, never
  inside a quest.
- **Preview before writing.** A per-link preview lists every change
  (`Potion 2 → 5`) and names the items you are short of.
- **Missing-item reporting** in the panel and, optionally, as an on-screen
  notice drawn on a dark strip so it is readable over any scene. Every shortfall
  says why: `not in the box` or `pouch full` — a stack the pouch does not carry
  needs a free slot, and one is never invented.
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
3. Decide the two global switches: **Ignore weapons** (leave it ticked unless you
   want the weapon to be part of the build) and the trigger checkboxes below.
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

## How a restock is applied

The mod never calls into the game. Invoking the game's own item-set apply from a
script threw on empty sets and crashed the client twice *after* returning "ok"
(an access violation about a second later), so the restock is done with save-data
writes:

1. stacks that are **not** in the item set, and any count above the set's, go back
   to the item box (which also frees pouch slots),
2. the pouch is topped up from the item box,
3. the result is verified by re-reading the pouch, and logged.

The pouch ends up holding **exactly** the item set, the way a manual apply
behaves. Nothing is ever created: the item box is the hard limit. The only
difference from the game's menu apply is slot order.

The automatic trigger waits until the mod can see the quest is over and the hub is
loaded — `get_IsQuestResult` and `get_IsQuestEndShowing` false,
`app.GameFlowManager.get_Loading` false, no active quest, readable item data —
held for ~3 s. **Apply now** runs exactly the same path, with the same retries;
a retry waits for the same settled hub. There is no switch for any of it.
When no link matches, the weapon-type fallback runs, then the default item set.

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
- **Applying** returns the non-set stacks to the item box and tops the pouch up
  from it, then verifies by re-reading the pouch. No game method is called.
- **Triggers** poll `app.MissionManager:get_IsPlayingQuest()` twice a second. No
  hooks.

## Limits

- Slot order is not written: the contents are exact, the arrangement is the
  game's. Stack order inside the pouch is unaffected.
- Field items (things you pick up in a hunt and cannot box) are not restockable;
  the mod reports them as missing instead of inventing them.
- A hand-edited build (pieces changed without re-saving a loadout) may not match
  a link built from that loadout; re-link it or capture the worn build instead.
- The mod never writes the item box beyond what the pouch takes, never touches
  other players, never edits game files, and makes no network calls.

## Development

- `tools/loadout_probe.lua` — read-only discovery probe (gear, item sets, save
  layout). Not shipped; run it in the hub if a game patch changes a field.
- `tests/` — offline tests under Lua 5.1 (271 assertions):
  - `logic_test.lua`: signature keys, modes, link resolution, diff/preview, link
    normalisation, dropdown key semantics.
  - `pipeline_test.lua`: the write pipeline and trigger state machine against a
    fake REFramework save, including the hub camp gate, retries and the
    already-stocked no-op.
  - `gear_test.lua`: build capture from the real save layout and the weapon-swap
    scenario end to end.
  - `run.sh` also compiles the mod and fails on any unexpected Lua global, because
    a misplaced `local` is invisible to the tests but fatal in game.

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
