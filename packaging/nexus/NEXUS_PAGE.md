[size=5][b]Linked Restock[/b][/size]

[b]Link an armour build to an item loadout — and keep it working when you swap weapons.[/b]

[size=4]Why[/size]
Auto Restock mods decide which item loadout to restore by matching your whole gear set, weapon included. Wilds lets you carry two weapons and swap at the tent or the Seikret, so after a mid-quest swap the weapon no longer matches the saved build and the linked item loadout silently stops being applied.

Linked Restock matches the build on [b]armour pieces + jewels (skills) + charm[/b], and only includes the weapon if you want it to. Tick [b]Ignore weapons[/b] and a weapon swap cannot break the link: same armour, same skills, any weapon.

[size=4]What it does[/size]
[list]
[*][b]Link any build to any item set[/b] — pick a saved armour set and an item set from two dropdowns and press [b]Link selected armour set[/b], or wear the build and press [b]Link current build[/b] to capture the weapon's roll data too.
[*][b]One link per build[/b] — ticking a link switches off any other link that would claim the same build, so the row is unambiguous.
[*][b]One matching switch[/b] — links always compare the most granular identity, and a single [b]Ignore weapons[/b] checkbox drops the weapon for every link at once. No per-link modes to configure twice.
[*][b]Restock when you are back in the hub[/b] (and optionally on quest accept). The hub trigger is state-based: it waits for the quest to be over, the results and end-of-quest screens to be gone, loading to finish, and for the game to report no field stage loaded (that is the hub scene) — then holds for a few seconds before writing. A missed poll cannot swallow it.
[*][b]Preview before writing[/b] — every change ("Potion 2 -> 5"), plus the items the item box cannot cover, named, with the reason.
[*][b]Fallbacks[/b] — per weapon type, then a default item set, when nothing matches.
[*][b]Export / import[/b] the link table as JSON.
[*][b]A link list that stays out of the way[/b] — collapsed by default, scrolls, with a Find box and a "N saved, M on" header.
[/list]

[size=4]What a restock actually does[/size]
[b]Save-data writes only. The mod never calls a game method.[/b]

[list=1]
[*]Stacks the item set does not list — and any count above the set's — are returned to the item box, which also frees pouch slots.
[*]The pouch is topped up from the item box.
[*]The result is verified by re-reading the pouch, and logged.
[/list]

The pouch ends up holding [b]exactly[/b] the item set, the way the item box's own apply behaves; only slot order is left to the game. Nothing is ever created: the item box is the hard limit, and anything it cannot cover is reported as [i]missing[/i] or [i]pouch full[/i].

This matters: the game's item-set apply, called from a script, threw on empty sets and crashed the client twice [i]after[/i] returning success. It is not part of this mod at all, not even as a fallback.

[size=4]How it works[/size]
[list]
[*]Worn gear is read from the save data ([font=Courier New]_EquipIndex.Index[/font] -> [font=Courier New]_EquipBox[/font]), i.e. what you are actually wearing — a mid-quest weapon swap is seen correctly.
[*]Skills are captured as jewels per piece; the skill-level array on this build carries no readable levels.
[*]Item loadouts come from [font=Courier New]_ItemMySet._Data[]._PouchItem[][/font], with the game's own item names.
[*]No hooks: quest and camp state are polled twice a second. No game files are modified, no network calls, other players are never touched.
[/list]

[size=4]Install[/size]
Install with Vortex/Fluffy, or extract into your game folder:
[code]
MonsterHunterWilds
├── dinput8.dll            (REFramework)
└── reframework
    └── autorun
        └── linked_restock.lua
[/code]

[size=4]Usage[/size]
[list=1]
[*]Insert -> Script Generated UI -> Linked Restock. Check the version in the panel title.
[*]New link: pick a saved armour set and an item set, press [b]Link selected armour set[/b] (no need to wear it), or press [b]Link current build[/b] while wearing it.
[*]Decide the switches: [b]Ignore weapons[/b], and the triggers [b]Quest accepted[/b] / [b]Back in the hub[/b].
[*]Press [b]Preview[/b] to see the changes, [b]Apply now[/b] to restock immediately.
[/list]

The panel is live: it shows the worn build, which link matches, and for every link the reason it does not ("no match - differs: armour pieces, charm").

[size=4]Limits[/size]
[list]
[*]Slot order inside the pouch is not rewritten — contents are exact, arrangement is the game's.
[*]Field items (picked up in a hunt, not boxable) are not restockable; they are reported, never invented.
[*]A build edited by hand (pieces changed without re-saving the loadout) may not match a link built from that loadout; re-link it or capture the worn build.
[*]If the hub check never matches on your install, the mod drops it for the session and says so in the log, rather than silently not restocking.
[/list]

[size=4]Requirements[/size]
[list]
[*]Monster Hunter Wilds (PC)
[*]REFramework for MH Wilds
[/list]

[size=4]Recent changes[/size]
[list]
[*][b]0.1.48[/b] — the hub check now uses the hub scene (no field stage loaded) instead of the camp manager, which read false at the hub.
[*][b]0.1.47[/b] — crash breadcrumb written as JSON (this REFramework exposes no [font=Courier New]io[/font]); camp lookup fixed; test gate against accidental Lua globals.
[*][b]0.1.45[/b] — the hub restock asks the game whether you are at the hub, self-calibrating and self-disabling if the check never matches.
[*][b]0.1.40[/b] — the game's item-set apply machinery was deleted from the file: no path can call it any more. Every restock is a save-data write.
[*][b]0.1.38[/b] — every trigger logs the worn build and why each link was passed over.
[*][b]0.1.30[/b] — dropdowns for item sets and armour sets, one switch, one link per build, collapsible link list.
[/list]

[size=4]Credits[/size]
REFramework by praydog. The MH Wilds save-data type names were confirmed against the community RSZ type dump used by the save editors.
