# Changelog

## 0.1.20 — the hub gate is exact, because the API dump named the signals

The flow dump the 0.1.18 build wrote to `linked_restock_api.json` (read from the
game folder) listed the getters that were being guessed at:

```
app.MissionManager.get_IsQuestResult
app.MissionManager.get_IsQuestEndShowing
app.GameFlowManager.get_Loading        (GameFlowManager is a managed singleton)
```

So the exact pass no longer waits ten seconds hoping the return flow is over. It
waits for the real conditions, and only for as long as they take:

- not in a quest, no active quest
- **no quest result screen** (`get_IsQuestResult`)
- **no quest end screen** (`get_IsQuestEndShowing`)
- **not loading** (`app.GameFlowManager.get_Loading`)
- item data readable

held for 8 polls (~4 s) so a flicker cannot open the gate. Flags are read
tolerantly (boolean or boxed/numeric), and the gate counter resets the moment any
condition fails.

The panel now says which condition is blocking:
`in the hub - exact apply waiting (results screen)` and then
`in the hub - exact apply in 3/8 poll(s)`.

The flow trace logs `playing / active / questdata / director / result / ending /
loading` on every change, so the next quest leaves a readable record.

## 0.1.19 — the exact apply has no switch

Requested in game: "remove the exact apply button, it should always be on,
otherwise there is no point".

- The **Exact game apply after the hub settles** checkbox is gone, and so is the
  `game_call_on_auto` config key. The two-stage automatic restock is simply what
  the mod does:
  1. at the trigger, a save-data top-up from the item box (immediate, cannot
     crash);
  2. ~10 s later, when the quest flow is completely over and the hub has been
     quiet for the whole gate window, the game's own `applyMySetToPouch`.
- The panel says `automatic: top-up at the trigger, then the game's own apply /
  once the hub is loaded and quiet (~10 s)` next to the triggers.
- The exact pass is skipped when the pouch already holds the set (nothing to
  fix), and it also repairs a top-up that the game discarded, because it
  re-reads the pouch before acting.
- Diagnostics keeps `hub settled: N/20 (exact apply queued)`.

## 0.1.18 — the exact apply waits for a loaded hub

Requested in game: use the game's own item-set call, "but not at the actual quest
end — when I am already back in the hub, with no loading screen".

`get_IsActiveQuest()` is already false on the results screen, so the 0.1.15
version could not tell the two apart and called the game while it was tearing the
quest down. The automatic path now runs in two stages:

1. **At the trigger** (results screen cleared) it tops the pouch up from the item
   box, which is a save-data write and cannot crash anything. The pouch is never
   left unstocked.
2. **Once the hub is settled** it runs the game's own `applyMySetToPouch`: not in
   a quest, no active quest, **no active quest data**, **no quest director**, item
   data readable, and that has to hold for ~10 s (20 polls). Only then is the
   game call made, and the same gate keeps its retries out of quests.

The panel's Diagnostics shows `hub settled: N/20` and whether an exact apply is
queued, so the wait is visible.

- The switch is now **Exact game apply after the hub settles** and is on by
  default; a config written before 0.1.18 has it turned on once, because the old
  `false` was a reaction to the quest-end crash, not to this rule.
- The mod now dumps the flow API (`app.MissionManager`, `app.PlayerManager`,
  `app.GameFlowManager`, `app.StageAreaLoadManager`, ...) to
  `reframework/data/linked_restock_api.json` on load and whenever the flow tuple
  changes with Debug log on, so the gate can be tightened on facts if the exact
  pass still fires too early.

## 0.1.17 — say what the automatic restock actually does

Wording only: the switch from 0.1.16 is now labelled by its risk and the line
under it states the current automatic path, `top-up from the item box only` or
`game item-set call, then top-up`, so the difference between the manual and
automatic apply is visible in the panel instead of implied.

## 0.1.16 — automatic restocks no longer call into the game

Reported in game: the client crashed at the end of a quest, while the mod was
restocking for the return.

The automatic path called `app.ItemMySetUtil.applyMySetToPouch(...)` (and had a
scattershot list of other `Item*` methods behind it) at the moment the game is
tearing the quest down. Invoking a game method in that state is not something a
mod can recover from with `pcall` — it crashed the game.

