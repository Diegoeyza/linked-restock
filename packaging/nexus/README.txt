Linked Restock
==============

Extract this archive into your Monster Hunter Wilds game folder, so the file ends
up here:

    <game>\reframework\autorun\linked_restock.lua

Steam default:

    C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterWilds\

Requires REFramework for MH Wilds (dinput8.dll).

Then launch the game and open:

    Insert -> Script Generated UI -> Linked Restock

The panel title shows the version. After updating, use
REFramework -> Script -> "Reset scripts" and check that title.

What it does, in one line: an armour build is linked to an item loadout, and the
pouch is restocked from the item box whenever you return to the hub (optionally on
quest accept too). Matching ignores the weapon unless you untick "Ignore weapons".

Restocks are save-data writes. The mod does not call any game method, so the
item-set apply that has crashed other restock mods is not used at all.

Settings and links: reframework\data\linked_restock.json
Full instructions and limits: see the mod page / README.
