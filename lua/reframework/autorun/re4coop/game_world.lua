-- RE4 (2023) adapter for world state: scenario flags, gimmick save states, breakables and
-- animals, cutscenes, location / warping / chapter switching. It implements the "world"
-- contracts of flag_sync, gimmick_sync, object_sync, cutscene_sync and travel. Like
-- game.lua (which it uses for the player context and the capability list), it is one of
-- the few modules that touch REFramework's `sdk`.
--
-- Status of what is used (see docs/RESEARCH.md for sources):
--   * Used in game by another published mod (RE4R-AP-Wizard): ScenarioFlagManager
--     requestSetFlag(System.Guid, System.Boolean) / checkFlag(System.Guid); the stage warp
--     (Prefecture/Location/EnvSceneManager.requestToChangeStatus + CharacterManager
--     .requestWarp with a StageIdentifier); PlayerContext.get_CurrentStageID;
--     CampaignManager.get_CurrentChapter and the chapter switch through
--     CampaignManager.loadGameSaveData; scene findComponents and GameObject GUIDs.
--   * In this mod's own research dump (v0.5): GimmickManager.pushDirtyList (a gimmick
--     changed state, hooked in game.lua), CampaignManager.get_CurrentStageIdentifier.
--   * Read in re4.exe's code (docs/RESEARCH.md 3.11): flag changes through
--     ScenarioFlagManagerBehavior.onSetScenarioFlagEvent / onSetCommonFlagEvent and
--     GlobalUserDataManager.findVariable / trySetBool; cutscenes through
--     ClapperboardMediator.procPayloadPlay (PayloadPlay); level triggers through
--     InteractTrigger.Work.executeTrigger, InteractHolder.findTrigger and
--     via.Scene.findGameObject(System.Guid).
--   * Read in re4.exe's code too: the gimmick table through GimmickManager.saveGameSaveData,
--     applied gimmick by gimmick (findContext, GimmickContext.loadSaveDataFromManager,
--     pushDirtyList); cutscene skips through ClapperboardMediator._Plays (PlayWork.InputSkip /
--     DoneSkip).
--   * Found in the game's type database: gimmick _Routine states.
--   * Read in re4.exe's code too (docs/RESEARCH.md 3.24): GmBase.setGmFlag(value, trigger, args)
--     writes the gimmick flag and runs the gimmick's own onChangeGmFlag (its reaction: the
--     item set in its slot, the lock opening, the puzzle solving); a sequence's effects run
--     through each PortrayalParam's triggerProcess (end effects later, from
--     PortrayalSettings.Param.onFinish); PurposeManager.updateMainPurpose(PurposeGuiItem)
--     shows a new objective (only one of higher priority).
--   * Read in re4.exe's code too (docs/RESEARCH.md 3.34): a loaded game's campaign jump
--     (CampaignManager.createCampaignJumperOrderFromInitialSettings) loads the map around its
--     base character's GameLocator and puts each character at its own; reloading in game is
--     the pause menu's Load Game (game_save.lua).
--   * Read in re4.exe's code too (docs/RESEARCH.md 3.35): a chapter part's start is its
--     CampaignInitialSetting in EnvSceneStructureDB's start point catalog
--     (getCampaignInitialSetting(CampaignInitialSettingKey)); the game's own chapter change
--     builds its jump from it with IsChapterStart set.
-- Every lookup is cached and every engine call is pcall'ed; missing pieces switch the
-- corresponding feature off and show up in the Diagnostics panel.

local R = require("re4coop.reflect")
local P = require("re4coop.protocol")
local Perf = require("re4coop.perf")

local World = {}
World.__index = World

local SFM = "chainsaw.ScenarioFlagManager"
local SFM_BHV = "chainsaw.ScenarioFlagManagerBehavior"
local GUD = "chainsaw.GlobalUserDataManager"
local VARIABLE = "via.userdata.Variable"
local SAVE_BASE = "share.SaveDataBase"
local GIM = "chainsaw.GimmickManager"
local GIM_CONTEXT = "chainsaw.GimmickContext"
local GIM_SAVE = "chainsaw.GimmickContext.SaveData"
local CLAP = "chainsaw.ClapperboardMediator"
local PAYLOAD_PLAY = "chainsaw.ClapperboardMediator.PayloadPlay"
local PLAY_WORK = "chainsaw.ClapperboardMediator.PlayWork"
local GM_DOOR = "chainsaw.GmDoor"
local FLAG_INFO = "chainsaw.ScenarioFlagManager.FlagInfo"
local COORD_PACK = "chainsaw.PlayerCoordSetting.Pack"
local TRIGGER_WORK = "chainsaw.InteractTrigger.Work"
local HOLDER = "chainsaw.InteractHolder"
local PORTRAYAL = "chainsaw.PortrayalSettings"
local PUSH_MOVE = "chainsaw.GmPushMove"
local MECH_ECHO = 15.0 -- seconds: the partner's mechanism is not played twice here, nor reported back
local CHARACTER_MANAGER = "chainsaw.CharacterManager"
local CAMPAIGN = "chainsaw.CampaignManager"
local GUI_MANAGER = "chainsaw.GuiManager"
local GAME_OVER = "chainsaw.GameOverManager"
local PREF_SCENE = "chainsaw.PrefectureSceneManager"
local LOC_SCENE = "chainsaw.LocationSceneManager"
local ENV_SCENE = "chainsaw.EnvSceneManager"
local CONTEXT_ID = "chainsaw.ContextID"
local PURPOSE_MGR = "chainsaw.PurposeManager"
local PURPOSE_ITEM = "chainsaw.gui.PurposeGuiItem"
local PORTRAYAL_PARAM = "chainsaw.PortrayalSettings.Param"
local GM_BASE_TYPE = "chainsaw.GmBase"
local SET_GM_FLAG = "setGmFlag" -- GmBase.setGmFlag(Boolean, InteractTrigger, InteractActionArgs), its only overload
local REPLAY_MUTE = 120.0 -- seconds a sequence we replayed keeps its end effects muted (until it finishes)

-- Breakables and animals whose destruction is synchronised.
World.OBJECT_TYPES = {
    "chainsaw.GmWoodBox", "chainsaw.GmSmoothWoodBox", "chainsaw.GmPhasedWoodBox", "chainsaw.GmSaveLoadWoodBox",
    "chainsaw.GmOilDrum", "chainsaw.GmBottle", "chainsaw.GmSimpleBreak", "chainsaw.GmBreakObj",
    "chainsaw.GmShootObj", "chainsaw.GmShootObj4DLC", "chainsaw.GmBlueCoin", "chainsaw.GmGlassBox",
    "chainsaw.GmWindowBreakable", "chainsaw.GmBreakWall", "chainsaw.GmBreakDoor", "chainsaw.GmFatBreak",
    "chainsaw.GmArmaBreak", "chainsaw.GmBreakFallenShelf", "chainsaw.GmLightBulb", "chainsaw.GmBreakableByEm",
    "chainsaw.GmCrow", "chainsaw.GmChicken", "chainsaw.GmFish", "chainsaw.GmAnimal", "chainsaw.GmBat",
    "chainsaw.GmBatGroup", "chainsaw.GmMouse", "chainsaw.GmCockroach", "chainsaw.GmSmokeBag",
}

-- Animals (chainsaw.GmAnimal and the animals derived from it): the host's game moves them and
-- the client's copies follow (animal_sync.lua, docs/RESEARCH.md 3.9).
World.ANIMAL_TYPES = {
    ["chainsaw.GmAnimal"] = true, ["chainsaw.GmCrow"] = true, ["chainsaw.GmChicken"] = true,
    ["chainsaw.GmFish"] = true, ["chainsaw.GmBat"] = true, ["chainsaw.GmMouse"] = true,
}

-- via.userdata.TypeKind of the variables behind scenario flags.
local KIND_BOOLEAN = 2
local KIND_TRIGGER = 16 -- fires for a frame (setTrigger) instead of holding a value

-- The handlers the game calls for every scenario / common flag change
-- (GlobalUserDataManager.registerValueChangedEvent, ScenarioFlagManagerBehavior.start).
World.FLAG_EVENTS = { "onSetScenarioFlagEvent", "onSetCommonFlagEvent" }

-- chainsaw.InteractTrigger.TriggerType.AreaHit: the player walked into an area.
local TRIGGER_AREA_HIT = 1

-- Level triggers whose GameObject carries one of these components run a pure event: the
-- game's scripted sequences (portrayals) and the option parameters they call, camera shots,
-- mini demos. Their effects are what the partner should see happen in their game too.
World.EVENT_COMPONENTS = {}
for _, n in ipairs({ "GmPortrayalAreaHit", "GmPortrayal", "CustomGmPortrayal", "PortrayalSettings",
    "ClapperboardSettings", "ClapperboardSequenceSettings", "CaptionSettings", "SetFlagSettings",
    "MessageSettings", "SoundCallSettings", "SoundCommonParamSettings", "SoundSupportSettings",
    "CameraShakeSettings", "EffectsPlaySettings", "EnvTransPlaySettings", "ObjectHideSettings",
    "ObjectHideSettings_CP11", "ObjectMoveSettings", "MotionPlaySettings", "MotionFsmPlaySettings",
    "RealTimeTimelineSettings", "NaviCutSettings", "NaviCutSettings_CP11", "WaitSettings",
    "VibrationPlaySettings", "VibrationPlaySettings_CP11", "RandomVibrationPlaySetting",
    "MaterialParamAnimationSettings", "MaterialParamAnimatorEnableSettings", "ParamCurveAnimatorSettings",
    "ChainEnableSettings", "ColliderEnableSettings", "RigidBodyPlaySettings", "EmoteVoiceSettings",
    "CharacterTalkSettings", "MapSettings", "NPCMonitorSettings", "MeshPartsHideSettings_CP11",
    "OffsetParentSettings", "PlMinorDemoSettings", "GmCameraBase", "GmCamera1Shot",
    "GmCamera1ShotForIronBallCrane", "GmCameraMultiShots", "GmMiniDemo", "GmMiniDemoBase", "GmMiniDemoFsm" }) do
    World.EVENT_COMPONENTS["chainsaw." .. n] = true
end
-- ...and never one of these: they kill or change the player, hand out or take items, save,
-- switch the game mode or the campaign. Any other gimmick (chainsaw.Gm*, chainsaw.Custom*: a
-- door, a ladder, a trap, a lever...) is a player action or a per-player hazard, not an event.
World.DENY_COMPONENTS = {}
for _, n in ipairs({ "PlDieSettings", "PlConditionSettings", "InventorySettings", "ReduceInventoryItemSettings",
    "ForceGetFileSettings", "RelatedDropItemSettings", "GameModeSettings", "CampaignProcessSettings",
    "GameRankSystemSettings", "DevelopProcessSettings", "TelemetrySaveSettings", "RichTutorialSettings",
    "TutorialSettings", "TestMovieSettings", "DevelopEventTextureSettings", "DevelopJumpPro_AO",
    "InteractGetPickupItem", "DropItem", "DollCustomSettings", "DeadBodyRemoveSettings",
    "JetSkiCrewReactionCauseSettings", "JetSkiDebriBlowAwaySettings", "cp1011BinocularsOptionSettings" }) do
    World.DENY_COMPONENTS["chainsaw." .. n] = true
end

-- Routine names (lower case prefixes) that mean "this object is finished" ("Break",
-- "BrokenWait", "Dead"...; not "WaitBreak").
local TERMINAL = { "break", "broken", "dead", "death", "die", "destroy", "crash", "shatter", "burst", "kill" }
local KILL_METHODS = { "requestBreak", "requestDead", "forceBreak", "forceDead", "breakObject", "requestDestroy",
    "onBreak", "dead", "setDead", "kill", "die" }

-- How long an armed spawn at the partner waits for the game to build its campaign jump.
World.SPAWN_TTL = 180.0
local ORDER = "chainsaw.CampaignJumper.Order"
local LOCATOR = "chainsaw.GameLocator"
local ENV_DB = "chainsaw.EnvSceneStructureDB"

local function lower(s) return tostring(s or ""):lower() end

local function ends_with(s, suffix)
    return s ~= nil and #s >= #suffix and s:sub(-#suffix) == suffix
end