- **Automatic restocks (quest accepted / back in the hub) write save data only.**
  They top the pouch up from the item box, which never enters game code, so a
  mistimed attempt costs nothing.
- The game's own call stays the manual path (`Apply now`, a link's `Apply`),
  where you are standing in the hub with settled data and it is proven to work.
- New switch **Game call on automatic restock** (off by default) for anyone who
  wants to trade that safety for exact item-set semantics on the automatic path.
- The blind `Item*` method scan is no longer used as a fallback at all: only
  `applyMySetToPouch`, `apply(set)` and the top-up remain.
- An automatic retry never runs inside a quest: it waits until you are out.
- Automatic failures retry up to three times, ~4 s apart, because the pouch is
  swapped during a quest return.

## 0.1.15 — the automatic path stops trusting a diff from trigger time

Reported in game: "it works when I select apply now" — the manual apply restocks,
the automatic one reported `every apply path failed`.

Manual apply runs in the hub with settled item data. The automatic fire runs
right after the quest, while the game is swapping the pouch and item-box arrays.
The task captured the diff at trigger time and verified against it, so it could:

- decide "already stocked" from arrays that read empty during the swap, and do
  nothing, or
- keep trying to reach counts read from a pouch object that no longer existed,
  exhausting every strategy while the real pouch sat untouched.

Now:

- **The diff is recomputed before every attempt and before every check.** Success
  means "the item set you are linked to is what the pouch holds now", not "the
  numbers captured at trigger time were reached".
- **Nothing fires while the item data reads empty.** The trigger waits, up to
  ~20 s, instead of consuming itself.
- **A failed task is re-run** after ~3 s, twice at most (with a `will retry` line)
  — a quest return is a moving target.
- The failure text now says whether the pouch ever changed and names the
  strategies tried, e.g. `the pouch never changed after
  ItemMySetUtil.applyMySetToPouch(3), ItemUtil.fillPouchItems()`.
- Every failure writes `reframework/data/linked_restock_failed_apply.json` with
  the set contents, the pouch at trigger time and now, the box, and the trace.
- `tools/apply_probe.lua` (new, optional): calls each apply method once and
  records the pouch before/after, for the case where the pipeline itself is in
  question.

## 0.1.14 — the hub return is detected by state, not by an edge

Reported in game: no restock on returning from a quest.

The hub trigger only armed when the mod *observed* the exact quest -> hub
transition, and it then counted down a delay that a missed poll could swallow.
Separately, the accept restock decremented a frame counter once per poll (every
30 frames), so "one second" was really thirty — the accept restock arrived half
a minute into the quest.

- The hub return now fires when a quest was seen (or the script was loaded
  mid-quest) and the game has been steadily out of a quest for the configured
  delay, with `MissionManager.get_IsActiveQuest()` false. The delay starts only
  when the results screen has really cleared, and it fires once per quest.
- Loading the script mid-quest counts as a quest in progress, so the hub return
  still works during development reloads.
- The accept restock waits two polls (~1 s) instead of sixty.
- `fire()` always writes a status line: `no link for this build (...)`,
  `cannot read the current build: ...`, `restock failed: ...` — the panel is no
  longer silent about a trigger that decided not to act.
- The panel shows a **Quest:** line — `in a quest`, `results screen - waiting for
  the hub`, `in the hub - hub restock in 2/4 poll(s)`, `already restocked for
  this quest`, `no quest seen` — plus the reason in `Last fired:`.

## 0.1.13 — the link list is a collapsed section with a scroll region

Reported in game: with hundreds of possible linked sets, the list pushed the
rest of the panel off the screen.

- **Links** is now its own collapsible section, closed by default (REFramework
  remembers the choice per panel). The header line always shows
  `N saved, M on`, so the state is readable while collapsed.
- The rows live in a scrolling child region, capped at 260 px, so the panel
  height no longer grows with the number of links. Builds without the
  `begin_child_window` binding fall back to a plain list.
- **Find:** box above the list filters rows by label (case-insensitive).
- Work per frame no longer scales with the list as badly: the item-set label
  table is built once per frame instead of once per row, and each row's match
  verdict is memoised against the worn signature (the gear is re-read twice a
  second, so verdicts are recomputed at that rate, not every frame).
