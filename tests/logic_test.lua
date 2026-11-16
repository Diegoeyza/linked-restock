--
-- logic_test.lua — offline tests for the pure parts of Linked Restock
--
-- Runs under a plain Lua 5.1 interpreter (the game's LuaJIT is 5.1), with the
-- REFramework globals stubbed out. Nothing here touches the game.
--
--   lua5.1 tests/logic_test.lua
--   ./tests/run.sh
--
-- The mod exports its pure functions on LR._test when LINKED_RESTOCK_TEST is
-- set, so the same code that ships is what gets tested.
--

-- ---------------------------------------------------------------------------
-- stubs for the REFramework environment
-- ---------------------------------------------------------------------------

_G.LINKED_RESTOCK_TEST = true

local function noop() end
re = { on_frame = noop, on_draw_ui = noop }
sdk = { find_type_definition = function() return nil end }
json = {
    dump_file = function() return true end,
    load_file = function() return nil end,
}
log = { info = noop, warn = noop, debug = noop }
imgui = {}
draw = nil

local here = arg and arg[0] or "tests/logic_test.lua"
local dir = string.match(here, "^(.*)[/\\]") or "."
local mod_path = dir .. "/../reframework/linked_restock.lua"

local LR = dofile(mod_path)
assert(type(LR) == "table" and LR._test, "mod did not export its test hooks")
local T = LR._test

-- ---------------------------------------------------------------------------
-- tiny test harness
-- ---------------------------------------------------------------------------

local passed, failed = 0, 0
local current = "?"

local function group(name)
    current = name
end

local function check(cond, what)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("FAIL [%s] %s\n", current, tostring(what)))
    end
end

local function eq(a, b, what)
    check(a == b, string.format("%s (got %s, want %s)", tostring(what),
        tostring(a), tostring(b)))
end

-- ---------------------------------------------------------------------------
-- fixtures
-- ---------------------------------------------------------------------------

