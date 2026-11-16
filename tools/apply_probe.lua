--
-- apply_probe.lua — Linked Restock apply-path probe
--
-- The mod's own apply path has never been proven in game: the first probe only
-- *listed* the candidate methods. This probe calls them, one per step, and
-- records the pouch before/after each call so the one that actually works, and
-- the index convention it wants, are facts instead of guesses.
--
--   Copy next to the mod in <game>\reframework\autorun\ and reload scripts.
--   Insert -> Script Generated UI -> Linked Restock Apply Probe v2.
--
--   WARNING: the steps really change the pouch (that is the point). Run it in
--   the hub, and press an item loadout in game afterwards to get back to normal.
--   It never touches the item box except through the game's own calls.
--
-- Writes reframework/data/linked_restock_apply_probe.json.
--

local M = "[LinkedRestockApplyProbe]"
local ALREADY = _G.LINKED_RESTOCK_APPLY_PROBE_LOADED
_G.LINKED_RESTOCK_APPLY_PROBE_LOADED = true

local PROBE_VERSION = "2"
local OUT_FILE = "linked_restock_apply_probe.json"
local FRAMES_BETWEEN_STEPS = 120 -- ~2 s: give an async apply time to land

-- ---------------------------------------------------------------------------
-- save-data helpers (same shapes the mod uses)
-- ---------------------------------------------------------------------------

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function calls_of(v)
    if v == nil then return nil end
    local t = type(v)
    if t ~= "userdata" and t ~= "table" then return nil end
    local n = safe(function() return v.get_Count end)
    local i = safe(function() return v.get_Item end)
    if n ~= nil and i ~= nil then return n, i end
    return nil
end

