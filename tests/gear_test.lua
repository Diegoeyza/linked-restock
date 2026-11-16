--
-- gear_test.lua — build capture and the client's weapon-swap scenario, end to
-- end, against a fake game shaped like the 2026-11-15 probe output.
--
-- The fake mirrors the live build:
--   * _EquipIndex.Index[1..15] holds equipment box positions (0-based), with
--     slot 1 = main weapon, 2..6 = armour, 7 = charm, 8 = reserve weapon,
--     9 = mantle, 10..15 = -1 empty;
--   * _EquipBox holds the works; cEquipWork uses Category_Gender
--     (0/1 armour, 13 weapon, 21 charm);
--   * item my-sets are a fixed 64-slot array with a few real entries;
--   * app.ItemMySetUtil.applyMySetToPouch(System.Int32) is the apply call.
--
-- Flow: capture -> link -> restock -> swap weapon (strict refuses) ->
-- ignore-weapons matches -> change jewels (refuses) -> gear mode accepts ->
-- change the charm roll (refuses).
--
--   lua5.1 tests/gear_test.lua
--

_G.LINKED_RESTOCK_TEST = true

-- ---------------------------------------------------------------------------
-- fake SDK
-- ---------------------------------------------------------------------------

local function fn(f)
    return { call = function(_, ...) return f(...) end }
end

local function descriptor(o, name)
    return {
        get_name = function() return name end,
        is_static = function() return false end,
        get_data = function(_, target)
            local src = (target and target._f) or o._f
            return src[name]
        end,
        set_data = function(_, target, v)
            target._f[name] = v
            return true
        end,
        get_type = function()
            return { get_full_name = function() return "System.Object" end }
        end,
    }
end

