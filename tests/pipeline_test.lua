--
-- pipeline_test.lua — exercises the game-facing apply pipeline against a fake
-- REFramework save, under Lua 5.1.
--
-- The fake implements just enough of the SDK surface the mod uses: objects with
-- field descriptors, 0-based collection wrappers, static utility methods and the
-- save-data roots. That lets the real code in reframework/linked_restock.lua
-- (no copies, no stubs inside the mod) run end to end:
--
--   item set -> diff -> game apply attempt -> pouch read-back -> retry ->
--   top-up from the box -> missing report
--
--   lua5.1 tests/pipeline_test.lua
--

-- ---------------------------------------------------------------------------
-- fake SDK
-- ---------------------------------------------------------------------------

_G.LINKED_RESTOCK_TEST = true

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

-- 0-based collection wrapper, the shape collect() expects
local function array(items)
    local a = { _items = items }
    a.get_Count = fn(function() return #items end)
    a.get_Item = fn(function(_, i) return items[i + 1] end)
    return a
end

local function item_work(id, count)
    return object("app.savedata.cItemWork", { ItemIdFixed = id, Num = count })
end

-- item names for the fake (app.user_data.ItemData.getDataByFixedId)
local ITEM_NAMES = { [1] = "Potion", [2] = "Whetfish Fin", [3] = "Trap Tool" }
local item_data_td = {
    get_full_name = function() return "app.user_data.ItemData" end,
    get_method = function(_, sig)
        if sig ~= "getDataByFixedId(System.Int32)" then return nil end
        -- static call: m:call(nil, id) -> the instance slot is nil
        return fn(function(_, id)
            local name = ITEM_NAMES[id]
            if name == nil then return nil end
            return object("app.user_data.ItemData.cData", { Name = name })
        end)
    end,
    get_fields = function() return {} end,
    get_methods = function() return {} end,
    get_parent_type = function() return nil end,
}

-- mutable world state the tests drive
local POUCH_SLOTS = 8
local world = {
    pouch = { item_work(1, 1) },              -- potion only, rest empty
    box = { item_work(1, 3), item_work(2, 2) },
    on_apply = nil,                          -- what the fake game call does
    apply_calls = 0,
}

-- the real pouch is a fixed array with empty slots; the top-up path needs them
local function pouch_array(works)
    local items = {}
    for i, w in ipairs(works) do items[i] = w end
    for i = #works + 1, POUCH_SLOTS do items[i] = item_work(0, 0) end
    return array(items)
end

local function rebuild_save()
    local set = object("app.savedata.cItemMySet", {
        Name = "Rompo LBG",
        _PouchItem = array({
            item_work(1, 5),
            item_work(2, 3),
            item_work(3, 2),
        }),
    })
    local set2 = object("app.savedata.cItemMySet", {
        Name = "Gathering",
        _PouchItem = array({ item_work(1, 10) }),
    })
    local item = object("app.savedata.cItemParam", {
        _PouchItem = pouch_array(world.pouch),
        _BoxItem = array(world.box),
    })
    local mysets = object("app.savedata.cItemMySetData", {
        _Data = array({ set, set2 }),
    })
    local save = object("app.savedata.cUserSaveData", {
        _Item = item,
        _ItemMySet = mysets,
    })
    local sdm = object("app.SaveDataManager", {})
    sdm.getCurrentUserSaveData = function() return save end
    return sdm, item
end

local sdm = rebuild_save()

-- fake game apply: writes the item set into the pouch (pouch only, no box use,
-- like an in-game item-set load does when the box has the stock)
local function fake_game_apply(index)
    world.apply_calls = world.apply_calls + 1
    if world.on_apply then return world.on_apply(index) end
    return nil
end

local apply_method = {
    get_name = function() return "applyMySetToPouch(System.Int32)" end,
    get_param_types = function()
        return { { get_full_name = function() return "System.Int32" end } }
    end,
    is_static = function() return true end,
    call = function(_, index) return fake_game_apply(index) end,
}

local pouch_helper = {
    get_name = function() return "restockPouchHelper(System.Int32)" end,
    get_param_types = function()
        return { { get_full_name = function() return "System.Int32" end } }
    end,
    is_static = function() return true end,
    call = function() return nil end,
}

-- fake MissionManager for the trigger state machine
local mm = { playing = false, active = false, result = false, ending = false,
             gfm_loading = false }
function mm:call(name)
    if name == "get_IsPlayingQuest" then return self.playing end
    if name == "get_IsActiveQuest" then return self.active end
    if name == "get_IsQuestResult" then return self.result end
    if name == "get_IsQuestEndShowing" then return self.ending end
    if name == "get_Loading" then return self.gfm_loading end
    return nil
end

local util_td = {
    get_full_name = function() return "app.ItemMySetUtil" end,
    get_parent_type = function() return nil end,
    get_fields = function() return {} end,
    get_methods = function() return { pouch_helper, apply_method } end,
    get_method = function(_, sig)
        if sig == "applyMySetToPouch(System.Int32)" then return apply_method end
        if sig == "restockPouchHelper(System.Int32)" then return pouch_helper end
        return nil
    end,
}

re = { on_frame = function() end, on_draw_ui = function() end }
sdk = {
    find_type_definition = function(name)
        if name == "app.ItemMySetUtil" then return util_td end
        if name == "app.user_data.ItemData" then return item_data_td end
        return nil
    end,
    get_managed_singleton = function(name)
        if name == "app.SaveDataManager" then return sdm end
        if name == "app.MissionManager" then return mm end
        if name == "app.GameFlowManager" then return mm end
        return nil
    end,
}
json = { dump_file = function() end, load_file = function() return nil end }
log = { info = function() end, warn = function() end, debug = function() end }
imgui = {}
draw = nil

local here = arg and arg[0] or "tests/pipeline_test.lua"
local dir = string.match(here, "^(.*)[/\\]") or "."
local LR = dofile(dir .. "/../reframework/linked_restock.lua")
local T = LR._test
assert(type(T) == "table", "mod did not export its test hooks")

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
    c.retry_limit = 3
    return c
end

-- run the frame loop until the task is done (or the cap is hit)
local function run_task(limit)
    for _ = 1, (limit or 400) do
        T.tick_task()
        if T.state.task == nil then return true end
    end
    return false
end

local function rebuild_world(pouch, box)
    world.pouch = pouch
    world.box = box
    world.apply_calls = 0
    sdm = rebuild_save()
end

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------

T.set_config(cfg())

-- 1) item set contents resolve ids, counts and names
local contents = T.item_set_contents(1)
check(contents ~= nil and #contents == 3, "item set 1 has three entries")
eq(contents[1].id, 1, "first id")
eq(contents[1].count, 5, "first count")
eq(contents[1].name, "Potion", "first name")
eq(T.item_set_name(1), "Rompo LBG", "item set name")

-- 2) the game's own apply is preferred and verified
rebuild_world({ item_work(1, 1) },
    { item_work(1, 9), item_work(2, 9), item_work(3, 9) })
