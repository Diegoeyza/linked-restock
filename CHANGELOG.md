# Changelog

## 0.1.8 — every set is selectable, and the pickers report what they see

Reported in game: "it still does not let me select the HH item set from the
dropdown". A combo whose list omits (or mislabels) one set cannot select it, and
the panel gave no way to tell which case it was. Both pickers now list every
slot the save has:

- **Item set** lists the sets that have a name or items first, labelled
  `Name (18)`; slots the mod cannot name are still there as
  `Slot #7 (18 items)`, and empty slots as `Slot #9 (empty)`.
- **Armour set** likewise lists every equipment loadout slot: `Name (#2)` for
  the ones with five readable armour pieces, `Slot #12 (no armour read)` for the
  rest.
- Under the item-set dropdown the panel prints the chosen slot and its item
  count, so a pick that did not take is visible immediately.
- **Diagnostics** prints the item sets and equipment loadouts the mod found
  (index, name, count) instead of a bare total, plus a **Reload lists** button
  that drops both caches after you create a set in game.
- Picking an entry logs the position and name when *Debug log* is on.

The lists are cached for a second (the pickers read 64 slots x 64 items), so a
set created in game shows up on the next second or after **Reload lists**.

## 0.1.7 — dropdowns, and linking a saved armour set

Two requests from the live install:

- The pickers are **dropdowns** again. They were combos in 0.1.5, but a combo
  sharing a line with its label was pushed off the panel edge; each dropdown now
  takes its own line at the panel's available width, so it cannot be clipped and
  a long list (many item sets, 64 loadout slots) scrolls normally.
- **Link an armour set without wearing it.** New link now has two selectors: a
  saved equipment loadout, and the item set, plus the match mode. "Link selected
  armour set" builds the link's signature straight from the saved my-set.
  "Link current build" still captures the worn gear with full weapon data.

Because a saved my-set has no weapon roll fields, and the game does not write
decorations to every record the same way, a loadout-built link defaults to
**armour + charm**: the five armour pieces plus the charm's amulet type. The
row's Match dropdown can be tightened to *armour + skills* (jewels compare by
equipment slot) or loosened to *armour pieces only*. Worn-gear links are
unchanged and keep full fidelity.

Also:

- The charm is compared by amulet type for loadout links, so a charm the my-set
  records without its rolled-skill array still matches the worn one.
- Skill arrays ignore trailing empty slots (`{158,-1,-1}` and `{158}` are the
  same piece, and a my-set does not always keep the zero padding).
- **Re-link once after this update**: the signature text changed, so links made
  with 0.1.6 and earlier will not match.

## 0.1.6 — controls that cannot be clipped

Reported in game: "it is not letting me make a new link, it does not let me
change the base item set". The panel's rows were wider than the REFramework
window, so the combo boxes and buttons were pushed off the right edge (the same
reason Refresh had gone missing earlier).

- Every picker is now a pair of `<` / `>` buttons with the current value shown
  in brackets, stacked vertically: item set and match mode for the new link,
  and per link row. Nothing depends on a combo popup or on horizontal space.
- Per link: item set, match mode, Preview, Apply, Remove on their own lines.
- The default item set picker cycles `(none)` and the real sets the same way.
- When no item loadouts are found the panel says so instead of showing an empty
  picker, and pressing "Link current build" with no set selected reports it.
- Removed the unused label builder.

## 0.1.5 — stop counting specialized equipment as a weapon

The panel reported "same armour as Omega - weapons differ" while the worn set
was a different loadout with the same armour. Root cause: slot 9 (specialized
equipment / mantle) holds a work stored with weapon-shaped default fields
(Category_Gender 13, type 0, id 0), so the build carried a phantom third weapon
— the same thing that produced "3 weapons ... Hope Sword I" earlier. Every saved
loadout stores two weapons, so the weapon set could never match.

- Only slots 1..8 contribute weapons to the identity (main weapon, 5 armour,
  charm at 7, reserve at 8). Later weapon-shaped slots are ignored.
- The label picks the armour-matching loadout that agrees on the most parts and
  names what differs (`- weapons differ`, `- charm differ`).
- Diagnostics gained a `worn:` line (armour count, weapons with their ids,
  charm) for support reports.
- Tests: 159 assertions; the fake now has slot 9 shaped like the live build and
  asserts two weapons and an exact label match.

## 0.1.4 — the loadout label matches the whole gear

Reported in game: the panel named the "Omega" loadout while the worn set was a
different loadout that shares the same five armour pieces but has another
secondary weapon and another charm.

- The label now tries a whole-gear match first (same armour, same charm type,
  same weapons). Only if no saved loadout matches does it fall back to the
  armour, and then it says so: `same armour as Omega (#2) - charm/weapons
  differ`. It never presents a partial match as exact again.
- Charm identity for the label is the amulet type only (`FreeVal0`): `FreeVal1`
  means different things in a worn work and in a saved my-set.
- Links made from a partial match are labelled `<name> (armour)`.
- Tests: 158 assertions (a decoy loadout with the same armour is listed first
  and must not steal the name; a weapon swap degrades the label to partial).

## 0.1.3 — loadout label, armour upgrades, visible Refresh

Follow-up from the in-game report: weapons read correctly but the worn loadout
still showed "not one of the saved loadouts", and the Refresh button was not
reachable.

- Armour identity no longer includes upgrade/reinforcement fields
  (`FreeVal2`, `BonusByCreating`, `BonusByGrinding`, `GrindingNum`). Those are
  real on worn pieces but zero in a saved loadout, so the label comparison
  failed. They still count for weapons, where they are the Artian roll.
- The loadout label compares identity keys (category + series/part) on both
  sides, and the slot-base detection uses the same comparison.
- Refresh is now a button next to the build line ("Refresh") and again under the
  new-link row ("Refresh build"); the new-link buttons moved to their own row so
  nothing is clipped on narrow panels.
- The build is re-read every two seconds while the panel has not managed to read
  it yet, instead of once at open.

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