- Removed rows drop their cached verdict.

## 0.1.12 — one matching switch

Reported in game: the per-link **Match** dropdown duplicated the global
**Ignore weapons** checkbox, so every set had to be configured twice.

- The per-link match-mode dropdown is gone, in the new-link form and in every
  row. Links always inherit the global switch, and the default is the most
  granular match: armour pieces + skills + charm + weapon.
- **Ignore weapons** stays at the top and drops the weapon from that key; the
  line under it spells out what links currently compare.
- Each row prints the model as text (`Matching: armour + skills + charm + weapon`)
  instead of offering it for selection.

A link built from a saved loadout now resolves the weapon's roll from the
equipment box: if exactly one owned work matches the loadout's weapon id, its
Artian type / created / grinded fields are used, so such a link is as strict as
a worn-gear link. If the weapon exists more than once (different rolls) the roll
cannot be known, so the weapon group is dropped for that link (the row says
`no weapon roll data`) instead of the link never matching.

Links loaded from an older config have their mode reset to inherit. A loadout
link saved before this version stores an identity-only weapon key with no roll
fields, which could never equal a worn key: those are detected and treated as
"roll unknown", so they keep matching instead of silently failing.

## 0.1.11 — one enabled link per build

Reported in game: two links for Agressive Conga with different item loadouts were
both ticked, and both rows said they matched.

Two enabled links whose keys resolve to the same build are indistinguishable at
match time: the panel shows both as matching and only the first in list order
would ever apply. A build now drives exactly one item set:

- ticking a link switches off every other enabled link that resolves to the same
  build (same key under its own mode), and the status line says which;
- creating a link (worn or from a saved loadout) switches off its predecessors
  for that build;
- the config is de-duplicated at load and after an import, so an existing file
  cannot keep two claimants;
- a disabled row now reads `(off - not used)` instead of claiming a match.

Different builds, and links that only match under a looser mode, are left alone:
the rule compares the effective key, not just the armour pieces.

## 0.1.10 — the panel shows the live match, and why a link refuses

Reported in game: "I made a linked set with conga and HH, but when I switched to
the conga loadout, the matched says nothing yet".

`Matched:` was only written inside the trigger path, so it stayed on "nothing
yet" until a quest was accepted or the hub was entered — and the worn build was
only re-read when you pressed Refresh, so a loadout switched in game was never
noticed. The panel is now live:

- The worn build is re-read twice a second while the panel is open, so
  `Current build` follows a loadout switch by itself.
- **Matched now:** runs the real resolution every frame and shows either the
  link (`Conga -> HH [armour + charm]`), the fallback, or
  `no link for this build (no link matches this build)`.
- Each link row ends with **matches the worn build** or
  **no match - differs: armour pieces, charm** — the mismatching groups by name,
  computed per group under that link's own mode.
- The previous fire-time line is kept as `Last fired:`.

Note for links made before 0.1.9: their stored signature can belong to the
entry one row off (the dropdown bug), so a link labelled `Conga` may hold
`DPS Omega`'s armour. Remove and re-create it.

## 0.1.9 — dropdowns pick the entry you clicked

Reported in game: "when I select link selected armor set, it is linking the
armor set from above it, not the one I picked".

Cause: `imgui.combo` in REFramework does not speak in 0-based positions. It
takes the **table key** of the current entry, previews `values[selection]`,
returns the **key** of the clicked entry and iterates the label table. The
picker passed its 0-based position straight in and used the returned key as a
position, so the preview and the value used were always one entry apart.

- `labeled_dropdown` now converts on both boundaries: position + 1 going in, key
  - 1 coming out, with a range check so a stale key can never pick a stranger.
- Every dropdown goes through it: armour set, item set, match mode, default item
  set and the per-link item set / match rows.
- `logic_test` pins the convention down with fake combos (position 0 -> key 1,
  click key 3 -> position 2, out-of-range clamps, out-of-table keys ignored).

Links made in 0.1.8 may point at the item set below the one that was shown;
worth checking the row after reloading.

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
