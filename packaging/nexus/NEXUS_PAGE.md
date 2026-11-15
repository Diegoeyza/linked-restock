[size=5][b]Linked Restock[/b][/size]

[b]Link an armour build to an item loadout — and keep it working when you swap weapons.[/b]

[img]https://staticdelivery.nexusmods.com/images/placeholder.png[/img]

[size=4]Why[/size]
Auto Restock mods decide which item loadout to restore by matching your whole gear set, weapon included. Wilds lets you carry two weapons and swap at the tent or the Seirret — so after a mid-quest swap the weapon no longer matches the saved build and the linked item loadout silently stops being applied.

Linked Restock matches the build on [b]armour pieces + resolved skill levels + charm[/b], and only includes the weapon if you want it to. Tick [b]Ignore weapons[/b] and a weapon swap cannot break the link: same armour, same skills, any weapon.

[size=4]Features[/size]
[list]
[*][b]Link any build to any item loadout[/b] — wear it, pick the set, press "Link current build". No need to save an in-game loadout first.
[*][b]Ignore weapons[/b] — global checkbox plus per-link match modes: armour + skills + weapon, armour + skills, armour + charm, armour only.
[*][b]Restock on quest accept and/or back in the hub.[/b] Quest accept is the reliable moment and the default; the hub trigger waits two seconds so the game's own return/arena flow cannot overwrite it.
[*][b]Verified apply with fallbacks.[/b] The game's own item-set call is tried first, the pouch is read back afterwards, and the last resort is a clamped top-up from the item box. Nothing is created.
[*][b]Preview before writing[/b] — every change ("Potion 2 -> 5") and the items the box cannot cover, named.
[*][b]Fallbacks[/b] — per weapon type, then a default item set.
[*][b]Export/import[/b] the link table as JSON.
[/list]

[size=4]How it works[/size]
[list]
[*]Gear is read from the live catalogue ([font=Courier New]app.PlayerManager:get_Catalog()[/font]) — what you are actually wearing, not what a loadout slot remembers.
[*]Skills are the resolved levels on your hunter ([font=Courier New]cHunterSkill._EquipDataHolderRef._EquipSkillDataArray[/font]), so armour skills, decorations, set bonuses and the charm are one map.
[*]Item loadouts come from the save data ([font=Courier New]_ItemMySet._Data[]._PouchItem[]_[/font]) with the game's own item names.
[*]No hooks: quest state is polled twice a second. No game files are modified, no network calls, other players are never touched.
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
[*]In the hub, equip the build you want to link.
[*]Insert -> Script Generated UI -> Linked Restock.
[*]New link: pick the item loadout and the match mode, press [b]Link current build[/b].
[*]Tick [b]Quest accepted[/b] and/or [b]Back in the hub[/b].
[*]Use [b]Preview[/b] to see the exact changes, [b]Apply[/b] to try it immediately.
[/list]

[size=4]Limits[/size]
[list]
[*]v0.1.0: the game call that applies an item set is discovered by name and verified by reading the pouch back. If it is not found on your build, the pouch top-up path runs instead and the panel says so under Diagnostics. Run the included probe once and keep the JSON if you want the exact call confirmed.
[*]The top-up path fills the pouch but cannot remove items the set does not list (the in-game "exact set" behaviour).
[*]The item box is the hard limit: anything the box cannot cover is reported, never created.
[/list]

[size=4]Requirements[/size]
[list]
[*]Monster Hunter Wilds (PC)
[*]REFramework for MH Wilds
[/list]

[size=4]Credits[/size]
REFramework by praydog. The MH Wilds save-data type names were confirmed against the community RSZ type dump used by the save editors.