local function type_def(o)
    return {
        get_full_name = function() return o._t end,
        get_parent_type = function() return nil end,
        get_fields = function()
            local out = {}
            for name in pairs(o._f) do out[#out + 1] = descriptor(o, name) end
            return out
        end,
        get_methods = function() return o._methods or {} end,
        get_method = function(_, sig)
            return o._by_method and o._by_method[sig] or nil
        end,
    }
end

local function object(type_name, fields)
    local o = { _t = type_name, _f = fields or {} }
    function o:get_type_definition() return type_def(o) end
    function o:set_field(name, value)
        self._f[name] = value
        return true
    end
    return o
end

local function array(items)
    local a = { _items = items }
    a.get_Count = fn(function() return #items end)
    a.get_Item = fn(function(_, i) return items[i + 1] end)
    return a
end

local function item_work(id, count)
    return object("app.savedata.cItemWork", { ItemIdFixed = id, Num = count })
end

local function int_array(values)
    local items = {}
    for i, v in ipairs(values) do items[i] = v end
    return array(items)
end

-- ---------------------------------------------------------------------------
-- equipment works
-- ---------------------------------------------------------------------------

-- armour: Category_Gender 0 (male), FreeVal0 = series, FreeVal1 = part
local function armor_work(series, part, jewels)
    return object("app.savedata.cEquipWork", {
        Category_Gender = 0,
        FreeVal0 = series,
        FreeVal1 = part,
        FreeVal2 = 0,
        EquipmentAccessoryIdArray = int_array(jewels or { -1, -1, -1 }),
        BowgunCustomizeId = int_array({ -1, -1 }),
    })
end

-- weapon: Category_Gender 13, FreeVal0 = type, FreeVal1 = id, FreeVal2 = artian
-- performance type, BonusByCreating = the roll
local function weapon_work(wtype, wid, perf, bonus, jewels)
    return object("app.savedata.cEquipWork", {
        Category_Gender = 13,
        FreeVal0 = wtype,
        FreeVal1 = wid,
        FreeVal2 = perf or 0,
        BonusByCreating = bonus or 0,
        BonusByGrinding = 0,
        GrindingNum = 0,
        EquipmentAccessoryIdArray = int_array(jewels or { -1, -1, -1 }),
        BowgunCustomizeId = int_array({ -1, -1 }),
    })
end

-- charm: Category_Gender 21, rolled skills live in BowgunCustomizeId
-- (skill * 1000 + level, per the save layout)
local function charm_work(amulet_type, rolls)
    return object("app.savedata.cEquipWork", {
        Category_Gender = 21,
        FreeVal0 = amulet_type,
        FreeVal1 = 1,
        FreeVal2 = 0,
        EquipmentAccessoryIdArray = int_array({ -1, -1, -1 }),
        BowgunCustomizeId = int_array(rolls or { -1, -1 }),
    })
end

-- positions are 0-based game indices, exactly like _EquipIndex.Index
local FILLER = 40 -- unrelated works in front of the equipped ones
local POS = { weapon = 30, armor = 31, charm = 36, weapon2 = 37, mantle = 38 }

local world = {}

local function rebuild_world(index_base)
    index_base = index_base or 0
    local box = {}
    for i = 1, FILLER do
        box[i] = armor_work(900, 0, { -1, -1, -1 }) -- never equipped
    end
    local function put(pos, work) box[pos + 1] = work end
    world.weapon = weapon_work(3, 441, 0, 1234567, { 235, 2, 0 })
    put(POS.weapon, world.weapon)
    put(POS.armor, armor_work(39, 0, { 158, -1, -1 }))
    put(POS.armor + 1, armor_work(39, 1, { 158, -1, -1 }))
    put(POS.armor + 2, armor_work(168, 2, { 157, 132, 160 }))
    put(POS.armor + 3, armor_work(196, 3, { 157, -1, -1 }))
    put(POS.armor + 4, armor_work(198, 4, { 123, 167, -1 }))
    world.charm = charm_work(192, { 5, 258 })
    put(POS.charm, world.charm)
    world.weapon2 = weapon_work(6, 85, 0, 0, { 236, 82, 45 })
    put(POS.weapon2, world.weapon2)
    -- armour upgrade/reinforcement data on one piece: identity must ignore it
    box[POS.armor + 3]._f.FreeVal2 = 7
    box[POS.armor + 3]._f.BonusByCreating = 123
    box[POS.armor + 3]._f.GrindingNum = 2

    put(POS.mantle, weapon_work(0, 0, 0, 0, { -1, -1, -1 }))

    -- slot order: 1 weapon, 2..6 armour, 7 charm, 8 weapon, 9 mantle
    local index = {}
    for i, pos in ipairs({
        POS.weapon, POS.armor, POS.armor + 1, POS.armor + 2, POS.armor + 3,
        POS.armor + 4, POS.charm, POS.weapon2, POS.mantle,
        -1, -1, -1, -1, -1, -1,
    }) do
        index[i] = pos < 0 and -1 or (pos + index_base)
    end

    -- two saved loadouts sharing the same five armour pieces: "Omega" is the
    -- decoy (different secondary weapon and a different charm), the real one is
    -- "Guardian Arkveld". A label that only looks at armour picks Omega.
    -- my-sets keep the decorations of each piece (the live probe shows them),
    -- which is what makes a loadout-built link comparable to the worn gear
    local myset_jewels = {
        { 158, -1, -1 }, { 158, -1, -1 }, { 157, 132, 160 },
        { 157, -1, -1 }, { 123, 167, -1 },
    }
    -- the array order is the slot order (probe: 1 weapon, 2..6 armour, 7 charm,
    -- 8 reserve weapon, 9 specialized equipment)
    local function make_myset(name, weapon2_id, charm_type)
        local pieces = {}
        pieces[1] = object("app.savedata.cMysetEquipWork", {
            Category = 1, FreeVal0 = 3, FreeVal1 = 441, IsNone = 0,
            EquipmentAccessoryIdArray = int_array({ 235, 2, 0 }),
        })
        for i = 0, 4 do
            pieces[#pieces + 1] = object("app.savedata.cMysetEquipWork", {
                Category = 0, FreeVal0 = ({ 39, 39, 168, 196, 198 })[i + 1],
                FreeVal1 = i, IsNone = 0,
                EquipmentAccessoryIdArray = int_array(myset_jewels[i + 1]),
            })
        end
        pieces[7] = object("app.savedata.cMysetEquipWork", {
            Category = 2, FreeVal0 = charm_type, FreeVal1 = 2, IsNone = 0,
            EquipmentAccessoryIdArray = int_array({ 5, 258 }),
        })
        pieces[8] = object("app.savedata.cMysetEquipWork", {
            Category = 1, FreeVal0 = 6, FreeVal1 = weapon2_id, IsNone = 0,
            EquipmentAccessoryIdArray = int_array({ 236, 82, 45 }),
        })
        pieces[9] = object("app.savedata.cMysetEquipWork", {
            Category = 3, FreeVal0 = 2, FreeVal1 = 0, IsNone = 0,
        })
        return object("app.savedata.cEquipMyset", {
            _MysetParam = object("app.savedata.cMysetBaseParam", {
                MysetName = name, IsEmpty = 0,
            }),
            _MysetEquipWork = array(pieces),
        })
    end
    local myset = make_myset("Guardian Arkveld", 85, 192)

    local equip = object("app.savedata.cEquipParam", {
        _EquipBox = array(box),
        _EquipIndex = object("app.savedata.cEquipIndex", { Index = int_array(index) }),
        _EquipMySet = array({ make_myset("Omega", 99, 191), myset }),
        _CharmEquipped = object("app.savedata.cCharmEquipped", { MainCharm = 192 }),
    })

    -- item sets: the game keeps 64 slots, only three are real
    local function item_set(name, contents)
        return object("app.savedata.cItemMySet", {
            Name = name,
            _PouchItem = array(contents),
        })
    end
    local sets = {
        item_set("Base", { item_work(1, 10), item_work(2, 3) }),
        item_set("Shrooms", { item_work(1, 10), item_work(3, 5) }),
        item_set("LBG", { item_work(1, 10), item_work(2, 3), item_work(3, 2) }),
    }
    local all_sets = {}
    for i = 1, 64 do all_sets[i] = sets[i] or item_set("", {}) end

    world.item = object("app.savedata.cItemParam", {
        _PouchItem = array({ item_work(0, 0), item_work(0, 0), item_work(0, 0),
                             item_work(0, 0), item_work(0, 0), item_work(0, 0) }),
        _BoxItem = array({ item_work(1, 90), item_work(2, 90), item_work(3, 90) }),
    })

    local save = object("app.savedata.cUserSaveData", {
        _Equip = equip,
        _Item = world.item,
        _ItemMySet = object("app.savedata.cItemMySetData", { _Data = array(all_sets) }),
    })
    local sdm = object("app.SaveDataManager", {})
    sdm.getCurrentUserSaveData = function() return save end
    world.sdm = sdm
    return sdm
end

-- the confirmed apply call: fill the pouch from the 0-based set index
local apply_calls = 0
local apply_method = {
    get_name = function() return "applyMySetToPouch(System.Int32)" end,
    get_num_params = function() return 1 end,
    get_param_types = function()
        return { { get_full_name = function() return "System.Int32" end } }
    end,
    is_static = function() return true end,
    call = function(_, index)
        apply_calls = apply_calls + 1
        local sets = world.item and world.item._f and nil
        local _, save = nil, world.sdm
        local data = save.getCurrentUserSaveData()
        local all = data._f._ItemMySet._f._Data._items
        local set = all[index + 1]
        if set == nil then return nil end
        -- rewrite the pouch to the set contents
        local works = {}
        for _, w in ipairs(set._f._PouchItem._items) do
            works[#works + 1] = item_work(w._f.ItemIdFixed, w._f.Num)
        end
        for i = #works + 1, 6 do works[i] = item_work(0, 0) end
        world.item._f._PouchItem = array(works)
        return nil
    end,
}

local apply_set_method = {
    get_name = function() return "apply(app.savedata.cItemMySet)" end,
    get_num_params = function() return 1 end,
    get_param_types = function()
        return { { get_full_name = function() return "app.savedata.cItemMySet" end } }
    end,
    is_static = function() return true end,
    call = function() return nil end,
}

local util_td = {
    get_full_name = function() return "app.ItemMySetUtil" end,
    get_parent_type = function() return nil end,
    get_fields = function() return {} end,
    get_methods = function() return { apply_method, apply_set_method } end,
    get_method = function(_, sig)
        if sig == "applyMySetToPouch(System.Int32)" then return apply_method end
        if sig == "apply(app.savedata.cItemMySet)" then return apply_set_method end
        return nil
    end,
}

re = { on_frame = function() end, on_draw_ui = function() end }
json = { dump_file = function() end, load_file = function() return nil end }
log = { info = function() end, warn = function() end, debug = function() end }
imgui = {}
draw = nil

local sdm = rebuild_world()

sdk = {
    find_type_definition = function(name)
        if name == "app.ItemMySetUtil" then return util_td end
        return nil
    end,
    get_managed_singleton = function(name)
        if name == "app.SaveDataManager" then return sdm end
        return nil
    end,
}

local here = arg and arg[0] or "tests/gear_test.lua"
local dir = string.match(here, "^(.*)[/\\]") or "."
local LR = dofile(dir .. "/../reframework/linked_restock.lua")
local T = LR._test

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------

local passed, failed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1 else
        failed = failed + 1
        io.write("FAIL " .. tostring(what) .. "\n")
    end
end
local function eq(a, b, what)
    check(a == b, string.format("%s (got %s, want %s)", tostring(what),
        tostring(a), tostring(b)))
end

local function cfg()
    local c = T.default_config()
    c.notify = false
    c.links = {}
    return c
end

local function run_task(limit)
    for _ = 1, (limit or 400) do
        T.tick_task()
        if T.state.task == nil then return true end
    end
    return false
end

local function reset_items()
    for _, w in ipairs(world.item._f._PouchItem._items) do
        w._f.ItemIdFixed = 0
        w._f.Num = 0
    end
    for _, w in ipairs(world.item._f._BoxItem._items) do
        w._f.Num = 90
    end
end

-- ---------------------------------------------------------------------------
-- the flow
-- ---------------------------------------------------------------------------

-- 1) capture the build from _EquipIndex -> _EquipBox
T.set_config(cfg())
local sig, source = T.current_signature()
check(sig ~= nil, "the build is readable")
check(source:find("offset %+0") ~= nil, "the 0 offset is detected (" .. tostring(source) .. ")")
eq(sig.armor_count, 5, "five armour pieces")
eq(sig.jewel_count, 5, "five armour jewel slots")
check(sig.charm ~= nil, "the charm is part of the signature")
check(sig.weapon ~= nil and sig.weapon ~= "", "the weapons are part of the signature")
eq(#(sig.weapon_ids or {}), 2, "only the two real weapon slots count (slot 9 is specialized equipment)")

-- 2) the label matches the whole gear, not just the armour: "Omega" shares the
--    five armour pieces but has a different secondary weapon and charm, and is
--    listed first. One piece also carries upgrade fields the loadout does not
--    record -- that must not matter either.
local name, index, quality = T.game_loadout_name(sig)
eq(name, "Guardian Arkveld", "the exact loadout wins over the armour-only one")
eq(index, 2, "and its index is reported")
eq(quality, "full", "the match is exact")

-- 3) link it and restock through the confirmed apply call
T.get_config().links = {
    T.normalize_link({
        id = "l1", label = name, item_set = 1, item_set_name = "Base",
        apply_mode = "exact", sig = sig,
    }),
}
reset_items()
eq(T.fire("test"), true, "the link resolves for this build")
check(run_task(), "the restock completes")
eq(T.pouch_snapshot()[1], 10, "the linked item set landed")
eq(T.pouch_snapshot()[2], 3, "and so did its second item")
check(apply_calls >= 1, "applyMySetToPouch was called, not just the top-up")