world.on_apply = function()
    -- what the game's item-set load leaves behind
    world.pouch = { item_work(1, 5), item_work(2, 3), item_work(3, 2) }
    sdm = rebuild_save()
end
local link = { id = "a", label = "fire", item_set = 1, item_set_name = "Rompo LBG",
               apply_mode = "exact", enabled = true }
check(T.start_task(link, "test"), "task starts")
check(run_task(), "task completes")
eq(world.apply_calls, 1, "the game apply ran once")
local pouch = T.pouch_snapshot()
eq(pouch[1], 5, "potion reached the set count")
eq(pouch[2], 3, "whetfish reached the set count")
eq(pouch[3], 2, "trap tool reached the set count")
check(T.state.last_result:find("restocked") ~= nil, "result says restocked")

-- 3) a silent game call falls through to the top-up path
rebuild_world({ item_work(1, 1) }, { item_work(1, 3), item_work(2, 1) })
world.on_apply = nil  -- the game call does nothing
check(T.start_task(link, "test"), "task starts with a dead game call")
check(run_task(), "task completes via top-up")
eq(T.pouch_snapshot()[1], 4, "potion topped up to 1+3")
eq(T.pouch_snapshot()[2], 1, "whetfish topped up to the single one in the box")
eq(T.pouch_snapshot()[3], nil, "no trap tool was invented")
local box = T.box_snapshot()
eq(box[1], nil, "the box gave its three potions away")
eq(box[2], nil, "the box gave its whetfish away")
check(T.state.last_result:find("missing") ~= nil,
    "the items the box could not cover are reported")

-- 4) box short: fills what it can, reports the rest, invents nothing
rebuild_world({}, { item_work(1, 2) })
check(T.start_task(link, "test"), "task starts with an almost empty box")
check(run_task(), "task completes with a short box")
eq(T.pouch_snapshot()[1], 2, "only the two potions in the box moved")
eq(T.pouch_snapshot()[2], nil, "no whetfish were created")
eq(T.pouch_snapshot()[3], nil, "no trap tools were created")
check(T.state.last_result:find("missing") ~= nil, "missing items are named")

-- 5) already stocked: no apply, no write
rebuild_world({ item_work(1, 5), item_work(2, 3), item_work(3, 2) },
    { item_work(1, 9), item_work(2, 9), item_work(3, 9) })
