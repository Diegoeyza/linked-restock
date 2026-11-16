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

local VERSION = "0.1.10"
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
    full = { "armor", "jewels", "charm", "weapon" },
    no_weapon = { "armor", "jewels", "charm" },
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
--   sig = { armor = { "..." }, jewels = { "..." }, charm = "...", weapon = "...",
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

local function collection_get(c, i)
    if c == nil then return nil end
    local v = safe(function() return c:get_Item(i) end)
    if v ~= nil then return v end
    local get_item = safe(function() return c.get_Item end)
    if get_item then
        local got = safe(function() return get_item:call(c, i) end)
        if got ~= nil then return got end
    end
    return safe(function() return c[i] end)
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

local function mode_of(link, cfg)
    local m = link and link.mode
    if m ~= nil and m ~= "inherit" and MODE_GROUPS[m] ~= nil then return m end
    if cfg and cfg.ignore_weapons then return "no_weapon" end
    return "full"
end

-- Canonical string for one build under one mode. Two builds match when their
-- keys are equal, so the key format must be stable across sessions.
local GROUP_NAMES = {
    armor = "armour pieces",
    jewels = "skills (jewels)",
    charm = "charm",
    weapon = "weapon",
}

local function group_key(sig, g, charm_type_only)
    if sig == nil then return nil end
    if g == "armor" then
        return "A:" .. table.concat(sorted_list(sig.armor), "|")
    elseif g == "charm" then
        if charm_type_only and sig.charm_id ~= nil then
            return "C:" .. tostring(sig.charm_id)
        end
        return "C:" .. tostring(sig.charm or "")
    elseif g == "jewels" then
        return "J:" .. table.concat(sorted_list(sig.jewels), ";")
    elseif g == "weapon" then
        return "W:" .. tostring(sig.weapon or "")
    end
    return nil
end

local function sig_key(sig, mode, charm_type_only)
    if sig == nil then return nil end
    local parts = {}
    for _, g in ipairs(MODE_GROUPS[mode] or MODE_GROUPS.full) do
        parts[#parts + 1] = group_key(sig, g, charm_type_only)
    end
    return table.concat(parts, "#")
end

-- Why a link does not match the build in hand: the names of the groups whose
-- key differs, or nil when it matches. Used by the panel so a refusal is never
-- a bare "no match".
local function link_mismatch(link, sig, cfg)
    if sig == nil or link == nil then return "the build has not been read" end
    local mode = mode_of(link, cfg)
    local loose = (link.origin == "loadout")
    local bad = {}
    for _, g in ipairs(MODE_GROUPS[mode] or MODE_GROUPS.full) do
        if group_key(sig, g, loose) ~= group_key(link.sig, g, loose) then
            bad[#bad + 1] = GROUP_NAMES[g] or g
        end
    end
    if #bad == 0 then return nil end
    return "differs: " .. table.concat(bad, ", ")
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
            -- a link built from a saved loadout has no weapon rolls and may be
            -- missing the charm's rolled skills, so it compares the charm by
            -- amulet type; links captured from worn gear stay exact
            local loose_charm = (link.origin == "loadout")
            local a = sig_key(sig, mode, loose_charm)
            local b = sig_key(link.sig, mode, loose_charm)
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

-- The item master table, the same path meal-buffet uses for ingredient names
-- (app.VariousDataManager._Setting._ItemSetting._ItemData).
local function item_data_table()
    local vm = safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
    local setting = vm and field_value(vm, "_Setting")
    local item_setting = setting and field_value(setting, "_ItemSetting")
    return item_setting and field_value(item_setting, "_ItemData")
end

local function item_name(fixed_id)
    if fixed_id == nil or fixed_id == 0 then return nil end
    if item_name_cache[fixed_id] ~= nil then
        return item_name_cache[fixed_id] or nil
    end
    local entry = nil
    local tbl = item_data_table()
    if tbl ~= nil then
        local td = safe(function() return tbl:get_type_definition() end)
        local m = td and safe(function() return td:get_method("getDataByFixedId(System.Int32)") end)
        entry = m and safe(function() return m:call(tbl, fixed_id) end)
    end
    if entry == nil then
        -- fall back to the static form on the data type
        local typed = safe(sdk.find_type_definition, "app.user_data.ItemData")
        local get_data = typed and safe(function()
            return typed:get_method("getDataByFixedId(System.Int32)")
        end)
        entry = get_data and safe(function() return get_data:call(nil, fixed_id) end)
    end
    local name = nil
    if entry ~= nil then
        name = localized(call_method(entry, "get_RawName")
            or field_value(entry, "RawName") or field_value(entry, "_RawName"))
            or safe_str(field_value(entry, "Name"))
    end
    item_name_cache[fixed_id] = name or false
    return name
end

-- Local player: same scan meal-buffet uses (user-controlled character, never
-- the quest host by default).
-- ---------------------------------------------------------------------------
-- game: build signature
-- ---------------------------------------------------------------------------
--
-- Confirmed against linked_restock_probe_gear.json (2026-11-15) on the live
-- build:
--   * app.PlayerManager:get_Catalog() returns a prefab/asset holder with no
--     armour lists, so the live gear has to come from the save data;
--   * app.savedata.cEquipParam._EquipIndex.Index[1..15] holds the equipment box
--     position of the item worn in each slot (main weapon, 5 armour pieces,
--     charm, reserve weapon, mantle, then empties at -1);
--   * app.savedata.cEquipParam._EquipBox holds those works. cEquipWork uses
--     Category_Gender: 0/1 armour (low bit = gender), 13 weapon, 21 charm.
--     cMysetEquipWork uses a plain Category: 0 armour, 1 weapon, 2 charm, 3
--     other. Both are normalised below so keys match across the two sources.
--   * skills are NOT readable from cHunterSkill on this build (the equipment
--     array exposes no levels), so the skill side of the identity is the jewel
--     and bowgun-mod arrays, which are readable and are what changes when you
--     re-decorate. Charm skills live in the charm work's BowgunCustomizeId.

local CAT_ARMOR, CAT_WEAPON, CAT_CHARM, CAT_OTHER = "armor", "weapon", "charm", "other"

local function category_of(obj)
    if obj == nil then return nil end
    -- my-set shape: plain app.EquipDef.CATEGORY
    local plain = enum_number(field_value(obj, "Category"))
    if plain ~= nil then
        if plain == 0 then return CAT_ARMOR end
        if plain == 1 then return CAT_WEAPON end
        if plain == 2 then return CAT_CHARM end
        return CAT_OTHER
    end
    -- equip-box shape: Category_Gender bitset
    local cg = enum_number(field_value(obj, "Category_Gender"))
    if cg ~= nil then
        local c = math.floor(cg) % 256
        if c == 13 then return CAT_WEAPON end
        if c == 21 then return CAT_CHARM end
        if c == 0 or c == 1 then return CAT_ARMOR end
        return CAT_OTHER
    end
    return nil
end

-- One equipment work -> a stable short key: what it is plus the fields the
-- game itself persists (armour series/part, weapon type/id, Artian roll
-- fields), so two builds only share a key when they share the actual piece.
local function piece_key(obj, depth)
    if obj == nil then return nil end
    depth = depth or 0
    if depth > 3 then return nil end
    local cat = category_of(obj)
    if cat ~= nil then
        local f0 = enum_number(field_value(obj, "FreeVal0")) or 0
        local f1 = enum_number(field_value(obj, "FreeVal1")) or 0
        if cat ~= CAT_WEAPON then
            -- armour/charm identity: the piece itself. Upgrade levels and
            -- reinforcement must not break a link -- they do not change the
            -- build, and decorations are captured separately.
            return string.format("%s:%d:%d", cat, f0, f1)
        end
        -- weapons: the roll fields are part of the weapon (Artian perf type,
        -- created/grinded bonuses), which is what the client asked for.
        local f2 = enum_number(field_value(obj, "FreeVal2")) or 0
        local f3 = enum_number(field_value(obj, "FreeVal3")) or 0
        local bonus_create = enum_number(field_value(obj, "BonusByCreating")) or 0
        local bonus_grind = enum_number(field_value(obj, "BonusByGrinding")) or 0
        local grind = enum_number(field_value(obj, "GrindingNum")) or 0
        return string.format("%s:%d:%d:%d:%d:%d:%d:%d",
            cat, f0, f1, f2, f3, bonus_create, bonus_grind, grind)
    end
    -- a wrapper around the work (some builds nest it)
    for _, name in ipairs({ "EquipWork", "Work", "Data", "Param", "Info",
                            "EquipInfo", "ItemData", "cData" }) do
        local inner = field_value(obj, name)
        if inner ~= nil and type(inner) == "userdata" then
            local k = piece_key(inner, depth + 1)
            if k then return k end
        end
    end
    return nil
end

-- The part of the key that says *which* piece this is: category, series/type
-- and part/id. Upgrade levels and Artian rolls are deliberately left out, so a
-- live piece still matches the same piece in a saved loadout.
local function piece_identity(obj)
    local cat = category_of(obj)
    if cat == nil then return nil end
    local f0 = enum_number(field_value(obj, "FreeVal0")) or 0
    local f1 = enum_number(field_value(obj, "FreeVal1")) or 0
    return string.format("%s:%d:%d", cat, f0, f1)
end

-- Charm identity for the loadout label: the amulet type (FreeVal0). FreeVal1
-- means different things in a worn work and in a saved my-set, so it is not
-- used here; the rolled skills are compared by the signature, not the label.
local function charm_id_of(obj)
    if obj == nil then return nil end
    local amulet = enum_number(field_value(obj, "FreeVal0"))
    if amulet == nil then return nil end
    return "charm:" .. tostring(amulet)
end

-- A short int16[] of ids (decorations / bowgun mods) as a stable string.
-- -1 and 0 both mean "empty".
local function id_array_key(obj, field)
    local out = {}
    for i, v in ipairs(collect(field_value(obj, field), 8)) do
        local n = enum_number(v)
        if n ~= nil and n > 0 then out[i] = tostring(n) else out[i] = "" end
    end
    -- trailing empties carry no meaning (a zero-filled array and an absent one
    -- are the same piece), and a my-set does not always keep the zero padding
    while #out > 0 and out[#out] == "" do out[#out] = nil end
    return table.concat(out, ",")
end

-- The skill side of one piece: its jewels plus its bowgun mods. For a charm
-- that second array carries the rolled skills, so this covers random charms.
local function piece_skills(obj)
    return id_array_key(obj, "EquipmentAccessoryIdArray") .. "/"
        .. id_array_key(obj, "BowgunCustomizeId")
end

local last_base_score = nil
local last_slot_layout = nil

-- Every saved equipment loadout, with the parts that identify it: armour
-- pieces, the charm and the weapons. Cached for two seconds (a base check
-- otherwise walks 64 my-sets).
local saved_loadout_cache = { at = -1, list = {} }

local function saved_loadouts()
    local now = os.clock()
    if saved_loadout_cache.at >= 0 and (now - saved_loadout_cache.at) < 2.0 then
        return saved_loadout_cache.list
    end
    local list = {}
    for i, set in ipairs(equip_mysets()) do
        local param = field_value(set, "_MysetParam")
        local name = param and safe_str(field_value(param, "MysetName"))
        if name == nil or name == "" then name = "Set " .. tostring(i) end
        local armor, weapons, charm = {}, {}, nil
        for _, w in ipairs(collect(field_value(set, "_MysetEquipWork"), 16)) do
            local cat = category_of(w)
            local id = piece_identity(w)
            if id ~= nil then
                if cat == CAT_ARMOR then armor[#armor + 1] = id
                elseif cat == CAT_WEAPON then weapons[#weapons + 1] = id
                elseif cat == CAT_CHARM then charm = charm_id_of(w) end
            end
        end
        -- every slot is kept: a loadout the mod cannot read still has to be
        -- selectable by slot number (armor = "" keeps it out of name matching)
        list[#list + 1] = {
            index = i, name = name,
            armor = table.concat(sorted_list(armor), "|"),
            armor_count = #armor,
            weapons = table.concat(sorted_list(weapons), "|"),
            charm = charm,
        }
    end
    saved_loadout_cache = { at = now, list = list }
    return list
end

local function saved_armor_keys()
    local out = {}
    for _, l in ipairs(saved_loadouts()) do out[#out + 1] = l.armor end
    return out
end

local function slots_of(works, limit)
    local out = {}
    for slot = 1, limit or 20 do
        local w = works[slot]
        local cat = w and category_of(w)
        if cat == CAT_WEAPON then out[#out + 1] = "W"
        elseif cat == CAT_ARMOR then out[#out + 1] = "A"
        elseif cat == CAT_CHARM then out[#out + 1] = "C"
        elseif w ~= nil then out[#out + 1] = "o"
        else out[#out + 1] = "." end
    end
    return table.concat(out, " ")
end

-- The worn gear, by equipment slot, from _EquipIndex.Index -> _EquipBox.
--
-- Whether Index is 0- or 1-based is not documented, and a simple category check
-- cannot tell: the box groups items by category, so an off-by-one still reads
-- "a weapon" and "some armour". Three checks that a shift does break decide it:
--   * the five armour slots must carry armour parts 0..4, each exactly once;
--   * the charm slot must be the amulet recorded in _CharmEquipped;
--   * the armour key set should equal one of the saved equipment loadouts
--     (the common case: you are wearing a loadout).
local function current_equip_works()
    local ep = equip_param()
    if ep == nil then return nil, "no equip param" end
    local box = field_value(ep, "_EquipBox")
    local holder = field_value(ep, "_EquipIndex")
    local idx = collect(holder and field_value(holder, "Index"), 32)
    if box == nil or #idx == 0 then return nil, "no equipment index" end

    local charm_holder = field_value(ep, "_CharmEquipped")
    local equipped_charm = charm_holder and enum_number(field_value(charm_holder, "MainCharm"))

    -- Index may be a 0-based array position, a 1-based one, or one below the
    -- position; all three offsets are read and the structural checks decide.
    local function read_all(offset)
        local out = {}
        for slot, v in ipairs(idx) do
            local i = enum_number(v)
            if i ~= nil and i >= 0 and (i + offset) >= 0 then
                local w = collection_get(box, i + offset)
                if w ~= nil then out[slot] = w end
            end
        end
        return out
    end

    local function armor_parts_ok(works)
        local seen = {}
        for slot = 2, 6 do
            local w = works[slot]
            if w == nil or category_of(w) ~= CAT_ARMOR then return false end
            local part = enum_number(field_value(w, "FreeVal1"))
            if part == nil or part < 0 or part > 4 or seen[part] then return false end
            seen[part] = true
        end
        return true
    end

    local function charm_matches(works)
        local w = works[7]
        if w == nil or category_of(w) ~= CAT_CHARM then return false end
        local amulet = enum_number(field_value(w, "FreeVal0"))
        if amulet == nil or equipped_charm == nil then return false end
        return amulet == equipped_charm
    end

    local function armor_is_a_loadout(works)
        local armor = {}
        for slot = 1, 20 do
            local w = works[slot]
            if w ~= nil and category_of(w) == CAT_ARMOR then
                local k = piece_identity(w)
                if k then armor[#armor + 1] = k end
            end
        end
        if #armor ~= 5 then return false end
        local want = table.concat(sorted_list(armor), "|")
        for _, saved in ipairs(saved_armor_keys()) do
            if saved == want then return true end
        end
        return false
    end

    local function score(works)
        local n = 0
        if works[1] ~= nil and category_of(works[1]) == CAT_WEAPON then n = n + 3 end
        for slot = 2, 6 do
            if works[slot] ~= nil and category_of(works[slot]) == CAT_ARMOR then
                n = n + 1
            end
        end
        if armor_parts_ok(works) then n = n + 5 end
        if works[7] ~= nil and category_of(works[7]) == CAT_CHARM then n = n + 3 end
        if charm_matches(works) then n = n + 10 end
        if armor_is_a_loadout(works) then n = n + 20 end
        return n
    end

    local best_works, best_score, best_offset = nil, -1, 0
    for _, offset in ipairs({ 0, -1, 1 }) do
        local candidate = read_all(offset)
        local candidate_score = score(candidate)
        if candidate_score > best_score then
            best_works, best_score, best_offset = candidate, candidate_score, offset
        end
    end
    local works = best_works or {}
    local chosen = best_offset
    last_base_score = math.max(best_score, 0)
    last_slot_layout = slots_of(works, #idx)
    return works, string.format("equip_index (offset %+d, score %d)", chosen, last_base_score)
end

-- Signature of a saved equipment loadout, for linking without wearing it.
-- The my-set stores the same fields as the worn work for armour, jewels, charm
-- and weapon identity, but NOT the weapon roll fields (Artian bonuses), so a
-- weapon key built from here is identity + jewels only. Such links are matched
-- as armour + skills + charm (no_weapon), which is what the loadout can prove.
local function signature_from_myset(set)
    if set == nil then return nil, "no loadout" end
    local armor, armor_ids, jewels, weapons, weapon_ids = {}, {}, {}, {}, {}
    local charm, charm_id = nil, nil
    local slots = collect(field_value(set, "_MysetEquipWork"), 16)
    for slot, w in ipairs(slots) do
        local cat = category_of(w)
        local key = piece_key(w)
        if key ~= nil then
            if cat == CAT_ARMOR then
                armor[#armor + 1] = key
                local id = piece_identity(w)
                if id then armor_ids[#armor_ids + 1] = id end
                jewels[#jewels + 1] = tostring(slot) .. "=" .. piece_skills(w)
            elseif cat == CAT_WEAPON and slot <= 8 then
                local id = piece_identity(w)
                if id then
                    weapons[#weapons + 1] = id .. "|" .. piece_skills(w)
                    weapon_ids[#weapon_ids + 1] = id
                end
            elseif cat == CAT_CHARM then
                -- compare the amulet by type: the my-set is not guaranteed to
                -- keep the rolled-skill array the worn work carries
                charm = charm_id_of(w)
                charm_id = charm_id_of(w)
            end
        end
    end
    if #armor == 0 then return nil, "this loadout has no armour" end
    return {
        armor = sorted_list(armor),
        armor_ids = sorted_list(armor_ids),
        weapon_ids = sorted_list(weapon_ids),
        charm_id = charm_id,
        jewels = sorted_list(jewels),
        charm = charm,
        weapon = #weapons > 0 and table.concat(sorted_list(weapons), "|") or nil,
        armor_count = #armor,
        jewel_count = #jewels,
        weapon_label = (#weapon_ids > 0) and "from loadout" or nil,
        from_loadout = true,
    }, "loadout"
end

local function myset_by_index(index)
    return equip_mysets()[index]
end

local last_gear_source = nil
local weapon_name -- display names, defined with the weapon catalogue below

-- The build in hand:
--   armour  = the five armour piece keys (sorted)
--   jewels  = per-slot jewel/mod signature of the armour (the skill state)
--   charm   = charm work key + its jewels/rolled skills
--   weapon  = weapon work keys + their jewels/mods, or nil when the mode
--             ignores weapons (the caller does that with sig_key)
local function current_signature()
    local works, source = current_equip_works()
    last_gear_source = source
    if works == nil then return nil, tostring(source) end
    local armor, jewels, weapons, armor_ids = {}, {}, {}, {}
    local weapon_ids = {}
    local charm, charm_id = nil, nil
    local weapon_labels = {}
    local seen_label = {}
    for slot = 1, 20 do
        local w = works[slot]
        if w ~= nil then
            local cat = category_of(w)
            local key = piece_key(w)
            if key ~= nil then
                if cat == CAT_ARMOR then
                    armor[#armor + 1] = key
                    jewels[#jewels + 1] = slot .. "=" .. piece_skills(w)
                    local id = piece_identity(w)
                    if id then armor_ids[#armor_ids + 1] = id end
                elseif cat == CAT_WEAPON and slot <= 8 then
                    weapons[#weapons + 1] = key .. "|" .. piece_skills(w)
                    local wid_key = piece_identity(w)
                    if wid_key then weapon_ids[#weapon_ids + 1] = wid_key end
                    local wt = enum_number(field_value(w, "FreeVal0"))
                    local wid = enum_number(field_value(w, "FreeVal1"))
                    local label = wt ~= nil and weapon_name(wt, wid) or nil
                    if label == nil and wt ~= nil then
                        label = string.format("weapon type %d #%s", wt, tostring(wid))
                    end
                    if label ~= nil and not seen_label[label] and #weapon_labels < 2 then
                        seen_label[label] = true
                        weapon_labels[#weapon_labels + 1] = label
                    end
                elseif cat == CAT_CHARM then
                    charm = charm_id_of(w) .. "|" .. piece_skills(w)
                    charm_id = charm_id_of(w)
                end
            end
        end
    end
    if #armor == 0 then
        return nil, "no armour in the current gear (" .. tostring(source) .. ")"
    end
    local weapon = nil
    if #weapons > 0 then
        weapon = table.concat(sorted_list(weapons), "|")
    end
    return {
        armor = sorted_list(armor),
        armor_ids = sorted_list(armor_ids),
        weapon_ids = sorted_list(weapon_ids),
        charm_id = charm_id,
        jewels = sorted_list(jewels),
        charm = charm,
        weapon = weapon,
        armor_count = #armor,
        jewel_count = #jewels,
        weapon_label = #weapon_labels > 0
            and table.concat(weapon_labels, " + ") or nil,
    }, source
end

-- Weapon display name, for the panel only: find the entry whose typed id field
-- equals the work's FreeVal1 (app.WeaponDef.<Type>Id, per the save layout).
local WEAPON_FIELDS = { "_WeaponLongSword", "_WeaponShortSword", "_WeaponTwinSword",
    "_WeaponTachi", "_WeaponHammer", "_WeaponWhistle", "_WeaponLance", "_WeaponGunLance",
    "_WeaponSlashAxe", "_WeaponChargeAxe", "_WeaponRod", "_WeaponBow",
    "_WeaponHeavyBowgun", "_WeaponLightBowgun" }
local TYPE_ID_FIELD = { "_LongSword", "_ShortSword", "_TwinSword", "_Tachi",
    "_Hammer", "_Whistle", "_Lance", "_GunLance", "_SlashAxe", "_ChargeAxe",
    "_Rod", "_Bow", "_HeavyBowgun", "_LightBowgun" }
local weapon_arrays = nil

local function get_weapon_arrays()
    if weapon_arrays ~= nil then return weapon_arrays end
    weapon_arrays = {}
    local vdm = safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
    local equip_data = vdm and safe(function() return vdm._Setting._EquipDatas end)
    if equip_data then
        for i, fname in ipairs(WEAPON_FIELDS) do
            local arr = safe(function() return equip_data[fname] end)
            local list = {}
            if arr then
                list = collect(safe(function() return arr:call("get_Values") end), 400)
            end
            weapon_arrays[i - 1] = list
        end
    end
    return weapon_arrays
end

local weapon_name_cache = {}

-- The save's FreeVal1 and get_WeaponID() are the same 0-based position, but
-- the collected catalogue list is 1-based, so the name lives at [id + 1]
-- (proven in HuntDumper v0.9.3: id 45 -> list[46] "G. Resounding Galahad",
-- while the entry whose typed id field equals 45 is the upgrade before it).
weapon_name = function(wtype, wid)
    if wtype == nil or wid == nil then return nil end
    local key = tostring(wtype) .. ":" .. tostring(wid)
    if weapon_name_cache[key] ~= nil then return weapon_name_cache[key] or nil end
    local list = get_weapon_arrays()[wtype] or {}

    local function name_of(entry)
        if entry == nil then return nil end
        local raw = field_value(entry, "_Name")
            or safe(function() return entry:get_field("_Name") end)
        return localized(raw)
    end

    local name = name_of(list[wid + 1]) or name_of(list[wid])
    if name == nil then
        local id_field = TYPE_ID_FIELD[wtype + 1]
        if id_field ~= nil then
            for _, e in ipairs(list) do
                local id = enum_number(field_value(e, id_field))
                if id ~= nil and (id == wid + 1 or id == wid) then
                    name = name_of(e)
                    if name ~= nil then break end
                end
            end
        end
    end
    weapon_name_cache[key] = name or false
    return name
end

-- Which saved loadout the worn gear is, for the panel label only (never used
-- to match links). Whole-gear first: same armour pieces, same charm and the
-- same weapons. Failing that, a loadout with the same armour is reported as a
-- partial match instead of being presented as exact -- several loadouts can
-- share five armour pieces and differ in the charm or the weapons.
local loadout_name_cache = { key = nil, name = nil, index = nil, quality = nil }

local function game_loadout_name(sig)
    if sig == nil then return nil, nil, nil end
    local key = table.concat({
        table.concat(sorted_list(sig.armor_ids or {}), "|"),
        tostring(sig.charm_id or ""),
        table.concat(sorted_list(sig.weapon_ids or {}), "|"),
    }, "#")
    if loadout_name_cache.key == key then
        return loadout_name_cache.name, loadout_name_cache.index,
            loadout_name_cache.quality, loadout_name_cache.diff
    end

    local armor_key = table.concat(sorted_list(sig.armor_ids or {}), "|")
    local weapon_key = table.concat(sorted_list(sig.weapon_ids or {}), "|")
    local best, best_score = nil, -1
    for _, l in ipairs(saved_loadouts()) do
        if l.armor == armor_key and armor_key ~= "" then
            local score = 0
            if l.charm == sig.charm_id then score = score + 1 end
            if l.weapons == weapon_key then score = score + 2 end
            if score > best_score then best, best_score = l, score end
            if score == 3 then
                loadout_name_cache = { key = key, name = l.name, index = l.index,
                                       quality = "full" }
                return l.name, l.index, "full"
            end
        end
    end
    if best ~= nil then
        local why = {}
        if best.charm ~= sig.charm_id then why[#why + 1] = "charm" end
        if best.weapons ~= weapon_key then why[#why + 1] = "weapons" end
        local diff = table.concat(why, " + ")
        loadout_name_cache = { key = key, name = best.name, index = best.index,
                               quality = "armor", diff = diff }
        return best.name, best.index, "armor", diff
    end
    loadout_name_cache = { key = key, name = nil, index = nil, quality = nil }
    return nil, nil, nil
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
    -- get_num_params() is the reliable count (hunt_dumper uses it); the param
    -- type array itself is not a Lua table, so # is only a fallback.
    local n = safe(function() return m:get_num_params() end)
    if type(n) == "number" then return n end
    local params = safe(function() return m:get_param_types() end)
    if params == nil then return 0 end
    local k = safe(function() return #params end)
    if type(k) == "number" and k > 0 then return k end
    return #collect(params, 8)
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

-- Try every plausible call shape for a candidate: static and instance form,
-- display index and 0-based index. Which one is right is decided by the pouch
-- read-back, not by guessing the method's intent.
local function call_candidate(cand, index)
    local td = safe(sdk.find_type_definition, cand.type)
    local m = td and safe(function() return td:get_method(cand.name) end)
    if not m then return false, "method gone" end
    local obj = safe(item_param) or safe(save_data)
    local attempts = {}
    for _, i in ipairs({ index, index - 1 }) do
        attempts[#attempts + 1] = { self = nil, index = i }
        if obj ~= nil then attempts[#attempts + 1] = { self = obj, index = i } end
    end
    for _, a in ipairs(attempts) do
        local ok = safe(function()
            if cand.params == 1 then
                m:call(a.self, a.index)
            else
                m:call(a.self, a.index, false)
            end
            return true
        end)
        if ok then
            return true, string.format("%s(%s%s)", cand.name, tostring(a.index),
                a.self ~= nil and ", self" or "")
        end
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
    accept_pending = false,
    accept_frames = 0,
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
        origin = (l.origin == "loadout") and "loadout" or nil,
        sig = nil,
    }
    if type(l.sig) == "table" then
        local sig = {
            armor = type(l.sig.armor) == "table" and l.sig.armor or {},
            charm = l.sig.charm,
            armor_ids = type(l.sig.armor_ids) == "table" and l.sig.armor_ids or nil,
            jewels = type(l.sig.jewels) == "table" and l.sig.jewels
                or (type(l.sig.skills) == "table" and l.sig.skills) or {},
            weapon = l.sig.weapon,
            charm_id = l.sig.charm_id,
            weapon_label = l.sig.weapon_label,
        }
        sig.armor_count = #sig.armor
        sig.jewel_count = #sig.jewels
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

local function static_method(type_name, signature)
    local td = safe(sdk.find_type_definition, type_name)
    return td and safe(function() return td:get_method(signature) end) or nil
end

-- Apply paths, best first. The first two are the calls confirmed on the live
-- build by the probe (2026-11-15); the generic scan stays for other builds.
local function strategies_for(link, diff, index)
    local list = {}
    local set_obj = item_sets()[index]

    local apply_pouch = static_method("app.ItemMySetUtil",
        "applyMySetToPouch(System.Int32)")
    if apply_pouch ~= nil then
        for _, base in ipairs({ index - 1, index }) do
            list[#list + 1] = {
                label = "ItemMySetUtil.applyMySetToPouch(" .. tostring(base) .. ")",
                run = function()
                    apply_pouch:call(nil, base)
                    return true
                end,
            }
        end
    end

    local apply_set = static_method("app.ItemMySetUtil",
        "apply(app.savedata.cItemMySet)")
    if apply_set ~= nil and set_obj ~= nil then
        list[#list + 1] = {
            label = "ItemMySetUtil.apply(set)",
            run = function()
                apply_set:call(nil, set_obj)
                return true
            end,
        }
    end

    for _, cand in ipairs(apply_candidates()) do
        local already = (apply_pouch ~= nil
                and cand.name == "applyMySetToPouch(System.Int32)")
            or (apply_set ~= nil and cand.name == "apply(app.savedata.cItemMySet)")
        if not already then
            list[#list + 1] = {
                label = cand.type .. "." .. cand.name,
                run = function() return call_candidate(cand, index) end,
            }
        end
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
    local works = current_equip_works()
    if works == nil then return nil end
    for slot = 1, 20 do
        local w = works[slot]
        if w ~= nil and category_of(w) == CAT_WEAPON then
            return enum_number(field_value(w, "FreeVal0"))
        end
    end
    return nil
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

-- What would match the build in hand, without touching the pouch. The panel
-- shows this, so switching loadouts updates it without waiting for a trigger.
local function preview_match(sig)
    if sig == nil then
        return { why = "the build has not been read yet" }
    end
    local link, mode, why = resolve_link(sig, config.links, config)
    if link ~= nil then
        return { link = link, mode = mode, why = why }
    end
    local wt = current_weapon_type()
    local idx = wt ~= nil and config.fallback_by_weapon[tostring(wt)] or nil
    local kind = "weapon-type fallback"
    if idx == nil then
        idx = config.default_item_set
        kind = "default item set"
    end
    return { fallback = idx, fallback_kind = kind, why = why }
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
            if config.triggers.quest_accept then
                -- one second after the quest starts: the game initialises the
                -- quest pouch at the start, and a write before that is lost
                state.accept_pending = true
                state.accept_frames = 60
            end
        else
            state.accept_pending = false
            -- the quest is over: wait until the game itself is out of the quest
            -- (IsActiveQuest stays true through the results screen) and then a
            -- beat longer, so the return flow cannot overwrite the pouch
            state.hub_frames = config.hub_delay_frames
            state.hub_pending = config.triggers.hub_return
        end
        state.last_in_quest = q
    end

    if state.accept_pending then
        if q ~= true then
            state.accept_pending = false
        elseif state.accept_frames > 0 then
            state.accept_frames = state.accept_frames - 1
        else
            state.accept_pending = false
            state.accept_done_seq = state.quest_seq
            state.dirty = true
            fire("quest accepted")
        end
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
    set_index = 0,     -- combo position of the item set to link
    armor_index = 0,   -- combo position of the saved armour loadout to link
    mode_index = 0,    -- 0 = inherit
    show_preview = nil,   -- { link=, diff=, missing= }
    show_diag = false,
}

-- Every item-set slot, used first. A fixed 64-slot array holds the sets, and a
-- set the mod cannot name still has to be pickable, so unnamed and empty slots
-- are listed after the real ones as "Slot #n" instead of being hidden.
-- The original index is kept because that is what the apply call takes.
local item_choice_cache = { at = -1, list = {} }

local function item_set_choices()
    local now = os.clock()
    if item_choice_cache.at >= 0 and (now - item_choice_cache.at) < 1.0 then
        return item_choice_cache.list
    end
    local real, empty = {}, {}
    for i, set in ipairs(item_sets()) do
        local name = safe_str(field_value(set, "Name")) or ""
        local count = 0
        for _, w in ipairs(collect(field_value(set, "_PouchItem"), 64)) do
            local id = enum_number(field_value(w, "ItemIdFixed"))
            local n = enum_number(field_value(w, "Num")) or 0
            if id ~= nil and id ~= 0 and n > 0 then count = count + 1 end
        end
        local entry = {
            index = i,
            name = (name ~= "" and name) or ("Slot #" .. tostring(i)),
            count = count,
            named = (name ~= ""),
        }
        if name ~= "" or count > 0 then
            real[#real + 1] = entry
        else
            empty[#empty + 1] = entry
        end
    end
    local out = real
    for _, e in ipairs(empty) do out[#out + 1] = e end
    item_choice_cache = { at = now, list = out }
    return out
end

-- label for one item-set choice: name, item count, and the slot when unnamed
local function item_set_label(c)
    if c == nil then return "?" end
    if c.named then
        return string.format("%s  (%d)", c.name, c["count"] or 0)
    end
    if (c["count"] or 0) > 0 then
        return string.format("%s  (%d items)", c.name, c["count"])
    end
    return c.name .. "  (empty)"
end

local function choice_pos(choices, index)
    if index == nil then return nil end
    for pos, c in ipairs(choices) do
        if c.index == index then return pos - 1 end
    end
    return nil
end

local function choice_index(choices, pos)
    local c = choices[pos + 1]
    return c and c.index or nil
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

local function mode_label_at(pos)
    if pos == nil or pos <= 0 then return MODE_LABELS.inherit end
    return MODE_LABELS[MODES[pos]] or MODE_LABELS.inherit
end

local function item_set_labels(choices)
    local out = {}
    for _, c in ipairs(choices) do out[#out + 1] = item_set_label(c) end
    return out
end

local function mode_labels()
    local out = {}
    for i = 0, #MODES do out[#out + 1] = mode_label_at(i) end
    return out
end

-- The REFramework panel is narrow, so a dropdown takes the whole line instead
-- of sitting after its label: a combo sharing a line gets pushed off the edge.
local function dropdown_width()
    local w = nil
    safe(function() w = imgui.get_content_region_available_width() end)
    if type(w) ~= "number" or w <= 0 then w = 300 end
    w = w - 8
    if w < 160 then w = 160 end
    if w > 420 then w = 420 end
    return w
end

-- label on one line, dropdown on the next. Returns the new 0-based position,
-- or nil when nothing was picked.
--
-- REFramework's imgui.combo speaks in *table keys*: it previews values[sel],
-- returns the key of the clicked entry, and its popup iterates the table. So
-- the callers' 0-based positions are converted here (an array is keyed
-- 1..#labels) and converted back on the way out. Passing the position straight
-- through picked the entry one below the one clicked.
local function labeled_dropdown(label, id, pos, labels)
    if type(labels) ~= "table" or #labels == 0 then labels = { "(none)" } end
    if pos == nil or pos < 0 or pos > #labels - 1 then pos = 0 end
    imgui.text(label)
    safe(function() imgui.set_next_item_width(dropdown_width()) end)
    local changed, key = imgui.combo(id, pos + 1, labels)
    if changed and type(key) == "number" and key >= 1 and key <= #labels then
        return key - 1
    end
    return nil
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

local function draw_link_row(link, i, choices, live_sig)
    local changed = false
    if imgui.checkbox("##on" .. i, link.enabled ~= false) then
        link.enabled = not link.enabled
        changed = true
    end
    imgui.same_line()
    local suffix = (link.origin == "loadout") and "   (from loadout)" or ""
    imgui.text(tostring(link.label) .. suffix)

    safe(function() imgui.indent(14) end)

    if choice_pos(choices, link.item_set) == nil then
        ui_text_colored("  item set missing - pick one", 0xFF8080FF)
    end
    local pos = labeled_dropdown("  Item set", "##set" .. i,
        choice_pos(choices, link.item_set), item_set_labels(choices))
    if pos ~= nil then
        local idx = choice_index(choices, pos)
        if idx ~= nil then
            link.item_set = idx
            link.item_set_name = item_set_name(idx)
            changed = true
        end
    end

    local mpos = labeled_dropdown("  Match", "##mode" .. i,
        mode_to_index(link.mode), mode_labels())
    if mpos ~= nil then
        link.mode = mode_from_index(mpos)
        changed = true
    end

    local why = link_mismatch(link, live_sig, config)
    if live_sig == nil then
        imgui.text("  (build not read yet)")
    elseif why == nil then
        ui_text_colored("  matches the worn build", 0xFF80FF80)
    else
        ui_text_colored("  no match - " .. why, 0xFF8080FF)
    end

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

    safe(function() imgui.unindent(14) end)
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

    local c3, v3 = imgui.checkbox("Ignore weapons (armour + skills only)",
        config.ignore_weapons)
    if c3 then config.ignore_weapons = v3 changed = true end
    local c4, v4 = imgui.checkbox("Notify missing items", config.notify_missing)
    if c4 then config.notify_missing = v4 changed = true end

    imgui.separator()
    imgui.text("Restock when:")
    local t1, tv1 = imgui.checkbox("Quest accepted", config.triggers.quest_accept)
    if t1 then config.triggers.quest_accept = tv1 changed = true end
    local t2, tv2 = imgui.checkbox("Back in the hub", config.triggers.hub_return)
    if t2 then config.triggers.hub_return = tv2 changed = true end
    local t3, tv3 = imgui.checkbox("On-screen notice", config.notify)
    if t3 then config.notify = tv3 changed = true end

    imgui.separator()
    -- re-read the worn build while the panel is open: changing loadout in game
    -- must update this line without pressing anything
    if state.frames - (state.sig_try_frame or -999) > 30 then
        state.sig_try_frame = state.frames
        local sig = current_signature()
        if sig ~= nil then state.last_sig = sig end
    end
    if state.last_sig ~= nil then
        local sig = state.last_sig
        imgui.text(string.format("Current build: %d armour - %d jewel slots - %s",
            sig.armor_count or 0, sig.jewel_count or 0,
            tostring(sig.weapon_label or "no weapon")))
        local name, idx, quality, diff = game_loadout_name(sig)
        local loadout_line
        if name == nil then
            loadout_line = "not one of the saved loadouts"
        elseif quality == "full" then
            loadout_line = string.format("%s (#%d)", name, idx)
        else
            loadout_line = string.format("same armour as %s (#%d) - %s differ",
                name, idx, tostring(diff or "charm/weapons"))
        end
        imgui.text("Game loadout: " .. loadout_line)
    else
        imgui.text("Current build: (not read yet)")
    end
    if imgui.button("Refresh build") then
        state.dirty = true
        item_name_cache = {}
        loadout_name_cache = { key = nil, name = nil, index = nil }
        local sig, err = current_signature()
        if sig == nil then
            notify("cannot read the current build: " .. tostring(err))
        else
            state.last_sig = sig
            notify("read the current build")
        end
    end
    local live = preview_match(state.last_sig)
    if live.link ~= nil then
        ui_text_colored(string.format("Matched now: %s -> %s  [%s]",
            tostring(live.link.label),
            tostring(live.link.item_set_name or "-"),
            tostring(live.mode)), 0xFF80FF80)
    elseif live.fallback ~= nil then
        imgui.text(string.format("Matched now: %s - %s", tostring(live.fallback_kind),
            tostring(item_set_name(live.fallback) or live.fallback)))
    else
        ui_text_colored("Matched now: no link for this build ("
            .. tostring(live.why) .. ")", 0xFF8080FF)
    end
    if state.last_match ~= nil then
        imgui.text(string.format("Last fired: %s -> %s  [%s]",
            tostring(state.last_match.label),
            tostring(state.last_match.item_set_name or "-"),
            tostring(state.last_match.mode)))
    end
    imgui.text("Last: " .. tostring(state.last_result))
    if state.task ~= nil then
        ui_text_colored("working: " .. tostring(state.task.reason), 0xFF80FFFF)
    end

    imgui.separator()
    imgui.text("Links")
    local choices = item_set_choices()
    if #config.links == 0 then
        imgui.text("No links yet: wear the build, pick an item set below,")
        imgui.text("press \"Link current build\".")
    end
    for i = #config.links, 1, -1 do
        if draw_link_row(config.links[i], i, choices, state.last_sig) then
            changed = true
        end
        imgui.separator()
    end

    imgui.text("New link")
    local loadouts = saved_loadouts()
    local loadout_choices = {}
    if #choices == 0 then
        ui_text_colored("no item loadouts found - load a save first", 0xFF8080FF)
    else
        -- every my-set slot, usable ones first: a loadout the reader cannot
        -- parse is still selectable by slot instead of disappearing
        local loadout_labels = {}
        local empty_loadouts = {}
        for _, l in ipairs(loadouts) do
            if (l.armor_count or 0) > 0 then
                loadout_choices[#loadout_choices + 1] = l
                loadout_labels[#loadout_labels + 1] =
                    string.format("%s  (#%d)", l.name, l.index)
            else
                empty_loadouts[#empty_loadouts + 1] = l
            end
        end
        for _, l in ipairs(empty_loadouts) do
            loadout_choices[#loadout_choices + 1] = l
            loadout_labels[#loadout_labels + 1] =
                string.format("Slot #%d  (no armour read)", l.index)
        end
        if #loadout_choices == 0 then
            ui_text_colored("no equipment loadout slots found", 0xFF8080FF)
        else
            local ai = labeled_dropdown("Armour set to link", "##new_armor",
                ui.armor_index, loadout_labels)
            if ai ~= nil then
                ui.armor_index = ai
                if config.debug then
                    log.info("[LinkedRestock] armour dropdown -> slot "
                        .. tostring(loadout_choices[ai + 1] and
                            loadout_choices[ai + 1].index))
                end
            end
        end

        local si = labeled_dropdown("Item set", "##new_set",
            ui.set_index, item_set_labels(choices))
        if si ~= nil then
            ui.set_index = si
            if config.debug then
                log.info("[LinkedRestock] item set dropdown -> pos " .. tostring(si)
                    .. " = " .. item_set_label(choices[si + 1]))
            end
        end

        local cur_set = choices[(ui.set_index or 0) + 1]
        if cur_set ~= nil then
            imgui.text(string.format("  -> slot #%d, %d items%s",
                cur_set.index, cur_set["count"] or 0,
                cur_set.named and "" or " (unnamed)"))
        end

        local mi = labeled_dropdown("Match", "##new_mode",
            ui.mode_index, mode_labels())
        if mi ~= nil then ui.mode_index = mi end

        if #loadout_choices > 0
            and imgui.button("Link selected armour set##link_loadout") then
            local entry = loadout_choices[(ui.armor_index or 0) + 1]
            local set = entry and myset_by_index(entry.index)
            local sig, err = signature_from_myset(set)
            local target = choice_index(choices, ui.set_index or 0)
            if entry == nil then
                notify("no armour set selected")
            elseif sig == nil then
                notify("cannot link that loadout: " .. tostring(err))
            elseif target == nil then
                notify("no item set selected")
            else
                local mode = mode_from_index(ui.mode_index)
                local forced = nil
                -- A saved loadout has no weapon roll fields, and the game does
                -- not store decorations on every record the same way, so a link
                -- built from one matches on armour pieces + charm type. Tighten
                -- it in the row's Match dropdown once it is proven in game.
                if mode == "full" or mode == "inherit" or mode == "no_weapon" then
                    mode = "gear"
                    forced = true
                end
                local link = normalize_link({
                    id = tostring(os.time()) .. tostring(math.random(999)),
                    label = entry.name,
                    mode = mode,
                    item_set = target,
                    item_set_name = item_set_name(target),
                    apply_mode = "exact",
                    origin = "loadout",
                    sig = sig,
                })
                if link == nil then
                    notify("cannot read that loadout's armour")
                else
                    config.links[#config.links + 1] = link
                    changed = true
                    notify("linked " .. entry.name .. " -> "
                        .. tostring(link.item_set_name or link.item_set)
                        .. (forced and " (armour + charm)" or ""))
                end
            end
        end

        if imgui.button("Link current build##link_current") then
            local sig, err = current_signature()
            local target = choice_index(choices, ui.set_index or 0)
            if sig == nil then
                notify("cannot read the current build: " .. tostring(err))
            elseif target == nil then
                notify("no item set selected")
            else
                local name, _, quality = game_loadout_name(sig)
                local label = name
                    and (quality == "full" and name or (name .. " (armour)"))
                    or ("Custom build " .. os.date("%H:%M"))
                local link = normalize_link({
                    id = tostring(os.time()) .. tostring(math.random(999)),
                    label = label,
                    mode = mode_from_index(ui.mode_index),
                    item_set = target,
                    item_set_name = item_set_name(target),
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
        if imgui.button("Apply now##apply_now") then
            state.dirty = true
            fire("manual")
        end
    end

    imgui.separator()
    local default_labels = { "(none)" }
    for _, c in ipairs(choices) do default_labels[#default_labels + 1] = c.name end
    local dpos = nil
    local cur = choice_pos(choices, config.default_item_set)
    if cur ~= nil then dpos = cur + 1 else dpos = 0 end
    local np = labeled_dropdown("Default item set when no link matches",
        "##default_set", dpos, default_labels)
    if np ~= nil then
        if np == 0 then
            config.default_item_set = nil
        else
            config.default_item_set = choice_index(choices, np - 1)
        end
        changed = true
    end

    draw_preview()

    imgui.separator()
    local dc2, dv2 = imgui.checkbox("Diagnostics", ui.show_diag)
    if dc2 then ui.show_diag = dv2 end
    if ui.show_diag then
        imgui.text("gear source: " .. tostring(state.last_gear_source or "-"))
        imgui.text("slot layout: " .. tostring(last_slot_layout or "-"))
        imgui.text("slot score: " .. tostring(last_base_score or "-"))
        if state.last_sig ~= nil then
            imgui.text("worn: armour " .. tostring(#(state.last_sig.armor_ids or {}))
                .. " | weapons " .. tostring(#(state.last_sig.weapon_ids or {}))
                .. " (" .. table.concat(state.last_sig.weapon_ids or {}, " ") .. ")"
                .. " | charm " .. tostring(state.last_sig.charm_id or "-"))
        end
        local nreal = 0
        for _, c in ipairs(choices) do
            if c.named or (c["count"] or 0) > 0 then nreal = nreal + 1 end
        end
        imgui.text("item sets: " .. tostring(nreal) .. " real / "
            .. tostring(#item_sets()) .. " slots")
        for pos, c in ipairs(choices) do
            if pos <= 10 and (c.named or (c["count"] or 0) > 0) then
                imgui.text(string.format("  #%d %s - %d items", c.index,
                    tostring(c.name), c["count"] or 0))
            end
        end
        imgui.text("equipment loadouts: " .. tostring(#loadout_choices) .. " slots")
        for pos, l in ipairs(loadout_choices) do
            if pos <= 10 and (l.armor_count or 0) > 0 then
                imgui.text(string.format("  #%d %s - %d armour", l.index,
                    tostring(l.name), l.armor_count))
            end
        end
        imgui.text("pouch slots: " .. tostring(#pouch_works())
            .. " | box slots: " .. tostring(#box_works()))
        imgui.text("apply candidates: " .. tostring(#apply_candidates()))
        if imgui.button("Reload lists##reload_lists") then
            item_choice_cache = { at = -1, list = {} }
            saved_loadout_cache = { at = -1, list = {} }
            item_name_cache = {}
            notify("re-read item sets and loadouts")
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
    imgui.text("restock uses the game's item-set path; nothing is created.")
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
    labeled_dropdown = labeled_dropdown,
    link_mismatch = link_mismatch,
    group_key = group_key,
    default_config = default_config,
    MODES = MODES,
    MODE_GROUPS = MODE_GROUPS,
    -- game-side hooks, exercised against a fake save in tests/pipeline_test.lua
    state = state,
    start_task = start_task,
    tick_task = tick_task,
    poll = poll,
    fire = fire,
    current_signature = current_signature,
    signature_from_myset = signature_from_myset,
    game_loadout_name = game_loadout_name,
    piece_key = piece_key,
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