local function collect(list, maxItems)
    local out = {}
    if list == nil then return out end
    local cnt, item = calls_of(list)
    if cnt ~= nil then
        local n = safe(function() return cnt:call(list) end) or 0
        if maxItems and n > maxItems then n = maxItems end
        for k = 0, n - 1 do
            out[#out + 1] = safe(function() return item:call(list, k) end)
        end
        return out
    end
    local n = safe(function() return list:get_Count() end)
    if n ~= nil and safe(function() return list:get_Item(0) end) ~= nil then
        for k = 0, n - 1 do out[#out + 1] = safe(function() return list:get_Item(k) end) end
        return out
    end
    for k = 0, (maxItems or 64) - 1 do
        local v = safe(function() return list[k] end)
        if v == nil then break end
        out[#out + 1] = v
    end
    return out
end

local function enum_number(v)
    if v == nil then return nil end
    local t = type(v)
    if t == "number" then return v end
    if t == "boolean" or t == "string" then return nil end
    local n = safe(function() return v:get_value() end)
    if type(n) == "number" then return n end
    local n2 = safe(function() return tonumber(tostring(v)) end)
    if type(n2) == "number" then return n2 end
    return nil
end

local function descriptors(obj)
    local td = safe(function() return obj:get_type_definition() end)
    local fields = td and safe(function() return td:get_fields() end) or {}
    local out = {}
    for _, f in ipairs(fields) do
        local name = safe(function() return f:get_name() end)
        if name then out[name] = f end
    end
    return out
end

local function field_value(obj, name)
    if obj == nil then return nil end
    local v = safe(function() return obj:get_field(name) end)
    if v ~= nil then return v end
    local v2 = safe(function() return obj[name] end)
    if v2 ~= nil then return v2 end
    local f = descriptors(obj)[name]
    if f then return safe(function() return f:get_data(obj) end) end
    return nil
end

local function write_field(obj, name, value)
    if obj == nil then return false end
    local ok = safe(function() obj:set_field(name, value) return true end)
    if ok then return true end
    local f = descriptors(obj)[name]
    if f == nil then return false end
    return safe(function() f:set_data(obj, value) return true end) == true
end

local function save_data()
    local sdm = safe(function() return sdk.get_managed_singleton("app.SaveDataManager") end)
    return sdm and safe(function() return sdm:getCurrentUserSaveData() end)
end

local function item_param()
    local sd = save_data()
    return sd and field_value(sd, "_Item")
end

local function pouch_works()
    return collect(item_param() and field_value(item_param(), "_PouchItem"), 64)
end

local function pouch_snapshot()
    local out = {}
    for i, w in ipairs(pouch_works()) do
        local id = enum_number(field_value(w, "ItemIdFixed")) or 0
        local n = enum_number(field_value(w, "Num")) or 0
        if id ~= 0 and n > 0 then out[tostring(id)] = (out[tostring(id)] or 0) + n end
        out["slots_" .. tostring(i)] = tostring(id) .. "x" .. tostring(n)
    end
    return out
end

local function snapshot_delta(before, after)
    local delta = {}
    local keys = {}
    for k in pairs(before or {}) do keys[k] = true end
    for k in pairs(after or {}) do keys[k] = true end
    for k in pairs(keys) do
        if not string.find(k, "^slots_") then
            local a = before and before[k] or 0
            local b = after and after[k] or 0
            if a ~= b then delta[k] = { from = a, to = b } end
        end
    end
    return delta
end

local function item_sets()
    local sd = save_data()
    local ims = sd and field_value(sd, "_ItemMySet")
    return collect(ims and field_value(ims, "_Data"), 64)
end

local function set_items(set)
    local out = {}
    for _, w in ipairs(collect(field_value(set, "_PouchItem"), 64)) do
        local id = enum_number(field_value(w, "ItemIdFixed")) or 0
        local n = enum_number(field_value(w, "Num")) or 0
        if id ~= 0 and n > 0 then out[#out + 1] = { id = id, count = n } end
    end
    return out
end

local function set_name(set)
    local v = field_value(set, "Name")
    if v == nil then return nil end
    local t = type(v)
    if t == "string" or t == "number" then return tostring(v) end
    return safe(function() return tostring(v) end)
end

-- ---------------------------------------------------------------------------
-- method resolution
-- ---------------------------------------------------------------------------

local function type_def(name)
    return safe(function() return sdk.find_type_definition(name) end)
end

local function method(tn, sig)
    local t = type_def(tn)
    return t and safe(function() return t:get_method(sig) end)
end

-- call a static method: returns value, err
local function static_call(tn, sig, ...)
    local m = method(tn, sig)
    if m == nil then return nil, "missing " .. tn .. "." .. sig end
    local args = { ... }
    local ok, res = pcall(function() return m:call(nil, unpack(args)) end)
    if not ok then return nil, tostring(res) end
    return res
end

local function method_exists(tn, sig)
    return method(tn, sig) ~= nil
end

-- ---------------------------------------------------------------------------
-- plan
-- ---------------------------------------------------------------------------

local plan = {}
local info = {}
local index = 0
local pending = nil
local results = {}
local running = false

local function add(label, fn)
    plan[#plan + 1] = { label = label, run = fn }
end

local function build_plan()
    plan = {}
    info = { introspect = {}, item_sets = {}, pouch_before = pouch_snapshot() }

    local sets = item_sets()
    for i, set in ipairs(sets) do
        local items = set_items(set)
        if #items > 0 or set_name(set) ~= nil then
            info.item_sets[#info.item_sets + 1] = {
                index = i, name = set_name(set), count = #items, items = items,
            }
        end
    end

    -- index convention: which argument values does the game consider valid?
    local probe_range = {}
    for i = -1, 6 do probe_range[#probe_range + 1] = i end
    for _, i in ipairs(probe_range) do
        local valid, err = static_call("app.ItemMySetUtil",
            "isValidData(System.Int32)", i)
        local data = set_name(static_call("app.ItemMySetUtil",
            "getItemMySetData(System.Int32)", i) or nil)
        info.introspect[#info.introspect + 1] = {
            arg = i, valid = tostring(valid), err = err, name = data,
        }
    end

    local target = info.item_sets[1]
    info.target = target

    if target == nil then return end
    local t = target.index

    -- the counts the game itself reports for one id of that set, at both bases
    local first_id = target.items[1] and target.items[1].id
    if first_id ~= nil then
        local v0 = static_call("app.ItemMySetUtil", "getItemNum(System.Int32, app.ItemDef.ID)", t, first_id)
        local v1 = static_call("app.ItemMySetUtil", "getItemNum(System.Int32, app.ItemDef.ID)", t - 1, first_id)
        info.item_num = { id = first_id, at_index = tostring(v0), at_index_minus_1 = tostring(v1) }
    end

    add("applyMySetToPouch(" .. t .. ")", function()
        return static_call("app.ItemMySetUtil", "applyMySetToPouch(System.Int32)", t)
    end)
    add("applyMySetToPouch(" .. (t - 1) .. ")", function()
        return static_call("app.ItemMySetUtil", "applyMySetToPouch(System.Int32)", t - 1)
    end)
    add("ItemMySetUtil.apply(set)", function()
        local set = static_call("app.ItemMySetUtil", "getItemMySetData(System.Int32)", t)
        if set == nil then return nil, "getItemMySetData returned nil" end
        return static_call("app.ItemMySetUtil", "apply(app.savedata.cItemMySet)", set)
    end)
    add("ItemUtil.fillPouchItems()", function()
        return static_call("app.ItemUtil", "fillPouchItems()")
    end)
    add("ItemUtil.fillPouchItem(id, count)", function()
        if first_id == nil then return nil, "no item id" end
        return static_call("app.ItemUtil",
            "fillPouchItem(app.ItemDef.ID, System.Nullable`1<System.Int16>)",
            first_id, target.items[1].count)
    end)
    add("direct write: Num +1 on first pouch slot", function()
        local pouch = pouch_works()
        local w = pouch[1]
        if w == nil then return nil, "no pouch work" end
        local n = enum_number(field_value(w, "Num")) or 0
        local ok = write_field(w, "Num", n + 1)
        return ok
    end)
    add("direct write: empty slot gets item " .. tostring(first_id), function()
        local pouch = pouch_works()
        for _, w in ipairs(pouch) do
            local id = enum_number(field_value(w, "ItemIdFixed")) or 0
            if id == 0 then
                return write_field(w, "ItemIdFixed", first_id)
                    and write_field(w, "Num", 1)
            end
        end
        return nil, "no empty pouch slot exists in _PouchItem"
    end)
end

local function finish()
    info.steps = results
    info.pouch_after = pouch_snapshot()
    info.generated_at = os.date("%Y-%m-%d %H:%M:%S")
    info.probe_version = PROBE_VERSION
    info.methods = {
        applyMySetToPouch = method_exists("app.ItemMySetUtil", "applyMySetToPouch(System.Int32)"),
        apply_set = method_exists("app.ItemMySetUtil", "apply(app.savedata.cItemMySet)"),
        fill_pouch_items = method_exists("app.ItemUtil", "fillPouchItems()"),
        fill_pouch_item = method_exists("app.ItemUtil",
            "fillPouchItem(app.ItemDef.ID, System.Nullable`1<System.Int16>)"),
        change_item_num = method_exists("app.ItemUtil", "changeItemNum(app.ItemDef.ID, System.Int16, app.ItemUtil.POUCH_TYPE)"),
        pouch_size = tostring(static_call("app.ItemUtil", "getPouchSize(app.ItemUtil.POUCH_TYPE)", 0) or "?"),
    }
    safe(function() json.dump_file(OUT_FILE, info) end)
    last_result = "wrote " .. OUT_FILE
    log.info(M .. " " .. last_result)
    running = false
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local last_result = "(not run)"

local function draw_ui()
    if not imgui.tree_node("Linked Restock Apply Probe v" .. PROBE_VERSION) then
        return
    end
    imgui.text("Calls the apply methods and records the pouch before/after each.")
    imgui.text("This really changes the pouch. Run it in the hub.")
    imgui.text("Reload or press an item loadout in game afterwards to reset.")
    imgui.separator()
    if not running then
        if imgui.button("Run steps") then
            build_plan()
            index = 0
            pending = nil
            results = {}
            running = true
            last_result = "running " .. tostring(#plan) .. " step(s)"
            log.info(M .. " " .. last_result)
        end
        imgui.same_line()
        if imgui.button("Dump state only") then
            build_plan()
            info.steps = {}
            info.pouch_after = pouch_snapshot()
            info.generated_at = os.date("%Y-%m-%d %H:%M:%S")
            info.probe_version = PROBE_VERSION
            safe(function() json.dump_file(OUT_FILE, info) end)
            running = false
            last_result = "wrote " .. OUT_FILE .. " (no apply calls)"
        end
    else
        imgui.text(string.format("running: %d/%d", index, #plan))
    end
    imgui.separator()
    imgui.text("result: " .. tostring(last_result))
    for i = #results, math.max(1, #results - 5), -1 do
        local r = results[i]
        local changed = 0
        for _ in pairs(r.delta or {}) do changed = changed + 1 end
        imgui.text(string.format("  %s -> %s (%d changed)",
            tostring(r.label), r.ok and "ok" or "err", changed))
    end
    imgui.tree_pop()
end

-- ---------------------------------------------------------------------------
-- step runner
-- ---------------------------------------------------------------------------

local function tick()
    if not running then return end

    if pending ~= nil then
        if pending.wait > 0 then
            pending.wait = pending.wait - 1
            return
        end
        local after = pouch_snapshot()
        results[#results + 1] = {
            label = pending.label,
            ok = pending.ok,
            err = pending.err,
            delta = snapshot_delta(pending.before, after),
            pouch = after,
        }
        pending = nil
        return
    end

    if index >= #plan then
        finish()
        return
    end

    index = index + 1
    local p = plan[index]
    local before = pouch_snapshot()
    local ok, err = pcall(p.run)
    pending = {
        label = p.label,
        before = before,
        wait = FRAMES_BETWEEN_STEPS,
        ok = ok,
        err = ok and nil or tostring(err),
    }
    last_result = "ran " .. tostring(p.label)
end

if not ALREADY then
    re.on_frame(function() safe(tick) end)
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.warn(M .. " draw_ui: " .. tostring(err)) end
    end)
    log.info(M .. " loaded v" .. PROBE_VERSION)
else
    log.info(M .. " duplicate load ignored")
end