-- 4) the client's bug: swap the weapon, a strict match must refuse
world.weapon._f.FreeVal1 = 900
world.weapon._f.FreeVal2 = 1
world.weapon._f.BonusByCreating = 7654321
T.state.task = nil
eq(T.fire("test"), false, "a weapon swap refuses a strict link")
check(T.state.task == nil, "nothing is applied on a refused match")
check(T.state.last_result:find("no link") ~= nil, "and the panel says why")
local swap_sig = T.current_signature()
local swap_name, _, swap_quality = T.game_loadout_name(swap_sig)
check(swap_name ~= nil, "the armour still identifies a loadout")
eq(swap_quality, "armor", "but only as a partial (charm/weapons differ)")

-- 5) with Ignore weapons the same build still matches, and restocks
T.get_config().ignore_weapons = true
reset_items()
check(T.fire("test") == true, "ignore-weapons restores the link after the swap")
check(T.state.last_match ~= nil, "a link matched")
check(run_task(), "and the restock completes")
eq(T.pouch_snapshot()[1], 10, "the linked item set landed again")

-- 6) re-jewelled armour is a different build under ignore-weapons
local armor_work_obj = world.item and nil
local box = world.sdm.getCurrentUserSaveData()._f._Equip._f._EquipBox._items
box[POS.armor + 1]._f.EquipmentAccessoryIdArray = int_array({ 158, 9, -1 })
T.state.task = nil
reset_items()
check(T.fire("test") == false, "a re-jewelled build does not silently restock")
eq(T.pouch_snapshot()[1], nil, "the pouch was left alone")