local function sig(over)
    local s = {
        armor = { "0:100:0:0:0:0:0:0", "0:200:1:0:0:0:0:0",
                  "0:300:2:0:0:0:0:0", "0:400:3:0:0:0:0:0",
                  "0:500:4:0:0:0:0:0" },
        charm = "charm:21:0:0:0:0:0:0|0,0,0",
        jewels = { "2=1,2", "3=4", "4=5,6", "5=7", "6=8" },
        weapon = "13:6:441:0:0:0:0:0",
        weapon_label = "Long Sword",
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

local function link(over)
    local l = {
        id = "l1", label = "test build", mode = "inherit",
        item_set = 1, item_set_name = "Set A", apply_mode = "exact",
        enabled = true, sig = sig(),
    }
    for k, v in pairs(over or {}) do l[k] = v end
    return l
end

-- ---------------------------------------------------------------------------
-- signature keys
-- ---------------------------------------------------------------------------

group("sig_key")
do
    local a = T.sig_key(sig(), "full")
    local b = T.sig_key(sig(), "full")
    eq(a, b, "same build -> same key")
    check(type(a) == "string" and #a > 0, "key is a non-empty string")

    -- order of the armour list must not matter
    local shuffled = sig({ armor = { "0:500:4:0:0:0:0:0", "0:300:2:0:0:0:0:0",
        "0:100:0:0:0:0:0:0", "0:400:3:0:0:0:0:0", "0:200:1:0:0:0:0:0" } })
    eq(T.sig_key(shuffled, "full"), a, "armour order is not part of the key")

    -- order of the jewels must not matter either
    local s2 = sig()
    s2.jewels = { "6=8", "5=7", "4=5,6", "3=4", "2=1,2" }
    eq(T.sig_key(s2, "full"), a, "jewel order is not part of the key")

    -- a different weapon changes the full key but not the no_weapon key
    local other_weapon = sig({ weapon = "13:6:999:0:0:0:0:0" })
    check(T.sig_key(other_weapon, "full") ~= a, "weapon is part of the full key")
    eq(T.sig_key(other_weapon, "no_weapon"), T.sig_key(sig(), "no_weapon"),
        "weapon is not part of the no_weapon key")

    -- jewels (the skill state) matter until the mode drops them
    local other_jewels = sig({ jewels = { "2=1,9", "3=4", "4=5,6", "5=7", "6=8" } })
    check(T.sig_key(other_jewels, "no_weapon") ~= T.sig_key(sig(), "no_weapon"),
        "jewels are part of the no_weapon key")
    eq(T.sig_key(other_jewels, "gear"), T.sig_key(sig(), "gear"),
        "jewels are not part of the gear key")

    -- charm matters until the mode drops it
    local other_charm = sig({ charm = "charm:21:0:0:1:0:0:0|0,0,0" })
    check(T.sig_key(other_charm, "gear") ~= T.sig_key(sig(), "gear"),
        "charm is part of the gear key")
    eq(T.sig_key(other_charm, "armor"), T.sig_key(sig(), "armor"),
        "charm is not part of the armor key")

    -- a different armour piece changes every mode
    local other_armor = sig({ armor = { "0:100:0:0:0:0:0:0", "0:200:1:0:0:0:0:0",
        "0:300:2:0:0:0:0:0", "0:400:3:0:0:0:0:0", "0:999:4:0:0:0:0:0" } })
    for _, mode in ipairs(T.MODES) do
        check(T.sig_key(other_armor, mode) ~= T.sig_key(sig(), mode),
            "armour change is visible in mode " .. mode)
    end
end

-- ---------------------------------------------------------------------------
-- mode selection
-- ---------------------------------------------------------------------------

group("mode_of")
do
    local cfg = { ignore_weapons = false }
    eq(T.mode_of(link(), cfg), "full", "default is the full build")
    eq(T.mode_of(link({ mode = "inherit" }), { ignore_weapons = true }),
        "no_weapon", "inherit follows the ignore-weapons switch")
    eq(T.mode_of(link({ mode = "gear" }), { ignore_weapons = true }),
        "gear", "an explicit mode wins over the switch")
    eq(T.mode_of(link({ mode = "nonsense" }), { ignore_weapons = false }),
        "full", "an unknown mode falls back to full")
    eq(T.mode_of(nil, cfg), "full", "nil link does not crash")
end

group("mode index")
do
    for i, mode in ipairs(T.MODES) do
        eq(T.mode_from_index(i), mode, "index -> mode " .. i)
        eq(T.mode_to_index(mode), i, "mode -> index " .. mode)
    end
    eq(T.mode_to_index("inherit"), 0, "inherit is combo index 0")
    eq(T.mode_from_index(0), "inherit", "combo index 0 is inherit")
end

-- ---------------------------------------------------------------------------
-- link resolution
-- ---------------------------------------------------------------------------

group("resolve_link")
do
    local cfg = { ignore_weapons = false }
    local l = link()

    local found, mode = T.resolve_link(sig(), { l }, cfg)
    check(found == l, "identical build matches")
    eq(mode, "full", "matched under the full mode")

    local swapped = sig({ weapon = "13:6:999:0:0:0:0:0" })
    local none = T.resolve_link(swapped, { l }, cfg)
    check(none == nil, "a weapon swap breaks a full match")

    local found2, mode2 = T.resolve_link(swapped, { l }, { ignore_weapons = true })
    check(found2 == l, "the same swap still matches with ignore-weapons on")
    eq(mode2, "no_weapon", "matched under the no_weapon mode")

    -- a re-decorated build (jewels differ) refuses a strict link
    local redecorated = sig({ jewels = { "2=1,9", "3=4", "4=5,6", "5=7", "6=8" } })
    check(T.resolve_link(redecorated, { link({ mode = "full" }) }, cfg) == nil,
        "a strict link refuses a jewel change")

    -- but gear mode ignores jewels, so it still matches
    local gear_link = link({ mode = "gear" })
    local gfound, gmode = T.resolve_link(redecorated, { gear_link }, cfg)
    check(gfound == gear_link, "gear mode ignores jewel changes")
    eq(gmode, "gear", "gear mode is reported")

    -- armour-only mode ignores a charm swap
    local armor_link = link({ mode = "armor" })
    local afound = T.resolve_link(sig({ charm = "charm:99", jewels = {} }),
        { armor_link }, cfg)
    check(afound == armor_link, "armor mode ignores charm and skills")

    -- disabled links are skipped
    local off = link({ enabled = false })
    check(T.resolve_link(sig(), { off }, cfg) == nil, "disabled links do not match")

    -- first match wins
    local a = link({ id = "a", label = "a" })
    local b = link({ id = "b", label = "b" })
    local first = T.resolve_link(sig(), { a, b }, cfg)
    check(first == a, "the first matching link wins")

    -- two builds that share armour and differ only by weapon
    local fire = link({ id = "fire", item_set = 1,
        sig = sig({ weapon = "13:6:441:0:0:0:0:0" }) })
    local water = link({ id = "water", item_set = 2,
        sig = sig({ weapon = "13:6:442:1:0:0:0:0" }) })
    local water_build = sig({ weapon = "13:6:442:1:0:0:0:0" })
    local hit = T.resolve_link(water_build, { fire, water }, cfg)
    check(hit == water, "the matching weapon picks its own link")

    -- with ignore-weapons on, the first of the two is still the one that wins,
    -- which is what the panel shows -- documented here so the rule is visible
    local any = T.resolve_link(water_build, { fire, water }, { ignore_weapons = true })
    check(any == fire, "ignore-weapons makes the first link win")
end

-- ---------------------------------------------------------------------------
-- diff / preview
-- ---------------------------------------------------------------------------

group("loadout links without weapon rolls")
do
    local l = T.normalize_link(link({
        id = "old", label = "old loadout link", origin = "loadout",
        sig = sig({ weapon = "13:6:441|235,2,0" }),
    }))
    eq(l.sig.weapon_unknown, true,
        "a loadout link storing an identity-only weapon drops the weapon group")
    local worn = T.normalize_link(link({
        id = "worn", label = "worn",
        sig = sig({ weapon = "13:6:441:0:0:1234567:0:0|235,2,0" }),
    }))
    eq(worn.sig.weapon_unknown, nil, "a worn link keeps the weapon group")
end

group("one enabled link per build")
do
    local cfg = T.default_config()
    cfg.ignore_weapons = true
    cfg.links = {
        link({ id = "a", label = "Conga", item_set = 2 }),
        link({ id = "b", label = "Conga alt", item_set = 3 }),
        link({ id = "c", label = "Other", item_set = 4,
               sig = sig({ armor = { "0:777:7:0:0:0:0:0" } }) }),
    }
    T.set_config(cfg)
    eq(T.dedupe_links(), 1, "a second enabled link for the same build is turned off")
    eq(cfg.links[1].enabled, true, "the first link stays on")
    eq(cfg.links[2].enabled, false, "the duplicate is off")
    eq(cfg.links[3].enabled, true, "a link for another build is untouched")

    cfg.links[2].enabled = true
    local off = T.disable_conflicting(cfg.links[2])
    eq(#off, 1, "enabling it switched one conflicting link off")
    eq(off[1], "Conga", "and names the link it switched off")
    eq(cfg.links[1].enabled, false, "the other link for that build is off")
    eq(cfg.links[2].enabled, true, "the one just enabled stays on")
    eq(cfg.links[3].enabled, true, "the other build is still on")
end

group("link_mismatch")
do
    local cfg = { ignore_weapons = false }
    eq(T.link_mismatch(link({ mode = "full" }), sig(), cfg), nil,
        "an identical build matches")
    eq(T.link_mismatch(link({ mode = "full" }),
        sig({ armor = { "0:999:9:0:0:0:0:0" } }), cfg),
        "differs: armour pieces", "armour differences are named")
    eq(T.link_mismatch(link({ mode = "full" }), sig({ jewels = { "2=9" } }), cfg),
        "differs: skills (jewels)", "jewel differences are named")
    eq(T.link_mismatch(link({ mode = "full" }),
        sig({ charm = "charm:99:0:0:0:0:0:0|0,0,0" }), cfg),
        "differs: charm", "a charm difference is named")
    eq(T.link_mismatch(link({ mode = "full" }),
        sig({ weapon = "13:6:1:0:0:0:0:0" }), cfg),
        "differs: weapon", "a weapon difference is named")
    eq(T.link_mismatch(link({ mode = "no_weapon" }),
        sig({ weapon = "13:6:1:0:0:0:0:0" }), cfg), nil,
        "no_weapon mode ignores the weapon")
    eq(T.link_mismatch(link({ mode = "armor" }),
        sig({ jewels = { "2=9" }, charm = "x" }), cfg), nil,
        "armor mode only looks at the pieces")

    -- links built from a saved loadout compare the charm by amulet type
    local l = link({ mode = "gear", origin = "loadout" })
    l.sig.charm_id = "charm:21"
    local worn = sig({ charm = "charm:21:0:0:0:0:0:0|9,9,9",
                       charm_id = "charm:21" })
    eq(T.link_mismatch(l, worn, cfg), nil,
        "a loadout link matches the amulet when only its skills differ")
    local other = sig({ charm = "charm:22:0:0:0:0:0:0", charm_id = "charm:22" })
    eq(T.link_mismatch(l, other, cfg), "differs: charm",
        "a different amulet is still a mismatch")
end

group("compute_diff")
do
    local contents = {
        { id = 1, count = 5, name = "Potion" },
        { id = 2, count = 3, name = "Whetfish Fin" },
        { id = 3, count = 2, name = "Trap Tool" },
    }

    -- exact, box covers two of the five potions, nothing else in stock
    local pouch = { [1] = 2 }
    local box = { [1] = 2 }
    local changes, missing = T.compute_diff(contents, pouch, box, "exact")
    eq(#changes, 1, "one item changes")
    eq(changes[1].id, 1, "the changed item is the potion")
    eq(changes[1].from, 2, "from is what the pouch holds")
    eq(changes[1].to, 4, "to is clamped by the item box")
    eq(#missing, 3, "three items are short")
    local short = 0
    for _, m in ipairs(missing) do short = short + m.short end
    eq(short, 1 + 3 + 2, "short counts match the box")

    -- plenty in the box
    local full_box = { [1] = 99, [2] = 99, [3] = 99 }
    local c2, m2 = T.compute_diff(contents, {}, full_box, "exact")
    eq(#c2, 3, "all three items change")
    eq(#m2, 0, "nothing is missing")
    eq(c2[1].to, 5, "target is the set's own count")

    -- top-up never lowers what the pouch already holds
    local c3, m3 = T.compute_diff(contents, { [1] = 7 }, { [1] = 99 }, "topup")
    local potion_changed = false
    for _, c in ipairs(c3) do if c.id == 1 then potion_changed = true end end
    check(not potion_changed, "top-up leaves an over-full stack alone")
    eq(#m3, 2, "only the two absent items are missing")

    -- top-up with a partial box
    local c4, m4 = T.compute_diff(contents, { [1] = 1 }, { [1] = 2 }, "topup")
    eq(c4[1].from, 1, "top-up from 1")
    eq(c4[1].to, 3, "top-up is clamped by the box")
    eq(m4[1].short, 2, "two potions still short")

    -- nothing to do
    local c5 = T.compute_diff(contents, { [1] = 5, [2] = 3, [3] = 2 },
        { [1] = 9, [2] = 9, [3] = 9 }, "exact")
    eq(#c5, 0, "a stocked pouch produces no changes")

    -- empty inputs do not crash
    local c6, m6 = T.compute_diff({}, nil, nil, "exact")
    eq(#c6, 0, "empty contents")
    eq(#m6, 0, "empty missing list")
end

group("diff_satisfied")
do
    local changes = { { id = 1, from = 0, to = 5 } }
    local ok, culprit = T.diff_satisfied(changes, { [1] = 5 })
    check(ok == true, "targets reached")
    eq(culprit, nil, "no culprit when satisfied")

    local ok2, c = T.diff_satisfied(changes, { [1] = 4 })
    check(ok2 == false, "short by one is not satisfied")
    check(c ~= nil and c.id == 1, "the short change is reported")
end

-- ---------------------------------------------------------------------------
-- link normalisation / persistence shape
-- ---------------------------------------------------------------------------

group("normalize_link")
do
    local n = T.normalize_link({
        label = "Archfiend α + LS",
        mode = "no_weapon",
        item_set = 3.7,
        item_set_name = "Rompo LBG",
        apply_mode = "topup",
        sig = sig(),
    })
    check(n ~= nil, "a complete link is accepted")
    eq(n.item_set, 3, "item set index is an integer")
    eq(n.apply_mode, "topup", "apply mode survives")
    eq(n.mode, "inherit", "the match mode is always inherited from the global switch")
    eq(n.sig.armor_count, 5, "armour count is recorded")
    eq(n.sig.jewel_count, 5, "jewel slot count is recorded")
    eq(n.enabled, true, "links default to enabled")
    check(type(n.id) == "string" and #n.id > 0, "a link id is generated")

    eq(T.normalize_link({ sig = { armor = {} } }), nil,
        "a link without armour is rejected")
    eq(T.normalize_link({ label = "no sig" }), nil, "a link without a signature is rejected")
    eq(T.normalize_link("nonsense"), nil, "non-tables are rejected")

    local weird = T.normalize_link({ sig = sig(), apply_mode = "banana", mode = 42 })
    check(weird ~= nil, "odd fields do not drop the link")
    eq(weird.apply_mode, "exact", "unknown apply modes fall back to exact")
    eq(weird.mode, "inherit", "non-string modes fall back to inherit")
end

-- ---------------------------------------------------------------------------
-- scenario: the client's two bug reports
-- ---------------------------------------------------------------------------

group("client scenarios")
do
    -- 1. link a fire build, swap weapons mid-quest, come back to the hub
    local fire_build = sig({ weapon = "13:6:441:0:0:0:0:0" })
    local fire_link = link({ label = "Fire set", item_set = 1,
        sig = fire_build, mode = "no_weapon" })
    local after_swap = sig({ weapon = "13:6:900:0:0:0:0:0" })
    local hit = T.resolve_link(after_swap, { fire_link }, { ignore_weapons = false })
    check(hit == fire_link,
        "a mid-quest weapon swap still applies the linked set")

    -- 2. same armour, two weapons, two item sets (weapons included)
    local water_build = sig({ weapon = "13:7:442:2:0:0:0:0" })
    local water_link = link({ label = "Water set", item_set = 2,
        sig = water_build, mode = "full" })
    local fire_strict = link({ label = "Fire set", item_set = 1,
        sig = fire_build, mode = "full" })
    check(T.resolve_link(water_build, { fire_strict, water_link }, {})
        == water_link, "each weapon picks its own item set")

    -- 3. re-decorated set with a strict link: no match, no wrong restock
    local strict = link({ mode = "full" })
    local redecorated = sig({ jewels = { "2=1,9", "3=4", "4=5,6", "5=7", "6=8" } })
    check(T.resolve_link(redecorated, { strict }, {}) == nil,
        "a changed jewel does not silently restock the old set")
end

-- ---------------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- dropdown: REFramework's imgui.combo speaks in table keys, not positions
-- ---------------------------------------------------------------------------

imgui.text = noop
imgui.set_next_item_width = noop
local labels = { "Base", "Shrooms", "HH" }

imgui.combo = function(_, sel, _)
    eq(sel, 1, "the combo receives a 1-based key for position 0")
    return true, 3 -- the user clicked the third entry
end
eq(T.labeled_dropdown("Item set", "##pick", 0, labels), 2,
    "clicking the third entry returns 0-based position 2")

imgui.combo = function(_, sel, _)
    eq(sel, 3, "position 2 is handed over as key 3")
    return false, 0
end
eq(T.labeled_dropdown("Item set", "##pick", 2, labels), nil,
    "no change leaves the position alone")

imgui.combo = function(_, sel, _)
    eq(sel, 1, "an out-of-range position is clamped to the first key")
    return true, 1
end
eq(T.labeled_dropdown("Item set", "##pick", 99, labels), 0,
    "an out-of-range position falls back to the first entry")

imgui.combo = function()
    return true, 99 -- a key outside the table must never be used
end
eq(T.labeled_dropdown("Item set", "##pick", 0, labels), nil,
    "a key outside the list is ignored")

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
