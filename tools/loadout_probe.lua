--
-- loadout_probe.lua — read-only discovery probe for Linked Restock
--
-- Why: the mod needs three things the save layout does not spell out at the
-- Lua level — (1) which game method applies an item my-set, (2) what the live
-- "currently equipped" objects look like, and (3) where the local hunter's
-- skills and weapon stats can be read from. This probe dumps all of it.
--
-- It never writes to the game, never hooks anything, and only writes JSON
-- under reframework/data/. Run it in the hub (not mid-quest): the equipped
-- gear and the item box both exist there.
--
-- Outputs (all in <game>\reframework\data\):
--   linked_restock_probe_types.json   type/field/method surface of candidates
--   linked_restock_probe_gear.json    equipment my-sets, current gear, skills
--   linked_restock_probe_items.json   item my-sets, pouch, box, item names
--   linked_restock_probe_apply.json   apply-method candidates + a dry call log
--
-- Load: <game>\reframework\autorun\loadout_probe.lua
--   REFramework menu (Insert) -> Script Generated UI -> "Linked Restock Probe"
--   -> "Dump everything". Then send the four JSON files back.
--
-- Every SDK call is pcall-guarded: a missing type is reported, never thrown.
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui

local PROBE_VERSION = "1"
local M = "[LinkedRestockProbe]"

local ALREADY_LOADED = _G.LINKED_RESTOCK_PROBE_LOADED == true
_G.LINKED_RESTOCK_PROBE_LOADED = true

-- ---------------------------------------------------------------------------
-- helpers (same shapes the other probes on this build use)
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

local function enum_number(v)
    if type(v) == "number" then return v end
    if v == nil then return nil end
    for _, n in ipairs({ "m_value", "value__", "Value" }) do
        local x = field_value(v, n)
        if type(x) == "number" then return x end
    end
    if type(v) == "userdata" then
        return safe(function() return v:read_byte(0) end)
    end
    return nil
end

-- Shallow object description: primitives inline, objects/arrays by type and
-- size. Never recurses past one level, so a bad pointer cannot branch.
-- A param/return/field type: REFramework exposes get_name() and (sometimes)
-- get_full_name(); try both.
local function name_of(thing)
    if thing == nil then return nil end
    return safe(function() return thing:get_full_name() end)
        or safe(function() return thing:get_name() end)
end