-- 7) gear mode accepts the jewel change, as documented
T.get_config().links[1].mode = "gear"
check(T.fire("test") == true, "gear mode accepts a jewel change")
check(run_task(), "and applies")
eq(T.pouch_snapshot()[1], 10, "the pouch is restocked")

-- 8) a different charm roll is a different build (charms carry skills)
T.get_config().links[1].mode = "inherit"
world.charm._f.BowgunCustomizeId = int_array({ 5, 260 })
T.state.task = nil
reset_items()
check(T.fire("test") == false, "a charm re-roll does not match the old link")
eq(T.pouch_snapshot()[1], nil, "and nothing was applied")

-- 9) the same save with a 1-based Index must resolve to the same build
local first_armor = sig.armor
sdm = rebuild_world(1)
local sig2, source2 = T.current_signature()
check(sig2 ~= nil, "the 1-based layout is readable")
check(source2:find("offset %-1") ~= nil, "the -1 offset is detected (" .. tostring(source2) .. ")")
eq(table.concat(sig2.armor, "|"), table.concat(first_armor, "|"),
    "both bases resolve to the same armour")
local name2 = T.game_loadout_name(sig2)
eq(name2, "Guardian Arkveld", "and the loadout label is still found")

-- ---------------------------------------------------------------------------

