--
-- linked_restock.lua v0.1.0 - link an armour build to an item loadout and
-- restock it automatically
--
-- What it does:
--   * reads every equipment my-set (the game's own "loadouts") and lets you
--     link one build to one item my-set;
--   * identifies the build by the armour pieces, the resolved skill levels
--     and the charm - and by the weapon, unless "Ignore weapons" is on;
--     with it on, swapping to your secondary weapon (or any other weapon)
--     does not break the link: that is the whole point of this mod;
--   * restocks when a quest is accepted (default), when you are back in the
--     hub, or both; every apply is read back and retried if the pouch did not
--     actually change;
--   * never invents items: it applies through the game's own item-set path
--     (or tops the pouch up from the item box), so the box is the hard limit;
--   * shows a preview of exactly what would change before anything is
--     written, and names the items you are short of;
--   * keeps links in reframework/data/linked_restock.json, exportable and
--     importable.
--
-- Build identity, in one line:
--   armour pieces + charm + skill levels (+ weapon stats unless ignored).
--   A re-decorated set is a different build; the same armour with a different
--   weapon is the same build when "Ignore weapons" is on.
--
-- Verification model: applying an item set is the game's own call whenever it
-- can be found, and every attempt is verified by reading the pouch back. If a
-- call silently does nothing, the next candidate runs, and the last resort is
-- a clamped pouch top-up from the item box. Nothing is ever written to the
-- box beyond what the pouch takes.
--
-- Load: <game>\reframework\autorun\linked_restock.lua, then REFramework menu
--   (Insert) -> Script Generated UI -> "Linked Restock".
-- Footprint: no hooks, UI only. SDK calls are pcall-guarded; the frame loop
-- reads state a few times a second and writes only when a trigger fires.
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui
local os = os
local draw = draw
local unpack = unpack or table.unpack

local VERSION = "0.1.0"
local CONFIG_FILE = "linked_restock.json"
local LINKS_FILE = "linked_restock_links.json"

local ALREADY_LOADED = _G.LINKED_RESTOCK_LOADED == true
_G.LINKED_RESTOCK_LOADED = true
local TEST_MODE = _G.LINKED_RESTOCK_TEST == true

local LR = {}

-- ---------------------------------------------------------------------------
-- config
-- ---------------------------------------------------------------------------

local MODES = { "full", "no_weapon", "gear", "armor" }

local MODE_GROUPS = {
    full = { "armor", "charm", "skills", "weapon" },
    no_weapon = { "armor", "charm", "skills" },
    gear = { "armor", "charm" },
    armor = { "armor" },
}

local MODE_LABELS = {
    inherit = "inherit",
    full = "armour + skills + weapon",
    no_weapon = "armour + skills",
    gear = "armour + charm",
    armor = "armour pieces only",
}

local config = {
    enabled = true,
    debug = false,
    ignore_weapons = false,
    notify_missing = true,
    notify = true,
    triggers = { quest_accept = true, hub_return = true },
    hub_delay_frames = 120,   -- 2 s after the quest ends
    retry_limit = 3,
    default_item_set = nil,   -- 1-based item my-set index
    fallback_by_weapon = {},  -- weapon type -> item my-set index (1-based)
    links = {},
}

-- Link shape:
-- {
--   id = "...", label = "...",
--   sig = { armor = { "..." }, charm = "...", skills = { ["1"] = 5 }, weapon = "...",
--           weapon_label = "Long Sword", armor_count = 5 },
--   mode = "inherit",        -- inherit | full | no_weapon | gear | armor
--   item_set = 3,            -- 1-based
--   item_set_name = "Rompo LBG",
--   apply_mode = "exact",    -- exact | topup
--   enabled = true,
-- }

local function default_config()
    return {
        enabled = true,
        debug = false,
        ignore_weapons = false,
        notify_missing = true,
        notify = true,
        triggers = { quest_accept = true, hub_return = true },
        hub_delay_frames = 120,
        retry_limit = 3,
        default_item_set = nil,
        fallback_by_weapon = {},
        links = {},
    }
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function safe_str(v)
    if v == nil then return nil end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    return tostring(v)
end

local function num(v)
    if type(v) == "number" then return v end
    return nil
end

local function type_name(obj)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    return td and safe(function() return td:get_full_name() end) or nil
end

local function find_field_descriptor(obj, name)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 10 do
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if safe(function() return f:get_name() end) == name then return f end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

local function field_value(obj, name)
    local f = find_field_descriptor(obj, name)
    if not f then return nil end
    local is_static = safe(function() return f:is_static() end)
    return safe(function() return f:get_data(is_static and nil or obj) end)
end

-- int/enum wrapper -> number, whatever the build uses
local function enum_number(v)
    if type(v) == "number" then return v end
    if v == nil then return nil end
    for _, n in ipairs({ "m_value", "value__", "Value" }) do
        local x = field_value(v, n)
        if type(x) == "number" then return x end
    end
    return nil
end

local function write_field(obj, name, value)
    if obj == nil then return false end
    local ok = safe(function() obj:set_field(name, value) return true end)
    if ok then return true end
    local f = find_field_descriptor(obj, name)
    if not f then return false end
    return safe(function() f:set_data(obj, value) return true end) == true
end

local function collect(list, maxItems)
    local out = {}
    if list == nil then return out end
    local cnt = safe(function() return list.get_Count end)
    local item = safe(function() return list.get_Item end)
    if cnt ~= nil and item ~= nil then
        local n = safe(function() return cnt:call(list) end) or 0
        if maxItems and n > maxItems then n = maxItems end
        for i = 0, n - 1 do
            out[#out + 1] = safe(function() return item:call(list, i) end)
        end
        return out
    end
    for i = 0, (maxItems or 64) - 1 do
        local v = safe(function() return list[i] end)
        if v == nil then break end
        out[#out + 1] = v
    end
    return out
end

local function count_of(list)
    if list == nil then return 0 end
    local cnt = safe(function() return list.get_Count end)
    if cnt then return safe(function() return cnt:call(list) end) or 0 end
    return #list
end

local function call_method(obj, name)
    if obj == nil then return nil end
    local v = safe(function() return obj:call(name) end)
    if v ~= nil then return v end
    local td = safe(function() return obj:get_type_definition() end)
    local m = td and safe(function() return td:get_method(name) end)
    if not m then return nil end
    return safe(function() return m:call(obj) end)
end

-- ---------------------------------------------------------------------------
-- pure logic (exported to the offline tests)
-- ---------------------------------------------------------------------------

local function sorted_list(t)
    local out = {}
    for _, v in ipairs(t or {}) do out[#out + 1] = tostring(v) end
    table.sort(out)
    return out
end

local function sorted_skill_pairs(t)
    local out = {}
    for k, v in pairs(t or {}) do
        out[#out + 1] = tostring(k) .. "=" .. tostring(v)
    end
    table.sort(out)
    return out
end

local function mode_of(link, cfg)
    local m = link and link.mode
    if m ~= nil and m ~= "inherit" and MODE_GROUPS[m] ~= nil then return m end
    if cfg and cfg.ignore_weapons then return "no_weapon" end
    return "full"
end

-- Canonical string for one build under one mode. Two builds match when their
-- keys are equal, so the key format must be stable across sessions.
local function sig_key(sig, mode)
    if sig == nil then return nil end
    local groups = MODE_GROUPS[mode] or MODE_GROUPS.full
    local parts = {}
    for _, g in ipairs(groups) do
        if g == "armor" then
            parts[#parts + 1] = "A:" .. table.concat(sorted_list(sig.armor), "|")
        elseif g == "charm" then
            parts[#parts + 1] = "C:" .. tostring(sig.charm or "")
        elseif g == "skills" then
            parts[#parts + 1] = "S:" .. table.concat(sorted_skill_pairs(sig.skills), ";")
        elseif g == "weapon" then
            parts[#parts + 1] = "W:" .. tostring(sig.weapon or "")
        end
    end
    return table.concat(parts, "#")
end

-- First link whose key matches the current build. The strictest link wins:
-- links are tried in the order the user arranged them, and a link only
-- matches under its own mode, so a "full" link cannot shadow an "armor" one
-- by accident - the caller can also sort by strictness.
local function resolve_link(sig, links, cfg)
    if sig == nil then return nil, nil, "no build signature" end
    for _, link in ipairs(links or {}) do
        if link.enabled ~= false then
            local mode = mode_of(link, cfg)
            local a, b = sig_key(sig, mode), sig_key(link.sig, mode)
            if a ~= nil and b ~= nil and a == b then
                return link, mode, "matched (" .. mode .. ")"
            end
        end
    end
    return nil, nil, "no link matches this build"
end

-- What applying `contents` would change. Never returns a target the item box
-- cannot cover: `to` is clamped by the stock in the box.
local function compute_diff(contents, pouch, box, mode)
    local changes, missing = {}, {}
    for _, e in ipairs(contents or {}) do
        local have = (pouch and pouch[e.id]) or 0
        local stock = (box and box[e.id]) or 0
        local want = e.count or 0
        local target
        if mode == "topup" then
            if have >= want then target = have else
                target = math.min(want, have + stock)
            end
        else
            target = math.min(want, have + stock)
        end
        if target ~= have then
            changes[#changes + 1] = {
                id = e.id, name = e.name or ("item " .. tostring(e.id)),
                from = have, to = target,
            }
        end
        if target < want then
            missing[#missing + 1] = {
                id = e.id, name = e.name or ("item " .. tostring(e.id)),
                short = want - target,
            }
        end
    end
    return changes, missing
end

-- Does the pouch now hold what the diff promised?
local function diff_satisfied(changes, pouch)
    for _, c in ipairs(changes or {}) do
        local have = (pouch and pouch[c.id]) or 0
        if have < c.to then return false, c end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- game: save data roots
-- ---------------------------------------------------------------------------

local function save_data()
    local sdm = safe(function() return sdk.get_managed_singleton("app.SaveDataManager") end)
    if not sdm then return nil, "no SaveDataManager" end
    local sd = safe(function() return sdm:getCurrentUserSaveData() end)
    if sd then return sd, "getCurrentUserSaveData" end
    local v0 = field_value(sdm, "v0")
    if v0 then return v0, "v0" end
    return nil, "no current user save"
end

local function equip_param()
    local sd = save_data()
    return sd and field_value(sd, "_Equip")
end

local function item_param()
    local sd = save_data()
    return sd and field_value(sd, "_Item")
end

local function equip_mysets()
    return collect(equip_param() and field_value(equip_param(), "_EquipMySet"), 64)
end

local function item_sets()
    local sd = save_data()
    local ims = sd and field_value(sd, "_ItemMySet")
    return collect(ims and field_value(ims, "_Data"), 64)
end

local function pouch_works()
    local ip = item_param()
    return collect(ip and field_value(ip, "_PouchItem"), 64)
end

local function box_works()
    local ip = item_param()
    return collect(ip and field_value(ip, "_BoxItem"), 2000)
end

local function snapshot(works, id_field, count_field)
    local map = {}
    for _, w in ipairs(works or {}) do
        local id = enum_number(field_value(w, id_field))
        local n = enum_number(field_value(w, count_field)) or 0
        if id ~= nil and id ~= 0 and n > 0 then
            map[id] = (map[id] or 0) + n
        end
    end
    return map
end

local function pouch_snapshot()
    return snapshot(pouch_works(), "ItemIdFixed", "Num")
end

local function box_snapshot()
    return snapshot(box_works(), "ItemIdFixed", "Num")
end

-- ---------------------------------------------------------------------------
-- game: item names
-- ---------------------------------------------------------------------------

local item_name_cache = {}

local function localized(guid)
    if guid == nil then return nil end
    local msg = safe(sdk.find_type_definition, "via.gui.message")
    local get = msg and safe(function() return msg:get_method("get(System.Guid)") end)
    return get and safe_str(safe(function() return get:call(nil, guid) end)) or nil
end

local function item_name(fixed_id)
    if fixed_id == nil or fixed_id == 0 then return nil end
    if item_name_cache[fixed_id] ~= nil then
        return item_name_cache[fixed_id] or nil
    end
    local typed = safe(sdk.find_type_definition, "app.user_data.ItemData")
    local get_data = typed and safe(function()
        return typed:get_method("getDataByFixedId(System.Int32)")
    end)
    local data = get_data and safe(function() return get_data:call(nil, fixed_id) end)
    local name = nil
    if data ~= nil then
        name = localized(field_value(data, "RawName") or field_value(data, "_RawName"))
            or safe_str(field_value(data, "Name"))
    end
    item_name_cache[fixed_id] = name or false
    return name
end

-- Local player: same scan meal-buffet uses (user-controlled character, never
-- the quest host by default).
local function instanced_array(pm)
    local list = field_value(pm, "_InstancedPlayerList")
        or field_value(pm, "<InstancedPlayerList>k__BackingField")
        or field_value(pm, "_PlayerList")
    if not list then return nil end
    return field_value(list, "_Array")
        or field_value(list, "<Array>k__BackingField")
        or field_value(list, "_Items")
        or list
end

local function character_of(inst, pi)
    for _, name in ipairs({ "get_Character", "get_Hunter", "get_Player" }) do
        local v = pi and call_method(pi, name)
        if v ~= nil and v ~= 0 then return v end
    end
    for _, name in ipairs({ "get_Hunter", "get_Character" }) do
        local v = call_method(inst, name)
        if v ~= nil and v ~= 0 then return v end
    end
    return field_value(inst, "<Character>k__BackingField") or field_value(inst, "_Character")
end

local last_character_source = nil

local function local_character()
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    if not pm then
        last_character_source = "no_player_manager"
        return nil, nil, "no_player_manager"
    end
    local arr = instanced_array(pm)
    if arr then
        for i = 0, 7 do
            local inst = safe(function() return arr[i] end)
            if inst == nil then break end
            local pi = call_method(inst, "get_PlayerInfo")
            local ch = character_of(inst, pi)
            local st = ch and call_method(ch, "get_HunterStatus")
            if st and call_method(st, "get_IsUserControl") == true
                and call_method(st, "get_IsNpc") ~= true then
                last_character_source = "user_control"
                return ch, st, "user_control"
            end
        end
    end
    -- Hub / loading: the master player is the local hunter when solo.
    local master = safe(function() return pm:getMasterPlayer() end)
    if master then
        local ch = field_value(master, "<Character>k__BackingField")
            or field_value(master, "_Character")
        local st = ch and call_method(ch, "get_HunterStatus")
        if st then
            last_character_source = "master_player"
            return ch, st, "master"
        end
    end
    last_character_source = "no_local_character"
    return nil, nil, "no_local_character"
end

-- ---------------------------------------------------------------------------
-- game: build signature
-- ---------------------------------------------------------------------------

-- One armour/weapon entry -> a stable short key. The save-data works store
-- their identity in FreeVal0..2 with Category/Category_Gender telling what
-- they are (app.ArmorDef.SERIES / ARMOR_PARTS for armour, weapon type + id for
-- weapons). Live catalogue entries wrap the same shape, so retry one level
-- inside a wrapper before giving up.
local function piece_key(obj, depth)
    if obj == nil then return nil end
    depth = depth or 0
    if depth > 3 then return nil end
    local cat = enum_number(field_value(obj, "Category"))
    local catg = enum_number(field_value(obj, "Category_Gender"))
    local category = cat or catg
    if category ~= nil then
        local f0 = enum_number(field_value(obj, "FreeVal0")) or 0
        local f1 = enum_number(field_value(obj, "FreeVal1")) or 0
        local f2 = enum_number(field_value(obj, "FreeVal2")) or 0
        local f3 = enum_number(field_value(obj, "FreeVal3")) or 0
        local bonus_create = enum_number(field_value(obj, "BonusByCreating")) or 0
        local bonus_grind = enum_number(field_value(obj, "BonusByGrinding")) or 0
        local grind = enum_number(field_value(obj, "GrindingNum")) or 0
        -- category low byte, then what the game itself persists: enough to
        -- tell two weapons or two armour pieces apart, including Artian rolls.
        return string.format("%d:%d:%d:%d:%d:%d:%d:%d",
            math.floor(category) % 256, f0, f1, f2, f3,
            bonus_create, bonus_grind, grind)
    end
    for _, name in ipairs({ "EquipWork", "Work", "Data", "Param", "Info",
                            "EquipInfo", "ItemData", "cData" }) do
        local inner = field_value(obj, name)
        if inner ~= nil and type(inner) == "userdata" then
            local k = piece_key(inner, depth + 1)
            if k then return k end
        end
    end
    for _, name in ipairs({ "_EquipId", "EquipId", "_ItemId", "ItemId", "_Id", "Id" }) do
        local id = enum_number(field_value(obj, name))
        if id ~= nil and id ~= 0 then
            return "id:" .. tostring(id)
        end
    end
    return nil
end

local function category_of(obj)
    local c = enum_number(field_value(obj, "Category"))
    if c ~= nil then return math.floor(c) % 256 end
    local cg = enum_number(field_value(obj, "Category_Gender"))
    if cg ~= nil then return math.floor(cg) % 256 end
    return nil
end

-- Armour category bits: 0 with the gender in bit 0, so 0 and 1 are armour.
local function is_armor_category(cat)
    return cat == 0 or cat == 1
end

local WEAPON_CATEGORY = 13

-- The armour actually worn, from the live catalogue (cPlayerCatalogHolder).
-- This is the only source that survives a mid-quest weapon swap: the saved
-- my-set index does not follow the armour when only the weapon changes.
local function catalog_pieces()
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    local catalog = pm and safe(function() return pm:get_Catalog() end)
    if catalog == nil then return nil, "no catalog" end
    local armor = collect(field_value(catalog, "cArmorList"), 8)
    if #armor == 0 then return nil, "cArmorList empty" end
    local pieces = {}
    for _, p in ipairs(armor) do
        local key = piece_key(p)
        if key then pieces[#pieces + 1] = key end
    end
    if #pieces == 0 then return nil, "cArmorList unreadable" end

    local charm = nil
    local charm_obj = field_value(catalog, "cWpCharm")
    if charm_obj ~= nil then
        local main = enum_number(field_value(charm_obj, "MainCharm"))
        if main ~= nil and main ~= 0 then
            charm = "charm:" .. tostring(main)
        else
            charm = piece_key(charm_obj)
        end
    end
    return { armor = pieces, charm = charm }, "catalog"
end

-- Fallback: the game remembers the active my-set index in _EquipIndex.
-- Index[weapon type] is the equipment loadout in use for that type on the
-- current build; a single-entry array is used as the current set too.
-- Note: this path does follow a warrior's last used set per weapon type, so it
-- can be stale after a mid-quest weapon swap - the catalogue is preferred.
local function save_pieces()
    local ep = equip_param()
    if ep == nil then return nil, "no equip param" end
    local sets = equip_mysets()
    if #sets == 0 then return nil, "no equipment my-sets" end
    local idx_holder = field_value(ep, "_EquipIndex")
    local idx = collect(idx_holder and field_value(idx_holder, "Index"), 32)
    local pick
    local ch = local_character()
    local wtype = nil
    if ch ~= nil then
        local weapon = call_method(ch, "get_Weapon")
        wtype = weapon and enum_number(field_value(weapon, "_WpType"))
    end
    if wtype ~= nil and idx[wtype + 1] ~= nil then
        pick = enum_number(idx[wtype + 1])
    end
    if pick == nil and #idx >= 1 then pick = enum_number(idx[1]) end
    if pick == nil then return nil, "no current my-set index" end
    local set = sets[pick + 1] or sets[1]
    if set == nil then return nil, "my-set index out of range" end
    local armor = {}
    for _, work in ipairs(collect(field_value(set, "_MysetEquipWork"), 16)) do
        local key = piece_key(work)
        local cat = category_of(work)
        if key and cat ~= WEAPON_CATEGORY then armor[#armor + 1] = key end
    end
    if #armor == 0 then return nil, "my-set has no armour" end
    local charm_obj = field_value(ep, "_CharmEquipped")
    local charm = nil
    if charm_obj ~= nil then
        local main = enum_number(field_value(charm_obj, "MainCharm"))
        charm = "charm:" .. tostring(main or 0)
    end
    return { armor = armor, charm = charm }, "save_index"
end

-- Resolved skill levels of the local hunter's gear:
-- cHunterSkill._EquipDataHolderRef._EquipSkillDataArray[].{_Skill,_SkillLv}
-- (_SkillLv is an sdk ValueType stored as a small negative int32).
local skill_source_error = nil

local function skill_lv_value(raw)
    if raw == nil then return nil end
    local n = enum_number(raw)
    if n ~= nil and n >= 0 and n <= 20 then return math.floor(n) end
    if type(raw) == "userdata" then
        local b = safe(function() return raw:read_byte(0) end)
        if type(b) == "number" then
            if b > 127 then b = b - 256 end
            local lv = math.abs(b)
            if lv >= 1 and lv <= 20 then return lv end
        end
    end
    return nil
end

local function current_skills()
    local _, status = local_character()
    local skill = status and field_value(status, "_Skill")
    if skill == nil then
        skill_source_error = "no _Skill on HunterStatus"
        return nil
    end
    local holder = field_value(skill, "_EquipDataHolderRef")
    local arr = holder and field_value(holder, "_EquipSkillDataArray")
    if arr == nil then
        skill_source_error = "no _EquipSkillDataArray"
        return nil
    end
    local map = {}
    for _, e in ipairs(collect(arr, 256)) do
        local id = enum_number(field_value(e, "_Skill"))
            or enum_number(field_value(e, "_SkillId"))
        if id ~= nil and id ~= 0 then
            local lv = skill_lv_value(field_value(e, "_SkillLv")
                or field_value(e, "_Level"))
            if lv ~= nil and lv > 0 then
                map[tostring(id)] = lv
            end
        end
    end
    skill_source_error = nil
    return map
end

local WEAPON_FIELDS = { "_WeaponLongSword", "_WeaponShortSword", "_WeaponTwinSword",
    "_WeaponTachi", "_WeaponHammer", "_WeaponWhistle", "_WeaponLance", "_WeaponGunLance",
    "_WeaponSlashAxe", "_WeaponChargeAxe", "_WeaponRod", "_WeaponBow",
    "_WeaponHeavyBowgun", "_WeaponLightBowgun" }
local weapon_arrays = nil
local weapon_name_cache = {}

local function get_weapon_arrays()
    if weapon_arrays ~= nil then return weapon_arrays end
    weapon_arrays = {}
    local vdm = safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
    local equipData = vdm and safe(function() return vdm._Setting._EquipDatas end)
    if equipData then
        for i, fname in ipairs(WEAPON_FIELDS) do
            local arr = safe(function() return equipData[fname] end)
            local list = {}
            if arr then
                list = collect(safe(function() return arr:call("get_Values") end), 400)
            end
            weapon_arrays[i - 1] = list
        end
    end
    return weapon_arrays
end

-- get_WeaponID()/FreeVal1 is 0-based into the type's array; the collected
-- table is 1-based, hence the +1 (the same off-by-one hunt_dumper fixed).
local function weapon_name(wtype, wid)
    if wtype == nil or wid == nil then return nil end
    local key = tostring(wtype) .. ":" .. tostring(wid)
    if weapon_name_cache[key] ~= nil then return weapon_name_cache[key] or nil end
    local list = get_weapon_arrays()[wtype]
    local entry = list and (list[wid + 1] or list[wid])
    if entry == nil and list then
        for _, e in ipairs(list) do
            local ix = enum_number(field_value(e, "_Index"))
            if ix ~= nil and (ix == wid + 1 or ix == wid) then entry = e break end
        end
    end
    local name = entry and localized(field_value(entry, "_Name"))
    weapon_name_cache[key] = name or false
    return name
end

local last_gear_source = nil

-- Weapon key: the worn weapon from the catalogue pack when readable, falling
-- back to type + id plus the saved work's Artian fields. The key carries the
-- upgrades, so the same weapon with different rolls (or a different element)
-- counts as a different weapon, which is what the client asked for.
local function catalog_weapon_key(wtype)
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    local catalog = pm and safe(function() return pm:get_Catalog() end)
    if catalog == nil or wtype == nil then return nil end
    local packs = field_value(catalog, "cWeaponTypePack")
    if packs == nil then return nil end
    local list = collect(packs, 32)
    local pack = nil
    if #list > 0 then
        pack = list[wtype + 1] or list[wtype]
    else
        pack = packs
    end
    return pack and piece_key(pack) or nil
end

local function save_weapon_key(wid, wtype)
    local ep = equip_param()
    local matches = {}
    for _, work in ipairs(collect(ep and field_value(ep, "_EquipBox"), 1000)) do
        if category_of(work) == WEAPON_CATEGORY then
            local f1 = enum_number(field_value(work, "FreeVal1"))
            local f0 = enum_number(field_value(work, "FreeVal0"))
            if wid ~= nil and f1 == wid and (wtype == nil or f0 == nil or f0 == wtype) then
                matches[#matches + 1] = work
            end
        end
    end
    -- only trust it when the id is unambiguous in the box
    if #matches == 1 then return piece_key(matches[1]) end
    return nil
end

local function current_weapon()
    local ch = local_character()
    if ch == nil then return nil, nil end
    local weapon = call_method(ch, "get_Weapon")
    local wtype = weapon and enum_number(field_value(weapon, "_WpType"))
    local wid = enum_number(call_method(ch, "get_WeaponID"))
    if wtype == nil and wid == nil then return nil, nil end
    local base = string.format("13:%s:%s", tostring(wtype), tostring(wid))
    local extra = catalog_weapon_key(wtype) or save_weapon_key(wid, wtype)
    local key = extra and (base .. ":" .. extra) or base
    local label = weapon_name(wtype, wid)
    if label == nil then
        label = string.format("weapon type %s - #%s", tostring(wtype), tostring(wid))
    end
    return key, label
end

-- The build in hand: armour keys (sorted, one per piece), charm key, resolved
-- skills, and the weapon key described above.
local function current_signature()
    local gear, source = catalog_pieces()
    if gear == nil then
        gear, source = save_pieces()
    end
    last_gear_source = source
    if gear == nil then return nil, tostring(source) end
    local skills = current_skills()
    if skills == nil then return nil, skill_source_error or "no skills" end
    local armor = sorted_list(gear.armor)
    local weapon, weapon_label = current_weapon()
    local skill_count = 0
    for _ in pairs(skills) do skill_count = skill_count + 1 end
    return {
        armor = armor,
        charm = gear.charm,
        skills = skills,
        weapon = weapon,
        weapon_label = weapon_label,
        armor_count = #armor,
        skill_count = skill_count,
    }, source
end

-- Game loadout name for the build in hand (label only; never used to match).
-- Compares the armour pieces, because the charm key from the catalogue and the
-- charm entry inside a my-set are not the same shape.
local loadout_name_cache = { key = nil, name = nil, index = nil }

local function game_loadout_name(sig)
    if sig == nil then return nil end
    local want = sig_key({ armor = sig.armor }, "armor")
    if loadout_name_cache.key == want then
        return loadout_name_cache.name, loadout_name_cache.index
    end
    for i, set in ipairs(equip_mysets()) do
        local param = field_value(set, "_MysetParam")
        local name = param and safe_str(field_value(param, "MysetName"))
        if name == nil or name == "" then name = "Set " .. tostring(i) end
        local armor = {}
        for _, work in ipairs(collect(field_value(set, "_MysetEquipWork"), 16)) do
            local key = piece_key(work)
            if key and category_of(work) ~= WEAPON_CATEGORY then
                armor[#armor + 1] = key
            end
        end
        if #armor > 0 and sig_key({ armor = armor }, "armor") == want then
            loadout_name_cache = { key = want, name = name, index = i }
            return name, i
        end
    end
    loadout_name_cache = { key = want, name = nil, index = nil }
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- game: item sets, pouch, apply
-- ---------------------------------------------------------------------------

local function item_set_contents(index)
    local set = item_sets()[index]
    if set == nil then return nil end
    local out = {}
    for _, work in ipairs(collect(field_value(set, "_PouchItem"), 64)) do
        local id = enum_number(field_value(work, "ItemIdFixed"))
        local n = enum_number(field_value(work, "Num")) or 0
        if id ~= nil and id ~= 0 and n > 0 then
            out[#out + 1] = { id = id, count = n, name = item_name(id) }
        end
    end
    return out
end

local function item_set_name(index)
    local set = item_sets()[index]
    if set == nil then return nil end
    local name = safe_str(field_value(set, "Name"))
    if name == nil or name == "" then name = "Item set " .. tostring(index) end
    return name
end

-- Top-up: bring the pouch up to what the item set asks for, taking from the
-- box and never exceeding the set's own counts. This is the last-resort path
-- when the game's own apply call cannot be found on this build.
local function write_topup(diff)
    local pouch = pouch_works()
    local box = box_works()
    if #pouch == 0 then return false, "no pouch" end

    -- index the box per item id so we can decrement the right slots
    local box_by_id = {}
    for _, w in ipairs(box) do
        local id = enum_number(field_value(w, "ItemIdFixed"))
        local n = enum_number(field_value(w, "Num")) or 0
        if id and id ~= 0 and n > 0 then
            box_by_id[id] = box_by_id[id] or {}
            box_by_id[id][#box_by_id[id] + 1] = w
        end
    end

    local moved = 0
    for _, c in ipairs(diff or {}) do
        local need = c.to - c.from
        if need > 0 then
            -- existing pouch slots for the item first
            local placed = 0
            for _, w in ipairs(pouch) do
                if placed >= need then break end
                local id = enum_number(field_value(w, "ItemIdFixed"))
                if id == c.id then
                    local have = enum_number(field_value(w, "Num")) or 0
                    local add = math.min(need - placed, math.max(0, c.to - have))
                    if add > 0 and write_field(w, "Num", have + add) then
                        placed = placed + add
                    end
                end
            end
            -- then empty slots
            if placed < need then
                for _, w in ipairs(pouch) do
                    if placed >= need then break end
                    local id = enum_number(field_value(w, "ItemIdFixed")) or 0
                    if id == 0 then
                        local add = need - placed
                        if write_field(w, "ItemIdFixed", c.id)
                            and write_field(w, "Num", add) then
                            placed = placed + add
                        end
                    end
                end
            end
            -- take what was placed out of the box
            local left = placed
            for _, w in ipairs(box_by_id[c.id] or {}) do
                if left <= 0 then break end
                local n = enum_number(field_value(w, "Num")) or 0
                local take = math.min(left, n)
                if take > 0 then
                    if n - take <= 0 then
                        write_field(w, "ItemIdFixed", 0)
                        write_field(w, "Num", 0)
                    else
                        write_field(w, "Num", n - take)
                    end
                    left = left - take
                    moved = moved + take
                end
            end
        end
    end
    return true, moved > 0 and ("topped up " .. tostring(moved)) or "nothing to move"
end

-- The game's own item-set apply, found by name: the exact signature is not
-- documented, so candidates are tried in order and every attempt is verified
-- by the caller.
local apply_candidates_cache = nil

local function method_param_count(m)
    return #(safe(function() return m:get_param_types() end) or {})
end

local function method_is_static(m)
    return safe(function() return m:is_static() end) == true
end

local function apply_candidates()
    if apply_candidates_cache ~= nil then return apply_candidates_cache end
    local out = {}
    local type_names = { "app.ItemMySetUtil", "app.ItemPouchUtil", "app.ItemUtil" }
    local verbs = { "apply", "load", "restock", "refill", "change", "call", "use", "set" }

    -- Score names so the most plausible call runs first: an explicit item
    -- my-set apply beats a generic pouch helper, which beats anything else.
    local function score(low)
        local has_verb = false
        for _, v in ipairs(verbs) do
            if string.find(low, v, 1, true) then has_verb = true break end
        end
        if not has_verb then return 0 end
        if string.find(low, "myset", 1, true) then return 3 end
        if string.find(low, "itemset", 1, true) then return 3 end
        if string.find(low, "item", 1, true) then return 2 end
        if string.find(low, "pouch", 1, true) then return 1 end
        return 0
    end

    for _, tn in ipairs(type_names) do
        local td = safe(sdk.find_type_definition, tn)
        if td then
            for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
                local name = safe(function() return m:get_name() end) or ""
                local low = string.lower(name)
                local params = method_param_count(m)
                local first3 = string.sub(low, 1, 3)
                local s = score(low)
                if s > 0
                    and first3 ~= "get" and first3 ~= "is_" and first3 ~= "has"
                    and (params == 1 or params == 2) then
                    out[#out + 1] = {
                        type = tn, name = name, params = params,
                        static = method_is_static(m), score = s,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.name < b.name
    end)
    apply_candidates_cache = out
    return out
end

local function call_candidate(cand, index)
    local td = safe(sdk.find_type_definition, cand.type)
    local m = td and safe(function() return td:get_method(cand.name) end)
    if not m then return false, "method gone" end
    -- try the display index and the 0-based one; the pouch check decides
    local tries = { index, index - 1 }
    for _, i in ipairs(tries) do
        local ok = safe(function()
            if cand.static then
                if cand.params == 1 then m:call(nil, i)
                else m:call(nil, i, false) end
            else
                local obj = item_param() or save_data()
                if obj == nil then return nil end
                if cand.params == 1 then m:call(obj, i)
                else m:call(obj, i, false) end
            end
            return true
        end)
        if ok then return true, cand.name .. "(" .. tostring(i) .. ")" end
    end
    return false, "call failed"
end

-- ---------------------------------------------------------------------------
-- runtime state
-- ---------------------------------------------------------------------------

local state = {
    frames = 0,
    in_quest = nil,
    last_in_quest = nil,
    quest_seq = 0,
    accept_done_seq = -1,
    hub_frames = 0,
    hub_pending = false,
    task = nil,          -- { link, reason, diff, phase, strategies, try, wait, attempts }
    notice = nil,        -- { text, until_frame }
    last_result = "(idle)",
    last_match = nil,    -- { label, mode, item_set_name }
    last_sig = nil,
    last_sig_error = nil,
    last_gear_source = nil,
    dirty = true,
}

local function notify(text)
    state.last_result = text
    if config.notify and draw ~= nil then
        state.notice = { text = text, until_frame = state.frames + 360 }
    end
    if config.debug then log.info("[LinkedRestock] " .. text) end
end

-- ---------------------------------------------------------------------------
-- config persistence
-- ---------------------------------------------------------------------------

local function normalize_link(l)
    if type(l) ~= "table" then return nil end
    local link = {
        id = type(l.id) == "string" and l.id or tostring(os.time()) .. math.random(1000),
        label = type(l.label) == "string" and l.label or "build",
        mode = type(l.mode) == "string" and l.mode or "inherit",
        item_set = type(l.item_set) == "number" and math.floor(l.item_set) or nil,
        item_set_name = type(l.item_set_name) == "string" and l.item_set_name or nil,
        apply_mode = (l.apply_mode == "topup") and "topup" or "exact",
        enabled = l.enabled ~= false,
        sig = nil,
    }
    if type(l.sig) == "table" then
        local sig = {
            armor = type(l.sig.armor) == "table" and l.sig.armor or {},
            charm = l.sig.charm,
            skills = type(l.sig.skills) == "table" and l.sig.skills or {},
            weapon = l.sig.weapon,
            weapon_label = l.sig.weapon_label,
        }
        sig.armor_count = #sig.armor
        local n = 0
        for _ in pairs(sig.skills) do n = n + 1 end
        sig.skill_count = n
        link.sig = sig
    end
    if link.sig == nil or #link.sig.armor == 0 then return nil end
    return link
end

local function load_config()
    local cfg = safe(function() return json.load_file(CONFIG_FILE) end)
    local base = default_config()
    if type(cfg) ~= "table" then config = base return end
    if type(cfg.enabled) == "boolean" then base.enabled = cfg.enabled end
    if type(cfg.debug) == "boolean" then base.debug = cfg.debug end
    if type(cfg.ignore_weapons) == "boolean" then base.ignore_weapons = cfg.ignore_weapons end
    if type(cfg.notify_missing) == "boolean" then base.notify_missing = cfg.notify_missing end
    if type(cfg.notify) == "boolean" then base.notify = cfg.notify end
    if type(cfg.triggers) == "table" then
        if type(cfg.triggers.quest_accept) == "boolean" then
            base.triggers.quest_accept = cfg.triggers.quest_accept
        end
        if type(cfg.triggers.hub_return) == "boolean" then
            base.triggers.hub_return = cfg.triggers.hub_return
        end
    end
    if type(cfg.hub_delay_frames) == "number" then
        base.hub_delay_frames = math.max(0, math.min(1800, math.floor(cfg.hub_delay_frames)))
    end
    if type(cfg.retry_limit) == "number" then
        base.retry_limit = math.max(1, math.min(6, math.floor(cfg.retry_limit)))
    end
    if type(cfg.default_item_set) == "number" then
        base.default_item_set = math.floor(cfg.default_item_set)
    end
    if type(cfg.fallback_by_weapon) == "table" then
        for k, v in pairs(cfg.fallback_by_weapon) do
            if type(v) == "number" then
                base.fallback_by_weapon[tostring(k)] = math.floor(v)
            end
        end
    end
    if type(cfg.links) == "table" then
        base.links = {}
        for _, l in ipairs(cfg.links) do
            local n = normalize_link(l)
            if n then base.links[#base.links + 1] = n end
        end
    end
    config = base
end

local function save_config()
    safe(function()
        json.dump_file(CONFIG_FILE, {
            version = VERSION,
            enabled = config.enabled,
            debug = config.debug,
            ignore_weapons = config.ignore_weapons,
            notify_missing = config.notify_missing,
            notify = config.notify,
            triggers = config.triggers,
            hub_delay_frames = config.hub_delay_frames,
            retry_limit = config.retry_limit,
            default_item_set = config.default_item_set,
            fallback_by_weapon = config.fallback_by_weapon,
            links = config.links,
        })
    end)
end

-- ---------------------------------------------------------------------------
-- apply pipeline
-- ---------------------------------------------------------------------------

local function strategies_for(link, diff, index)
    local list = {}
    for _, cand in ipairs(apply_candidates()) do
        list[#list + 1] = {
            label = cand.type .. "." .. cand.name,
            run = function() return call_candidate(cand, index) end,
        }
    end
    list[#list + 1] = {
        label = "top-up from the item box",
        run = function() return write_topup(diff) end,
    }
    return list
end

local function start_task(link, reason)
    local index = link.item_set
    if index == nil then
        notify("link has no item set assigned")
        return false
    end
    local contents = item_set_contents(index)
    if contents == nil then
        notify("item set " .. tostring(index) .. " is missing")
        return false
    end
    local mode = (link.apply_mode == "topup") and "topup" or "exact"
    local pouch, box = pouch_snapshot(), box_snapshot()
    local diff, missing = compute_diff(contents, pouch, box, mode)
    state.task = {
        link = link,
        reason = reason,
        diff = diff,
        missing = missing,
        mode = mode,
        strategies = strategies_for(link, diff, index),
        try = 1,
        attempts = 0,
        wait = 0,
        phase = "run",
    }
    if #diff == 0 then
        state.task = nil
        notify("pouch already stocked for " .. tostring(link.item_set_name or index))
        return true
    end
    return true
end

local function finish_task(ok, detail)
    local task = state.task
    state.task = nil
    if task == nil then return end
    local label = tostring(task.link.item_set_name or task.link.item_set)
    if ok then
        local parts = { "restocked " .. label }
        if #task.diff > 0 then
            parts[#parts + 1] = "(" .. tostring(#task.diff) .. " items)"
        end
        if config.notify_missing and #task.missing > 0 then
            local names = {}
            for i, m in ipairs(task.missing) do
                if i > 3 then names[#names + 1] = "..." break end
                names[#names + 1] = tostring(m.name)
            end
            parts[#parts + 1] = "- missing " .. table.concat(names, ", ")
        end
        if detail then parts[#parts + 1] = "- " .. detail end
        notify(table.concat(parts, " "))
    else
        notify("restock failed for " .. label .. (detail and (" - " .. detail) or ""))
    end
end

local function tick_task()
    local task = state.task
    if task == nil then return end
    if task.wait > 0 then
        task.wait = task.wait - 1
        return
    end
    if task.phase == "run" then
        local strat = task.strategies[task.try]
        if strat == nil then
            finish_task(false, "every apply path failed")
            return
        end
        local ok = safe(strat.run)
        if config.debug then
            log.info("[LinkedRestock] try " .. strat.label .. " -> " .. tostring(ok))
        end
        task.phase = "verify"
        task.wait = 60 -- one second: some calls apply on the next frame
        return
    end
    -- verify
    local pouch = pouch_snapshot()
    local ok, missing_change = diff_satisfied(task.diff, pouch)
    if ok then
        finish_task(true, nil)
        return
    end
    task.try = task.try + 1
    task.attempts = task.attempts + 1
    task.phase = "run"
    task.wait = 0
    if task.attempts >= config.retry_limit * (#task.strategies + 1) then
        local detail = missing_change
            and ("still short of " .. tostring(missing_change.name)) or nil
        finish_task(false, detail)
    end
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------

local function in_quest()
    local mm = safe(function() return sdk.get_managed_singleton("app.MissionManager") end)
    if mm == nil then return nil end
    local v = call_method(mm, "get_IsPlayingQuest")
    if v == nil then v = call_method(mm, "get_IsActiveQuest") end
    return v
end

local function current_weapon_type()
    local ch = local_character()
    local weapon = ch and call_method(ch, "get_Weapon")
    return weapon and enum_number(field_value(weapon, "_WpType")) or nil
end

local function fire(reason)
    if not config.enabled then return end
    local sig, err = current_signature()
    if sig == nil then
        if state.dirty then
            state.dirty = false
            notify("cannot read the current build: " .. tostring(err))
        end
        return false
    end
    state.last_sig = sig
    local link, mode, why = resolve_link(sig, config.links, config)
    if link == nil then
        -- fallbacks: weapon type, then default item set
        local wt = current_weapon_type()
        local idx = wt ~= nil and config.fallback_by_weapon[tostring(wt)] or nil
        if idx == nil then idx = config.default_item_set end
        if idx == nil then
            state.last_match = nil
            if state.dirty then
                state.dirty = false
                notify("no link for this build (" .. tostring(why) .. ")")
            end
            return false
        end
        link = { item_set = idx, item_set_name = item_set_name(idx),
                 apply_mode = "exact", mode = "armor",
                 label = "fallback set " .. tostring(idx) }
        why = "fallback"
    end
    state.last_match = {
        label = link.label, mode = why,
        item_set_name = link.item_set_name or item_set_name(link.item_set),
        item_set = link.item_set,
    }
    local ok, err2 = start_task(link, reason)
    if not ok then
        notify("cannot restock: " .. tostring(err2 or "unknown"))
        return false
    end
    return true
end

local function poll()
    local q = in_quest()
    if q == nil then return end

    -- first reading after load: remember it, do not treat it as a transition
    if state.last_in_quest == nil then
        state.last_in_quest = q
        return
    end

    if q ~= state.last_in_quest then
        if q == true then
            state.quest_seq = state.quest_seq + 1
            state.hub_pending = false
            if config.triggers.quest_accept and state.accept_done_seq ~= state.quest_seq then
                state.accept_done_seq = state.quest_seq
                state.dirty = true
                fire("quest accepted")
            end
        else
            -- the quest is over: wait until the game itself is out of the quest
            -- (IsActiveQuest stays true through the results screen) and then a
            -- beat longer, so the return flow cannot overwrite the pouch
            state.hub_frames = config.hub_delay_frames
            state.hub_pending = config.triggers.hub_return
        end
        state.last_in_quest = q
    end

    if state.hub_pending and q == false then
        local mm = safe(function() return sdk.get_managed_singleton("app.MissionManager") end)
        local still_active = mm and call_method(mm, "get_IsActiveQuest")
        if still_active == true then
            -- results screen / return in progress: keep waiting
            state.hub_frames = config.hub_delay_frames
            return
        end
        if state.hub_frames > 0 then
            state.hub_frames = state.hub_frames - 1
        else
            state.hub_pending = false
            state.dirty = true
            fire("back in the hub")
        end
    end
end

local function on_frame()
    state.frames = state.frames + 1
    state.last_gear_source = last_gear_source
    local ok, err = pcall(tick_task)
    if not ok and config.debug then
        log.warn("[LinkedRestock] task: " .. tostring(err))
    end
    if (state.frames % 30) == 0 then
        local ok2, err2 = pcall(poll)
        if not ok2 and config.debug then
            log.warn("[LinkedRestock] poll: " .. tostring(err2))
        end
    end
    if state.notice ~= nil and state.frames < state.notice.until_frame and draw ~= nil then
        safe(function()
            draw.text(state.notice.text, 40, 120, 0xFFFFFFFF)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local ui = {
    set_index = 0,     -- combo index for the "link current build" picker
    mode_index = 0,    -- 0 = inherit
    new_label = "",
    show_preview = nil,   -- { link=, diff=, missing= }
    show_diag = false,
}

local function item_set_labels()
    local labels = {}
    for i, set in ipairs(item_sets()) do
        local name = safe_str(field_value(set, "Name"))
        if name == nil or name == "" then name = "Item set " .. tostring(i) end
        labels[#labels + 1] = name
    end
    if #labels == 0 then labels[1] = "(no item sets found)" end
    return labels
end

local function mode_labels()
    return { MODE_LABELS.inherit, MODE_LABELS.full, MODE_LABELS.no_weapon,
             MODE_LABELS.gear, MODE_LABELS.armor }
end

local function mode_from_index(i)
    return MODES[i] or "inherit"
end

local function mode_to_index(mode)
    if mode == nil or mode == "inherit" then return 0 end
    for i, m in ipairs(MODES) do
        if m == mode then return i end
    end
    return 0
end

local function ui_text_colored(text, color)
    local ok = safe(function() imgui.text_colored(text, color) return true end)
    if ok ~= true then imgui.text(text) end
end

local function preview(link)
    local contents = item_set_contents(link.item_set)
    if contents == nil then
        notify("item set " .. tostring(link.item_set) .. " is missing")
        return
    end
    local mode = (link.apply_mode == "topup") and "topup" or "exact"
    local diff, missing = compute_diff(contents, pouch_snapshot(), box_snapshot(), mode)
    ui.show_preview = { link = link, diff = diff, missing = missing, mode = mode }
end

local function draw_preview()
    local p = ui.show_preview
    if p == nil then return end
    imgui.separator()
    imgui.text("Preview - " .. tostring(p.link.item_set_name or p.link.item_set)
        .. " - " .. (p.mode == "topup" and "top up" or "exact set"))
    if #p.diff == 0 then
        imgui.text("nothing would change")
    else
        for _, c in ipairs(p.diff) do
            imgui.text(string.format("  %s  %d -> %d", tostring(c.name), c.from, c.to))
        end
    end
    if #p.missing > 0 then
        local names = {}
        for _, m in ipairs(p.missing) do
            names[#names + 1] = tostring(m.name) .. " x" .. tostring(m.short)
        end
        ui_text_colored("not in the item box: " .. table.concat(names, ", "), 0xFF8080FF)
    end
    if imgui.button("Apply this now##apply_preview") then
        state.dirty = true
        start_task(p.link, "manual")
    end
    imgui.same_line()
    if imgui.button("Close##close_preview") then ui.show_preview = nil end
end

local function draw_link_row(link, i, labels)
    local changed = false
    if imgui.checkbox("##on" .. i, link.enabled ~= false) then
        link.enabled = not link.enabled
        changed = true
    end
    imgui.same_line()
    imgui.text(tostring(link.label))
    imgui.same_line()

    local sel = (link.item_set or 1) - 1
    local c, pick = imgui.combo("##set" .. i, sel, labels)
    if c then
        link.item_set = pick + 1
        link.item_set_name = item_set_name(link.item_set)
        changed = true
    end
    imgui.same_line()
    local mc, mi = imgui.combo("##mode" .. i, mode_to_index(link.mode), mode_labels())
    if mc then
        link.mode = mode_from_index(mi)
        changed = true
    end
    imgui.same_line()
    if imgui.button("Preview##p" .. i) then preview(link) end
    imgui.same_line()
    if imgui.button("Apply##a" .. i) then
        state.dirty = true
        start_task(link, "manual")
    end
    imgui.same_line()
    if imgui.button("Remove##r" .. i) then
        table.remove(config.links, i)
        changed = true
    end
    return changed
end

local function draw_ui()
    if not imgui.tree_node("Linked Restock v" .. VERSION) then return end

    local changed = false

    local c1, v1 = imgui.checkbox("Enabled", config.enabled)
    if c1 then config.enabled = v1 changed = true end
    imgui.same_line()
    local c2, v2 = imgui.checkbox("Debug log", config.debug)
    if c2 then config.debug = v2 changed = true end

    local c3, v3 = imgui.checkbox("Ignore weapons (match armour + skills only)", config.ignore_weapons)
    if c3 then config.ignore_weapons = v3 changed = true end
    imgui.same_line()
    local c4, v4 = imgui.checkbox("Notify missing items", config.notify_missing)
    if c4 then config.notify_missing = v4 changed = true end

    imgui.separator()
    imgui.text("Restock when:")
    local t1, tv1 = imgui.checkbox("Quest accepted", config.triggers.quest_accept)
    if t1 then config.triggers.quest_accept = tv1 changed = true end
    imgui.same_line()
    local t2, tv2 = imgui.checkbox("Back in the hub", config.triggers.hub_return)
    if t2 then config.triggers.hub_return = tv2 changed = true end
    imgui.same_line()
    local t3, tv3 = imgui.checkbox("On-screen notice", config.notify)
    if t3 then config.notify = tv3 changed = true end

    imgui.separator()
    -- lazily read the build once when the panel is first opened, so the user
    -- does not have to wait for a trigger to see what the mod sees
    if state.last_sig == nil and not state.sig_attempted then
        state.sig_attempted = true
        local sig = current_signature()
        if sig ~= nil then state.last_sig = sig end
    end
    if state.last_sig ~= nil then
        local sig = state.last_sig
        imgui.text(string.format("Current build: %d armour - charm %s - %d skills - %s",
            sig.armor_count or 0, tostring(sig.charm or "-"),
            sig.skill_count or 0, tostring(sig.weapon_label or "no weapon")))
        local name, idx = game_loadout_name(sig)
        imgui.text("Game loadout: " .. (name or "not one of the saved loadouts")
            .. (idx and (" (#" .. tostring(idx) .. ")") or ""))
    else
        imgui.text("Current build: (not read yet)")
    end
    if state.last_match ~= nil then
        imgui.text(string.format("Matched: %s -> %s  [%s]",
            tostring(state.last_match.label),
            tostring(state.last_match.item_set_name or "-"),
            tostring(state.last_match.mode)))
    else
        imgui.text("Matched: nothing yet")
    end
    imgui.text("Last: " .. tostring(state.last_result))
    if state.task ~= nil then
        ui_text_colored("working: " .. tostring(state.task.reason), 0xFF80FFFF)
    end

    imgui.separator()
    imgui.text("Links")
    if #config.links == 0 then
        imgui.text("No links yet. Wear the build, pick its item set, press "
            .. "\"Link current build\".")
    end
    local labels = item_set_labels()
    for i = #config.links, 1, -1 do
        if draw_link_row(config.links[i], i, labels) then changed = true end
    end

    imgui.separator()
    imgui.text("New link")
    if ui.set_index > #labels - 1 then ui.set_index = 0 end
    imgui.text("Item set:")
    imgui.same_line()
    local sc, si = imgui.combo("##new_set", ui.set_index, labels)
    if sc then ui.set_index = si end
    imgui.same_line()
    imgui.text("Match:")
    imgui.same_line()
    local mc, mi = imgui.combo("##new_mode", ui.mode_index, mode_labels())
    if mc then ui.mode_index = mi end
    imgui.same_line()
    if imgui.button("Link current build") then
        local sig, err = current_signature()
        if sig == nil then
            notify("cannot read the current build: " .. tostring(err))
        else
            local name = game_loadout_name(sig)
            local label = name or ("Custom build " .. os.date("%H:%M"))
            local link = normalize_link({
                id = tostring(os.time()) .. tostring(math.random(999)),
                label = label,
                mode = mode_from_index(ui.mode_index),
                item_set = ui.set_index + 1,
                item_set_name = item_set_name(ui.set_index + 1),
                apply_mode = "exact",
                sig = sig,
            })
            if link == nil then
                notify("could not read enough of the build to link it")
            else
                config.links[#config.links + 1] = link
                state.last_sig = sig
                changed = true
                notify("linked " .. label .. " -> "
                    .. tostring(link.item_set_name or link.item_set))
            end
        end
    end
    imgui.same_line()
    if imgui.button("Refresh##refresh") then
        state.dirty = true
        item_name_cache = {}
        changed = false
        local sig, err = current_signature()
        if sig == nil then
            notify("cannot read the current build: " .. tostring(err))
        else
            state.last_sig = sig
            notify("read the current build")
        end
    end
    imgui.same_line()
    if imgui.button("Apply now") then
        state.dirty = true
        fire("manual")
    end

    imgui.separator()
    imgui.text("Default item set (used when no link matches):")
    imgui.same_line()
    local dsel = (config.default_item_set or 0) - 1
    if dsel < 0 then dsel = 0 end
    local dl = { "(none)" }
    for _, l in ipairs(labels) do dl[#dl + 1] = l end
    local dc, di = imgui.combo("##default_set", dsel, dl)
    if dc then
        config.default_item_set = (di == 0) and nil or di
        changed = true
    end

    draw_preview()

    imgui.separator()
    local dc2, dv2 = imgui.checkbox("Diagnostics", ui.show_diag)
    if dc2 then ui.show_diag = dv2 end
    if ui.show_diag then
        imgui.text("gear source: " .. tostring(state.last_gear_source or "-"))
        imgui.text("character source: " .. tostring(last_character_source or "-"))
        imgui.text("item sets: " .. tostring(#item_sets()))
        imgui.text("pouch slots: " .. tostring(#pouch_works()))
        imgui.text("box slots: " .. tostring(#box_works()))
        imgui.text("skill source: " .. tostring(skill_source_error or "ok"))
        local cands = apply_candidates()
        imgui.text("apply candidates: " .. tostring(#cands))
        for i, cand in ipairs(cands) do
            if i <= 8 then
                imgui.text("  " .. cand.type .. "." .. cand.name
                    .. " (" .. tostring(cand.params) .. (cand.static and ", static)" or ")"))
            end
        end
        if #cands == 0 then
            ui_text_colored("no apply method found - top-up from the box is the "
                .. "active path (run the probe to extend the candidate list)", 0xFF80FFFF)
        end
        if imgui.button("Export links") then
            safe(function()
                json.dump_file(LINKS_FILE, { version = VERSION, links = config.links })
            end)
            notify("exported links to reframework/data/" .. LINKS_FILE)
        end
        imgui.same_line()
        if imgui.button("Import links") then
            local doc = safe(function() return json.load_file(LINKS_FILE) end)
            local n = 0
            if type(doc) == "table" and type(doc.links) == "table" then
                for _, l in ipairs(doc.links) do
                    local nl = normalize_link(l)
                    if nl then
                        config.links[#config.links + 1] = nl
                        n = n + 1
                    end
                end
            end
            notify("imported " .. tostring(n) .. " link(s)")
            changed = true
        end
    end

    if changed then save_config() end
    imgui.separator()
    imgui.text("restock happens through the game's item-set path; nothing is created.")
    imgui.tree_pop()
end

-- ---------------------------------------------------------------------------
-- tests / registration
-- ---------------------------------------------------------------------------

LR._test = {
    sig_key = sig_key,
    mode_of = mode_of,
    resolve_link = resolve_link,
    compute_diff = compute_diff,
    diff_satisfied = diff_satisfied,
    normalize_link = normalize_link,
    mode_from_index = mode_from_index,
    mode_to_index = mode_to_index,
    default_config = default_config,
    MODES = MODES,
    MODE_GROUPS = MODE_GROUPS,
    -- game-side hooks, exercised against a fake save in tests/pipeline_test.lua
    state = state,
    start_task = start_task,
    tick_task = tick_task,
    poll = poll,
    fire = fire,
    item_set_contents = item_set_contents,
    item_set_name = item_set_name,
    pouch_snapshot = pouch_snapshot,
    box_snapshot = box_snapshot,
    write_topup = write_topup,
    apply_candidates = apply_candidates,
    set_config = function(c) config = c end,
    get_config = function() return config end,
}

if not TEST_MODE then
    if not ALREADY_LOADED then
        load_config()
        re.on_frame(function()
            local ok, err = pcall(on_frame)
            if not ok then log.warn("[LinkedRestock] on_frame: " .. tostring(err)) end
        end)
        re.on_draw_ui(function()
            local ok, err = pcall(draw_ui)
            if not ok then log.warn("[LinkedRestock] draw_ui: " .. tostring(err)) end
        end)
        log.info("[LinkedRestock] loaded v" .. VERSION .. " (no hooks, UI only)")
    else
        log.info("[LinkedRestock] duplicate load ignored")
    end
end

return LR