local function starts_any(name, list)
    local n = lower(name)
    for _, p in ipairs(list) do
        if n:sub(1, #p) == p then return true end
    end
    return false
end

local function yaw_of(q)
    if q == nil then return 0 end
    local x, y, z, w = q.x or 0, q.y or 0, q.z or 0, q.w or 1
    return math.atan(2 * (w * y + x * z), 1 - 2 * (x * x + y * y))
end

-- game: the core adapter (game.lua) for the player context and the capability list.
function World.new(game, log)
    local self = setmetatable({}, World)
    self.game = game
    self.log = log or function() end
    self.r = R.new(self.log)
    self.callbacks = {}      -- on_flag(guid, value, pulse), on_cutscene(ev), on_trigger(ev), spawn_spot(), reload_slot()
    self.applying = false    -- we are setting a flag ourselves (its change event is ours)
    self.applying_cutscene = false
    self.applying_trigger = false
    self.dirty_seen = 0      -- game.gimmick_calls already reported by gimmicks_dirty()
    self.active = false      -- a partner is connected (set by the session)
    self.word_queue = {}     -- pending flag word changes (group -> word -> {set, clear})
    self.flag_groups = nil   -- group name -> ScenarioFlagManager.Group (per manager)
    self.trigger_events = {} -- triggers our player set off this frame (hook), classified in update()
    self.trigger_owner_info = {} -- GameObject GUID -> {event, why}: what kind of trigger owner it is
    self.mech_events = {}    -- portrayals / pushes our game started this frame (hooks), classified later
    self.mech_remote = {}    -- "guid:key" -> time: the partner's mechanism we just played here
    self.mech_owner_info = {} -- GameObject GUID -> {gimmick, why}: what a portrayal's GameObject is
    self.applying_mech = false
    self.muting = 0          -- > 0: effects of the partner's actions replayed here are muted (mute hooks)
    self.muted_types = {}    -- "chainsaw.XSettings" -> true: its effects can be muted (or do nothing)
    self.replayed = {}       -- PortrayalSettings address -> until: sequences we replayed (their end effects muted)
    self.reacting = false    -- a gimmick reacts to the partner's change (gimmick_react)
    self.counters = { flag_events = 0, cutscene_events = 0, trigger_events = 0, trigger_not_event = 0,
        skip_events = 0, gimmicks_applied = 0, gimmicks_waiting = 0, gimmick_reactions = 0, muted_effects = 0 }
    self.gim_waiting = {}    -- ctx_key -> {item, since}: partner gimmicks whose context is not set up here yet
    self.skips_seen = {}     -- PlayWork address -> true: skips already reported
    self.doors = {}          -- GameObject GUID -> {comp, go, pos, kind}: the doors of the loaded areas
    self.door_guest = {}     -- GUID -> true: doors our partner keeps open here (Guest slot set)
    self.auto_hold = {}      -- GUID -> true: automatic doors we keep activating for the partner
    self.big_added = {}      -- GUID -> true: big doors whose "someone close" count we raised
    self.object_index = {}   -- guid -> {comp, go, info={field, enum}, kind, animal, pos} from the latest scan
    self.comp_guid = {}      -- component address -> guid
    self.animal_frozen = {}  -- guid -> {core, go, how}: animals whose state machine we took off the update
    self.chapter_target = nil
    self.spawn_until = nil   -- the next campaign jump puts our player at the partner's (arm_spawn)
    self.spawn_start = nil   -- { chapter, key, point }: ...or at a chapter's start (arm_chapter_start)
    self.spawn_last = nil    -- { at, kind, moved, why, stage, chapter }: what the last armed jump did
    self:probe()
    return self
end

-- set_field, or set_native_field for fields the managed setter refuses (enum-typed fields).
function World:set_field_any(obj, type_name, field, value)
    if R.set(obj, field, value) and R.number(R.get(obj, field)) == value then return true end
    local td = self.r:type(type_name)
    return td ~= nil and (pcall(sdk.set_native_field, obj, td, field, value))
end

-- Live config (experimental switches live in the core adapter's settings).
function World:setting(key)
    local s = self.game and self.game.settings
    return s and s[key]
end

function World:perf()
    return (self.game and self.game.perf) or Perf.NULL
end

function World:crumb(step, detail, urgent)
    self:perf():crumb(step, detail, urgent)
end

-- The game reloaded: scanned components and half-read tables belong to the old scene.
function World:on_reload()
    self:restore_animals()
    self.object_index = {}
    self.comp_guid = {}
    self.comp_guid_n = 0
    self.gim_scan = nil
    self.object_scan = nil
    self.word_queue = {}
    self.flag_groups = nil
    self.trigger_events = {}
    self.trigger_owner_info = {}
    self.mech_events = {}
    self.mech_remote = {}
    self.mech_owner_info = {}
    self.skips_seen = {}
    self.doors = {}
    self.doors_at = nil
    self.door_guest = {}
    self.auto_hold = {}
    self.big_added = {}
end

function World:cap(name, ok, detail)
    if self.game ~= nil and self.game.cap ~= nil then
        return self.game:cap(name, ok, detail)
    end
    return ok
end

-------------------------------------------------------------------------------
-- Probing
-------------------------------------------------------------------------------

local function params_are(info, list)
    if #info.params ~= #list then return false end
    for i, t in ipairs(list) do
        if info.params[i] ~= t then return false end
    end
    return true
end

local function ret_ends(info, suffix)
    return ends_with(info.ret, suffix)
end

-- A save/load method of a manager: the game declares them with share.SaveDataBase (the
-- object is the manager's own SaveData).
local function save_method(info, save_type)
    return #info.params == 0 and (ret_ends(info, save_type) or info.ret == SAVE_BASE)
end
local function load_method(info, save_type)
    return #info.params == 1 and (ends_with(info.params[1], save_type) or info.params[1] == SAVE_BASE)
end

function World:probe()
    local r = self.r
    -- Scenario flags. Every flag is a via.userdata.Variable (a GUID and a value); the game sets
    -- them from everywhere (requestSetFlag, portrayals, cutscene start/end flags, a thousand
    -- direct Variable.set_Bool calls) and announces every change to two handlers of
    -- ScenarioFlagManagerBehavior. GlobalUserDataManager finds and sets any of them by GUID.
    self.flag_event_ms = {}
    for _, name in ipairs(World.FLAG_EVENTS) do
        local m = r:find_method(SFM_BHV, function(i) return i.name == name and params_are(i, { VARIABLE }) end)
        if m ~= nil then self.flag_event_ms[#self.flag_event_ms + 1] = m end
    end
    self.var_find_m = r:find_method(GUD, function(i) return i.name == "findVariable" and params_are(i, { "System.Guid" }) end)
    self.var_set_m = r:find_method(GUD, function(i) return i.name == "trySetBool" and params_are(i, { "System.Guid", "System.Boolean" }) end)
    -- requestSetFlag(Guid, ck_readonly) turns a flag on (the Boolean is a read-only check, not
    -- the value); checkFlag(Guid) reads it.
    self.flag_set_m = r:find_method(SFM, function(i) return i.name == "requestSetFlag" and params_are(i, { "System.Guid", "System.Boolean" }) end)
    self.flag_check_m = r:find_method(SFM, function(i) return i.name == "checkFlag" and params_are(i, { "System.Guid" }) end)
    self.flag_save_m = r:find_method(SFM, function(i) return save_method(i, "ScenarioFlagManager.SaveData") end,
        { "saveGameSaveData" })
    self.flag_load_m = r:find_method(SFM, function(i) return load_method(i, "ScenarioFlagManager.SaveData") end,
        { "loadGameSaveData" })
    local can_set = self.var_set_m ~= nil or self.flag_set_m ~= nil
    local can_read = self.var_find_m ~= nil or self.flag_check_m ~= nil
    self:cap("flags", can_set and can_read, can_set and ((self.var_set_m and "GlobalUserDataManager.trySetBool" or "requestSetFlag")
        .. " / " .. (self.var_find_m and "findVariable" or (self.flag_check_m and "checkFlag" or "no check"))) or "no setter")
    self:cap("flag_words", self.flag_save_m ~= nil and self.flag_load_m ~= nil,
        self.flag_save_m and (self.flag_save_m.name .. " / " .. (self.flag_load_m and self.flag_load_m.name or "no load")) or "no save/load")

    -- Gimmick save table: read through saveGameSaveData (a fresh copy); partner states are
    -- applied gimmick by gimmick the way the game's own load does it -
    -- GimmickManager.findContext(id) -> GimmickContext.loadSaveDataFromManager(SaveData), then
    -- pushDirtyList - never through loadGameSaveData, which clears the whole manager first.
    self.gim_save_m = r:find_method(GIM, function(i) return save_method(i, "GimmickManager.SaveData") end,
        { "saveGameSaveData" })
    self.gim_find_m = r:find_method(GIM, function(i) return i.name == "findContext" and params_are(i, { CONTEXT_ID }) end)
    self.gim_ctx_load_m = r:find_method(GIM_CONTEXT, function(i)
        return i.name == "loadSaveDataFromManager" and params_are(i, { GIM_SAVE }) end)
    self.gim_dirty_m = r:find_method(GIM, function(i) return i.name == "pushDirtyList" and #i.params == 1 end)
    -- The gimmick's live object (its GimmickCore), to let it react to the partner's change.
    self.gim_core_m = r:find_method(GIM, function(i) return i.name == "findGimmick" and params_are(i, { CONTEXT_ID }) end)
    local gim_ok = self.gim_save_m ~= nil and self.gim_find_m ~= nil and self.gim_ctx_load_m ~= nil
    self:cap("gimmicks", gim_ok, gim_ok and "saveGameSaveData / findContext + loadSaveDataFromManager"
        or (self.gim_save_m == nil and "no saveGameSaveData" or "no findContext / loadSaveDataFromManager"))

    -- Breakables / animals present in this game build.
    self.object_types = {}
    for _, name in ipairs(World.OBJECT_TYPES) do
        if r:type(name) ~= nil then self.object_types[#self.object_types + 1] = name end
    end
    self:cap("objects", #self.object_types > 0, ("%d object types"):format(#self.object_types))
    local trap_types = 0
    for name in pairs(World.TRAP_KINDS) do
        if r:type(name) ~= nil then trap_types = trap_types + 1 end
    end
    self:cap("traps", trap_types > 0, ("%d trap types (bear trap, sensor bomb)"):format(trap_types))
    -- Animals: a gimmick's state machine (GmBase.updateGimmick) runs from its GimmickCore, and
    -- GimmickManager updates the cores registered with registerMove. A client's copy of a host
    -- animal leaves that list while it follows the host.
    self.move_reg_m = r:find_method(GIM, function(i) return i.name == "registerMove" and #i.params == 1 end)
    self.move_unreg_m = r:find_method(GIM, function(i) return i.name == "unregisterMove" and #i.params == 1 end)
    self:cap("animal_puppets", self.move_reg_m ~= nil and self.move_unreg_m ~= nil,
        self.move_unreg_m and "GimmickManager.unregisterMove / registerMove" or "no move registry")

    -- Cutscenes: every "play once" camera request (story cutscenes, movies) ends in
    -- ClapperboardMediator.procPayloadPlay(play id, PayloadPlay); checkHasDone(type, id) says
    -- whether this save already played one.
    self.cs_proc_m = r:find_method(CLAP, function(i) return i.name == "procPayloadPlay" and params_are(i, { "System.UInt32", PAYLOAD_PLAY }) end)
    self.cs_emit_m = r:find_method(CLAP, function(i) return i.name == "emitPlayID" and #i.params == 0 end)
    self.cs_done_m = r:find_method(CLAP, function(i) return i.name == "checkHasDone" and params_are(i, { "System.Int32", "System.Int32" }) end)
    local cs_ok = self.cs_proc_m ~= nil and self.cs_emit_m ~= nil and r:type(PAYLOAD_PLAY) ~= nil
    self:cap("cutscenes", cs_ok, cs_ok and "ClapperboardMediator.procPayloadPlay (PayloadPlay)"
        or (self.cs_proc_m == nil and "no procPayloadPlay" or "no emitPlayID / PayloadPlay"))
    -- Skips: the skip button only sets PlayWork.InputSkip; the mediator's procSkip then skips
    -- the playing camera if it can be skipped (and sets DoneSkip). _Plays holds one PlayWork
    -- per screen.
    self.cs_skip_ok = r:find_field(CLAP, function(i) return i.name == "_Plays" end) ~= nil
        and r:find_field(PLAY_WORK, function(i) return i.name == "InputSkip" end) ~= nil
        and r:find_field(PLAY_WORK, function(i) return i.name == "DoneSkip" end) ~= nil
    self:cap("cutscene_skips", self.cs_skip_ok, self.cs_skip_ok and "PlayWork.InputSkip / DoneSkip" or "no PlayWork skip fields")

    -- Level triggers: InteractManager runs every activated trigger through
    -- InteractTrigger.Work.executeTrigger(target, userdata); InteractHolder.findTrigger(hash)
    -- finds one again on its GameObject.
    self.trig_exec_m = r:find_method(TRIGGER_WORK, function(i) return i.name == "executeTrigger" and #i.params == 2 end)
    self.trig_find_m = r:find_method(HOLDER, function(i) return i.name == "findTrigger" and params_are(i, { "System.UInt32" }) end)
    local trig_ok = self.trig_exec_m ~= nil and self.trig_find_m ~= nil
    self:cap("triggers", trig_ok, trig_ok and "InteractTrigger.Work.executeTrigger / InteractHolder.findTrigger"
        or (self.trig_exec_m == nil and "no executeTrigger" or "no findTrigger"))

    -- Doors: GmDoor opens when bit 0 (Attr0Bit.Open) of its first attribute is set and closes
    -- by itself once nobody keeps it open: _NeedKeepOpenSelf[Host] is our player (a timer
    -- refreshed while it stands in the doorway), [Guest] the other player - which only the
    -- game's dormant network receiver recvGmParam(NeedOpenSelfIndex, value) sets.
    self.door_ok = r:type(GM_DOOR) ~= nil
        and r:find_method(GM_DOOR, function(i) return i.name == "recvGmParam" and #i.params == 3 end) ~= nil
        and r:find_field(GM_DOOR, function(i) return i.name == "_NeedKeepOpenSelf" end) ~= nil
    self:cap("doors", self.door_ok, self.door_ok and "GmDoor Guest slot, GmAutoDoorBase sensor, GmBigDoor count"
        or "no GmDoor keep-open slots")

    -- Objectives (docs/RESEARCH.md 3.24): PurposeManager computes the current objective from
    -- the game's conditions (flags, items held...) and only ever moves on to one of higher
    -- priority (updateMainPurpose); the partner's more advanced one is shown through it.
    self.purpose_update_m = r:find_method(PURPOSE_MGR, function(i)
        return i.name == "updateMainPurpose" and params_are(i, { PURPOSE_ITEM }) end)
    self.purpose_ctor_m = r:find_method(PURPOSE_ITEM, function(i) return i.name == ".ctor" and #i.params == 6 end)
    self:cap("purposes", self.purpose_update_m ~= nil and self.purpose_ctor_m ~= nil,
        self.purpose_update_m and "PurposeManager.updateMainPurpose" or "no updateMainPurpose")

    -- Travel.
    self.warp_m = r:find_method(CHARACTER_MANAGER, function(i) return i.name == "requestWarp" and #i.params == 4 end)
    self:cap("warp", self.warp_m ~= nil and r:type("chainsaw.StageIdentifier") ~= nil,
        self.warp_m and "CharacterManager.requestWarp + stage preload" or "fallback: transform teleport")
    self.load_save_m = r:find_method(CAMPAIGN, function(i) return i.name == "loadGameSaveData" and #i.params == 1 end)
    self:cap("chapter_switch", self.load_save_m ~= nil,
        self.load_save_m and "CampaignManager.loadGameSaveData" or "not found")
    -- Where a loaded game puts the player (docs/RESEARCH.md 3.34): the in-game setup builds its
    -- campaign jump with createCampaignJumperOrderFromInitialSettings; the jump loads the map
    -- around its base character's locator (stage, position) and puts every character at its own.
    self.order_m = r:find_method(CAMPAIGN, function(i)
        return i.name == "createCampaignJumperOrderFromInitialSettings" and #i.params == 4 end)
    local spawn_ok = self.order_m ~= nil and r:type(ORDER) ~= nil and r:type(LOCATOR) ~= nil
    self:cap("spawn_at_partner", spawn_ok, spawn_ok and "CampaignJumper.Order locators (in-game setup)"
        or "no createCampaignJumperOrderFromInitialSettings")
    if not spawn_ok then self.order_m = nil end
    -- Where a chapter part starts (docs/RESEARCH.md 3.35): its CampaignInitialSetting in the start
    -- point catalog, the one the game's own chapter change and a new game start it from.
    self.start_setting_m = r:find_method(ENV_DB, function(i)
        return i.name == "getCampaignInitialSetting" and #i.params == 1 end)
    local start_ok = self.order_m ~= nil and self.start_setting_m ~= nil
    self:cap("chapter_start", start_ok, start_ok and "EnvSceneStructureDB.getCampaignInitialSetting (start points)"
        or "no start point catalog")
end

function World:install_hooks(callbacks)
    self.callbacks = callbacks or {}
    local r = self.r
    local installed = 0

    -- Flag changes: the game's own change events report every flag, whoever set it. Only
    -- flags turning on (and trigger-kind flags firing) are news for the partner; a reload
    -- turning flags back off stays local, but flag_sync hears of it so the flag counts as
    -- news again the next time it turns on.
    for _, info in ipairs(self.flag_event_ms or {}) do
        local base = info.static and 2 or 3
        local ok = r:hook(info, function(args)
            -- Cheap checks first: this runs for every flag the game changes.
            if self.applying or not self.active then return end
            local cb = self.callbacks.on_flag
            if cb == nil or not self:flag_hook_budget() then return end
            local var = R.arg_obj(args[base])
            if var == nil then return end
            local kind = R.number(R.call(var, "get_TypeKind"))
            local pulse = kind == KIND_TRIGGER
            local value = pulse or R.call(var, "get_Bool") == true
            local guid = R.guid_string(R.call(var, "get_Guid"))
            if guid == nil then return end
            self.counters.flag_events = self.counters.flag_events + 1
            pcall(cb, guid, value, pulse)
        end)
        if ok then installed = installed + 1 end
    end
    self.flag_hooks = installed > 0
    self:cap("flag_hooks", self.flag_hooks, ("%d change handlers hooked"):format(installed))

    -- Cutscenes: every "play once" request our game plays, as its PayloadPlay.
    local cs_hooked = false
    if self.cs_proc_m ~= nil then
        local base = self.cs_proc_m.static and 2 or 3
        cs_hooked = r:hook(self.cs_proc_m, function(args)
            if self.applying_cutscene or not self.active then return end
            local cb = self.callbacks.on_cutscene
            if cb == nil then return end
            local ev = self:read_payload(R.arg_obj(args[base + 1]))
            if ev ~= nil then
                self.counters.cutscene_events = self.counters.cutscene_events + 1
                pcall(cb, ev)
            end
        end)
    end
    self:cap("cutscene_hooks", cs_hooked, cs_hooked and "procPayloadPlay hooked" or "not hooked")

    -- Level triggers our player sets off: queued here (the hook runs inside the game's
    -- interaction update), classified and reported by update().
    local trig_hooked = false
    if self.trig_exec_m ~= nil then
        local base = self.trig_exec_m.static and 2 or 3
        trig_hooked = r:hook(self.trig_exec_m, function(args)
            if self.applying_trigger or not self.active or self.callbacks.on_trigger == nil then return end
            local target = R.arg_int(args[base])
            local objs = self.game and self.game.player_objects
            if target == nil or objs == nil or not objs[target] then return end -- an NPC, an enemy, a doll
            local work = R.arg_obj(args[base - 1])
            local trig = work and R.call(work, "get_Trigger")
            if trig == nil or R.number(R.call(trig, "get_Type")) ~= TRIGGER_AREA_HIT then return end
            if #self.trigger_events < 32 then
                local body = self.game.player_body
                local okb, body_addr = pcall(function() return body:get_address() end)
                local head = okb and body_addr ~= nil and target ~= body_addr
                self.trigger_events[#self.trigger_events + 1] = { trig = trig, head = head }
            end
        end)
    end
    self:cap("trigger_hooks", trig_hooked, trig_hooked and "executeTrigger hooked" or "not hooked")

    -- Mechanisms (docs/RESEARCH.md 3.19): every scripted sequence a gimmick starts
    -- (PortrayalSettings.call - all its overloads end in the UInt32 one) and a pushed object
    -- that moved (GmBase.setGmFlag(true) on a GmPushMove). Only recorded here; classified in
    -- report_mechanisms. A sequence the partner's game just started here and our own game now
    -- starts again (its own reaction to the same flags) is not played twice.
    local mech_hooked = 0
    local port_call = r:find_method(PORTRAYAL, function(i)
        return i.name == "call" and #i.params == 3 and i.params[1] == "System.UInt32" end)
    if port_call ~= nil and r:hook(port_call, function(args)
        if not self.active then return end
        local this = R.arg_obj(args[2])
        if this == nil then return end
        local key = (sdk.to_int64(args[3]) or 0) & 0xFFFFFFFF
        if self.reacting then
            -- A gimmick reacting to the partner's change plays its own sequence: the partner's
            -- report of the same sequence (MECHANISMS) must not play it a second time, and its
            -- end effects stay muted.
            local go = R.call(this, "get_GameObject")
            local guid = go and R.game_object_guid(go)
            if guid ~= nil then self.mech_remote[guid .. ":" .. key] = self:now() end
            local a = R.address(this)
            if a ~= nil then self.replayed[a] = self:now() + REPLAY_MUTE end
            return
        end
        if self.applying_mech or self.applying_trigger or self.applying_cutscene then return end
        if next(self.mech_remote) ~= nil then
            local go = R.call(this, "get_GameObject")
            local guid = go and R.game_object_guid(go)
            local t = guid and self.mech_remote[guid .. ":" .. key]
            if t ~= nil and self:now() - t < MECH_ECHO then
                self.counters.mech_doubles = (self.counters.mech_doubles or 0) + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end
        if #self.mech_events < 64 then
            self.mech_events[#self.mech_events + 1] = { kind = 1, comp = this, key = key }
        end
    end) then mech_hooked = mech_hooked + 1 end
    local set_flag = r:find_method("chainsaw.GmBase", function(i) return i.name == "setGmFlag" and #i.params == 3 end)
    if set_flag ~= nil and r:hook(set_flag, function(args)
        if not self.active or self.applying_mech then return end
        if (sdk.to_int64(args[3]) or 0) & 1 == 0 then return end
        local this = R.arg_obj(args[2])
        if this == nil or R.type_name(this) ~= PUSH_MOVE then return end
        if R.call(this, "getGmFlag") == true then return end -- already moved
        if #self.mech_events < 64 then
            self.mech_events[#self.mech_events + 1] = { kind = 2, comp = this, key = 0 }
        end
    end) then mech_hooked = mech_hooked + 1 end
    self:cap("mechanisms", mech_hooked == 2, ("%d of 2 hooked (PortrayalSettings.call, GmBase.setGmFlag)"):format(mech_hooked))
    self:install_mute_hooks()

    -- Chapter switch: rewrite the chapter of the next save load when armed. (Not the save's
    -- _SpecialJumpSequence, as 0.6-0.11 did after RE4R-AP-Wizard: it is a SpecialOrderType, a
    -- chapter opening, and the in-game setup only reads it for a new game - docs/RESEARCH.md
    -- 3.34. Where the player appears is the campaign jump's locator: see the spawn below.)
    if self.load_save_m ~= nil then
        local base = self.load_save_m.static and 2 or 3
        r:hook(self.load_save_m, function(args)
            local chapter = self.chapter_target
            if chapter == nil then return end
            self.chapter_target = nil
            local data = R.arg_obj(args[base])
            local init = data and R.get(data, "_InitialSettings")
            if init == nil then
                self.log("chapter switch: save data has no _InitialSettings")
                return
            end
            if R.number(R.get(init, "_Chapter")) == chapter then
                return -- the save is already in that chapter: keep its own checkpoint
            end
            local ok1 = self:set_field_any(init, "chainsaw.CampaignInitialSetting", "_Chapter", chapter)
            self.log(("chapter switch applied: %d (%s)"):format(chapter, tostring(ok1)))
        end)
    end

    -- Spawn at the partner: when armed, the campaign jump the in-game setup builds next (after
    -- a save loaded or a new game started) puts our player where the partner is - or, for the
    -- lobby's chapter jump, at that chapter's start.
    if self.order_m ~= nil then
        r:hook(self.order_m, function() end, function(retval)
            if self.spawn_until ~= nil then
                local ok, err = pcall(self.on_order_built, self, retval)
                if not ok then self.log("spawn at partner failed: " .. tostring(err)) end
            end
            return retval
        end)
    end
end

-------------------------------------------------------------------------------
-- Muting the partner's effects (docs/RESEARCH.md 3.24)
--
-- What the partner's player did is replayed here through the game's own code: the gimmick's
-- reaction, its scripted sequence, a level event. A sequence's parameter sets can also hand out
-- items, take them, kill the player, end the chapter, start a tutorial or change the game mode
-- (World.DENY_COMPONENTS). Those effects belong to the player who acted: while we replay, each
-- such effect's triggerProcess (and makeFinish, where it does something) is skipped. The
-- effects at the end of a sequence run later (PortrayalSettings.Param.onFinish): a sequence we
-- replayed keeps them muted until it finishes. An effect type whose methods could not be hooked
-- is not muted, and a sequence that runs one is still never shared.
-------------------------------------------------------------------------------

local function method_function(m)
    local ok, fn = pcall(function() return m:get_function() end)
    return ok and fn or nil
end

function World:install_mute_hooks()
    local r = self.r
    -- The game's shared empty method: a method that is it does nothing (and must never be
    -- hooked - thousands of methods share it).
    local stub_info = r:find_method("chainsaw.PortrayalParam", function(i) return i.name == "makeFinish" end)
    local stub = stub_info and method_function(stub_info.method) or nil
    local seen, hooked, harmless = {}, 0, 0
    local function mute_pre()
        if self.muting > 0 then
            self.counters.muted_effects = self.counters.muted_effects + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end
    -- One method: true when it is muted (hooked, or does nothing).
    local function mute(info)
        local fn = method_function(info.method)
        if fn ~= nil and fn == stub then
            harmless = harmless + 1
            return true
        end
        if fn ~= nil and seen[fn] then return true end -- the same code as a method hooked already
        if r:hook(info, mute_pre) then
            if fn ~= nil then seen[fn] = true end
            hooked = hooked + 1
            return true
        end
        return false
    end
    for name in pairs(World.DENY_COMPONENTS) do
        local pt = name .. ".Param"
        local play = r:type(pt) and r:find_method(pt, function(i) return i.name == "triggerProcess" and #i.params == 2 end)
        -- Only an effect whose own triggerProcess is muted counts as muted (an inherited or
        -- missing one could not be told from the effect itself).
        if play ~= nil and play.owner == pt and mute(play) then
            local finish = r:find_method(pt, function(i) return i.name == "makeFinish" and #i.params == 0 end)
            if finish == nil or finish.owner ~= pt or mute(finish) then self.muted_types[name] = true end
        end
    end
    -- End effects of a sequence we replayed.
    local finish = r:find_method(PORTRAYAL_PARAM, function(i) return i.name == "onFinish" and #i.params == 0 end)
    local stack = {}
    local finish_hooked = finish ~= nil and r:hook(finish, function(args)
        local muted = false
        if next(self.replayed) ~= nil then
            local this = R.arg_obj(args[2])
            local settings = this and R.get(this, "_Settings")
            local key = settings and R.address(settings)
            local until_t = key and self.replayed[key]
            if until_t ~= nil then
                self.replayed[key] = nil
                if self:now() < until_t then muted = true end
            end
        end
        if muted then self.muting = self.muting + 1 end
        stack[#stack + 1] = muted
    end, function(retval)
        local muted = table.remove(stack)
        if muted then self.muting = math.max(0, self.muting - 1) end
        return retval
    end)
    self:cap("mute_effects", hooked > 0 and finish_hooked,
        ("%d effect methods muted while replaying, %d do nothing, end effects %s"):format(hooked, harmless,
            finish_hooked and "muted" or "NOT muted"))
end

-- Runs fn with the partner's effects muted (see install_mute_hooks).
function World:muted(fn)
    self.muting = self.muting + 1
    local ok, err = pcall(fn)
    self.muting = math.max(0, self.muting - 1)
    if not ok then self.log("muted replay failed: " .. tostring(err)) end
    return ok
end

-- The PortrayalSettings on `go` and below keep their end effects muted for a while: we are
-- about to replay their sequence.
function World:mark_replayed(go)
    if go == nil then return end
    local now = self:now()
    for a, t in pairs(self.replayed) do
        if now > t then self.replayed[a] = nil end
    end
    local nodes = (self.game and self.game.collect_tree) and self.game:collect_tree(go, 3) or { { go = go } }
    for _, node in ipairs(nodes) do
        R.each(R.call(node.go, "get_Components"), function(c)
            if R.type_name(c) == PORTRAYAL then
                local a = R.address(c)
                if a ~= nil then self.replayed[a] = now + REPLAY_MUTE end
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- Scenario flags
-------------------------------------------------------------------------------

function World:flag_mgr()
    return self.r:singleton(SFM)
end

-- The via.userdata.Variable behind a flag GUID (GlobalUserDataManager.findVariable), or nil.
function World:flag_variable(guid)
    local m = self.var_find_m
    if m == nil then return nil end
    local g = self.r:guid_value(guid)
    if g == nil then return nil end
    local ok, var = pcall(m.method.call, m.method, nil, g)
    if ok and var ~= nil then return var end
    return nil
end

-- Sets a flag through the game, so everything that reacts to it reacts (its change event
-- runs): GlobalUserDataManager.trySetBool, else ScenarioFlagManager.requestSetFlag (on only).
function World:flag_set(guid, value)
    local g = self.r:guid_value(guid)
    if g == nil then return false end
    value = value and true or false
    self:crumb("world.flag_set", guid)
    self.applying = true
    local ok = false
    local m = self.var_set_m
    if m ~= nil then
        local okc, r = pcall(m.method.call, m.method, nil, g, value)
        ok = okc and r ~= false
    end
    if not ok and value and self.flag_set_m ~= nil then
        local mgr = self:flag_mgr()
        if mgr ~= nil then
            -- ck_readonly = false: the partner's game already decided this flag may be set.
            ok = pcall(self.flag_set_m.method.call, self.flag_set_m.method, mgr, g, false)
        end
    end
    self.applying = false
    return ok
end

-- Fires a trigger-kind flag (via.userdata.Variable.setTrigger).
function World:flag_pulse(guid)
    local var = self:flag_variable(guid)
    if var == nil then return false end
    self:crumb("world.flag_pulse", guid)
    self.applying = true
    local ok = pcall(var.call, var, "setTrigger")
    self.applying = false
    return ok
end

function World:flag_check(guid)
    local var = self:flag_variable(guid)
    if var ~= nil then
        local v = R.call(var, "get_Bool")
        if type(v) == "boolean" then return v end
    end
    local m, mgr = self.flag_check_m, self:flag_mgr()
    if m == nil or mgr == nil then return nil end
    local g = self.r:guid_value(guid)
    if g == nil then return nil end
    local ok, v = pcall(m.method.call, m.method, mgr, g)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- Sync is running (a partner is connected): the hooks only do work while it is.
function World:set_active(on)
    self.active = on and true or false
end

function World:now()
    local clock = self.game and self.game.clock
    return clock and clock() or os.clock()
end

-- Some games re-set flags every frame. If the setter hooks fire more than FLAG_HOOK_BUDGET
-- times in a second, they stop reading arguments for a while and the word diffs (which
-- see only real changes) take over, so the frame rate never pays for it.
local FLAG_HOOK_BUDGET = 400
local FLAG_HOOK_PAUSE = 5.0

function World:flag_hook_budget()
    local t = self:now()
    if t < (self.flag_overflow_until or -math.huge) then return false end
    if t - (self.flag_window or -math.huge) >= 1.0 then
        self.flag_window, self.flag_calls = t, 0
    end
    self.flag_calls = self.flag_calls + 1
    if self.flag_calls > FLAG_HOOK_BUDGET then
        self.flag_overflow_until = t + FLAG_HOOK_PAUSE
        self.flag_overflows = (self.flag_overflows or 0) + 1
        self:cap("flag_hooks", true, ("setters busy (%d/s): word diffs for %ds"):format(FLAG_HOOK_BUDGET, FLAG_HOOK_PAUSE))
        return false
    end
    return true
end

-- Whether every flag change arrives through the hooks (else flag_sync diffs the words).
function World:flag_hooks_active()
    return self.flag_hooks == true and self:now() >= (self.flag_overflow_until or -math.huge)
end

function World:flag_save_data()
    local m, mgr = self.flag_save_m, self:flag_mgr()
    if m == nil or mgr == nil or self.flag_load_m == nil then return nil end
    local ok, sd = pcall(m.method.call, m.method, mgr)
    if ok then return sd end
    return nil
end

function World:flag_words_snapshot()
    local sd = self:flag_save_data()
    if sd == nil then return nil end
    local out, n = {}, 0
    R.each(R.get(sd, "Datas"), function(g)
        local name = R.string(R.get(g, "GroupName"))
        if name ~= nil then
            out[name] = R.numbers(R.get(g, "Flags"))
            n = n + 1
        end
    end)
    if n == 0 then return nil end
    return out
end

-- Rewrites groups in a fresh save object and loads it back (the game's own load: it sets
-- every flag variable from the words). changes(name, words_array, current) returns true if it
-- modified the array. Only for the complete copy a joining client takes over; live changes
-- go flag by flag (apply_word_queue).
function World:flag_rewrite(edit)
    local sd = self:flag_save_data()
    if sd == nil then return false end
    local changed = false
    R.each(R.get(sd, "Datas"), function(g)
        local name = R.string(R.get(g, "GroupName"))
        local arr = R.get(g, "Flags")
        if name ~= nil and arr ~= nil and edit(name, arr, R.numbers(arr)) then changed = true end
    end)
    if not changed then return true end
    self:crumb("world.flag_table_reload", "full", true)
    self.applying = true
    local ok = pcall(self.flag_load_m.method.call, self.flag_load_m.method, self:flag_mgr(), sd)
    self.applying = false
    return ok
end

function World:flag_words_apply_full(groups)
    local by_name = {}
    for _, g in ipairs(groups) do by_name[g.name] = g.words end
    return self:flag_rewrite(function(name, arr, cur)
        local target = by_name[name]
        if target == nil then return false end
        local changed = false
        for i, w in pairs(target) do
            if i <= #cur and cur[i] ~= w then
                if R.set_number(arr, i - 1, w) then changed = true end
            end
        end
        return changed
    end)
end

-- Queued; applied together by World:update(). Only bits turning on are applied (a flag going
-- off in the partner's game is their reload, not news).
function World:flag_words_apply(group, word, set, clear)
    if set == 0 then return true end
    local g = self.word_queue[group]
    if g == nil then
        g = {}
        self.word_queue[group] = g
    end
    g[word] = (g[word] or 0) | set
    return true
end

-- ScenarioFlagManager.Group by its name (the SaveGroup.GroupName of the words): bit i of its
-- words is the flag variable i of its UserVariables (ScenarioFlagManager.applyBit2Variable).
function World:flag_group(name)
    if self.flag_groups == nil then
        local groups = {}
        R.each(R.get(self:flag_mgr(), "_Group"), function(g)
            local n = R.string(R.get(g, "<Name>k__BackingField") or R.call(g, "get_Name"))
            if n ~= nil then groups[n] = g end
        end)
        if next(groups) == nil then return nil end
        self.flag_groups = groups
    end
    return self.flag_groups[name]
end

-- Turns flags on bit by bit through their variables (the change events run, as for any flag
-- the game sets). No table reload while playing.
function World:apply_word_queue()
    if next(self.word_queue) == nil then return end
    local queue = self.word_queue
    self.word_queue = {}
    for name, words in pairs(queue) do
        local g = self:flag_group(name)
        local vars = g and (R.get(g, "<Variables>k__BackingField") or R.call(g, "get_Variables"))
        if vars ~= nil then
            for word, set in pairs(words) do
                for bit = 0, 31 do
                    if (set >> bit) & 1 == 1 then
                        local var = R.call(vars, "getVariable", word * 32 + bit)
                        if var ~= nil and R.call(var, "get_Bool") ~= true then
                            self.applying = true
                            pcall(var.call, var, "set_Bool", true)
                            self.applying = false
                        end
                    end
                end
            end
        else
            self.word_apply_failed = (self.word_apply_failed or 0) + 1
        end
    end
end

function World:update()
    self:apply_word_queue()
    self:report_triggers()
    self:report_skips()
    self:retry_waiting_gimmicks()
    self:refresh_auto_holds()
end

-------------------------------------------------------------------------------
-- Gimmick save table
-------------------------------------------------------------------------------

function World:read_ctx(id)
    if id == nil then return nil end
    local cat = R.number(R.get(id, "_Category"))
    local kind = R.number(R.get(id, "_Kind"))
    local group = R.number(R.get(id, "_Group"))
    local index = R.number(R.get(id, "_Index"))
    if cat == nil or group == nil or index == nil then return nil end
    return { category = cat, kind = kind or 0, group = group, index = index }
end

function World:gim_save_data()
    local mgr = self.r:singleton(GIM)
    if mgr == nil or self.gim_save_m == nil then return nil, nil end
    local ok, sd = pcall(self.gim_save_m.method.call, self.gim_save_m.method, mgr)
    if ok and sd ~= nil then return sd, mgr end
    return nil, nil
end

local function bytes_of(arr)
    local out = {}
    for i, v in ipairs(R.numbers(arr)) do out[i] = string.char(v & 0xFF) end
    return table.concat(out)
end

function World:read_gimmick(item)
    local ctx = self:read_ctx(R.get(item, "ID"))
    local data = R.get(item, "SaveData")
    if ctx == nil or data == nil then return nil end
    local out = { ctx = ctx, attr = bytes_of(R.get(data, "Attr")), triggers = {}, acc = {},
        detected = R.get(data, "IsDetected") == true }
    R.each(R.get(data, "TriggerSave"), function(t)
        out.triggers[#out.triggers + 1] = { id = R.number(R.get(t, "SaveID")) or 0, done = R.number(R.get(t, "Done")) or 0 }
    end)
    R.each(R.get(data, "AccDatas"), function(a)
        local tn = R.type_name(a) or ""
        local v = R.number(R.get(a, "Value")) or 0
        out.acc[#out.acc + 1] = { kind = tn:find("Float") and 1 or 2, value = v }
    end)
    return out
end

local GIMMICKS_PER_CALL = 40   -- items fully read per call
local GIMMICK_IDS_PER_CALL = 150 -- items whose ID is checked per call (targeted reads)

-- The table can hold hundreds of gimmicks; reading it all in one frame would hitch, so scans
-- run over several calls and return the table when done (nil until then).
--   force = read everything now (one-off full copies);
--   keys  = { [ctx_key] = true }: read only those gimmicks (the ones that announced a change).
-- The table itself comes from GimmickManager's save method, which builds a fresh copy: that
-- is done once per scan, not per call.
function World:gimmicks_snapshot(force, keys)
    local scan = self.gim_scan
    if scan ~= nil and scan.keys ~= keys then scan = nil end -- a different kind of scan was running
    if scan == nil then
        local sd = self:gim_save_data()
        if sd == nil then return nil end
        local items = {}
        R.each(R.get(sd, "Datas"), function(item) items[#items + 1] = item end)
        scan = { sd = sd, items = items, next = 1, out = {}, keys = keys }
        self.gim_scan = scan
        self:perf():crumb("world.gimmick_scan", keys and "targeted" or "full")
    end
    local per_call = keys and GIMMICK_IDS_PER_CALL or GIMMICKS_PER_CALL
    local last = force and #scan.items or math.min(#scan.items, scan.next + per_call - 1)
    for i = scan.next, last do
        local item = scan.items[i]
        if keys ~= nil then
            local key = P.ctx_key(self:read_ctx(R.get(item, "ID")))
            if key ~= nil and keys[key] then
                local g = self:read_gimmick(item)
                if g ~= nil then scan.out[key] = g end
            end
        else
            local g = self:read_gimmick(item)
            if g ~= nil then scan.out[P.ctx_key(g.ctx)] = g end
        end
    end
    scan.next = last + 1
    if scan.next <= #scan.items then return nil end
    self.gim_scan = nil
    return scan.out
end

-- Writes a partner's state into a SaveData (a clone of our context's current one): new
-- arrays only (a clone may share its arrays with the live state), and accessory values only
-- where our record has the same kind of value - an accessory object of another type is the
-- gimmick's own and stays.
function World:write_gimmick(data, item)
    local n = #item.attr
    local attr = R.new_array("System.Byte", n)
    if attr == nil then return false end
    for i = 1, n do
        R.set_number(attr, i - 1, item.attr:byte(i), "byte")
    end
    R.set(data, "Attr", attr)
    -- Triggers that already fired.
    local trig = R.new_array("chainsaw.GimmickContext.TriggerDone", #item.triggers)
    if trig ~= nil then
        for i, t in ipairs(item.triggers) do
            local td = R.new_instance("chainsaw.GimmickContext.TriggerDone")
            if td ~= nil then
                R.set(td, "SaveID", t.id)
                R.set(td, "Done", t.done)
                pcall(function() trig[i - 1] = td end)
            end
        end
        R.set(data, "TriggerSave", trig)
    end
    R.set(data, "IsDetected", item.detected and true or false)
    -- Accessory values.
    local old = {}
    R.each(R.get(data, "AccDatas"), function(a) old[#old + 1] = a end)
    local count = math.max(#old, #item.acc)
    if count > 0 then
        local acc = R.new_array("chainsaw.GimmickContext.AccessoryData", count)
        if acc == nil then return true end
        for i = 1, count do
            local a, v = old[i], item.acc[i]
            local tn = a and R.type_name(a) or nil
            local obj = a
            if v ~= nil and (a == nil or tn == "chainsaw.GimmickContext.AccessoryDataFloat"
                or tn == "chainsaw.GimmickContext.AccessoryDataUint") then
                local want = v.kind == 1 and "chainsaw.GimmickContext.AccessoryDataFloat" or "chainsaw.GimmickContext.AccessoryDataUint"
                if a == nil or (tn == want and R.number(R.get(a, "Value")) ~= v.value) then
                    obj = R.new_instance(want)
                    if obj ~= nil then R.set(obj, "Value", v.value) end
                end
            end
            if obj ~= nil then pcall(function() acc[i - 1] = obj end) end
        end
        R.set(data, "AccDatas", acc)
    end
    return true
end

function World:new_ctx_value(ctx)
    local id = R.new_instance(CONTEXT_ID)
    if id == nil then return nil end
    R.set(id, "_Category", ctx.category)
    R.set(id, "_Kind", ctx.kind)
    R.set(id, "_Group", ctx.group)
    R.set(id, "_Index", ctx.index)
    return id
end

-- One partner gimmick state into our game: "applied", "missing" (no context for it here yet)
-- or "failed".
function World:apply_gimmick(mgr, it)
    local id = self:new_ctx_value(it.ctx)
    if id == nil then return "failed" end
    local okf, ctx = pcall(self.gim_find_m.method.call, self.gim_find_m.method, mgr, id)
    if not okf or ctx == nil then return "missing" end
    self:gimmick_react(mgr, id, ctx, it)
    local cur = R.get(ctx, "_SaveCur")
    local data = cur and R.call(cur, "clone") or R.new_instance(GIM_SAVE)
    if data == nil or not self:write_gimmick(data, it) then return "failed" end
    local ok = pcall(self.gim_ctx_load_m.method.call, self.gim_ctx_load_m.method, ctx, data)
    if not ok then return "failed" end
    -- Into the game's own save buffer too, as for any gimmick that changed state.
    if self.gim_dirty_m ~= nil then pcall(self.gim_dirty_m.method.call, self.gim_dirty_m.method, mgr, ctx) end
    self.counters.gimmicks_applied = self.counters.gimmicks_applied + 1
    return "applied"
end

-- The gimmick's live object here, bound to context `ctx` and set up: GimmickManager.findGimmick
-- (the GimmickCore registered for the ID) -> its GameObject's GmBase whose Context is `ctx`
-- (an option, GmOption*, only when there is nothing else). component, type name, GameObject.
function World:live_gimmick(mgr, id, ctx)
    if self.gim_core_m == nil then return nil end
    local okc, core = pcall(self.gim_core_m.method.call, self.gim_core_m.method, mgr, id)
    if not okc or core == nil then return nil end
    local go = R.call(core, "get_GameObject")
    if go == nil then return nil end
    local ctx_addr = R.address(ctx)
    local found, name
    R.each(R.call(go, "get_Components"), function(c)
        local ok, isa = pcall(function() return c:get_type_definition():is_a(GM_BASE_TYPE) end)
        if ok and isa and R.address(R.call(c, "get_Context")) == ctx_addr and R.call(c, "get_HasInitialized") ~= false then
            local tn = R.type_name(c) or ""
            if found == nil or (name:find("^chainsaw%.GmOption") and not tn:find("^chainsaw%.GmOption")) then
                found, name = c, tn
            end
        end
    end)
    return found, name, go
end

-- The partner set this gimmick (its flag went on there: an item placed in its slot, a lock
-- opened, a puzzle solved). Writing the partner's record alone changes only the saved state:
-- an object already on our screen kept its old look, and a gimmick that reacts to a story flag
-- by itself (GmUseItem.updateGimmick: flag set -> setGmFlag) never did, since its gimmick flag
-- was already on. So the live gimmick sets its own flag first, the game's way -
-- GmBase.setGmFlag(true) runs its onChangeGmFlag: the same reaction it has in the partner's
-- game (the item appears in the slot, the lock opens, the door unlocks) - with the partner's
-- player's effects muted (items given or taken, deaths, chapter ends: install_mute_hooks).
-- Never for gimmicks with their own sync or that are a player's own action (World.MECH_DENY,
-- traps, pushed objects). docs/RESEARCH.md 3.24.
function World:gimmick_react(mgr, id, ctx, it)
    if self:setting("gimmick_reactions") == false then return false end
    if it.attr == nil or (it.attr:byte(1) or 0) == 0 then return false end
    if R.call(ctx, "getGmFlag") == true then return false end
    local gm, name, go = self:live_gimmick(mgr, id, ctx)
    if gm == nil then return false end
    if World.MECH_DENY[name] or World.TRAP_KINDS[name] or name == PUSH_MOVE then return false end
    self:crumb("world.gimmick_react", name, true)
    self:mark_replayed(go)
    self.reacting, self.applying_mech = true, true
    local ok = self:muted(function() gm:call(SET_GM_FLAG, true, nil, nil) end)
    self.reacting, self.applying_mech = false, false
    if ok then
        self.counters.gimmick_reactions = self.counters.gimmick_reactions + 1
        self.last_reaction = name
    end
    return ok
end

local GIMMICK_WAIT = 1800.0 -- how long a partner state waits for its gimmick to be set up here
local GIMMICK_RETRY = 3.0

function World:gimmicks_apply(items)
    self.gim_scan = nil -- a scan in progress would read the old states
    -- Not while the game is loading or playing a cutscene: gimmicks are being set up then.
    local loc = self:location()
    if loc == nil or loc.loading or loc.cutscene then return nil end -- not now: keep the queue
    local mgr = self.r:singleton(GIM)
    if mgr == nil or self.gim_find_m == nil or self.gim_ctx_load_m == nil then return false end
    self:crumb("world.gimmick_apply", ("%d items"):format(#items), true)
    local now = self:now()
    for _, it in ipairs(items) do
        local key = P.ctx_key(it.ctx)
        local r = self:apply_gimmick(mgr, it)
        if r == "missing" then
            self.gim_waiting[key] = { item = it, since = (self.gim_waiting[key] or {}).since or now }
        else
            self.gim_waiting[key] = nil
        end
    end
    self:count_waiting_gimmicks()
    return true
end

function World:count_waiting_gimmicks()
    local n = 0
    for _ in pairs(self.gim_waiting) do n = n + 1 end
    self.counters.gimmicks_waiting = n
end

-- Partner states whose gimmick had no context here (its area not set up yet): tried again now
-- and then.
function World:retry_waiting_gimmicks()
    if next(self.gim_waiting) == nil then return end
    local now = self:now()
    if now - (self.gim_retry_at or -math.huge) < GIMMICK_RETRY then return end
    self.gim_retry_at = now
    local loc = self:location()
    if loc == nil or loc.loading or loc.cutscene then return end
    local mgr = self.r:singleton(GIM)
    if mgr == nil or self.gim_find_m == nil or self.gim_ctx_load_m == nil then return end
    for key, w in pairs(self.gim_waiting) do
        if now - w.since > GIMMICK_WAIT or self:apply_gimmick(mgr, w.item) ~= "missing" then
            self.gim_waiting[key] = nil
        end
    end
    self:count_waiting_gimmicks()
end

-- True once after GimmickManager.pushDirtyList ran (game.lua hooks it and counts the
-- calls): a gimmick changed state, so the save table is worth reading again right away.
function World:gimmicks_dirty()
    local n = self.game and self.game.gimmick_calls or 0
    if n ~= self.dirty_seen then
        self.dirty_seen = n
        return true
    end
    return false
end

-- The gimmicks that announced a change since the last call ({ [ctx_key] = true }), or nil when
-- the hook cannot tell which ones.
function World:gimmick_dirty_keys()
    if self.game == nil or self.game.take_gimmick_dirty_keys == nil then return nil end
    return self.game:take_gimmick_dirty_keys()
end

-------------------------------------------------------------------------------
-- Breakables and animals
-------------------------------------------------------------------------------

function World:scene()
    local ok, scene = pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local td = sdk.find_type_definition("via.SceneManager")
        return sdk.call_native_func(sm, td, "get_CurrentScene")
    end)
    if ok then return scene end
    return nil
end

local function position_of(go)
    local tf = R.call(go, "get_Transform")
    local p = tf and R.call(tf, "get_Position")
    if p == nil then return nil end
    return { x = p.x, y = p.y, z = p.z }
end

function World:routine_info(type_name)
    self.routine_cache = self.routine_cache or {}
    local c = self.routine_cache[type_name]
    if c == nil then
        local f = self.r:find_field(type_name, function(i) return i.name == "_Routine" end, 4)
        c = { field = f ~= nil, enum = f and self.r:enum(f.type) or nil }
        self.routine_cache[type_name] = c
    end
    return c
end

local function is_terminal(name)
    return name ~= nil and starts_any(name, TERMINAL)
end

-- One scene-wide search per object type is not free, and there are ~30 types: each call
-- refreshes OBJECT_TYPES_PER_SCAN types and keeps the others from their last search, so a
-- full round takes a few scans. Returns the merged snapshot.
local OBJECT_TYPES_PER_SCAN = 4

function World:objects_scan()
    local scene = self:scene()
    if scene == nil or #self.object_types == 0 then return nil end
    self.comp_guid_n = (self.comp_guid_n or 0) + 1
    if self.comp_guid_n > 2000 then
        -- Components come and go with areas; addresses can be reused. Start afresh now and then.
        self.comp_guid = {}
        self.comp_guid_n = 0
    end
    local scan = self.object_scan
    if scan == nil then
        scan = { next = 1, by_type = {} } -- type name -> { objects = {guid -> obj}, index = {guid -> entry} }
        self.object_scan = scan
    end
    local n = #self.object_types
    local count = scan.complete and math.min(OBJECT_TYPES_PER_SCAN, n) or n -- the first round reads all
    for _ = 1, count do
        local tname = self.object_types[scan.next]
        scan.next = scan.next % n + 1
        if scan.next == 1 then scan.complete = true end
        local objects, index = {}, {}
        local t = self.r:typeof(tname)
        local comps = t and (R.call(scene, "findComponents(System.Type)", t) or R.call(scene, "findComponents", t))
        R.each(comps, function(comp)
            local okaddr, addr = pcall(function() return comp:get_address() end)
            local cached = okaddr and self.comp_guid[addr] or nil
            local go = R.call(comp, "get_GameObject")
            local okg, go_addr = pcall(function() return go:get_address() end)
            go_addr = okg and go_addr or nil
            local guid
            if cached ~= nil and go_addr ~= nil and cached.go_addr == go_addr then
                guid = cached.guid -- the same object as before (the address was not reused)
            else
                guid = R.game_object_guid(go)
                if okaddr and guid then self.comp_guid[addr] = { guid = guid, go_addr = go_addr } end
            end
            if guid ~= nil and objects[guid] == nil then
                local rtype = R.type_name(comp) or tname
                local info = self:routine_info(rtype)
                local routine = info.field and R.number(R.get(comp, "_Routine")) or nil
                local rname = routine and info.enum and info.enum.values[routine] or nil
                local pos = position_of(go)
                objects[guid] = { kind = tname, pos = pos, routine = routine, terminal = is_terminal(rname) }
                index[guid] = { comp = comp, go = go, info = info, kind = rtype, pos = pos,
                    animal = World.ANIMAL_TYPES[rtype] == true or World.ANIMAL_TYPES[tname] == true }
            end
        end)
        scan.by_type[tname] = { objects = objects, index = index }
    end
    local objects, index = {}, {}
    for _, t in pairs(scan.by_type) do
        for guid, o in pairs(t.objects) do objects[guid] = o end
        for guid, e in pairs(t.index) do index[guid] = e end
    end
    self.object_index = index
    local loc = self:location()
    return { stage = loc and loc.stage or nil, objects = objects }
end

-- A scanned component is used again only while its GameObject still exists.
function World:object_alive(o)
    if o == nil or o.go == nil then return false end
    if self.game ~= nil and self.game.go_alive ~= nil then return self.game:go_alive(o.go) end
    return true
end

function World:object_apply(guid, event, value)
    local o = self.object_index[guid]
    if o == nil or not self:object_alive(o) then return "missing" end
    local E = P.OBJECT_EVENT
    self:crumb("world.object_apply", o.info and R.type_name(o.comp) or guid, true)
    self.applying = true
    local result = "failed"
    -- Forcing an object's state machine into another state is experimental (exp_force_routine).
    local force_routine = self:setting("exp_force_routine") == true
    if event == E.ROUTINE then
        if force_routine and o.info.field and R.set(o.comp, "_Routine", value) then result = "done" end
    elseif event == E.DESTROYED then
        -- 0) An animal dies the way a shot kills it: its state machine enters Die.
        if o.animal and self:animal_kill_entry(guid, o) then
            result = "done"
        end
        -- 1) The same terminal state the partner's copy reached (plays its own break/death).
        if result ~= "done" and force_routine and value ~= nil and value >= 0 and o.info.field
            and R.set(o.comp, "_Routine", value) then
            result = "done"
        end
        -- 2) A break / kill method of the object.
        if result ~= "done" then
            local tname = R.type_name(o.comp)
            for _, mname in ipairs(KILL_METHODS) do
                local info = tname and self.r:find_method(tname, function(i) return i.name == mname and #i.params == 0 end, nil, 3)
                if info ~= nil and pcall(info.method.call, info.method, o.comp) then
                    result = "done"
                    break
                end
            end
        end
        -- 3) Last resort: hide it.
        if result ~= "done" and o.go ~= nil then
            local ok1 = pcall(function() o.go:call("set_DrawSelf", false) end)
            local ok2 = pcall(function() o.go:call("set_UpdateSelf", false) end)
            if ok1 or ok2 then result = "done" end
        end
    end
    self.applying = false
    return result
end

-------------------------------------------------------------------------------
-- Animals (crows, chickens, fish, bats, rats): the host's game moves them; the client's
-- copies of the ones near both players follow (animal_sync.lua). Facts from re4.exe
-- (docs/RESEARCH.md 3.9): an animal's AI is GmBase.updateGimmick, called by its GimmickCore's
-- move update, which GimmickManager runs for every core registered with registerMove (the
-- core switches itself off once registered). GimmickCore.finish - the gimmick ending - is
-- the only caller of unregisterMove and clears the core's _HasRegisteredMove. A shot calls
-- the animal's onHitDamage, which sets its routine to Die there and then (set_Routine), so
-- hits still land on an animal whose AI is off the update.
-------------------------------------------------------------------------------

local ANIMAL_PREFILTER = 40.0 -- metres: positions from the scan can be a few seconds old

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- A scanned animal that still exists, or nil.
function World:animal(guid)
    local o = self.object_index[guid]
    if o == nil or not o.animal then return nil end
    if o.tf == nil then
        -- Never ask a destroyed GameObject for its transform (the game throws; see Game:go_alive).
        if self.game ~= nil and self.game.go_alive ~= nil and not self.game:go_alive(o.go) then return nil end
        o.tf = R.call(o.go, "get_Transform") or false
    end
    if not o.tf then return nil end
    if self.game ~= nil and self.game.alive ~= nil and not self.game:alive(o.tf) then return nil end
    return o
end

local function animal_routine(o)
    local routine = o.info.field and R.number(R.get(o.comp, "_Routine")) or nil
    local rname = routine and o.info.enum and o.info.enum.values[routine] or nil
    return routine, is_terminal(rname)
end

-- Layer 0 of the animal's via.motion.Motion (GmAnimal._Motion).
function World:animal_layer(o)
    if o.layer == nil then
        local motion = R.get(o.comp, "_Motion") or R.call(o.comp, "get_Motion")
        o.layer = (motion and R.call(motion, "getLayer", 0)) or false
    end
    return o.layer or nil
end

-- Position, rotation, routine and animation of a scanned animal, read now.
function World:animal_read(guid, o)
    local p = R.call(o.tf, "get_Position")
    if p == nil then return nil end
    o.pos = { x = p.x, y = p.y, z = p.z }
    local q = R.call(o.tf, "get_Rotation")
    local routine, dead = animal_routine(o)
    local a = { guid = guid, pos = o.pos, rot = q and { x = q.x, y = q.y, z = q.z, w = q.w } or nil,
        routine = routine, dead = dead }
    local layer = self:animal_layer(o)
    if layer ~= nil then
        local bank, mid = R.number(R.call(layer, "get_MotionBankID")), R.number(R.call(layer, "get_MotionID"))
        if bank ~= nil and mid ~= nil then
            a.motion = { bank = bank, id = mid, frame = R.number(R.call(layer, "get_Frame")) or 0 }
        end
    end
    return a
end

-- Host: the animals within `radius` of every point in `points` (both players), nearest to
-- the first point first, at most `max`, read now.
function World:animals_near(points, radius, max)
    if #points == 0 then return {} end
    local cands = {}
    for guid, o in pairs(self.object_index) do
        if o.animal and o.pos ~= nil then
            local far = false
            for _, p in ipairs(points) do
                if dist3(o.pos, p) > radius + ANIMAL_PREFILTER then far = true break end
            end
            if not far then cands[#cands + 1] = { guid = guid, d = dist3(o.pos, points[1]) } end
        end
    end
    table.sort(cands, function(a, b) return a.d < b.d end)
    local out = {}
    for _, c in ipairs(cands) do
        if #out >= max then break end
        local o = self:animal(c.guid)
        local a = o and self:animal_read(c.guid, o) or nil
        if a ~= nil then
            local near = true
            for _, p in ipairs(points) do
                if dist3(a.pos, p) > radius then near = false break end
            end
            if near then out[#out + 1] = a end
        end
    end
    return out
end

-- Client: our copy of an animal - { pos, routine, dead } - or nil when it is not loaded.
function World:animal_local(guid)
    local o = self:animal(guid)
    if o == nil then return nil end
    local routine, dead = animal_routine(o)
    return { pos = o.pos, routine = routine, dead = dead }
end

local function gimmick_core(o)
    if o.core == nil then o.core = R.call(o.comp, "get_Core") or false end
    return o.core or nil
end

-- Client: our copy of an animal stops running its own AI (on = true: it becomes a puppet of
-- the host's) or runs it again (on = false). Returns true when it is (no longer) a puppet.
function World:animal_puppet(guid, on)
    if not on then
        local f = self.animal_frozen[guid]
        if f ~= nil then
            self.animal_frozen[guid] = nil
            self:animal_thaw(f)
        end
        return true
    end
    if self.animal_frozen[guid] ~= nil then return true end
    local o = self:animal(guid)
    local core = o and gimmick_core(o)
    if core == nil then return false end
    local how
    if R.get(core, "_HasRegisteredMove") == true then
        local mgr = self.r:singleton(GIM)
        local m = self.move_unreg_m
        if mgr == nil or m == nil or not pcall(m.method.call, m.method, mgr, core) then
            self:cap("animal_puppets", false, "unregisterMove failed")
            return false
        end
        how = "move"
    elseif R.call(core, "get_Enabled") == true then
        if not pcall(core.call, core, "set_Enabled", false) then return false end
        how = "core" -- a core that updates itself (no central update)
    else
        how = "none" -- nothing runs its state machine right now
    end
    self:crumb("world.animal", "puppet")
    self.animal_frozen[guid] = { core = core, go = o.go, tf = o.tf, how = how }
    return true
end

-- Gives an animal's state machine back to the game, unless the animal is gone or the game
-- finished its gimmick meanwhile (it must never come back onto the update list then).
function World:animal_thaw(f)
    if self.game ~= nil and self.game.alive ~= nil and not self.game:alive(f.tf) then return end
    self:crumb("world.animal", "release")
    if f.how == "move" then
        if R.get(f.core, "_HasRegisteredMove") == true then
            local mgr = self.r:singleton(GIM)
            local m = self.move_reg_m
            if mgr ~= nil and m ~= nil then pcall(m.method.call, m.method, mgr, f.core) end
        end
    elseif f.how == "core" then
        pcall(f.core.call, f.core, "set_Enabled", true)
    end
end

-- Every animal we took off the update runs on its own again (session ended, reload).
function World:restore_animals()
    for _, f in pairs(self.animal_frozen or {}) do self:animal_thaw(f) end
    self.animal_frozen = {}
end

-- Client: a puppet animal takes the host animal's position and rotation.
function World:animal_set_transform(guid, pos, rot)
    local o = self:animal(guid)
    if o == nil then return false end
    local ok = pcall(o.tf.call, o.tf, "set_Position", Vector3f.new(pos.x, pos.y, pos.z))
    if ok and rot ~= nil then
        ok = pcall(o.tf.call, o.tf, "set_Rotation", Quaternion.new(rot.w, rot.x, rot.y, rot.z))
    end
    if ok then o.pos = { x = pos.x, y = pos.y, z = pos.z } end
    return ok
end

-- Client: a puppet animal plays the host animal's animation (TreeLayer.changeMotion, as for
-- enemies).
function World:animal_set_motion(guid, motion)
    local o = self:animal(guid)
    local layer = o and self:animal_layer(o)
    if layer == nil then return false end
    return (pcall(function()
        layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
            motion.bank, motion.id, motion.frame or 0.0, 8.0, 2, 0)
    end))
end

-- The animal dies with its own logic: the routine a shot gives it (set_Routine(Die)), after
-- its AI is back on the update. True if it is dead (or dying) now.
function World:animal_kill_entry(guid, o)
    local routine, dead = animal_routine(o)
    if dead then return true end
    local die = o.info.enum and o.info.enum.names.Die
    if die == nil then return false end
    self:animal_puppet(guid, false)
    local tname = R.type_name(o.comp) or o.kind
    local m = tname and self.r:find_method(tname, function(i) return i.name == "set_Routine" and #i.params == 1 end, nil, 1)
    self:crumb("world.animal", "kill")
    if m ~= nil and pcall(m.method.call, m.method, o.comp, die) then return true end
    return routine ~= nil and R.set(o.comp, "_Routine", die) and R.number(R.get(o.comp, "_Routine")) == die
end

function World:animal_kill(guid)
    local o = self:animal(guid)
    return o ~= nil and self:animal_kill_entry(guid, o)
end

-------------------------------------------------------------------------------
-- Cutscenes
-------------------------------------------------------------------------------

-- RE4 plays every "play once" camera request - story cutscenes (timeline events) and movies -
-- through ClapperboardMediator.calcRequest, which strips the requester's callbacks and packs
-- the request into a PayloadPlay, complete data made to be sent to another game: camera type
-- and ID, screen, start and end flags (ScenarioFlagManager.FlagInfo group/index pairs), the
-- data owner (ContextID code of the level object whose scripted sequence continues when it
-- ends), that next step (EndPortrayal) and, for movies, where to put the players
-- (PlayerCoordSetting.Pack). procPayloadPlay plays it and records it as seen (checkHasDone).

function World:cutscene_playing()
    local gui = self.r:singleton(GUI_MANAGER)
    if gui == nil or R.call(gui, "get_IsPlayingEvent") ~= true then return nil end
    return true
end

-- Whether this save already played that camera (ClapperboardMediator.checkHasDone).
function World:cutscene_done(camera, id)
    local m, mgr = self.cs_done_m, self.r:singleton(CLAP)
    if m == nil or mgr == nil then return nil end
    local ok, v = pcall(m.method.call, m.method, mgr, camera or P.CAMERA.TIMELINE, id)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- Elements of a value-type array: the array object keeps its count at 0x1C and its elements
-- inline from 0x20 (what the game's own code reads).
local ARRAY_DATA = 0x20
local FLAG_INFO_SIZE = 8     -- FlagInfo { Int32 GroupIndex, Int32 Index }
local COORD_PACK_SIZE = 0x30 -- PlayerCoordSetting.Pack { PlKind, _, Position @0x10, RotationY @0x20, flags @0x24.. }

local function i32(v)
    v = math.floor(tonumber(v) or 0) & 0xFFFFFFFF
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

local function read_flag_infos(arr)
    local out = {}
    if arr == nil then return out end
    local n = math.min(R.count(arr), P.MAX_CUTSCENE_FLAGS)
    for i = 0, n - 1 do
        local okg, g = pcall(arr.read_dword, arr, ARRAY_DATA + i * FLAG_INFO_SIZE)
        local oki, idx = pcall(arr.read_dword, arr, ARRAY_DATA + i * FLAG_INFO_SIZE + 4)
        if okg and oki and g ~= nil and idx ~= nil then
            out[#out + 1] = { group = i32(g), index = i32(idx) }
        end
    end
    return out
end

local function read_coord_packs(arr)
    local out = {}
    if arr == nil then return out end
    local n = math.min(R.count(arr), P.MAX_CUTSCENE_COORDS)
    for i = 0, n - 1 do
        local base = ARRAY_DATA + i * COORD_PACK_SIZE
        local ok, c = pcall(function()
            return { kind = i32(arr:read_dword(base)),
                pos = { x = arr:read_float(base + 0x10), y = arr:read_float(base + 0x14), z = arr:read_float(base + 0x18) },
                rot_y = arr:read_float(base + 0x20), reset_camera = arr:read_byte(base + 0x24) ~= 0,
                only_npc = arr:read_byte(base + 0x25) ~= 0, only_pc = arr:read_byte(base + 0x26) ~= 0 }
        end)
        if ok and c ~= nil then out[#out + 1] = c end
    end
    return out
end

local function write_flag_infos(list)
    if list == nil or #list == 0 then return nil end
    local arr = R.new_array(FLAG_INFO, #list)
    if arr == nil then return nil end
    for i, f in ipairs(list) do
        local base = ARRAY_DATA + (i - 1) * FLAG_INFO_SIZE
        if not pcall(arr.write_dword, arr, base, (f.group or 0) & 0xFFFFFFFF)
            or not pcall(arr.write_dword, arr, base + 4, (f.index or 0) & 0xFFFFFFFF) then
            return nil
        end
    end
    return arr
end

local function write_coord_packs(list)
    if list == nil or #list == 0 then return nil end
    local arr = R.new_array(COORD_PACK, #list)
    if arr == nil then return nil end
    for i, c in ipairs(list) do
        local base = ARRAY_DATA + (i - 1) * COORD_PACK_SIZE
        local p = c.pos or { x = 0, y = 0, z = 0 }
        local ok = pcall(function()
            arr:write_dword(base, (c.kind or 0) & 0xFFFFFFFF)
            arr:write_float(base + 0x10, p.x)
            arr:write_float(base + 0x14, p.y)
            arr:write_float(base + 0x18, p.z)
            arr:write_float(base + 0x20, c.rot_y or 0)
            arr:write_byte(base + 0x24, c.reset_camera and 1 or 0)
            arr:write_byte(base + 0x25, c.only_npc and 1 or 0)
            arr:write_byte(base + 0x26, c.only_pc and 1 or 0)
        end)
        if not ok then return nil end
    end
    return arr
end

-- The cutscene a PayloadPlay describes, as the CUTSCENE message carries it, or nil.
function World:read_payload(p)
    if p == nil then return nil end
    local camera = R.number(R.get(p, "CameraType"))
    local id = R.number(R.get(p, "ID"))
    if camera == nil or id == nil or (camera ~= P.CAMERA.TIMELINE and camera ~= P.CAMERA.MOVIE) then return nil end
    return {
        camera = camera, id = id, screen = R.number(R.get(p, "Screen")) or 0,
        owner_code = (R.number(R.get(p, "DataOwnerCode")) or 0xFFFFFFFF) & 0xFFFFFFFF,
        end_portrayal = (R.number(R.get(p, "EndPortrayal")) or 0) & 0xFFFFFFFF,
        start_flags = read_flag_infos(R.get(p, "StartFlag")),
        end_flags = read_flag_infos(R.get(p, "EndFlag")),
        coords = camera == P.CAMERA.MOVIE and read_coord_packs(R.get(p, "CoorsSettings")) or {},
    }
end

-- Plays the partner's cutscene here: the same payload through our own procPayloadPlay, the
-- way calcRequest plays a request of our own game.
function World:cutscene_play(ev)
    local mgr = self.r:singleton(CLAP)
    if mgr == nil or self.cs_proc_m == nil then return false, "no ClapperboardMediator" end
    local p = R.new_instance(PAYLOAD_PLAY)
    if p == nil then return false, "cannot create a PayloadPlay" end
    local ok = R.set(p, "CameraType", ev.camera or P.CAMERA.TIMELINE) and R.set(p, "ID", ev.id)
        and R.set(p, "Screen", ev.screen or 0)
        and R.set(p, "DataOwnerCode", (ev.owner_code or 0xFFFFFFFF) & 0xFFFFFFFF)
        and R.set(p, "EndPortrayal", (ev.end_portrayal or 0) & 0xFFFFFFFF)
    if not ok then return false, "cannot fill the PayloadPlay" end
    local start_flags, end_flags = write_flag_infos(ev.start_flags), write_flag_infos(ev.end_flags)
    if (start_flags == nil and #(ev.start_flags or {}) > 0) or (end_flags == nil and #(ev.end_flags or {}) > 0) then
        return false, "cannot build the flag lists"
    end
    if start_flags ~= nil then R.set(p, "StartFlag", start_flags) end
    if end_flags ~= nil then R.set(p, "EndFlag", end_flags) end
    if ev.camera == P.CAMERA.MOVIE then
        local coords = write_coord_packs(ev.coords)
        if coords ~= nil then R.set(p, "CoorsSettings", coords) end
    end
    local play_id = 0
    if self.cs_emit_m ~= nil then
        local okid, v = pcall(self.cs_emit_m.method.call, self.cs_emit_m.method, mgr)
        play_id = okid and R.number(v) or 0
    end
    self:crumb("world.cutscene_play", ("%d:%d"):format(ev.camera or 1, ev.id or 0), true)
    self.applying_cutscene = true
    local played = pcall(self.cs_proc_m.method.call, self.cs_proc_m.method, mgr, play_id, p)
    self.applying_cutscene = false
    if not played then return false, "procPayloadPlay failed" end
    return true
end

-- The cameras playing in our game (ClapperboardMediator._Plays, one PlayWork per screen).
function World:play_works()
    local out = {}
    if not self.cs_skip_ok then return out end
    local mgr = self.r:singleton(CLAP)
    R.each(mgr and R.get(mgr, "_Plays"), function(w)
        if w ~= nil then
            local camera, id = R.number(R.get(w, "CamType")), R.number(R.call(w, "get_CameraID"))
            if camera ~= nil and id ~= nil then out[#out + 1] = { work = w, camera = camera, id = id } end
        end
    end)
    return out
end

local function address_of(obj)
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or tostring(obj)
end

-- Reports the cameras our player skipped (DoneSkip turned on), once each.
function World:report_skips()
    local cb = self.callbacks.on_cutscene_skip
    if cb == nil or not self.active or not self.cs_skip_ok then return end
    local live = {}
    for _, p in ipairs(self:play_works()) do
        local a = address_of(p.work)
        live[a] = true
        if R.get(p.work, "DoneSkip") == true and not self.skips_seen[a] then
            self.skips_seen[a] = true
            if not (self.skips_applied or {})[a] then
                self.counters.skip_events = self.counters.skip_events + 1
                pcall(cb, { camera = p.camera, id = p.id })
            end
        end
    end
    for a in pairs(self.skips_seen) do
        if not live[a] then self.skips_seen[a] = nil end
    end
    for a in pairs(self.skips_applied or {}) do
        if not live[a] then self.skips_applied[a] = nil end
    end
end

-- Skips that camera here the way our skip button does: InputSkip on its PlayWork; the game
-- skips it if it can be skipped. "skipped" | "missing" (not playing here).
function World:cutscene_skip(camera, id)
    for _, p in ipairs(self:play_works()) do
        if p.camera == camera and p.id == id and R.get(p.work, "DoneSkip") ~= true then
            self:crumb("world.cutscene_skip", ("%d:%d"):format(camera, id))
            if not R.set(p.work, "InputSkip", true) then return "failed" end
            self.skips_applied = self.skips_applied or {}
            self.skips_applied[address_of(p.work)] = true
            return "skipped"
        end
    end
    return "missing"
end

-------------------------------------------------------------------------------
-- Traps (docs/RESEARCH.md 3.18)
--   chainsaw.GmLegHoldTrap (bear trap), _Routine: Wait 0, Bite 1, Close 2, Closed 3, Hide 4,
--     NpcBite 5, Rescue 6, OpenByEm 7. Its gimmick flag (GmBase.setGmFlag, attribute 0 of its
--     GimmickContext) is "closed": initializeGimmick starts a flagged trap Closed. onHitDamage
--     (shot while open) writes Close with _Rno 0; Close plays the snap, its sound and sets the
--     flag, then becomes Closed. requestSetClosed() goes straight to Closed and sets the flag;
--     requestOpenByEm() (a villager re-arming it) clears the flag and opens it.
--   chainsaw.GmSensorBomb (laser trip bomb), _Routine: Wait 0, Bomb 1, ReleaseReady 2,
--     Release 3, Done 4, Hide 5. Wait watches its gimmick flag: once set (shot: onHitDamage,
--     or the laser crossed) it goes to Bomb (explosion, attack, sound) and Done; a bomb loaded
--     flagged starts Done.
-------------------------------------------------------------------------------

local TRAP_SCAN_INTERVAL = 2.0
World.TRAP_KINDS = { ["chainsaw.GmLegHoldTrap"] = 1, ["chainsaw.GmSensorBomb"] = 2 } -- P.TRAP_KIND
local LEG_HOLD_STATE = { [0] = "open", [7] = "open", [1] = "closed", [2] = "closed", [3] = "closed",
    [5] = "closed", [6] = "closed", [4] = "hidden" }
local SENSOR_STATE = { [0] = "armed", [2] = "armed", [3] = "armed", [1] = "gone", [4] = "gone", [5] = "hidden" }
local LEG_HOLD_CLOSE, LEG_HOLD_CLOSED = 2, 3
local SENSOR_WAIT, SENSOR_DONE = 0, 4

-- The traps of the loaded areas, by GameObject GUID (scene data: the same on both PCs).
function World:traps_refresh(now)
    if self.traps_at ~= nil and now - self.traps_at < TRAP_SCAN_INTERVAL then return end
    self.traps_at = now
    local scene = self:scene()
    if scene == nil then return end
    local traps = {}
    for tname, kind in pairs(World.TRAP_KINDS) do
        local t = self.r:typeof(tname)
        if t ~= nil then
            R.each(R.call(scene, "findComponents(System.Type)", t) or R.call(scene, "findComponents", t), function(comp)
                local go = R.call(comp, "get_GameObject")
                local guid = go and R.game_object_guid(go)
                if guid ~= nil and traps[guid] == nil then
                    local old = self.traps and self.traps[guid]
                    traps[guid] = { comp = comp, go = go, kind = kind, pos = old and old.pos or position_of(go) }
                end
            end)
        end
    end
    self.traps = traps
end

function World:trap_state(t)
    local routine = R.number(R.get(t.comp, "_Routine"))
    if routine == nil then return nil end
    local states = t.kind == 2 and SENSOR_STATE or LEG_HOLD_STATE
    return states[routine], routine
end

local function trap_list(self, filter)
    local out = {}
    for guid, t in pairs(self.traps or {}) do
        if filter == nil or filter(t) then
            local state = self:trap_state(t)
            if state ~= nil then out[guid] = { kind = t.kind, state = state } end
        end
    end
    return out
end

-- The traps within `radius` of `pos`: { [guid] = {kind, state} }.
function World:traps_near(pos, radius)
    if pos == nil then return nil end
    self:traps_refresh(self:now())
    return trap_list(self, function(t) return t.pos ~= nil and dist3(t.pos, pos) <= radius end)
end

-- Every trap loaded: { [guid] = {kind, state} }.
function World:traps_all()
    self:traps_refresh(self:now())
    return trap_list(self)
end

-- The partner's trap event on our trap, through the trap's own mechanisms.
-- event: 1 fired (play it), 2 re-armed, 3 spent (set without playing it). "done" | "skip" | "missing"
function World:trap_apply(guid, kind, event)
    self:traps_refresh(self:now())
    local t = self.traps and self.traps[guid]
    if t == nil or (self.game and self.game.go_alive and not self.game:go_alive(t.go)) then return "missing" end
    local state, routine = self:trap_state(t)
    if state == nil then return "missing" end
    if state == "hidden" then return "skip" end
    self:crumb("world.trap_apply", ("%d/%d"):format(kind or 0, event or 0), true)
    self.applying = true
    local ok = false
    if t.kind == 1 then
        if event == 2 then
            if routine == LEG_HOLD_CLOSED then ok = pcall(function() t.comp:call("requestOpenByEm") end) end
        elseif state == "open" then
            if event == 1 then
                -- What a shot does (onHitDamage): Close from its first step - the snap, its sound,
                -- the "closed" flag - then Closed.
                ok = R.set(t.comp, "_Rno", 0) and R.set(t.comp, "_Routine", LEG_HOLD_CLOSE)
            else
                ok = pcall(function() t.comp:call("requestSetClosed") end)
            end
        end
    elseif t.kind == 2 and routine == SENSOR_WAIT then
        if event == 3 then
            -- Gone without going off: Done (its laser and model put away), flagged for the save.
            ok = R.set(t.comp, "_Rno", 0) and R.set(t.comp, "_Routine", SENSOR_DONE)
        else
            ok = true
        end
        -- The flag: a waiting bomb goes off on its next update (Wait -> Bomb), like when shot.
        if ok then ok = pcall(function() t.comp:call("setGmFlag", true, nil, nil) end) end
    end
    self.applying = false
    if not ok then return "skip" end
    self.counters.traps_applied = (self.counters.traps_applied or 0) + 1
    return "done"
end

-------------------------------------------------------------------------------
-- Doors
-------------------------------------------------------------------------------

local DOOR_SCAN_INTERVAL = 2.0
local DOOR_OPEN_BIT = 1   -- chainsaw.GmDoor.Attr0Bit.Open
local DOOR_HOST, DOOR_GUEST = 0, 1 -- chainsaw.GmDoor.NeedOpenSelfIndex
local AUTO_OPEN = 1       -- chainsaw.GmAutoDoorBase.RoutineType.Open
local BIG_OPEN = 2        -- chainsaw.GmBigDoor.RoutineType: Open = 2, Opened = 3, ForceOpened = 4

-- The kinds of doors that close by themselves once nobody is near, and how each is held open:
--   door: GmDoor and its kick-open variant - the Guest slot of _NeedKeepOpenSelf (recvGmParam);
--   auto: automatic, elevator and timing-shutter doors (GmAutoDoorBase) - open while _OpenTimer
--         runs, which their sensor reloads by setting _ActivateOpen (calcRoutine);
--   big:  big double doors (GmBigDoor) - open while IsAnyOneCloseToDoor > 0.
World.DOOR_KINDS = {
    ["chainsaw.GmDoor"] = "door", ["chainsaw.GmKickOpenDoor"] = "door",
    ["chainsaw.GmAutoDoor"] = "auto", ["chainsaw.GmAutoDoorMotion"] = "auto", ["chainsaw.GmElevatorDoor"] = "auto",
    ["chainsaw.GmTimingShutter"] = "auto", ["chainsaw.GmBigDoor"] = "big",
}

local function first_bool(arr)
    local v
    R.each(arr, function(x)
        v = x
        return true
    end)
    return v == true or R.number(v) == 1
end

-- The doors of the loaded areas, by GameObject GUID (scene data: the same on both PCs).
function World:doors_refresh(now)
    if not self.door_ok or (self.doors_at ~= nil and now - self.doors_at < DOOR_SCAN_INTERVAL) then return end
    self.doors_at = now
    local scene = self:scene()
    if scene == nil then return end
    local doors = {}
    for tname in pairs(World.DOOR_KINDS) do
        local t = self.r:typeof(tname)
        if t ~= nil then
            R.each(R.call(scene, "findComponents(System.Type)", t) or R.call(scene, "findComponents", t), function(comp)
                local go = R.call(comp, "get_GameObject")
                local guid = go and R.game_object_guid(go)
                if guid ~= nil and doors[guid] == nil then
                    local old = self.doors[guid]
                    local kind = World.DOOR_KINDS[R.type_name(comp) or ""] or World.DOOR_KINDS[tname]
                    doors[guid] = { comp = comp, go = go, kind = kind, pos = old and old.pos or position_of(go) }
                end
            end)
        end
    end
    self.doors = doors
end

function World:door_context(d)
    return R.call(d.comp, "get_GmkContext") or R.call(d.comp, "get_Context")
end

-- One door as our game has it: {open, hold, attr} (hold: our player keeps it open - never
-- what we do for the partner, or the two games would keep each other's doors open forever).
function World:door_state(guid, d)
    if d.kind == "auto" then
        local rno = R.number(R.get(d.comp, "_Rno0"))
        if rno == nil then return nil end
        local timer = R.number(R.get(d.comp, "_OpenTimer")) or 0
        return { open = rno == AUTO_OPEN, hold = timer > 0 and not self.auto_hold[guid], attr = 0 }
    elseif d.kind == "big" then
        local routine = R.number(R.get(d.comp, "_Routine"))
        if routine == nil then return nil end
        local near = (R.number(R.get(d.comp, "IsAnyOneCloseToDoor")) or 0) - (self.big_added[guid] and 1 or 0)
        return { open = routine >= BIG_OPEN, hold = near > 0, attr = 0 }
    end
    local routine = R.number(R.get(d.comp, "_Routine"))
    if routine == nil then return nil end
    local ctx = self:door_context(d)
    local attr = ctx and R.number(R.call(ctx, "getAttr(System.Int32)", 0)) or 0
    return { open = routine == 1, hold = first_bool(R.get(d.comp, "_NeedKeepOpenSelf")), attr = (attr or 0) & 0xFF }
end

-- How the doors within `radius` of `pos` are here: { [guid] = {open, hold, attr} } (open: it is
-- open or opening; hold: our player keeps it open; attr: a GmDoor's first attribute byte).
function World:doors_near(pos, radius)
    if not self.door_ok or pos == nil then return nil end
    self:doors_refresh(self:now())
    local out = {}
    for guid, d in pairs(self.doors) do
        if d.pos ~= nil and dist3(d.pos, pos) <= radius then
            out[guid] = self:door_state(guid, d)
        end
    end
    return out
end

-- The partner's door here: opened now if theirs opened, and held open while they hold
-- theirs - each kind through its own mechanism. "done" | "missing"
function World:door_apply(guid, st)
    local d = self.doors[guid]
    if d == nil or (self.game and self.game.go_alive and not self.game:go_alive(d.go)) then return "missing" end
    local hold = st.hold and true or false
    if d.kind == "auto" then
        self.auto_hold[guid] = hold or nil
        if hold or st.open then R.set(d.comp, "_ActivateOpen", true) end -- as its sensor does
        return "done"
    elseif d.kind == "big" then
        if hold ~= (self.big_added[guid] == true) then
            local n = R.number(R.get(d.comp, "IsAnyOneCloseToDoor")) or 0
            R.set(d.comp, "IsAnyOneCloseToDoor", hold and n + 1 or math.max(0, n - 1))
            self.big_added[guid] = hold or nil
        end
        return "done"
    end
    if hold or self.door_guest[guid] then
        pcall(d.comp.call, d.comp, "recvGmParam", DOOR_GUEST, hold and 1 or 0, nil)
        self.door_guest[guid] = hold or nil
    end
    if st.open then
        local ctx = self:door_context(d)
        local attr = ctx and R.number(R.call(ctx, "getAttr(System.Int32)", 0)) or nil
        if ctx ~= nil and attr ~= nil and (attr & DOOR_OPEN_BIT) == 0 and R.number(R.get(d.comp, "_Routine")) ~= 1 then
            self:crumb("world.door_open", guid)
            pcall(ctx.call, ctx, "pushAttr(System.Int32, System.Byte)", 0, ((st.attr or 0) | DOOR_OPEN_BIT) & 0xFF)
        end
    end
    return "done"
end

-- Automatic doors the partner stands in: their sensor flag, every frame (it is consumed each
-- time the door decides).
function World:refresh_auto_holds()
    for guid in pairs(self.auto_hold) do
        local d = self.doors[guid]
        if d == nil then
            self.auto_hold[guid] = nil
        else
            R.set(d.comp, "_ActivateOpen", true)
        end
    end
end

-- The partner left: nothing of theirs keeps our doors open any more.
function World:doors_release()
    for guid in pairs(self.door_guest) do
        local d = self.doors[guid]
        if d ~= nil then pcall(d.comp.call, d.comp, "recvGmParam", DOOR_GUEST, 0, nil) end
    end
    for guid in pairs(self.big_added) do
        local d = self.doors[guid]
        if d ~= nil then
            R.set(d.comp, "IsAnyOneCloseToDoor", math.max(0, (R.number(R.get(d.comp, "IsAnyOneCloseToDoor")) or 0) - 1))
        end
    end
    self.door_guest, self.auto_hold, self.big_added = {}, {}, {}
end

-------------------------------------------------------------------------------
-- Level triggers (docs/RESEARCH.md 3.11): an InteractHolder on a level GameObject holds its
-- InteractTriggers; the gimmicks and option settings on that GameObject register what a
-- trigger does (InteractHolder.initParamObjects). InteractManager marks a play-once trigger
-- done (Done |= 1, saved with its gimmick) and runs it through executeTrigger(target,
-- userdata). The same trigger exists in the partner's game: the GameObject's GUID comes from
-- the scene file and InteractHolder.findTrigger takes the hash of the trigger's name.
-------------------------------------------------------------------------------

local SUCCEED_ONCE = 1

-- What the components of a trigger's GameObject make of it: an event (see EVENT_COMPONENTS),
-- or not (and why). Cached by GUID.
function World:trigger_owner_kind(owner, guid)
    local info = self.trigger_owner_info[guid]
    if info ~= nil then return info end
    local event, why = false, "no event component"
    R.each(R.call(owner, "get_Components"), function(c)
        local tn = R.type_name(c) or ""
        if World.EVENT_COMPONENTS[tn] then
            event = true
        elseif World.DENY_COMPONENTS[tn] or tn:find("^chainsaw%.Gm") or tn:find("^chainsaw%.Custom") then
            why = tn
            event = false
            return true -- one is enough to rule it out
        end
    end)
    info = { event = event and why == "no event component", why = event and "" or why }
    if not info.event and info.why == "" then info.why = "no event component" end
    -- Whatever the portrayals on it call must pass the same test.
    if info.event then
        local bad = self:portrayal_callee_denied(owner)
        if bad ~= nil then info = { event = false, why = bad } end
    end
    self.trigger_owner_info[guid] = info
    return info
end

-- The first deny-listed parameter a PortrayalSettings on this GameObject would run, or nil.
function World:portrayal_callee_denied(owner)
    local port = self.game and self.game.get_component and self.game:get_component(owner, "chainsaw.PortrayalSettings") or nil
    if port == nil then return nil end
    local bad
    R.each(R.get(R.get(port, "_Params"), "_Params"), function(param)
        for _, list in ipairs({ "_CalleePlay", "_CalleeEnd" }) do
            R.each(R.get(param, list), function(callee)
                local tn = (R.type_name(callee) or ""):gsub("%.Param$", "")
                if World.DENY_COMPONENTS[tn] and not self.muted_types[tn] then
                    bad = tn
                    return true
                end
            end)
            if bad then return true end
        end
    end)
    return bad
end

-------------------------------------------------------------------------------
-- Mechanisms (docs/RESEARCH.md 3.19): levers, big doors and their locks, valves and cranks,
-- shelves, gates, bridges, lifts... A gimmick's scripted sequence - the object moving, the
-- in-game camera shot, the sounds, the flags - is a portrayal: PortrayalSettings.call(key,
-- trigger, args) on the gimmick. The game calls them with no trigger itself (GmLever.onUsed,
-- setUsed), and initializeGimmick puts them in their finished state (makeFinish) when the
-- gimmick loads already used. A pushed cart or shelf (GmPushMove) moves through its own
-- motion (MotWait -> MotMove -> MotMoved) and its gimmick flag.
-------------------------------------------------------------------------------

World.MECH_KIND = { PORTRAYAL = 1, PUSH = 2 }

-- Gimmicks whose sequences never cross: another sync handles them (doors, traps, breakables,
-- animals), or they are the player's own action (ladders, windows, jumps, item boxes, the
-- workbench, saving, mounted guns and vehicles).
World.MECH_DENY = {}
for _, n in ipairs({ "GmDoor", "GmKickOpenDoor", "GmAutoDoor", "GmAutoDoorMotion", "GmElevatorDoor",
    "GmTimingShutter", "GmLegHoldTrap", "GmSensorBomb", "GmPortrayalAreaHit", "GmLadderBase", "GmLeaningLadder",
    "GmUprightLadder", "GmFoldableLadder", "GmWindow", "GmWindowBoard", "GmCh1d2z0HedgeJump", "GmCoopJump2",
    "GmCoopMoveUp", "GmPlayerMoveMotion", "GmItemBox", "GmWorkbench", "GmWeaponUpgrade", "GmSofa", "GmMultiUse",
    "GmMedalLocker", "GmSavePoint", "GmSaveLoadWoodBox", "GmInstalledMachineGun", "GmAntiAircraftGun",
    "GmCannon", "GmCannonV2", "GmTurretShooterHandle", "GmBoat", "GmJetSki", "GmHookShot", "GmCatapult" }) do
    World.MECH_DENY["chainsaw." .. n] = true
end
for _, n in ipairs(World.OBJECT_TYPES) do World.MECH_DENY[n] = true end

local GM_BASE = "chainsaw.GmBase"

-- The gimmick on `go` (or its parent): component, type name.
function World:gimmick_on(go)
    local found, name
    for _ = 1, 2 do
        if go == nil then break end
        R.each(R.call(go, "get_Components"), function(c)
            local ok, isa = pcall(function() return c:get_type_definition():is_a(GM_BASE) end)
            if ok and isa then
                found, name = c, R.type_name(c)
                return true
            end
        end)
        if found ~= nil then break end
        local tf = R.call(go, "get_Transform")
        local parent = tf and R.call(tf, "get_Parent")
        go = parent and R.call(parent, "get_GameObject")
    end
    return found, name
end

-- Whether a portrayal on GameObject `go` (GUID `guid`) may play in the partner's game:
-- {ok, why} - it belongs to a gimmick, not a denied one, and runs nothing denied.
function World:mechanism_owner(go, guid)
    local info = self.mech_owner_info[guid]
    if info ~= nil then return info end
    local _, gname = self:gimmick_on(go)
    if gname == nil then
        info = { ok = false, why = "no gimmick" }
    elseif World.MECH_DENY[gname] then
        info = { ok = false, why = gname }
    else
        local bad = self:portrayal_callee_denied(go)
        info = bad and { ok = false, why = bad } or { ok = true, gimmick = gname }
    end
    self.mech_owner_info[guid] = info
    return info
end

-- The mechanisms our game started since the last call: { {guid, kind, key, gimmick}, ... }.
function World:take_mechanism_events()
    if #self.mech_events == 0 then return nil end
    local events = self.mech_events
    self.mech_events = {}
    local out = {}
    for _, e in ipairs(events) do
        local go = R.call(e.comp, "get_GameObject")
        local guid = go and R.game_object_guid(go)
        if guid ~= nil then
            if e.kind == World.MECH_KIND.PUSH then
                out[#out + 1] = { guid = guid, kind = e.kind, key = 0, gimmick = PUSH_MOVE }
            else
                local info = self:mechanism_owner(go, guid)
                if info.ok then
                    out[#out + 1] = { guid = guid, kind = e.kind, key = e.key, gimmick = info.gimmick }
                else
                    self.counters.mech_not_shared = (self.counters.mech_not_shared or 0) + 1
                    self.last_mech_not_shared = info.why
                end
            end
        end
    end
    return out
end

-- The partner's mechanism here, through the gimmick's own code. "done" | "skip" | "missing"
function World:mechanism_apply(ev)
    local scene = self:scene()
    local g = self.r:guid_value(ev.guid)
    if scene == nil or g == nil then return "missing" end
    local go = R.call(scene, "findGameObject(System.Guid)", g)
    if go == nil or (self.game and self.game.go_alive and not self.game:go_alive(go)) then return "missing" end
    local now = self:now()
    for k, t in pairs(self.mech_remote) do
        if now - t > MECH_ECHO then self.mech_remote[k] = nil end
    end
    local ok = false
    if ev.kind == World.MECH_KIND.PUSH then
        local push = self.game and self.game:get_component(go, PUSH_MOVE)
        if push == nil then return "missing" end
        if R.call(push, "getGmFlag") == true then return "skip" end -- already moved here
        self:crumb("world.mech_push", ev.guid, true)
        self.applying_mech = true
        -- What onAcceptExecute does once the player's push is accepted, without the player:
        -- the move motion, the AI map's blocker moved along, the "moved" flag.
        ok = pcall(function()
            local td = push:get_type_definition()
            local mot = td:get_field("MotMove"):get_data(nil)
            push:call("setGmMotion", mot)
            local move = push:get_field("_Move")
            if move ~= nil then push:call("moveEffectorShape", move) end
            push:call("setGmFlag", true, nil, nil)
        end)
        self.applying_mech = false
    else
        local info = self:mechanism_owner(go, ev.guid)
        if not info.ok then return "skip" end
        local port = self.game and self.game:get_component(go, PORTRAYAL)
        if port == nil then return "missing" end
        local played = self.mech_remote[ev.guid .. ":" .. ev.key]
        if played ~= nil and now - played < MECH_ECHO then
            return "skip" -- played here already (the gimmick's own reaction to the partner's change)
        end
        self:crumb("world.mech_portrayal", ("%s:%d"):format(ev.guid, ev.key or 0), true)
        self.mech_remote[ev.guid .. ":" .. ev.key] = now
        self:mark_replayed(go)
        self.applying_mech = true
        ok = self:muted(function()
            port:call("call(System.UInt32, chainsaw.InteractTrigger, chainsaw.InteractActionArgs)", ev.key, nil, nil)
        end)
        self.applying_mech = false
    end
    if not ok then return "skip" end
    self.counters.mech_applied = (self.counters.mech_applied or 0) + 1
    return "done"
end

-- Reports the event triggers our player set off since the last frame (queued by the hook).
function World:report_triggers()
    if #self.trigger_events == 0 then return end
    local events = self.trigger_events
    self.trigger_events = {}
    local cb = self.callbacks.on_trigger
    if cb == nil then return end
    for _, e in ipairs(events) do
        local trig = e.trig
        local owner = R.call(trig, "get_Owner")
        local guid = R.game_object_guid(owner)
        if guid ~= nil then
            local kind = self:trigger_owner_kind(owner, guid)
            if kind.event then
                self.counters.trigger_events = self.counters.trigger_events + 1
                pcall(cb, { guid = guid, hash = R.number(R.call(trig, "get_Hash")), trigger_type = TRIGGER_AREA_HIT,
                    once = R.number(R.get(trig, "Succeed")) == SUCCEED_ONCE, head = e.head })
            else
                self.counters.trigger_not_event = self.counters.trigger_not_event + 1
                self.last_not_event = kind.why
            end
        end
    end
end

-- Our copy of a trigger: the InteractTrigger with that name hash on the GameObject with that
-- GUID, or nil and why.
function World:trigger_find(guid, hash)
    local scene = self:scene()
    local g = self.r:guid_value(guid)
    if scene == nil or g == nil then return nil, "missing" end
    local go = R.call(scene, "findGameObject(System.Guid)", g)
    if go == nil or (self.game and self.game.go_alive and not self.game:go_alive(go)) then return nil, "missing" end
    local holder = self.game and self.game.get_component and self.game:get_component(go, HOLDER) or nil
    if holder == nil then return nil, "missing" end
    local trig = R.call(holder, "findTrigger(System.UInt32)", hash)
    if trig == nil then return nil, "missing" end
    return trig
end

local function trigger_done(trig)
    return R.number(R.get(trig, "Succeed")) == SUCCEED_ONCE and (R.number(R.call(trig, "get_Done")) or 0) ~= 0
end

-- Our player sets off the partner's trigger here: marked done like InteractManager does for a
-- play-once trigger (InteractTrigger.recvDone), then run with our player as the target. Only an
-- area trigger that is an event in our game too (the partner's game decided with its own data).
function World:trigger_run(ev)
    local trig, why = self:trigger_find(ev.guid, ev.hash)
    if trig == nil then return why end
    if trigger_done(trig) then return "done" end
    if R.number(R.call(trig, "get_Type")) ~= TRIGGER_AREA_HIT then
        self.last_not_event = "not an area trigger here"
        return "refused"
    end
    local owner = R.call(trig, "get_Owner")
    local kind = owner and self:trigger_owner_kind(owner, ev.guid)
    if kind == nil or not kind.event then
        self.last_not_event = kind and kind.why or "no owner"
        return "refused"
    end
    local ctx = self.game and self.game:player_context()
    local target = ctx and R.call(ctx, ev.head and "get_HeadGameObject" or "get_BodyGameObject")
    if target == nil then return "failed" end
    self:crumb("world.trigger_run", ("%s:%s"):format(tostring(ev.guid), tostring(ev.hash)), true)
    self.applying_trigger = true
    if R.number(R.get(trig, "Succeed")) == SUCCEED_ONCE then pcall(trig.call, trig, "recvDone", 1) end
    self:mark_replayed(owner)
    local ok = self:muted(function()
        trig:call("execute(via.GameObject, chainsaw.collision.GimmickSensorUserData)", target, nil)
    end)
    self.applying_trigger = false
    return ok and "run" or "failed"
end

-------------------------------------------------------------------------------
-- Objectives (docs/RESEARCH.md 3.24)
-------------------------------------------------------------------------------

-- Our current objective: { id (chainsaw.gui.PurposeID), priority, message (GUID), display,
-- mediate, delay } or nil.
function World:purpose_read()
    local pm = self.r:singleton(PURPOSE_MGR)
    if pm == nil then
        self:cap("purposes", false, "no PurposeManager instance")
        return nil
    end
    local item = R.call(pm, "get_CurrPurposeItem")
    if item == nil or R.call(item, "isValid") == false then return nil end
    local id = R.number(R.call(item, "get_MainPurposeID"))
    if id == nil or id <= 0 then return nil end
    return { id = id, priority = R.number(R.call(item, "get_Priority")) or 0,
        message = R.guid_string(R.call(item, "get_Message")), display = R.number(R.call(item, "get_DisplayTime")) or 0,
        mediate = R.call(item, "get_IsRequestMediate") == true, delay = R.number(R.call(item, "get_DelayTime")) or 0 }
end

-- Shows the partner's objective the game's way: a PurposeGuiItem like the one the game builds
-- from its own conditions, handed to updateMainPurpose (the objective banner shows it; a lower
-- priority than ours changes nothing). True once it is ours.
function World:purpose_apply(p)
    if self.purpose_update_m == nil or self.purpose_ctor_m == nil or p == nil or p.message == nil then return false end
    local pm = self.r:singleton(PURPOSE_MGR)
    local g = self.r:guid_value(p.message)
    if pm == nil or g == nil then return false end
    local item = R.new_instance(PURPOSE_ITEM)
    if item == nil then return false end
    if self.game and self.game.hold then self.game:hold(item, 10.0) end
    self:crumb("world.purpose", tostring(p.id), true)
    local ok = pcall(self.purpose_ctor_m.method.call, self.purpose_ctor_m.method, item, p.id, g, p.priority or 0,
        p.display or 0, p.mediate and true or false, p.delay or 0)
    if not ok then return false end
    ok = pcall(self.purpose_update_m.method.call, self.purpose_update_m.method, pm, item)
    local cur = self:purpose_read()
    return ok and cur ~= nil and cur.id == p.id
end

-------------------------------------------------------------------------------
-- Location, warp, chapter switch
-------------------------------------------------------------------------------

function World:location()
    local ctx = self.game and self.game:player_context()
    local campaign = self.r:singleton(CAMPAIGN)
    local chapter = campaign and R.number(R.call(campaign, "get_CurrentChapter")) or nil
    if ctx == nil then
        -- Loading screen or menus: report the chapter if the campaign knows it.
        if chapter ~= nil and chapter > 0 then
            return { chapter = chapter, loading = true, playable = false }
        end
        return nil
    end
    local pos = R.call(ctx, "get_Position")
    if pos == nil then return nil end
    local stage = R.number(R.call(ctx, "get_CurrentStageID"))
    local body = R.call(ctx, "get_BodyGameObject")
    local tf = body and R.call(body, "get_Transform")
    local rot = tf and R.call(tf, "get_Rotation")
    local cutscene = self.game:is_cutscene()
    -- Between two moments of play (a chapter change, a game over: the player's context lives
    -- on) the game counts as loading: nothing waits on it, travels, saves or replays now.
    local transition = self.game.in_transition ~= nil and self.game:in_transition() or false
    return { chapter = chapter, stage = stage, pos = { x = pos.x, y = pos.y, z = pos.z }, yaw = yaw_of(rot),
        loading = transition, playable = not cutscene and not transition, cutscene = cutscene,
        transition = transition or nil }
end

local function split_stage(stage)
    local pref = math.floor(stage / 1000)
    return pref, pref * 1000
end

-- A System.Nullable`1<inner> value with a value, as a real struct (REFramework ValueType):
-- passing a boxed object where the game expects a Nullable hands it garbage. set(vt, field)
-- writes the value into the struct's value field. nil if the type or its fields are unknown.
function World:make_nullable(inner, set)
    if ValueType == nil or ValueType.new == nil then return nil end
    local tname = "System.Nullable`1<" .. inner .. ">"
    local td = self.r:type(tname)
    if td == nil then return nil end
    local has_f, val_f
    for _, f in ipairs(self.r:fields(tname, 0)) do
        if not f.static then
            if f.type == "System.Boolean" then has_f = f.name elseif f.type == inner then val_f = f.name end
        end
    end
    if has_f == nil or val_f == nil then return nil end
    local ok, vt = pcall(ValueType.new, td)
    if not ok or vt == nil then return nil end
    if not pcall(vt.set_field, vt, has_f, true) or not pcall(set, vt, val_f) then return nil end
    return vt
end

-- Cross-stage warps (preloading the partner's stage and CharacterManager.requestWarp) are
-- experimental (stage_travel): without them, travelling moves the player directly.
function World:stage_warp_enabled()
    return self:setting("stage_travel") == true and self.warp_m ~= nil
end

-- Keeps the stage's scenes requested so the warp lands in a loaded area.
function World:preload_stage(stage)
    if stage == nil or stage < 0 or not self:stage_warp_enabled() then return false end
    local pref, loc = split_stage(stage)
    local pm, lm, em = self.r:singleton(PREF_SCENE), self.r:singleton(LOC_SCENE), self.r:singleton(ENV_SCENE)
    if pm == nil or lm == nil or em == nil then return false end
    local status = self:make_nullable("chainsaw.EnvSceneStatus", function(vt, f) vt:set_field(f, 3) end)
    if status == nil then
        self:cap("warp", false, "cannot build Nullable<EnvSceneStatus>: stage preload off")
        return false
    end
    self:crumb("world.preload_stage", tostring(stage), true)
    local ok = pcall(function()
        pm:call("requestToChangeStatus(chainsaw.PrefectureID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)", pref, status, 1)
        lm:call("requestToChangeStatus(chainsaw.LocID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)", loc, status, 1)
        em:call("requestToChangeStatus(chainsaw.StageID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)", stage, status, 1)
    end)
    return ok
end

function World:warp(stage, pos, yaw)
    if stage ~= nil and stage >= 0 and self:stage_warp_enabled() then
        local cm = self.r:singleton(CHARACTER_MANAGER)
        local ctx = self.game:player_context()
        local npos = self:make_nullable("via.vec3", function(vt, f) vt:set_field(f, Vector3f.new(pos.x, pos.y, pos.z)) end)
        local h = (yaw or 0) * 0.5
        local nrot = self:make_nullable("via.Quaternion", function(vt, f)
            vt:set_field(f, Quaternion.new(math.cos(h), 0.0, math.sin(h), 0.0))
        end)
        if cm ~= nil and ctx ~= nil and npos ~= nil and nrot ~= nil then
            local pref, loc = split_stage(stage)
            self:crumb("world.warp", tostring(stage), true)
            local ok = pcall(function()
                local sid = self.game:hold(sdk.create_instance("chainsaw.StageIdentifier"), 10.0)
                sid:call("setup(chainsaw.LocID, chainsaw.StageID, chainsaw.AreaID)", loc, stage, 0)
                cm:call("requestWarp(chainsaw.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>, chainsaw.StageIdentifier)",
                    ctx:get_field("_ID"), npos, nrot, sid)
            end)
            if ok then return true end
        end
    end
    -- Same area, no stage information or no stage warp: move the player directly (pos is
    -- already the landing spot next to the partner).
    local ctx = self.game:player_context()
    local body = ctx and R.call(ctx, "get_BodyGameObject")
    if body == nil then return false end
    return (self.game:warp_game_object(body, pos))
end

function World:arm_chapter_switch(chapter)
    if self.load_save_m == nil then return false end
    self.chapter_target = chapter
    return true
end

function World:disarm_chapter_switch()
    self.chapter_target = nil
end

-- Spawn at the partner (docs/RESEARCH.md 3.34): the next campaign jump the in-game setup
-- builds (a save loaded, a new game started, from the menus or in game) loads the partner's
-- map and puts our player at the partner's place. The place is asked for when the jump is
-- built (callbacks.spawn_spot() -> { stage, pos = {x,y,z}, rot = {x,y,z,w} | yaw } or nil), so
-- it is where the partner is then. One jump only; forgotten after `seconds`.
function World:arm_spawn(seconds)
    if self.order_m == nil then return false end
    self.spawn_until = self:now() + (seconds or World.SPAWN_TTL)
    self.spawn_start = nil -- the partner's place, not a chapter's start
    return true
end

function World:disarm_spawn()
    self.spawn_until = nil
    self.spawn_start = nil
end

function World:spawn_armed()
    return self.spawn_until ~= nil and self:now() <= self.spawn_until
end

local function locator_spot(loc)
    if loc == nil then return nil end
    local stage = R.number(R.get(loc, "_Stage"))
    local p, q = R.get(loc, "_Position"), R.get(loc, "_Rotation")
    if stage == nil or p == nil or type(p.x) ~= "number" then return nil end
    local rot = (q ~= nil and type(q.w) == "number") and { x = q.x, y = q.y, z = q.z, w = q.w } or nil
    return { stage = stage, pos = { x = p.x, y = p.y, z = p.z }, rot = rot }
end

-- Where the game starts chapter part `key` (chainsaw.CampaignInitialSettingKey, the
-- Campaign1001_ChpX_Y_Head of Lobby.head_key_of_id): its CampaignInitialSetting in the start point
-- catalog, read as plain numbers - { key, chapter, stage, pos, rot, chars = { [CharacterKindID] =
-- { stage, pos, rot } } } with the player's (PL1) place first - or nil and why.
function World:start_point(key)
    if self.start_setting_m == nil then return nil, "no start point catalog" end
    if key == nil then return nil, "no start point for that chapter" end
    local db = self.r:singleton(ENV_DB)
    if db == nil then return nil, "the start point catalog is not loaded" end
    local setting = R.call(db, "getCampaignInitialSetting", key)
    if setting == nil then return nil, ("start point %s is not in the catalog"):format(tostring(key)) end
    local props = {}
    R.each(R.get(setting, "_CharacterList"), function(p) props[#props + 1] = p end)
    -- The player: getPL1Index (the Player1 role), else the first character.
    local pl1 = R.number(R.call(setting, "getPL1Index"))
    if pl1 == nil or pl1 < 0 or pl1 >= #props then
        pl1 = 0
        for i, p in ipairs(props) do
            if R.number(R.get(p, "_DefaultRole")) == 0 then pl1 = i - 1 break end
        end
    end
    local point, chars = nil, {}
    for i, p in ipairs(props) do
        local spot = locator_spot(R.get(p, "_Locator"))
        local kind = R.number(R.get(p, "_Character"))
        if spot ~= nil and kind ~= nil and chars[kind] == nil then chars[kind] = spot end
        if i == pl1 + 1 and spot ~= nil then point = { stage = spot.stage, pos = spot.pos, rot = spot.rot } end
    end
    if point == nil then return nil, "the start point has no place for the player" end
    point.key, point.chapter, point.chars = key, R.number(R.get(setting, "_Chapter")), chars
    return point
end

-- The lobby's chapter jump (docs/RESEARCH.md 3.35): the next campaign jump - the continued save,
-- which the chapter switch loads into `chapter` - starts at that chapter's start point `key`, the
-- way the game's own chapter change starts a chapter: the start point's locators and
-- IsChapterStart (the chapter's opening event plays), no new-game special order. The start point
-- is read now (the catalog is there in the main menu), else when the jump is built. One jump only;
-- forgotten after `seconds`. An arm_spawn (the partner's place) replaces it.
function World:arm_chapter_start(chapter, key, seconds)
    if self.order_m == nil or self.start_setting_m == nil or chapter == nil or key == nil then return false end
    self.spawn_start = { chapter = chapter, key = key, point = (self:start_point(key)) }
    self.spawn_until = self:now() + (seconds or World.SPAWN_TTL)
    return true
end

-- Forgets an armed chapter start (a spawn at the partner stays armed).
function World:disarm_chapter_start()
    if self.spawn_start == nil then return end
    self.spawn_start = nil
    self.spawn_until = nil
end

-- The place an armed chapter start puts the jump at, or nil and why.
function World:chapter_start_spot(order, start)
    local point, why = start.point, nil
    if point == nil then point, why = self:start_point(start.key) end
    if point == nil then return nil, why end
    -- Only into the chapter it was armed for (the chapter switch rewrote the save's chapter).
    local chapter = R.number(R.get(order, "Chapter"))
    if chapter ~= start.chapter then
        return nil, ("the jump is into chapter %s, not %s"):format(tostring(chapter), tostring(start.chapter))
    end
    point.chapter_start = true
    return point
end

-- Post-hook of createCampaignJumperOrderFromInitialSettings while a spawn is armed.
function World:on_order_built(retval)
    local until_t, start = self.spawn_until, self.spawn_start
    self.spawn_until, self.spawn_start = nil, nil -- one jump only, whatever happens
    if until_t == nil or self:now() > until_t then return end
    local order = R.arg_obj(retval)
    local cb = self.callbacks or {}
    local spot, moved, why = nil, 0, nil
    if order == nil then
        why = "the game built no jump"
    elseif start ~= nil then
        spot, why = self:chapter_start_spot(order, start)
    else
        spot = cb.spawn_spot and cb.spawn_spot() or nil
        if spot == nil or spot.pos == nil or spot.stage == nil then why = "the partner's place is unknown" end
    end
    if spot ~= nil and why == nil then moved, why = self:apply_spawn(order, spot) end
    local kind = start ~= nil and "chapter start" or "spawn at partner"
    self.spawn_last = { at = self:now(), kind = kind, moved = moved, why = why, stage = spot and spot.stage,
        chapter = start and start.chapter }
    self.counters.spawns = (self.counters.spawns or 0) + (moved > 0 and 1 or 0)
    self:crumb(start ~= nil and "world.chapter_start" or "world.spawn_at_partner",
        ("%d moved %s"):format(moved, tostring(why or "")), true)
    if moved > 0 then
        self.log(("%s: %sstage %s, %d character(s) moved"):format(kind,
            start and ("chapter %s, "):format(tostring(start.chapter)) or "", tostring(spot.stage), moved))
    else
        self.log(("%s not applied: %s"):format(kind, tostring(why)))
    end
end

local function quat_of(spot)
    local q = spot.rot
    if q ~= nil and q.w ~= nil then return q end
    local h = (spot.yaw or 0) * 0.5
    return { x = 0, y = math.sin(h), z = 0, w = math.cos(h) }
end

-- Writes a GameLocator: stage, position, rotation. true when the position reads back.
function World:set_locator(loc, spot)
    self:set_field_any(loc, LOCATOR, "_Stage", spot.stage)
    local p = spot.pos
    local function at_spot()
        local v = R.get(loc, "_Position")
        return v ~= nil and type(v.x) == "number" and math.abs(v.x - p.x) < 0.01 and math.abs(v.z - p.z) < 0.01
    end
    if not (R.set(loc, "_Position", Vector3f.new(p.x, p.y, p.z)) and at_spot()) then
        R.call(loc, "set_Position(via.vec3)", Vector3f.new(p.x, p.y, p.z))
    end
    local q = quat_of(spot)
    if not R.set(loc, "_Rotation", Quaternion.new(q.w, q.x, q.y, q.z)) then
        R.call(loc, "set_Rotation(via.Quaternion)", Quaternion.new(q.w, q.x, q.y, q.z))
    end
    return at_spot() and R.number(R.get(loc, "_Stage")) == spot.stage
end

-- Moves a campaign jump's characters to `spot`: the base character (the map loads around its
-- locator), a character the spot has a place of its own for (spot.chars, by CharacterKindID: a
-- chapter start's Ashley), and every other character that was in the base's stage with it
-- (Ashley at its side); the others keep their own place. The opening: at the partner's place
-- none (the partner is past it); at a chapter's start (spot.chapter_start) what the game's own
-- chapter change sets - IsChapterStart, so the chapter's opening event plays, and no special
-- order (that is a new game's). Returns the number of characters moved, and why none was.
function World:apply_spawn(order, spot)
    local entries = {}
    R.each(R.get(order, "CharacterEntryList"), function(e) entries[#entries + 1] = e end)
    if #entries == 0 then return 0, "the jump has no characters" end
    local base = R.number(R.get(order, "LoadBaseCharacter")) or 0
    if base < 0 or base >= #entries then base = 0 end
    local base_loc = R.get(entries[base + 1], "Locator")
    if base_loc == nil then return 0, "the player has no place in the jump" end
    local from_stage = R.number(R.get(base_loc, "_Stage"))
    local moved = 0
    for i, e in ipairs(entries) do
        local loc = R.get(e, "Locator")
        local to = nil
        if i == base + 1 then
            to = spot
        else
            local kind = R.number(R.get(R.get(e, "Property"), "_Character"))
            to = spot.chars and kind ~= nil and spot.chars[kind] or nil
            if to == nil and from_stage ~= nil and R.number(R.get(loc, "_Stage")) == from_stage then to = spot end
        end
        if loc ~= nil and to ~= nil and self:set_locator(loc, to) then moved = moved + 1 end
    end
    if moved == 0 then return 0, "the locators could not be written" end
    self:set_field_any(order, ORDER, "SpecialJumpSequence", 0)
    R.set(order, "IsChapterStart", spot.chapter_start == true)
    return moved
end

-- The partner's stage is part of the map our game has loaded (CharacterManager.isActive; nil:
-- unknown).
function World:stage_loaded(stage)
    if stage == nil or stage < 0 then return nil end
    local cm = self.r:singleton(CHARACTER_MANAGER)
    local v = cm and R.call(cm, "isActive", stage)
    if type(v) ~= "boolean" then return nil end
    return v
end

-- Our game, in game, loads a save the way the pause menu's Load Game does, into `chapter`, and
-- comes back at the partner's place (docs/RESEARCH.md 3.34). The slot is the session's choice
-- (callbacks.reload_slot()). true, or false and why.
function World:trigger_reload(chapter)
    local cb = self.callbacks or {}
    local slot = cb.reload_slot and cb.reload_slot() or nil
    if slot == nil then return false, "no saved game to load" end
    if self.game == nil or self.game.ingame_load == nil then return false, "loading in game is not available" end
    if chapter ~= nil and not self:arm_chapter_switch(chapter) then return false, "chapter switching is not available" end
    local ok, why = self.game:ingame_load(slot)
    if not ok then
        if chapter ~= nil then self:disarm_chapter_switch() end
        return false, why
    end
    self:arm_spawn()
    self:crumb("world.trigger_reload", tostring(slot), true)
    return true
end

-- The in-game load trigger_reload started gave up (the save could not be read, or the game
-- would not leave).
function World:reload_failed()
    local l = self.game and self.game.ingame_loading
    return l ~= nil and l.phase == "failed"
end

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

World.DUMP_TYPES = { SFM, SFM_BHV, GUD, GIM, GIM_CONTEXT, CLAP, PAYLOAD_PLAY, PLAY_WORK, GM_DOOR, CAMPAIGN, CHARACTER_MANAGER, GAME_OVER, PREF_SCENE,
    LOC_SCENE, ENV_SCENE, "share.PauseManager", "chainsaw.PauseManagerCustom", "chainsaw.TimerManager",
    "chainsaw.GimmickContext", "chainsaw.GimmickCore", "chainsaw.GmBase", "chainsaw.GmWoodBox", "chainsaw.GmCrow",
    "chainsaw.GmDoor", "chainsaw.TimelineEventManager", "chainsaw.PurposeManager", "chainsaw.MapManager",
    "chainsaw.CharacterSpawnController", "chainsaw.CharacterSpawnPointController", "chainsaw.EnemyManager",
    "chainsaw.InteractManager", "chainsaw.InteractTrigger", TRIGGER_WORK, HOLDER, "chainsaw.PortrayalSettings",
    "chainsaw.GmPortrayalAreaHit", "chainsaw.MovieManager" }

return World
