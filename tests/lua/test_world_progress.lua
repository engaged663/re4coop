-- What one player completes is completed for the other (docs/RESEARCH.md 3.24): the partner's
-- gimmick changes make the gimmick react here (an item set in its slot, a lock opening, a puzzle
-- solving), sequences that hand out or take items are shared with those effects muted, level
-- events too, and the objective on screen is the more advanced one. The world adapter against
-- the mocked RE4, then two simulated games' objectives through the real codec.
local T = require("testlib")
local P = require("re4coop.protocol")
local mock = require("mock_reframework")

local G_SLOT = "33333333-0000-0000-0000-000000000001"
local G_LEVER = "33333333-0000-0000-0000-000000000002"
local G_DOOR = "33333333-0000-0000-0000-000000000003"
local G_EVENT = "33333333-0000-0000-0000-000000000004"
local G_PEDESTAL = "33333333-0000-0000-0000-000000000005"
local USE_KEY = 0x55E
local SLOT_CTX = { category = 1, kind = 0, group = 40200, index = 31 }
local PORT = 1

local function fresh(settings)
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    local world = mock.install()
    world.player = mock.make_player({ x = 0, y = 0, z = 0 })
    world.now = 0
    local Game = require("re4coop.game")
    local game = Game.new(function() end, function() return world.now end)
    for k, v in pairs(settings or {}) do game.settings[k] = v end
    local World = require("re4coop.game_world")
    local w = World.new(game, function() end)
    w:install_hooks({})
    w:set_active(true)
    game:read_player_state()
    return w, game, world
end

-- The partner's record of a gimmick: its flag (attribute 0) on.
local function partner_item(ctx, attr)
    return { ctx = ctx, attr = string.char(table.unpack(attr or { 1, 0 })), triggers = {}, acc = {}, detected = false }
end

local function played(world, guid, key)
    local n = 0
    for _, p in ipairs(world.portrayals) do
        if p.guid == guid and (key == nil or p.key == key) then n = n + 1 end
    end
    return n
end

T.run("the_partners_item_in_a_slot_unlocks_it_here_too", function()
    local w, game, world = fresh()
    T.check(game:capabilities().mute_effects.ok, "effects can be muted: " .. game:capabilities().mute_effects.detail)
    -- A slot that takes a key item: its "use" sequence takes the item from the player, sets a
    -- story flag, and at its end hands out a reward.
    local slot = mock.make_live_gimmick("chainsaw.GmUseItem", SLOT_CTX, G_SLOT, { keys = { [USE_KEY] = {
        callees = { "chainsaw.ReduceInventoryItemSettings.Param", "chainsaw.SetFlagSettings.Param" },
        end_callees = { "chainsaw.InventorySettings.Param" } } } })
    T.eq(slot:call("getGmFlag"), false, "locked")
    -- The partner set the item: the gimmick table brings its record.
    T.check(w:gimmicks_apply({ partner_item(SLOT_CTX) }), "applied")
    T.eq(slot:call("getGmFlag"), true, "set here too")
    T.eq(played(world, G_SLOT, USE_KEY), 1, "with its own reaction: the item appears and the lock opens")
    T.eq(world.portrayal_flags, 1, "the sequence ran (its story flag)")
    T.eq(world.items_taken, nil, "but our player's items are not taken")
    mock.finish_portrayals()
    T.eq(world.items_given, nil, "nor is the reward handed out again")
    T.eq(w.counters.gimmick_reactions, 1, "counted")
    T.eq(w.last_reaction, "chainsaw.GmUseItem", "which gimmick")
    -- The partner's report of the same sequence (MECHANISMS) arrives afterwards: not twice.
    T.eq(w:mechanism_apply({ guid = G_SLOT, kind = PORT, key = USE_KEY }), "skip", "played already")
    T.eq(played(world, G_SLOT, USE_KEY), 1, "once")
    -- The same record again changes nothing.
    w:gimmicks_apply({ partner_item(SLOT_CTX) })
    T.eq(played(world, G_SLOT, USE_KEY), 1, "still once")
    T.eq(w.counters.gimmick_reactions, 1, "no new reaction")
    -- The game's shared empty method is never hooked (thousands of methods share it).
    T.eq(mock.classes["chainsaw.DevelopProcessSettings.Param"].methods.triggerProcess.hooks, nil, "a stub stays unhooked")
    T.check(game:capabilities().mute_effects.detail:find("1 do nothing"), "and is counted as harmless")
end)