world.on_apply = function() error("should not be called") end
check(T.start_task(link, "test"), "already-stocked task returns true")
eq(T.state.task, nil, "no task is queued when nothing would change")
check(T.state.last_result:find("already stocked") ~= nil, "result says already stocked")

-- 5b) a mid-transition world (both arrays empty) is not "already stocked"
rebuild_world({}, {})
T.state.task = nil
eq(T.start_task(link, "test"), false, "an unreadable world does not start a task")
eq(T.state.task, nil, "nothing is queued while the item data is swapped")
check(T.state.last_result:find("not readable") ~= nil, "and the panel says why")

-- 5c) stage 1 of an automatic restock never calls into the game
rebuild_world({ item_work(1, 1) }, { item_work(1, 9) })
world.apply_calls = 0
world.on_apply = function() world.apply_calls = world.apply_calls + 1 end
T.state.task = nil
T.state.exact_due = nil
check(T.start_task(link, "back in the hub"), "an automatic task starts")
check(run_task(), "it completes through the top-up")
eq(world.apply_calls, 0, "no game method was called at the trigger")
eq(T.pouch_snapshot()[1], 5, "the pouch was still restocked")

-- 5d) the hub gate is exact: results screen, loading and quests all block it
mm.playing, mm.active = false, false
mm.result, mm.ending, mm.gfm_loading = false, false, false
T.get_config().hub_delay_frames = 60
eq(T.hub_need_polls(), 6, "the gate window is at least six polls")

local ok = T.hub_gate()
eq(ok, true, "a quiet hub opens the gate")

mm.result = true
local ok2, why2 = T.hub_gate()
eq(ok2, false, "the results screen closes the gate")
eq(why2, "results screen", "and names the reason")
mm.result = false

mm.ending = true
local ok3, why3 = T.hub_gate()
eq(ok3, false, "the quest end screen closes the gate")
eq(why3, "quest end screen", "and names that reason too")
mm.ending = false

mm.gfm_loading = true
local ok4, why4 = T.hub_gate()
eq(ok4, false, "a loading screen closes the gate")
eq(why4, "loading", "and names it")
mm.gfm_loading = false

mm.playing = true
eq(T.hub_gate(), false, "a quest closes the gate")
mm.playing = false
eq(T.hub_gate(), true, "and it opens again once nothing is in flight")

-- 6) candidate ranking puts the item-set apply first
local cands = T.apply_candidates()
check(#cands >= 2, "candidates found")
eq(cands[1].score, 3, "an item-set apply is ranked highest")
check(cands[1].score > cands[2].score, "scores are ordered")

-- 7) a link without an item set is refused, not crashed
local bad = T.start_task({ id = "b", label = "no set" }, "test")
check(bad == false, "a link without an item set is refused")
eq(T.state.task, nil, "no task left behind")

-- a readable world again: 5b left both arrays empty
rebuild_world({ item_work(1, 1) }, { item_work(1, 9) })

-- 8) trigger state machine: one accept per quest, one hub restock per quest,
-- and the hub return does not depend on catching the exact transition
local c2 = cfg()
c2.hub_delay_frames = 60 -- two polls
c2.triggers.quest_accept = true
c2.triggers.hub_return = true
T.set_config(c2)
T.state.last_in_quest = nil
T.state.quest_seq = 0
T.state.accept_done_seq = -1
T.state.accept_pending = false
T.state.hub_polls = 0
T.state.hub_done_seq = -1

mm.playing = false
mm.active = false
T.poll()
eq(T.state.quest_seq, 0, "the first poll is not a transition")

mm.playing = true
mm.active = true
T.poll()
eq(T.state.quest_seq, 1, "quest accept is seen")
eq(T.state.accept_done_seq, -1, "the accept restock waits for the quest to settle")
check(T.state.accept_pending == true, "accept restock is pending")
T.poll()
T.poll()
eq(T.state.accept_done_seq, 1, "the accept restock fires after the settle polls")
T.poll()
eq(T.state.accept_done_seq, 1, "and only once per quest")
eq(T.state.quest_seq, 1, "no second accept inside the same quest")

-- quest over: playing goes false but the results screen is still active
mm.playing = false
mm.active = true
for _ = 1, 10 do T.poll() end
eq(T.state.hub_done_seq, -1, "the results screen is not the hub yet")

-- really out of the quest: the delay has to pass, then it fires once
mm.active = false
for _ = 1, 5 do T.poll() end
eq(T.state.hub_done_seq, -1, "five settled polls are not enough")
T.poll()
eq(T.state.hub_done_seq, 1, "the hub restock fires once the gate has held")
for _ = 1, 5 do T.poll() end
eq(T.state.hub_done_seq, 1, "and once per quest, not every poll")

