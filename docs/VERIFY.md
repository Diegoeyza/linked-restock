# Linked Restock — verification plan

The write pipeline, the trigger state machine, the hub camp gate, the build
matching and the weapon-swap scenario are covered offline by `tests/` (271
assertions under Lua 5.1, `LUA=… ./tests/run.sh`). What cannot be faked is the
game itself, so this is the order that finds real problems fastest.

Run this after a game patch, or before a release, on the live install.

## 0. Load and version

1. Copy `reframework/linked_restock.lua` to `<game>\reframework\autorun\`.
2. Launch, then REFramework → **Script** → **Reset scripts**.
3. Insert → Script Generated UI → **Linked Restock**. The title must read the
   version you deployed; if it does not, the file did not reach the game.
4. In `re2_framework_log.txt` look for `[LinkedRestock] loaded v…`. A Lua error
   instead means a syntax problem (the tests would have caught it; check that the
   deployed file is byte-identical).

## 1. Basic link and Apply now

1. Pick a saved armour set and an item set in **New link**, press **Link
   selected armour set** (do not wear it — this path must stand on its own).
2. **Preview** lists the changes (`Potion 2 → 5`) and any shortfall.
3. **Apply now**: the notice says `restocked <set> (N items)`.
4. Open the item box: the pouch matches the set exactly (contents; slot order is
   the game's).
5. In the log: `pouch after <set>: <id>:<n> …`, then `recheck <set> +5s: still
   stocked`, and `live pouch identity: ptr0=true … idmatch0=8/8`. `ptr0=true`
   means the game's own `ItemUtil.getItemPouch` returns the array the mod writes.

## 2. Link from the worn build

1. Equip the build, **Link current build**. The label is the game's loadout name.
2. Change one piece (or one decoration) and press **Apply now**: it must not
   match, and the log must name the differing group
   (`no match for '<label>': differs: armour pieces`).
3. Put the piece back: it matches again.

## 3. Hub return trigger (the default)

1. Accept a quest from the hub, finish or return.
2. While the results/end screens play, the panel's **Quest:** line names the
   blocking state (`results screen`, `quest end screen`, `loading`).
3. When the hub is loaded, the gate holds a few seconds, the camp check opens, and
   the restock runs once. The log shows `flow … loading=false … camp=… tent=…
   zone=true` before it.
4. It never runs mid-quest: check the log for no `restocked` line while
   `playing=true`.

If the log says `camp check never matched at the hub - ignoring it`, the camp
signal is wrong for this install: report it with the `flow …` line, the mod keeps
working with the old gate for the session.

## 4. Quest accept trigger (optional)

Enable **Quest accepted**, accept a quest, and confirm the restock happens once,
about a second after the accept, and not again on the same quest.

## 5. The client's bug: weapon swap

1. Two weapons of the same type on the same armour, one link, **Ignore weapons**
   ticked.
2. Swap the weapon mid-quest and finish the quest: the link still matches and the
   item set is restored.
3. Untick **Ignore weapons** and repeat: the swap must now refuse, naming the
   weapon as the differing group.

## 6. Missing items

1. Link an item set containing something your box cannot cover.
2. The notice names it with the reason: `(no stock)` or `(pouch full)`.
3. Nothing is created: the box totals do not increase.

## 7. Fallbacks

1. Disable every link, wear a build, **Apply now**: the weapon-type fallback runs
   if configured, otherwise the default item set.
2. The log line is `build armour[…` followed by the fallback label, not `match`.

## 8. One link per build

1. Create a second link for the same build and tick it: the first is unticked.
2. Reload the script: the setting survives (no two enabled links on load).

## 9. Import / export

1. Diagnostics → **Export links**: `reframework\data\linked_restock_links.json`
   exists and contains every link.
2. Delete one link in the panel, **Import links**: it comes back.

## Regression checks after any edit

- `tests/run.sh` — 271 assertions stay green, **and the globals gate passes**
  (an accidental global is invisible to the tests but fatal in game).
- `luac51 -p reframework/linked_restock.lua` — Lua 5.1 syntax only.
- Deployed file is byte-identical to the repo (`cmp -s`).
- Panel opens without a Lua error in `re2_framework_log.txt`.
- A restock logs `pouch after` **and** `recheck +5s: still stocked`.