T.run("a_reaction_that_unlocks_another_object_keeps_its_end_effects_too", function()
    local w, _, world = fresh()
    -- The slot unlocks a door elsewhere, whose sequence hands out an item at its end.
    local door = mock.make_mechanism("33333333-0000-0000-0000-000000000006", "chainsaw.GmShelves", nil, {},
        { "chainsaw.InventorySettings.Param" })
    local slot = mock.make_live_gimmick("chainsaw.GmUseItem", SLOT_CTX, G_SLOT, { linked = door, linked_key = 3 })
    w:gimmicks_apply({ partner_item(SLOT_CTX) })
    T.eq(played(world, "33333333-0000-0000-0000-000000000006", 3), 1, "the door's sequence played")
    mock.finish_portrayals()
    T.eq(world.items_given, nil, "its item stays with the partner's player")
    T.eq(w:mechanism_apply({ guid = "33333333-0000-0000-0000-000000000006", kind = PORT, key = 3 }), "skip",
        "and the partner's report of it does not play it again")
    T.eq(slot:call("getGmFlag"), true, "the slot is set")
end)

T.run("a_gimmick_still_setting_up_reads_the_record_itself", function()
    local w, _, world = fresh()
    mock.make_live_gimmick("chainsaw.GmUseItem", SLOT_CTX, G_SLOT, { initialized = false })
    w:gimmicks_apply({ partner_item(SLOT_CTX) })
    T.eq(played(world, G_SLOT), 0, "no reaction: its initializeGimmick reads the new state")
    T.eq(world.gimmick_table["1:0:40200:31"].attr[1], 1, "which is written")
end)