-- Param type names of a method: get_num_params() is the count, the returned
-- array is indexed 1..n (not a Lua table).
local function method_param_names(m)
    local out = {}
    local n = safe(function() return m:get_num_params() end)
    local pts = safe(function() return m:get_param_types() end)
    if pts == nil then return out end
    if type(n) ~= "number" then
        local k = safe(function() return #pts end)
        n = (type(k) == "number") and k or 0
    end
    for i = 1, n do
        local p = safe(function() return pts[i] end)
        out[#out + 1] = name_of(p) or "?"
    end
    return out
end

local function describe(obj, depth, maxFields)
    depth = depth or 0
    maxFields = maxFields or 60
    if obj == nil then return nil end
    if type(obj) ~= "userdata" and type(obj) ~= "table" then
        return { value = safe_str(obj) }
    end
    local out = { type = type_name(obj) }
    local td = safe(function() return obj:get_type_definition() end)
    local fields = td and safe(function() return td:get_fields() end) or {}
    local seen = 0
    out.fields = {}
    for _, f in ipairs(fields) do
        if seen >= maxFields then break end
        local name = safe(function() return f:get_name() end)
        local is_static = safe(function() return f:is_static() end)
        if name and not is_static then
            seen = seen + 1
            local ftype = safe(function() return f:get_type() end)
            local tname = ftype and safe(function() return ftype:get_full_name() end)
            local v = safe(function() return f:get_data(obj) end)
            local entry = { name = name, type = tname }
            if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                entry.value = v
            elseif v ~= nil and depth < 1 then
                local child = describe(v, depth + 1, 12)
                entry.child = child
            end
            out.fields[#out.fields + 1] = entry
        end
    end
    return out
end

local function dump_type(typeName, opts)
    opts = opts or {}
    local out = { name = typeName }
    local td = safe(sdk.find_type_definition, typeName)
    if not td then
        out.missing = true
        return out
    end
    out.parent = safe(function()
        local p = td:get_parent_type()
        return p and p:get_full_name() or nil
    end)
    out.fields = {}
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        out.fields[#out.fields + 1] = {
            name = safe(function() return f:get_name() end),
            type = name_of(safe(function() return f:get_type() end)),
            static = safe(function() return f:is_static() end) == true,
        }
    end
    if opts.methods ~= false then
        out.methods = {}
        local n = 0
        for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
            if n >= (opts.max_methods or 500) then break end
            n = n + 1
            out.methods[#out.methods + 1] = {
                name = safe(function() return m:get_name() end),
                params = method_param_names(m),
                returns = name_of(safe(function() return m:get_return_type() end)),
                static = safe(function() return m:is_static() end) == true,
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- roots
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

local function item_sets()
    local sd = save_data()
    local ims = sd and field_value(sd, "_ItemMySet")
    return collect(ims and field_value(ims, "_Data"), 64)
end

-- Item id (fixed id) -> localized name, through the master data table the
-- meal mods use: VariousDataManager._Setting._ItemSetting._ItemData and its
-- getDataByFixedId(System.Int32) method, then _RawName -> via.gui.message.
-- (The static app.user_data.ItemData form returns nil on this build.)
local function item_name(fixed_id)
    if fixed_id == nil or fixed_id == 0 then return nil end
    local vm = safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
    local setting = vm and field_value(vm, "_Setting")
    local item_setting = setting and field_value(setting, "_ItemSetting")
    local tbl = item_setting and field_value(item_setting, "_ItemData")
    local entry = nil
    if tbl ~= nil then
        local td = safe(function() return tbl:get_type_definition() end)
        local m = td and safe(function()
            return td:get_method("getDataByFixedId(System.Int32)")
        end)
        entry = m and safe(function() return m:call(tbl, fixed_id) end)
    end
    if entry == nil then return nil end
    local raw = field_value(entry, "_RawName") or field_value(entry, "RawName")
    if raw ~= nil then
        local msg = safe(function() return via.gui.message.get(raw) end)
        if msg then return msg end
    end
    return safe_str(field_value(entry, "Name"))
end

-- ---------------------------------------------------------------------------
-- sections
-- ---------------------------------------------------------------------------

local function dump_types()
    local out = {
        probe_version = PROBE_VERSION,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        types = {},
    }
    -- fields only for the save-data structs (no interesting methods), fields
    -- plus methods for the utilities that can apply an item set
    local structs = {
        "app.SaveDataManager",
        "app.savedata.cUserSaveData",
        "app.savedata.cUserSaveParam",
        "app.savedata.cEquipParam",
        "app.savedata.cEquipWork",
        "app.savedata.cMysetEquipWork",
        "app.savedata.cEquipMyset",
        "app.savedata.cMysetBaseParam",
        "app.savedata.cEquipIndex",
        "app.savedata.cItemParam",
        "app.savedata.cItemWork",
        "app.savedata.cItemMySet",
        "app.savedata.cItemMySetData",
        "app.savedata.cCharmEquipped",
        "app.cPlayerCatalogHolder",
        "app.EquipDataHolder",
    }
    local utils = {
        "app.ItemMySetUtil",
        "app.ItemPouchUtil",
        "app.ItemUtil",
        "app.MysetLinkUtil",
        "app.MysetLinkUtil.MysetLinker",
        "app.ShareMysetUtil",
        "app.EquipUtil",
        "app.ItemBoxController",
    }
    for _, n in ipairs(structs) do
        out.types[n] = dump_type(n, { methods = false })
    end
    for _, n in ipairs(utils) do
        out.types[n] = dump_type(n, { max_methods = 400 })
    end
    json.dump_file("linked_restock_probe_types.json", out)
    return "types"
end

local function dump_gear()
    local out = {
        probe_version = PROBE_VERSION,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        sections = {},
    }

    local sd, how = save_data()
    out.save_data = { present = sd ~= nil, how = how, type = type_name(sd) }

    local ep = equip_param()
    out.equip_param = { present = ep ~= nil, type = type_name(ep) }

    -- current my-set index array (per category / weapon type)
    local idx = ep and field_value(ep, "_EquipIndex")
    out.equip_index = {
        present = idx ~= nil,
        type = type_name(idx),
        values = {},
    }
    for i, v in ipairs(collect(idx and field_value(idx, "Index"), 32)) do
        out.equip_index.values[i] = enum_number(v) or safe_str(v)
    end

    -- charm currently equipped
    local charm = ep and field_value(ep, "_CharmEquipped")
    out.charm = {
        present = charm ~= nil,
        type = type_name(charm),
        main = charm and enum_number(field_value(charm, "MainCharm")),
        sub = charm and enum_number(field_value(charm, "SubCharm")),
    }

    -- every saved equipment my-set: this is the client's "armor loadout"
    out.equip_mysets = {}
    for si, set in ipairs(collect(ep and field_value(ep, "_EquipMySet"), 64)) do
        local param = field_value(set, "_MysetParam")
        local entry = {
            index = si,
            name = param and safe_str(field_value(param, "MysetName")),
            is_empty = param and enum_number(field_value(param, "IsEmpty")),
            type = type_name(set),
            pieces = {},
        }
        for pi, piece in ipairs(collect(field_value(set, "_MysetEquipWork"), 16)) do
            local jewels = collect(field_value(piece, "EquipmentAccessoryIdArray"), 8)
            local jewel_ids = {}
            for i, j in ipairs(jewels) do jewel_ids[i] = enum_number(j) end
            entry.pieces[pi] = {
                type = type_name(piece),
                category = enum_number(field_value(piece, "Category")),
                gender = enum_number(field_value(piece, "GenderType")),
                is_none = enum_number(field_value(piece, "IsNone")),
                free0 = enum_number(field_value(piece, "FreeVal0")),
                free1 = enum_number(field_value(piece, "FreeVal1")),
                insect_id = enum_number(field_value(piece, "InsectId")),
                insect_equip = enum_number(field_value(piece, "InsectEquipId")),
                jewels = jewel_ids,
            }
        end
        out.equip_mysets[si] = entry
    end

    -- live catalog holder: the runtime "what am I wearing" source
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    local catalog = pm and safe(function() return pm:get_Catalog() end)
    out.catalog = {
        present = catalog ~= nil,
        type = type_name(catalog),
        shape = describe(catalog, 0, 40),
    }
    if catalog then
        out.catalog_lists = {}
        for _, field_name in ipairs({ "cArmorList", "cWeaponTypePack", "cWpCharm",
                                      "cAmuletList", "cMantleList", "cWp10Insect" }) do
            local list = field_value(catalog, field_name)
            local entry = {
                present = list ~= nil,
                type = type_name(list),
                count = nil,
                items = {},
            }
            if list ~= nil then
                local items = collect(list, 8)
                entry.count = #items
                for i, it in ipairs(items) do
                    entry.items[i] = describe(it, 0, 20)
                end
            end
            out.catalog_lists[field_name] = entry
        end
    end

    -- skills of the local hunter's equipment
    local function hunter_status_of(ch)
        if ch == nil or ch == 0 then return nil end
        return safe(function()
            return ch:call("get_HunterStatus")
        end) or field_value(ch, "<HunterStatus>k__BackingField")
    end
    local master = pm and safe(function() return pm:getMasterPlayer() end)
    local character = master and (field_value(master, "<Character>k__BackingField")
        or field_value(master, "_Character"))
    local status = hunter_status_of(character)
    local skill = status and field_value(status, "_Skill")
    out.skills = {
        master_player = master ~= nil,
        character = type_name(character),
        character_source = "<Character>k__BackingField",
        status = type_name(status),
        skill_object = type_name(skill),
        entries = {},
    }
    local holder = skill and field_value(skill, "_EquipDataHolderRef")
    out.skills.holder = type_name(holder)
    local arr = holder and field_value(holder, "_EquipSkillDataArray")
    out.skills.array = type_name(arr)
    for i, e in ipairs(collect(arr, 128)) do
        out.skills.entries[i] = {
            skill = enum_number(field_value(e, "_Skill"))
                or enum_number(field_value(e, "_SkillId")),
            level = enum_number(field_value(e, "_SkillLv"))
                or enum_number(field_value(e, "_Level")),
            raw_type = type_name(field_value(e, "_SkillLv")),
            raw_byte = safe(function()
                local raw = field_value(e, "_SkillLv")
                return type(raw) == "userdata" and raw:read_byte(0) or nil
            end),
        }
    end

    -- weapon works in the box + the weapon data the game exposes for them
    out.weapon_samples = {}
    local box = collect(ep and field_value(ep, "_EquipBox"), 400)
    out.equip_box_count = #box
    local box_obj = ep and field_value(ep, "_EquipBox")
    out.equip_box_count_total = safe(function()
        local cnt = box_obj and box_obj.get_Count
        if cnt == nil then return nil end
        return cnt:call(box_obj)
    end)
    local shown = 0
    local weapon_util = safe(sdk.find_type_definition, "app.WeaponUtil")
    local get_weapon_data = weapon_util and safe(function()
        return weapon_util:get_method("getWeaponData(app.savedata.cEquipWork)")
    end)
    for _, work in ipairs(box) do
        if shown >= 6 then break end
        local cat = enum_number(field_value(work, "Category_Gender"))
        if cat ~= nil and (cat % 256) == 13 then
            shown = shown + 1
            out.weapon_samples[shown] = {
                work = describe(work, 0, 30),
                weapon_data = nil,
            }
            if get_weapon_data then
                local wd = safe(function() return get_weapon_data:call(nil, work) end)
                out.weapon_samples[shown].weapon_data = describe(wd, 0, 40)
            end
        end
    end

    json.dump_file("linked_restock_probe_gear.json", out)
    return "gear"
end

local function dump_items()
    local out = {
        probe_version = PROBE_VERSION,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        item_param = {},
        item_mysets = {},
        pouch = {},
        box = {},
    }
    local ip = item_param()
    out.item_param.present = ip ~= nil
    out.item_param.type = type_name(ip)

    -- saved item my-sets
    for si, set in ipairs(item_sets()) do
        local entry = {
            index = si,
            type = type_name(set),
            name = safe_str(field_value(set, "Name")),
            items = {},
            order_len = #collect(field_value(set, "ItemOrder_Index"), 64),
        }
        for ii, work in ipairs(collect(field_value(set, "_PouchItem"), 64)) do
            local id = enum_number(field_value(work, "ItemIdFixed"))
            local num = enum_number(field_value(work, "Num"))
            if id ~= nil and id ~= 0 then
                entry.items[#entry.items + 1] = {
                    id = id, count = num, name = item_name(id),
                }
            end
        end
        out.item_mysets[si] = entry
    end

    -- live pouch
    for i, work in ipairs(collect(ip and field_value(ip, "_PouchItem"), 64)) do
        local id = enum_number(field_value(work, "ItemIdFixed"))
        local num = enum_number(field_value(work, "Num"))
        if id ~= nil and id ~= 0 then
            out.pouch[#out.pouch + 1] = {
                slot = i, id = id, count = num, name = item_name(id),
            }
        end
    end

    -- item box: aggregate per item id, plus a raw sample of slots
    local box = collect(ip and field_value(ip, "_BoxItem"), 2000)
    out.box_slots = #box
    out.box_samples = {}
    local totals = {}
    for i, work in ipairs(box) do
        local id = enum_number(field_value(work, "ItemIdFixed"))
        local num = enum_number(field_value(work, "Num"))
        if id ~= nil and id ~= 0 and num and num > 0 then
            totals[id] = (totals[id] or 0) + num
            if #out.box_samples < 12 then
                out.box_samples[#out.box_samples + 1] = {
                    slot = i, id = id, count = num, name = item_name(id),
                }
            end
        end
    end
    for id, total in pairs(totals) do
        out.box[#out.box + 1] = { id = id, count = total, name = item_name(id) }
    end
    table.sort(out.box, function(a, b) return a.id < b.id end)

    json.dump_file("linked_restock_probe_items.json", out)
    return "items"
end

local function dump_apply()
    local out = {
        probe_version = PROBE_VERSION,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        candidates = {},
        pattern_hits = {},
        notes = {},
    }

    -- Every method on the utility types, filtered by name so the real apply
    -- call is easy to spot.
    local names = { "app.ItemMySetUtil", "app.ItemPouchUtil", "app.ItemUtil",
                    "app.ItemMySet", "app.MysetLinkUtil", "app.EquipUtil",
                    "app.ItemBoxController", "app.ItemBoxBase" }
    for _, tn in ipairs(names) do
        local td = safe(sdk.find_type_definition, tn)
        local entry = { present = td ~= nil, methods = {} }
        if td then
            for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
                local mname = safe(function() return m:get_name() end) or ""
                local params = method_param_names(m)
                entry.methods[#entry.methods + 1] = {
                    name = mname, params = params,
                    static = safe(function() return m:is_static() end) == true,
                }
                local low = string.lower(mname)
                if low:find("myset") or low:find("pouch") or low:find("restock")
                    or low:find("refill") or low:find("item") then
                    out.pattern_hits[#out.pattern_hits + 1] = {
                        type = tn, name = mname, params = params,
                    }
                end
            end
        end
        out.candidates[tn] = entry
    end

    -- What the save looks like right now, so a later comparison can prove a
    -- call actually did something. Read-only.
    local ip = item_param()
    local pouch_before = {}
    for _, work in ipairs(collect(ip and field_value(ip, "_PouchItem"), 64)) do
        local id = enum_number(field_value(work, "ItemIdFixed"))
        if id and id ~= 0 then
            pouch_before[id] = (pouch_before[id] or 0) + (enum_number(field_value(work, "Num")) or 0)
        end
    end
    out.pouch_before = pouch_before
    out.item_set_count = #item_sets()
    out.notes[#out.notes + 1] =
        "Nothing was called. The mod picks the apply method by name and verifies "
        .. "the pouch afterwards; this file lists the candidates to confirm it."

    json.dump_file("linked_restock_probe_apply.json", out)
    return "apply"
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local last_result = "(nothing dumped yet)"

local function run(fn)
    local ok, res = pcall(fn)
    if ok then
        last_result = "wrote " .. tostring(res) .. " probe"
        log.info(M .. " " .. last_result)
    else
        last_result = "failed: " .. tostring(res)
        log.warn(M .. " " .. last_result)
    end
end

local function draw_ui()
    if not imgui.tree_node("Linked Restock Probe v" .. PROBE_VERSION) then return end
    imgui.text("Read-only. Run this in the hub (not mid-quest).")
    imgui.text("Writes JSON to reframework/data/, nothing else.")
    imgui.separator()
    if imgui.button("Dump everything") then
        run(function()
            dump_types()
            dump_gear()
            dump_items()
            dump_apply()
            return "all four"
        end)
    end
    imgui.same_line()
    if imgui.button("Types") then run(dump_types) end
    imgui.same_line()
    if imgui.button("Gear") then run(dump_gear) end
    imgui.same_line()
    if imgui.button("Items") then run(dump_items) end
    imgui.same_line()
    if imgui.button("Apply candidates") then run(dump_apply) end
    imgui.separator()
    imgui.text("result: " .. tostring(last_result))
    imgui.tree_pop()
end

-- ---------------------------------------------------------------------------

if not ALREADY_LOADED then
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.warn(M .. " draw_ui: " .. tostring(err)) end
    end)
    log.info(M .. " loaded v" .. PROBE_VERSION .. " (read-only, UI only)")
else
    log.info(M .. " duplicate load ignored")
end