-- 10) a link built from a saved loadout matches the worn build without
--     wearing it: armour + jewels + charm type, no weapon roll data
local save3 = sdm.getCurrentUserSaveData()
local myset2 = save3._f._Equip._f._EquipMySet._items[2]
local msig, msrc = T.signature_from_myset(myset2)
check(msig ~= nil, "a saved loadout gives a signature (" .. tostring(msrc) .. ")")
eq(#msig.armor, 5, "with its five armour pieces")

local loadout_link = T.normalize_link({
    id = "loadout1", label = "Guardian Arkveld", mode = "no_weapon",
    item_set = 1, item_set_name = "Base", origin = "loadout", sig = msig,
})
check(loadout_link ~= nil, "the loadout link normalises")
eq(loadout_link.origin, "loadout", "and keeps its origin")

local worn = T.current_signature()
local m1 = T.resolve_link(worn, { loadout_link }, { ignore_weapons = true })
check(m1 ~= nil, "the loadout link matches the worn build under no_weapon")

loadout_link.mode = "gear"
local m2 = T.resolve_link(worn, { loadout_link }, { ignore_weapons = true })
check(m2 ~= nil, "armour + charm mode matches too")

-- the equipment box holds exactly one copy of the weapon, so the roll fields
-- are known and a full match works for a loadout-built link too
check(msig.weapon_unknown == nil, "the weapon roll was resolved from the box")
loadout_link.mode = "full"
local m3 = T.resolve_link(worn, { loadout_link }, { ignore_weapons = false })
check(m3 ~= nil, "with the roll resolved it matches in full mode as well")

-- two copies of the same weapon id: the roll cannot be known, so the weapon
-- group is dropped instead of never matching
local box2 = save3._f._Equip._f._EquipBox._items
box2[#box2 + 1] = weapon_work(3, 441, 0, 111, { 235, 2, 0 })
local msig2 = T.signature_from_myset(myset2)
check(msig2.weapon_unknown == true, "two copies of a weapon leave the roll unknown")
local link2 = T.normalize_link({
    id = "loadout2", label = "loadout", item_set = 1, origin = "loadout",
    sig = msig2,
})
local m4 = T.resolve_link(worn, { link2 }, { ignore_weapons = false })
check(m4 ~= nil, "an unknown weapon roll does not block the match")

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
