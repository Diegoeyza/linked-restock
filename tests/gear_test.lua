--
-- gear_test.lua — the client's bug, end to end, against a fake game.
--
-- Fakes the live catalogue (armour, charm, weapon pack), the hunter's skill
-- list, the save-data loadouts and the item sets, then drives the real code:
--
--   capture the build -> save a link -> restock -> swap the weapon ->
--   restock again with "Ignore weapons" -> change a skill -> no match
--
--   lua5.1 tests/gear_test.lua
--

_G.LINKED_RESTOCK_TEST = true

-- ---------------------------------------------------------------------------
-- fake SDK (same shapes as pipeline_test.lua)
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

-- obj:call(name) is how REFramework reaches a method by name
local function with_methods(o, methods)
    o.call = function(_, name)
        local m = methods[name]
        if m == nil then return nil end
        return m()
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

-- ---------------------------------------------------------------------------
-- the build in hand
-- ---------------------------------------------------------------------------

-- armour: category_gender 0 (armour, male), FreeVal0 = series, FreeVal1 = part
local function armor_piece(series, part)
    return object("app.savedata.cEquipWork", {
        Category_Gender = 0, FreeVal0 = series, FreeVal1 = part, FreeVal2 = 0,
    })
end

-- weapon: category_gender 13, FreeVal0 = weapon type, FreeVal1 = weapon id,
-- FreeVal2 = artian performance type (the "rolls" part of the identity)
local function weapon_work(wtype, wid, perf, bonus_create)
    return object("app.savedata.cEquipWork", {
        Category_Gender = 13, FreeVal0 = wtype, FreeVal1 = wid,
        FreeVal2 = perf or 0, BonusByCreating = bonus_create or 0,
    })
end

local armor = {
    armor_piece(101, 0), armor_piece(102, 1), armor_piece(103, 2),
    armor_piece(104, 3), armor_piece(105, 4),
}
local main_weapon = weapon_work(3, 441, 0, 1234567)
local charm = object("app.savedata.cCharmEquipped", { MainCharm = 7, SubCharm = 0 })

local world = { weapon = main_weapon, skills = { 5, 3 } }

local function rebuild_world()
    local packs = {}
    for i = 1, 14 do packs[i] = nil end
    packs[4] = world.weapon -- weapon type 3 (0-based) -> position 4

    local catalog = object("app.cPlayerCatalogHolder", {
        cArmorList = array(armor),
        cWpCharm = charm,
        cWeaponTypePack = array({ world.weapon }),
    })

    local skill_entries = {}
    for i, lv in ipairs(world.skills) do
        skill_entries[i] = object("app.cHunterSkill.cInfo", { _Skill = i * 10, _SkillLv = lv })
    end
    local holder = object("app.EquipDataHolder", {
        _EquipSkillDataArray = array(skill_entries),
    })
    local skill = object("app.cHunterSkillParamInfo", { _EquipDataHolderRef = holder })
    local weapon = object("app.cWeapon", { _WpType = 3 })
    local status = with_methods(object("app.cHunterStatus", { _Skill = skill }), {
        get_IsUserControl = function() return true end,
        get_IsNpc = function() return false end,
    })

    local character = with_methods(object("app.HunterCharacter", {}), {
        get_HunterStatus = function() return status end,
        get_Weapon = function() return weapon end,
        get_WeaponID = function() return 441 end,
    })

    local player_info = with_methods(object("app.cPlayerManageInfo", {}), {
        get_Character = function() return character end,
    })
    local instance = with_methods(object("app.cPlayerManageControl", {}), {
        get_PlayerInfo = function() return player_info end,
        get_Character = function() return character end,
    })

    local player_manager = with_methods(object("app.PlayerManager", {
        _InstancedPlayerList = object("x", { _Array = array({ instance }) }),
    }), {
        get_Catalog = function() return catalog end,
    })
    -- the mod calls get_Catalog() directly (SDK method binding), so provide
    -- both shapes the fake objects are asked for
    player_manager.get_Catalog = function() return catalog end

    -- save data: one armour loadout with the same pieces, for the label
    local loadout_pieces = {}
    for i, p in ipairs(armor) do loadout_pieces[i] = p end
    loadout_pieces[#loadout_pieces + 1] = world.weapon
    local myset = object("app.savedata.cEquipMyset", {
        _MysetParam = object("app.savedata.cMysetBaseParam", {
            MysetName = "Guardian Arkveld", IsEmpty = 0,
        }),
        _MysetEquipWork = array(loadout_pieces),
    })
    local equip = object("app.savedata.cEquipParam", {
        _EquipMySet = array({ myset }),
        _EquipBox = array({ world.weapon }),
        _CharmEquipped = charm,
        _EquipIndex = object("app.savedata.cEquipIndex", { Index = array({ 0 }) }),
    })

    -- items: one item set and an empty pouch so a restock has work to do
    local item_set = object("app.savedata.cItemMySet", {
        Name = "Rompo LBG",
        _PouchItem = array({ item_work(1, 5), item_work(2, 3) }),
    })
    local item = object("app.savedata.cItemParam", {
        _PouchItem = array({ item_work(0, 0), item_work(0, 0), item_work(0, 0),
                             item_work(0, 0), item_work(0, 0), item_work(0, 0) }),
        _BoxItem = array({ item_work(1, 9), item_work(2, 9) }),
    })
    local save = object("app.savedata.cUserSaveData", {
        _Equip = equip,
        _Item = item,
        _ItemMySet = object("app.savedata.cItemMySetData", { _Data = array({ item_set }) }),
    })
    local sdm = object("app.SaveDataManager", {})
    sdm.getCurrentUserSaveData = function() return save end

    world.item = item
    world.skill_entries = skill_entries
    return player_manager, sdm
end

local player_manager, sdm = rebuild_world()

local apply_calls = 0
local apply_method = {
    get_name = function() return "applyItemMySet(System.Int32)" end,
    get_num_params = function() return 1 end,
    get_param_types = function()
        return { { get_full_name = function() return "System.Int32" end } }
    end,
    is_static = function() return true end,
    call = function()
        apply_calls = apply_calls + 1
        return nil -- the pouch read-back decides, and the top-up path fills it
    end,
}
local util_td = {
    get_full_name = function() return "app.ItemMySetUtil" end,
    get_parent_type = function() return nil end,
    get_fields = function() return {} end,
    get_methods = function() return { apply_method } end,
    get_method = function(_, sig)
        if sig == "applyItemMySet(System.Int32)" then return apply_method end
        return nil
    end,
}

re = { on_frame = function() end, on_draw_ui = function() end }
sdk = {
    find_type_definition = function(name)
        if name == "app.ItemMySetUtil" then return util_td end
        return nil
    end,
    get_managed_singleton = function(name)
        if name == "app.PlayerManager" then return player_manager end
        if name == "app.SaveDataManager" then return sdm end
        return nil
    end,
}
json = { dump_file = function() end, load_file = function() return nil end }
log = { info = function() end, warn = function() end, debug = function() end }
imgui = {}
draw = nil

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

-- ---------------------------------------------------------------------------
-- the flow
-- ---------------------------------------------------------------------------

-- 1) capture the build
T.set_config(cfg())
local sig, source = T.current_signature()
check(sig ~= nil, "the build is readable")
eq(source, "catalog", "the live catalogue is the gear source")
eq(sig.armor_count, 5, "five armour pieces")
eq(sig.skill_count, 2, "two skills")
eq(sig.charm, "charm:7", "the charm is part of the signature")
check(sig.weapon ~= nil and sig.weapon ~= "", "the weapon is part of the signature")

