# Linked Restock — verification plan

The pure logic, the apply pipeline (against a fake save) and the build capture
plus client scenario (against a fake catalogue) are covered by `tests/`
(159 assertions, Lua 5.1). What cannot be faked is the game itself: every real
SDK path has to be verified on the machine that runs it. This is
the order that finds problems fastest.

## 0. Probe (once, in the hub)

1. Copy `tools/loadout_probe.lua` next to the mod in
   `<game>\reframework\autorun\`.
2. Launch the game, load a save, stay in the hub (not mid-quest).
3. Insert → Script Generated UI → **Linked Restock Probe** → **Dump everything**.
4. Keep these four files from `<game>\reframework\data\`:
   `linked_restock_probe_types.json`, `_gear.json`, `_items.json`, `_apply.json`.

What to check in them:

- `_gear.json → catalog_lists.cArmorList` has five entries with readable
  pieces, and `catalog_lists.cWeaponTypePack` shows how the equipped weapon is
  wrapped (the mod tries `piece_key` on the pack itself and one level inside).
- `_gear.json → skills.entries` is not empty and `skills.holder` is
  `app.EquipDataHolder`.
- `_gear.json → equip_mysets` lists the saved armour loadouts with their names.
- `_items.json → item_mysets` lists the item loadouts with names and contents,
  and `box` totals are non-zero.
- `_apply.json → pattern_hits` shows an obvious item-set apply method (a
  one-argument call taking the set number). If there is none, the top-up path is
  the one that will run; that is fine, but note it.

If `cArmorList` or the weapon pack looks wrong, the `piece_key` extraction is
the thing to adjust — it is one function, near the top of the gear section.

## 1. Basic link and apply

1. Equip a saved armour loadout, pick an item loadout, press **Link current
   build**.
2. **Preview** on the link: the change list must match what you would expect
   from the item set, and nothing may be listed as missing unless the box really
   is short.
3. **Apply now**: the pouch contents change, the panel says `restocked …`, and
   the box count drops by the amount moved.

## 2. The client's bug: weapon swap

1. Link a build with **Ignore weapons** off, mode `full`.
2. Accept a quest, swap to the other weapon at the tent or the Seirret, finish
   or return from the quest.
3. Back in the hub the link must still apply. Repeat with **Ignore weapons**
   ticked and confirm behaviour does not change (the weapon is not part of the
   match at all).

## 3. Quest-accept trigger

1. Tick only **Quest accepted**.
2. Accept a quest from the hub: the pouch is restocked before you leave.
3. Finish the quest: nothing should be applied on return (trigger is off).

## 4. Hub-return trigger

1. Tick only **Back in the hub**.
2. Spend items during a quest (eat, flash, trap), finish it.
3. Two seconds after the results screen the pouch is topped up again. Repeat
   after an arena re-challenge: the restock must not be eaten by the game's
   restore.

## 5. Missing items

1. Empty the item box of one item that the item set lists.
2. Apply: every other item is filled, that one is skipped, and the panel/notice
   names it. Create nothing (box count cannot go negative, pouch cannot exceed
   the set's count).

## 6. Item set changed after linking

1. Link to item set 3.
2. Re-save item set 3 in game with different contents (same slot).
3. Apply: the new contents are what lands, and the panel still shows the linked
   slot name (the link follows the slot, which is the intended behaviour).

## 7. Loose match modes

1. Link with mode `gear`, change one decoration so the skills differ: the link
   must still apply.
2. Link with mode `full`, do the same: nothing is applied, and the panel says
   `no link matches this build` (this is the safe failure).

## 8. Two builds, one armour

1. Two weapons of the same type on the same armour, each linked to its own item
   set, mode `full`.
2. Equip one, note the item set; swap to the other in the hub, press Apply: the
   other item set is used.

## Regression checks after any edit

- `luac -p reframework/linked_restock.lua` (Lua 5.1) — no modern syntax.
- `LUA=… ./tests/run.sh` — 159 assertions stay green.
- Panel opens without a Lua error in `reframework/REFramework_log.txt`.