-- 9) reloading the script mid-quest still arms the hub return
T.state.last_in_quest = nil
T.state.quest_seq = 0
T.state.hub_done_seq = -1
T.state.hub_polls = 0
mm.playing = true
mm.active = true
T.poll()
eq(T.state.quest_seq, 1, "a mid-quest load counts as a quest in progress")
mm.playing = false
mm.active = false
mm.result, mm.ending, mm.gfm_loading = false, false, false
for _ = 1, 6 do T.poll() end
eq(T.state.hub_done_seq, 1, "the hub restock still fires after a mid-quest load")

-- 10) no quest seen: sitting in the hub does not restock
T.state.last_in_quest = nil
T.state.quest_seq = 0
T.state.hub_done_seq = -1
T.state.hub_polls = 0
mm.playing = false
mm.active = false
T.poll()
for _ = 1, 5 do T.poll() end
eq(T.state.hub_done_seq, -1, "nothing to return from, nothing fires")

-- ---------------------------------------------------------------------------

-- 11) a hub restock can never start while a quest is playing
rebuild_world({ item_work(1, 1) }, { item_work(1, 9) })
T.get_config().triggers.hub_return = true
T.state.task = nil
mm.playing, mm.active = true, true
local ok11, why11 = T.start_task(link, "back in the hub")
eq(ok11, false, "a hub restock is refused during a quest")
eq(why11, "in a quest", "and says why")
eq(T.state.task, nil, "nothing is queued")

-- 12) the hub fallback clock does not accumulate across a hunt
T.state.quest_seq = 5
T.state.hub_done_seq = 4
T.state.hub_wait = 0
T.state.settled_polls = 0
T.state.last_in_quest = true
mm.playing, mm.active = true, true
mm.result, mm.ending, mm.gfm_loading = false, false, false
for _ = 1, 150 do T.poll() end
eq(T.state.hub_wait, 0, "the hub fallback clock stays at zero during a quest")
eq(T.state.hub_done_seq, 4, "and the pending restock is not marked handled")
eq(T.state.task, nil, "no restock was started mid-quest")

-- 13) an automatic retry is held until the hub settles
mm.playing, mm.active = false, false
T.state.last_in_quest = false
T.state.task = nil
T.state.frames = 100
T.state.pending_retry = { link = link, reason = "back in the hub", auto = true,
                          exact = true, retry = 1, at = 0 }
mm.playing = true
T.on_frame()
check(T.state.pending_retry ~= nil, "an automatic retry is held during a quest")
check(T.state.pending_retry.at > T.state.frames, "and rescheduled for later")
mm.playing = false
mm.result, mm.ending, mm.gfm_loading = false, false, false
T.state.frames = 300
T.on_frame()
eq(T.state.pending_retry, nil, "it runs once the hub is settled")
T.state.task = nil

-- 14) the fallback clock does not run on the results or loading screens
T.get_config().triggers.hub_return = true
T.state.quest_seq = 7
T.state.hub_done_seq = 6
T.state.hub_wait = 0
T.state.settled_polls = 0
T.state.last_in_quest = false
T.state.task = nil
mm.playing, mm.active = false, true          -- results screen
mm.result, mm.ending, mm.gfm_loading = false, false, false
for _ = 1, 150 do T.poll() end
eq(T.state.hub_wait, 0, "the fallback clock stays at zero on the results screen")
eq(T.state.hub_done_seq, 6, "and no restock was fired there")

mm.active = false
mm.gfm_loading = true                        -- loading into the hub
for _ = 1, 150 do T.poll() end
eq(T.state.hub_wait, 0, "the fallback clock stays at zero while loading")
eq(T.state.hub_done_seq, 6, "and again nothing fired")

-- 15) a game call that throws is logged, skipped, and the top-up finishes
mm.gfm_loading = false
mm.result, mm.ending = false, false
rebuild_world({ item_work(1, 1) }, { item_work(1, 9) })
world.apply_calls = 0
world.on_apply = function() error("boom from the game") end
T.state.task = nil
T.state.pending_retry = nil
check(T.start_task(link, "back in the hub", nil, true),
    "an exact hub task starts (game calls allowed)")
check(run_task(), "it completes despite the throwing game call")
eq(world.apply_calls, 1, "only the first game call was attempted")
eq(T.pouch_snapshot()[1], 5, "the top-up did the work")
check(T.state.last_result:find("restocked") ~= nil, "and the result says restocked")
T.state.task = nil
T.state.pending_retry = nil

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