-- 2) the game loadout name is found by armour
local name, index = T.game_loadout_name(sig)
eq(name, "Guardian Arkveld", "the saved loadout name is used as the label")
eq(index, 1, "and its index is reported")

-- 3) link it and restock
T.get_config().links = {
    T.normalize_link({
        id = "l1", label = name, item_set = 1, item_set_name = "Rompo LBG",
        apply_mode = "exact", sig = sig,
    }),
}
local started = T.fire("test")
check(started == true, "the link resolves for this build")
check(run_task(), "the restock completes")
eq(T.pouch_snapshot()[1], 5, "the linked item set landed")
eq(apply_calls, 1, "the game apply was tried once")

-- 4) the client's bug: swap the weapon in place, a full match must refuse
T.state.task = nil
world.weapon._f.FreeVal1 = 900
world.weapon._f.FreeVal2 = 1
world.weapon._f.BonusByCreating = 7654321
local swapped = T.fire("test")
check(swapped == false, "a weapon swap refuses a strict link")
check(T.state.task == nil, "nothing is applied on a refused match")
check(T.state.last_result:find("no link") ~= nil, "and the panel says why")

-- 5) with Ignore weapons the very same build still matches, and restocks
local function reset_items()
    for _, w in ipairs(world.item._f._PouchItem._items) do
        w._f.ItemIdFixed = 0
        w._f.Num = 0
    end
    for _, w in ipairs(world.item._f._BoxItem._items) do
        w._f.Num = 9
    end
end

T.get_config().ignore_weapons = true
reset_items()
eq(T.pouch_snapshot()[1], nil, "the pouch starts empty")
local ok2 = T.fire("test")
check(ok2 == true, "ignore-weapons restores the same link after the swap")
check(T.state.last_match ~= nil, "a link matched")
check(run_task(), "and the restock completes")
eq(T.pouch_snapshot()[1], 5, "the linked item set landed again")

-- 6) a skill change is still a different build, even with ignore-weapons on
local calls_before = apply_calls
world.skill_entries[2]._f._SkillLv = 1
reset_items()
local ok3 = T.fire("test")
check(ok3 == false, "a re-decorated build does not silently restock")
eq(apply_calls, calls_before, "no apply was attempted")
eq(T.pouch_snapshot()[1], nil, "the pouch was left alone")

-- 7) and a looser link mode accepts it, as documented
T.get_config().links[1].mode = "gear"
local ok4 = T.fire("test")
check(ok4 == true, "gear mode accepts a skill change")
check(run_task(), "and applies")
eq(T.pouch_snapshot()[1], 5, "the pouch is restocked")

-- ---------------------------------------------------------------------------

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