T.run("a_gimmick_not_loaded_here_only_gets_the_record", function()
    local w, _, world = fresh()
    mock.set_gimmick(SLOT_CTX, { 0, 0 }) -- its context exists (save data), nothing on screen
    T.check(w:gimmicks_apply({ partner_item(SLOT_CTX) }), "applied")
    T.eq(world.gimmick_table["1:0:40200:31"].attr[1], 1, "the saved state: set (its area shows it when it loads)")
    T.eq(#world.portrayals, 0, "nothing plays")
    T.eq(w.counters.gimmick_reactions, 0, "no reaction")
end)

T.run("gimmicks_with_their_own_sync_or_switched_off_never_react", function()
    local w, game, world = fresh()
    local door_ctx = { category = 1, kind = 0, group = 40200, index = 32 }
    local door = mock.make_live_gimmick("chainsaw.GmDoor", door_ctx, G_DOOR)
    local reacted = false
    door.on_flag = function() reacted = true end
    w:gimmicks_apply({ partner_item(door_ctx) })
    T.eq(reacted, false, "a door: door_sync opens it, never this")
    T.eq(world.gimmick_table["1:0:40200:32"].attr[1], 1, "its record is still written")
    -- Switched off: the record only (as before).
    game.settings.gimmick_reactions = false
    local slot = mock.make_live_gimmick("chainsaw.GmUseItem", SLOT_CTX, G_SLOT)
    w:gimmicks_apply({ partner_item(SLOT_CTX) })
    T.eq(played(world, G_SLOT), 0, "no reaction")
    T.eq(slot:call("getGmFlag"), true, "the state is written")
    -- A gimmick whose flag is already on here (it reacted to the story flag by itself).
    game.settings.gimmick_reactions = nil
    local ctx2 = { category = 1, kind = 0, group = 40200, index = 33 }
    local done = mock.make_live_gimmick("chainsaw.GmUseItem", ctx2, "33333333-0000-0000-0000-000000000033",
        { attr = { 1, 0 } })
    T.check(done ~= nil, "set up")
    w:gimmicks_apply({ partner_item(ctx2) })
    T.eq(played(world, "33333333-0000-0000-0000-000000000033"), 0, "nothing to do")
end)

T.run("a_sequence_that_hands_out_items_is_shared_and_the_items_stay_with_the_player", function()
    local w, _, world = fresh()
    -- A lever whose sequence gives an item and sets a flag, and gives another one at its end.
    local lever = mock.make_mechanism(G_LEVER, "chainsaw.GmLever", nil,
        { "chainsaw.InventorySettings.Param", "chainsaw.SetFlagSettings.Param" }, { "chainsaw.InventorySettings.Param" })
    -- Our player pulls it: everything runs, and it is shared.
    mock.play_portrayal(lever, 7)
    mock.finish_portrayals()
    T.eq(world.items_given, 2, "our player gets both items")
    local ev = w:take_mechanism_events()
    T.eq(ev and #ev, 1, "shared (it used to be kept back because of the item)")
    -- The partner's pull of it here.
    world.now = 30
    T.eq(w:mechanism_apply({ guid = G_LEVER, kind = PORT, key = 7 }), "done", "played")
    T.eq(world.portrayal_flags, 2, "the lever moves and sets its flag")
    T.eq(world.items_given, 2, "no item for us")
    mock.finish_portrayals()
    T.eq(world.items_given, 2, "nor at its end")
    T.check(w.counters.muted_effects >= 2, "muted: " .. w.counters.muted_effects)
    T.eq(w:take_mechanism_events(), nil, "not reported back")
    -- Our own pull afterwards is ours again.
    world.now = 60
    mock.play_portrayal(lever, 7)
    mock.finish_portrayals()
    T.eq(world.items_given, 4, "both items")
end)

T.run("a_level_event_that_kills_runs_here_without_the_death", function()
    local w, _, world = fresh()
    local reported = {}
    w.callbacks.on_trigger = function(ev) reported[#reported + 1] = ev end
    local t
    t = mock.make_trigger(G_EVENT, "Area_Collapse", { components = { "chainsaw.GmPortrayalAreaHit",
        "chainsaw.PortrayalSettings" }, callees = { "chainsaw.PlDieSettings.Param", "chainsaw.SetFlagSettings.Param" },
        process = function()
            mock.component(t.go, "chainsaw.PortrayalSettings"):call(
                "call(System.UInt32, chainsaw.InteractTrigger, chainsaw.InteractActionArgs)", 1, nil, nil)
        end })
    mock.activate_trigger(t, world.player.body)
    w:update()
    T.eq(#reported, 1, "an event now (its death can be muted)")
    T.eq(world.player_killed, 1, "for our own player it runs as always")
    t.trigger.__fields["<Done>k__BackingField"] = 0
    T.eq(w:trigger_run(reported[1]), "run", "the partner's event runs here")
    T.eq(world.portrayal_flags, 2, "its sequence ran")
    T.eq(world.player_killed, 1, "without killing our player")
end)

-------------------------------------------------------------------------------
-- Objectives
-------------------------------------------------------------------------------

T.run("the_adapter_reads_and_shows_objectives", function()
    local w, game, world = fresh()
    T.check(game:capabilities().purposes.ok, "objectives capability")
    T.eq(w:purpose_read(), nil, "none yet")
    mock.set_purpose(2203, 40)
    local mine = assert(w:purpose_read())
    T.eq(mine.id, 2203, "id")
    T.eq(mine.priority, 40, "priority")
    T.check(mine.message ~= nil, "message")
    -- The partner's more advanced one: shown the game's way.
    T.check(w:purpose_apply({ id = 2204, priority = 41, message = "00000898-0000-0000-0000-000000000000", display = 3,
        delay = 0, mediate = false }), "taken")
    T.eq(w:purpose_read().id, 2204, "ours now")
    T.eq(world.purpose_banners, 1, "with the objective banner")
    -- An older one changes nothing (the game's own rule).
    T.eq(w:purpose_apply({ id = 2201, priority = 10, message = "00000899-0000-0000-0000-000000000000" }), false, "not taken")
    T.eq(w:purpose_read().id, 2204, "unchanged")
end)

-- Two games' objectives through the real codec.
local PurposeSync = require("re4coop.purpose_sync")

local function fake_world(id, prio)
    local w = { cur = id and { id = id, priority = prio, message = ("%08x-0000-0000-0000-000000000000"):format(id),
        display = 3, delay = 0, mediate = false } or nil, banners = 0, chapter = 22200 }
    function w:purpose_read() return self.cur end
    function w:purpose_apply(p)
        if self.cur ~= nil and p.priority <= self.cur.priority then return false end
        self.cur = { id = p.id, priority = p.priority, message = p.message, display = p.display, delay = p.delay,
            mediate = p.mediate }
        self.banners = self.banners + 1
        return true
    end
    return w
end

local function make_pair(settings)
    local pair = { now = 0, inbox = { host = {}, client = {} }, settings = settings or {} }
    pair.host_world, pair.client_world = fake_world(2201, 10), fake_world(2201, 10)
    local function sync(role, other)
        return PurposeSync.new({ role = role, protocol = P, settings = pair.settings,
            send = function(bytes) local q = pair.inbox[other] q[#q + 1] = bytes end })
    end
    pair.host, pair.client = sync("host", "client"), sync("client", "host")
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.5
            for _, who in ipairs({ "host", "client" }) do
                local q = self.inbox[who]
                self.inbox[who] = {}
                for _, b in ipairs(q) do self[who]:on_message(assert(P.decode(b)), self.now) end
            end
            for _, who in ipairs({ "host", "client" }) do
                local w = self[who .. "_world"]
                self[who]:tick(self.now, w, { ready = not w.loading, chapter = w.chapter })
            end
        end
    end
    return pair
end

T.run("the_more_advanced_objective_shows_in_both_games", function()
    local pair = make_pair()
    pair:step(4)
    T.eq(pair.client_world.banners, 0, "the same objective: nothing to do")
    -- The host places the item: its objective moves on; the client's conditions (the item is
    -- the host's) never would.
    pair.host_world.cur = { id = 2203, priority = 30, message = "000008a3-0000-0000-0000-000000000000", display = 3,
        delay = 0, mediate = false }
    pair:step(4)
    T.eq(pair.client_world.cur.id, 2203, "the client sees it too")
    T.eq(pair.client_world.banners, 1, "with the banner, once")
    T.eq(pair.client.counters.applied, 1, "counted")
    T.eq(pair.client.counters.sent, 1, "the host's objective is not sent back to it")
    -- The client gets further first: the host follows.
    pair.client_world.cur = { id = 2204, priority = 31, message = "000008a4-0000-0000-0000-000000000000", display = 3,
        delay = 0, mediate = false }
    pair:step(4)
    T.eq(pair.host_world.cur.id, 2204, "the host sees the client's")
    local sent_host, sent_client = pair.host.counters.sent, pair.client.counters.sent
    pair:step(60)
    T.eq(pair.host_world.banners, 1, "no ping-pong")
    T.eq(pair.client_world.banners, 1, "no ping-pong")
    T.eq(pair.host.counters.refused + pair.client.counters.refused, 0, "a game never tries an objective that is not ahead")
    T.check(pair.host.counters.sent - sent_host <= 2, "only a reminder now and then (" .. pair.host.counters.sent - sent_host .. ")")
    T.check(pair.client.counters.sent - sent_client <= 2, "from both")
end)

T.run("objectives_wait_for_the_game_and_stay_in_their_chapter", function()
    local pair = make_pair()
    pair:step(2)
    pair.client_world.loading = true
    pair.host_world.cur = { id = 2205, priority = 50, message = "000008a5-0000-0000-0000-000000000000", display = 3,
        delay = 0, mediate = false }
    pair:step(4)
    T.eq(pair.client_world.cur.id, 2201, "not while loading")
    pair.client_world.loading = nil
    pair.client_world.chapter = 22100 -- the client is still in the chapter before
    pair:step(4)
    T.eq(pair.client_world.cur.id, 2201, "another chapter's objective is not shown")
    T.eq(pair.client.counters.other_chapter, 1, "counted once")
    pair.client_world.chapter = 22200
    pair:step(4)
    T.eq(pair.client_world.cur.id, 2205, "once in the same chapter")
end)

T.run("objective_sync_can_be_switched_off_and_its_message_round_trips", function()
    local pair = make_pair({ sync_purposes = false })
    pair.host_world.cur = { id = 2207, priority = 70, message = "000008a7-0000-0000-0000-000000000000", display = 3,
        delay = 0, mediate = false }
    pair:step(6)
    T.eq(pair.client_world.cur.id, 2201, "off")
    T.eq(pair.host.counters.sent, 0, "nothing sent")
    local m = assert(P.decode(P.encode_purpose({ id = 2207, priority = 70, message = "000008a7-0000-0000-0000-000000000001",
        display = 2.5, delay = 0.5, mediate = true })))
    T.eq(m.type, P.T.PURPOSE, "type")
    T.eq(m.id, 2207, "id")
    T.eq(m.priority, 70, "priority")
    T.eq(m.message, "000008a7-0000-0000-0000-000000000001", "message")
    T.near(m.display, 2.5, 1e-6, "display time")
    T.eq(m.mediate, true, "mediate")
end)

T.finish()
