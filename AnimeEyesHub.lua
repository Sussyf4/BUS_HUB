--[[
  ═══════════════════════════════════════════════════════════════════
  Anime Eyes Hub — [🌍UPD] +1 Anime Eyes  (placeId 97617452700163)
  Built against the game's own remote contract:
    Cast(action, pos, enemyId) · Train() · Pad(idx, kind) · Teleport(worldId)
    Boss("join"|"leave"|"revive"|"home") · PetAction(action, data)
    Rebirth() · AutoRebirth(bool) · UnlockEye(id) · Equip(id)
  State = LocalPlayer attributes (InWave, RunCleared, Level, ...)
  ═══════════════════════════════════════════════════════════════════
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")
local Workspace         = game:GetService("Workspace")

-- run identity: a newer load of this script replaces the tag, and every older
-- copy notices the mismatch on its next Heartbeat and tears itself down. This is
-- what stops reloads from leaving zombie farm/attack loops behind.
local RUN_TAG = HttpService:GenerateGUID(false)

local LP = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RF = ReplicatedStorage:WaitForChild("Remotes")

-- ── game modules (already required & cached by the game itself) ───────
local World      = require(Shared.Config.World)
local Eyes       = require(Shared.Config.Eyes)
local PetsCfg    = require(Shared.Config.Pets)
local Economy    = require(Shared.Config.Economy)
local AbilitiesCfg = require(Shared.Config.Abilities)
local Fuse       = require(Shared.Logic.Fuse)
local BossLogic  = require(Shared.Logic.Boss)
local WorldsCfg  = require(Shared.Config.Worlds)
local WorldGate  = require(Shared.Logic.WorldGate)
local TitleList  = require(Shared.Logic.TitleList)
local Format     = require(Shared.Logic.Format)

-- The game's own number formatter, so status readouts read K/M/B/T/Qa/Qi…
-- instead of raw scientific notation (wins sit in the 1e27 range).
local function shortNum(v)
    v = tonumber(v) or 0
    local ok, s = pcall(Format.short, v)
    if ok and type(s) == "string" then return s end
    return tostring(v)
end

-- training plots per world: {index, req(rebirths), mult, pass, name}
-- Position i in every sheet maps to World.TRAINING[i] for that world.
local TrainingCfg = {}
for w = 1, 9 do
    local sheetName = (w == 1) and "Training" or ("Training" .. tostring(w))
    local okSheet, sheet = pcall(function() return require(Shared.Config[sheetName]) end)
    if okSheet and type(sheet) == "table" then
        local list = {}
        for i, plot in ipairs(sheet) do
            if type(plot) == "table" then
                list[i] = {
                    index = i,
                    req   = tonumber(plot.rebirths) or 0,
                    mult  = tonumber(plot.mult) or 1,
                    pass  = plot.pass,
                    name  = tostring(plot.name or plot.id or ("Training " .. tostring(i))),
                }
            end
        end
        TrainingCfg[w] = list
    end
end

local Client     = LP:WaitForChild("PlayerScripts"):WaitForChild("Client")
local EnemiesMod = require(Client.Enemies)   -- .list() -> {{id,pos,boss}}
local InputMod   = require(Client.Input)     -- .ability(action) -> {cooldown,range,...}

-- the game's own aiming module: Look.pose(player, aimPos, isSkill) rotates the
-- HumanoidRootPart toward the target and drives the eye/head tracking. The game
-- calls it right before every Cast, so we do the same (this is what makes the
-- character visibly point at the enemy instead of firing while facing away).
local LookMod
do
    local ok, mod = pcall(function() return require(Client.Look) end)
    if ok and type(mod) == "table" and type(mod.pose) == "function" then
        LookMod = mod
    end
end

-- ability table by id (config is either a plain list or has .list/.byId)
local abilById = {}
local function harvestAbilities(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if type(v) == "table" and type(v.id) == "string" then
            abilById[v.id] = v
        elseif type(k) == "string" and type(v) == "table" and type(v.cooldown) == "number" then
            abilById[k] = v
        end
    end
end
harvestAbilities(AbilitiesCfg)
harvestAbilities(AbilitiesCfg.list)
harvestAbilities(AbilitiesCfg.byId)

-- ── remotes ───────────────────────────────────────────────────────────
local R = {
    Cast        = RF:WaitForChild("Cast"),
    Train       = RF:WaitForChild("Train"),
    Teleport    = RF:WaitForChild("Teleport"),
    Boss        = RF:WaitForChild("Boss"),
    UnlockEye   = RF:WaitForChild("UnlockEye"),
    Equip       = RF:WaitForChild("Equip"),
    PetAction   = RF:WaitForChild("PetAction"),
    Rebirth     = RF:WaitForChild("Rebirth"),
    AutoRebirth = RF:WaitForChild("AutoRebirth"),
    EquipAura   = RF:WaitForChild("EquipAura"),
    Revive      = RF:WaitForChild("Revive"),
    ClaimReward = RF:WaitForChild("ClaimReward"),
    Pops        = RF:WaitForChild("Pops"),
    PickTitle   = RF:WaitForChild("PickTitle"),
    BossDrop    = RF:WaitForChild("BossDrop"),
}

-- aura config: the module exposes { list = {...}, byId = {...}, multFor(...) }
local AuraCfg: any = {}
do
    local ok, mod = pcall(function() return require(Shared.Config.Auras) end)
    if ok and type(mod) == "table" then AuraCfg = mod end
end
local AuraById = {}
do
    local src = AuraCfg
    if type(AuraCfg.byId) == "table" then
        src = AuraCfg.byId
    elseif type(AuraCfg.list) == "table" then
        src = AuraCfg.list
    end
    for k, a in pairs(src) do
        if type(a) == "table" and type(a.id) == "string" then
            AuraById[a.id] = a
        elseif type(k) == "string" and type(a) == "table" and type(a.mult) == "number" then
            AuraById[k] = a
        end
    end
end

-- ── config ────────────────────────────────────────────────────────────
local cfg = {
    combatOn   = false,   -- Auto Farm OP (attack loop)
    autoSkills = true,    -- auto use E / R
    stayAway   = true,    -- hold the fixed gap from enemies instead of chasing
    keepMin    = 15,      -- fixed gap from enemies (not user-editable)
    mobTarget  = "Nearest",
    trainOn    = true,    -- auto train (chakra): hub and stages alike
    multiOn    = false,   -- auto multi: stand on the best training plot you qualify for
    autoPops   = true,    -- claim free training pops (never the paid/gold one)
    giftOn     = true,    -- claim the 5 / 15 / 60 minute playtime gifts

    farmOn     = false,   -- Auto Farm Stages
    farmMode   = "Loop",  -- Loop | Rush | Jackpot 1-15 | Smart Continuous
    world      = 0,       -- forced farm world 1..9; 0 = stay in the current world
    stage      = 15,      -- farm stops after this stage (1..15)

    padsOn     = true,    -- pad solver is always on (no toggle)

    bossOn     = false,   -- Auto Boss
    bossDist   = 0,       -- close-in gap from the boss body (0 = walk right onto it)

    hatchOn    = false,   -- Auto Egg Hatch
    eggWorld   = 0,       -- egg world filter 1..9; 0 = the world you are in
    eggId      = "normal",
    hatchCount = 1,       -- 1..3
    hatchDelay = 0.25,    -- seconds between hatch invokes
    equipOn    = true,    -- Auto EquipBest (pets)
    sellOn     = false,   -- Auto Sell (low mult pets)

    rebirthOn  = false,   -- Auto Rebirth
    unlockEyes = true,    -- Auto Unlock Eye
    equipEyes  = true,    -- Auto Equip Best Eye
    equipTitle = true,    -- Auto Equip Best Title
    equipAura  = true,    -- Auto Equip Best Aura
    antiAfk    = true,    -- anti idle kick

    defaultsRev = 3,      -- bumps the "everything useful starts ON" migration

    -- named configs + Discord reporter
    cfgName      = "default", -- active profile name
    autoLoadCfg  = true,      -- load the last profile on script start
    webhookOn    = true,      -- reporter switch (no-op until a URL is set)
    webhookUrl   = "",
    webhookEvery = 15,        -- seconds between message edits
}

-- ── settings that survive a reload ────────────────────────────────────
-- Every update used to silently reset the toggles, which switched off the
-- operator's automation; carry the user-facing settings over instead. Internal
-- tuning fields (keepMin, bossDist, padsOn) are deliberately excluded so a
-- retuned default actually takes effect after an update.
local PERSIST = {
    combatOn = true, autoSkills = true, stayAway = true, mobTarget = true,
    trainOn = true, multiOn = true, autoPops = true, giftOn = true,
    farmOn = true, farmMode = true, world = true, stage = true,
    bossOn = true, hatchOn = true,
    eggWorld = true, eggId = true, hatchCount = true, hatchDelay = true,
    equipOn = true, sellOn = true,
    rebirthOn = true, unlockEyes = true, equipEyes = true, equipTitle = true,
    equipAura = true, antiAfk = true,
    defaultsRev = true,
    cfgName = true, autoLoadCfg = true,
    webhookOn = true, webhookUrl = true, webhookEvery = true,
}

local function persistCfg()
    if type(getgenv) ~= "function" then return end
    local t = {}
    for k in pairs(PERSIST) do t[k] = cfg[k] end
    getgenv().AnimeEyesHubCfg = t
end

local DEFAULT_REV = 3
local ON_BY_DEFAULT = {
    "trainOn", "stayAway", "equipOn", "unlockEyes", "equipEyes",
    "equipTitle", "equipAura", "autoPops", "giftOn", "antiAfk",
}

local function cleanProfileName(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[^%w _%-%.]", "")
    if #name > 32 then name = name:sub(1, 32) end
    if name == "" then name = "default" end
    return name
end

local function sanitizeCfg()
    cfg.stage = math.clamp(math.floor(tonumber(cfg.stage) or 15), 1, 15)
    cfg.world = math.clamp(math.floor(tonumber(cfg.world) or 0), 0, 9)
    cfg.eggWorld = math.clamp(math.floor(tonumber(cfg.eggWorld) or 0), 0, 9)
    cfg.hatchCount = math.clamp(math.floor(tonumber(cfg.hatchCount) or 1), 1, 3)
    cfg.hatchDelay = math.clamp(tonumber(cfg.hatchDelay) or 0.25, 0.1, 2)
    cfg.webhookEvery = math.clamp(math.floor(tonumber(cfg.webhookEvery) or 15), 10, 300)
    cfg.webhookUrl = tostring(cfg.webhookUrl or ""):gsub("^%s+", ""):gsub("%s+$", "")
    cfg.cfgName = cleanProfileName(cfg.cfgName)
    local modeOk = false
    for _, m in ipairs({ "Loop", "Rush", "Jackpot", "Smart" }) do
        if cfg.farmMode == m then modeOk = true end
    end
    if not modeOk then cfg.farmMode = "Loop" end
    if cfg.mobTarget ~= "Nearest" and cfg.mobTarget ~= "Boss First" then
        cfg.mobTarget = "Nearest"
    end
end

-- ── named configs (executor workspace) ────────────────────────────────
local CFG_DIR    = "AnimeEyesHub"
local CFG_FILE   = "AnimeEyesHub/configs.json"
local WH_FILE    = "AnimeEyesHub/webhook.json"

local function readJsonFile(path)
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return nil end
    local ok, exists = pcall(isfile, path)
    if not ok or not exists then return nil end
    local ok2, data = pcall(readfile, path)
    if not ok2 or type(data) ~= "string" or data == "" then return nil end
    local ok3, t = pcall(function() return HttpService:JSONDecode(data) end)
    if ok3 and type(t) == "table" then return t end
    return nil
end

local function writeJsonFile(path, value)
    if type(writefile) ~= "function" then return false end
    if type(makefolder) == "function" and type(isfolder) == "function" then
        pcall(function()
            if not isfolder(CFG_DIR) then makefolder(CFG_DIR) end
        end)
    end
    local ok, data = pcall(function() return HttpService:JSONEncode(value) end)
    if not ok then return false end
    return (pcall(writefile, path, data))
end

local configStore = readJsonFile(CFG_FILE) or {}
if type(configStore.profiles) ~= "table" then configStore.profiles = {} end
if type(configStore.lastName) ~= "string" or configStore.lastName == "" then
    configStore.lastName = "default"
end

local function snapshotProfile()
    local t = {}
    for k in pairs(PERSIST) do t[k] = cfg[k] end
    t.savedAt = os.time()
    return t
end

local function applyProfile(prof)
    if type(prof) ~= "table" then return 0 end
    local changed = 0
    for k in pairs(PERSIST) do
        local v = prof[k]
        if v ~= nil and type(v) == type(cfg[k]) then
            if cfg[k] ~= v then changed = changed + 1 end
            cfg[k] = v
        end
    end
    if (tonumber(cfg.defaultsRev) or 0) < DEFAULT_REV then
        for _, k in ipairs(ON_BY_DEFAULT) do cfg[k] = true end
        cfg.defaultsRev = DEFAULT_REV
    end
    sanitizeCfg()
    return changed
end

do
    local saved = (type(getgenv) == "function") and getgenv().AnimeEyesHubCfg or nil
    if type(saved) == "table" then
        for k in pairs(PERSIST) do
            local cur, sv = cfg[k], saved[k]
            if sv ~= nil and type(sv) == type(cur) then cfg[k] = sv end
        end
        -- one-time migration: the user asked for the automation defaults to be
        -- ON, and an old saved table would otherwise keep them all off.
        if (tonumber(cfg.defaultsRev) or 0) < DEFAULT_REV then
            for _, k in ipairs(ON_BY_DEFAULT) do cfg[k] = true end
            cfg.defaultsRev = DEFAULT_REV
        end
    end
end
sanitizeCfg()

-- "Auto Load Config": apply the last named profile over the live values.
if cfg.autoLoadCfg then
    local nm = cleanProfileName(configStore.lastName or cfg.cfgName)
    local prof = configStore.profiles[nm]
    if type(prof) == "table" then
        applyProfile(prof)
        cfg.cfgName = nm
    end
end
persistCfg()

-- ── small helpers ─────────────────────────────────────────────────────
local function attr(name, d)
    local v = LP:GetAttribute(name)
    if v == nil then return d end
    return v
end

local function decode(json, fallback)
    if type(json) ~= "string" or json == "" then return fallback end
    local ok, v = pcall(function() return HttpService:JSONDecode(json) end)
    if ok and v ~= nil then return v end
    return fallback
end

-- ── plot requirement, as the game actually displays it ────────────────
-- The game never compares a plot's raw `rebirths` against your Rebirths. Every
-- plot sign (and the "needs N Rebirths" message) shows
--   Economy.plotRebirths(raw, State.rebirthAnchors())
-- Once a world unlocks, its anchor makes each later rebirth worth more levels,
-- so the effective requirement DROPS: World 6's Bankai Altar is raw 465 but the
-- sign reads 430, Reiatzu Chamber is raw 441 but reads 414. The hub used to
-- compare those raw numbers, so Auto Multi settled on a lower plot and Auto
-- Rebirth aimed past the point where the best plot was already usable.
local EconLogic
do
    local ok, mod = pcall(function() return require(Shared.Logic.Economy) end)
    if ok and type(mod) == "table" and type(mod.plotRebirths) == "function" then
        EconLogic = mod
    end
end

-- RebirthAnchors is a JSON attribute ({ "6": 358 }) keyed by world. The game's
-- State.rebirthAnchors() re-keys it numerically, which is what plotRebirths
-- expects. Cache by raw attribute value so we only decode when it changes.
local anchorCacheRaw, anchorCacheVal = nil, {}

local function rebirthAnchors()
    local raw = attr("RebirthAnchors")
    if raw == anchorCacheRaw then return anchorCacheVal end

    local out = {}
    local tbl = (type(raw) == "table") and raw or decode(raw, nil)
    if type(tbl) == "table" then
        for k, v in pairs(tbl) do
            local n = tonumber(k)
            if n and type(v) == "number" then out[n] = v end
        end
    end

    anchorCacheRaw, anchorCacheVal = raw, out
    return out
end

-- Displayed requirement for a raw plot requirement (raw when the game's
-- transform is unavailable, e.g. before any world has been anchored).
local function plotReq(raw)
    raw = tonumber(raw) or 0
    if not EconLogic or raw <= 1 then return raw end
    local anchors = rebirthAnchors()
    if next(anchors) == nil then return raw end
    local ok, v = pcall(EconLogic.plotRebirths, raw, anchors)
    if ok and type(v) == "number" then return v end
    return raw
end

local function character() return LP.Character end
local function rootPart()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = LP.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function flatDist(a, b)
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- ── WindUI ────────────────────────────────────────────────────────────
local okW, WindUI = pcall(function()
    return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
end)
if not okW or type(WindUI) ~= "table" then
    warn("[AnimeEyesHub] WindUI failed to load: " .. tostring(WindUI))
    return
end

-- All CoreGui work is applied on the loader's elevated thread, not the Heartbeat
-- callback, which runs on a game scheduler thread without the Plugin capability
-- (see setStatus). Paragraphs are queued by key so only the latest text shows;
-- one-off jobs (notifications, toggle mirrors) keep their order.
local statusQueue = {}
local uiJobs = {}
local function uiRun(fn)
    uiJobs[#uiJobs + 1] = fn
end
local function notify(title, content, duration)
    uiRun(function()
        WindUI:Notify({ Title = title, Content = content, Duration = duration or 3 })
    end)
end

-- UI elements and helpers the ticks / Settings tab drive (filled in below).
local uiHooks = {}

local Window = WindUI:CreateWindow({
    Title   = "ANIME EYES HUB",
    Icon    = "solar:eye-bold",
    Author  = "Anime Eyes · " .. tostring(LP.Name),
    Folder  = "AnimeEyesHub",
    Size    = UDim2.fromOffset(560, 640),
    MinSize = Vector2.new(520, 400),
    MaxSize = Vector2.new(900, 760),
    Position = UDim2.new(0.5, 0, 0.5, 0),   -- centered on every screen
    AutoScale = true,                        -- shrink-to-fit a phone viewport
    Resizable = false,                       -- the layout fits itself; no drag-resize
    SideBarWidth = 160,
    Theme   = "Dark",
    NewElements = true,
    Topbar  = { Height = 44, ButtonsType = "Mac" },
    OpenButton = {
        Title = "ANIME EYES",
        Icon = "solar:eye-bold",
        CornerRadius = UDim.new(0, 12),
        StrokeThickness = 2,
        OnlyMobile = false,
        Enabled = true,
        Draggable = true,
    },
    ToggleKey = Enum.KeyCode.RightShift,
})
pcall(function() Window:SetToggleKey(Enum.KeyCode.RightShift) end)
pcall(function() Window:Tag({ Title = "v2.5", Icon = "solar:star-bold", Color = Color3.fromHex("#1c1c1c"), Border = true }) end)
pcall(function() Window:SelectTab(1) end)
pcall(function() WindUI:SetNotificationLower(true) end)

-- Responsive fit. WindUI scales the window to the viewport once, when it is
-- created; this mirrors its formula (80px margin, clamped to 0.3..1) and
-- re-applies it whenever the viewport changes, so the same build fills a
-- desktop window and shrinks to fit a phone (including after a rotation).
function uiHooks.fitScale()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    return math.clamp(math.min((vp.X - 80) / 560, (vp.Y - 80) / 640), 0.3, 1)
end
function uiHooks.applyScale()
    pcall(function() Window:SetUIScale(uiHooks.fitScale()) end)
end
uiHooks.applyScale()

-- Status paragraphs. The Heartbeat callback runs on the client's scheduler
-- thread at the default identity (re-elevated each tick, see below), so capture
-- the Desc TextLabel at build time and keep each update to a single property
-- write. WindUI's own :SetDesc is the fallback when the label was not found.
local function makeStatus(tab, title)
    local sentinel = "__aeh" .. tostring(math.floor(os.clock() * 1000000) % 1000000000) .. "__"
    local ok, para = pcall(function()
        return tab:Paragraph({ Title = title or "Status", Desc = sentinel })
    end)
    if not (ok and para) then return nil end
    local label
    pcall(function()
        local pf = para.ParagraphFrame
        local host = (type(pf) == "table" and pf.Parent) or pf
        if host then
            for _, d in ipairs(host:GetDescendants()) do
                if d:IsA("TextLabel") and d.Text == sentinel then
                    label = d
                    break
                end
            end
        end
        if label then
            label.Text = "idle"
            if type(pf) == "table" then pf.Desc = "idle" end
        end
    end)
    return { para = para, label = label }
end
-- Status paragraphs are queued here and written by the UI thread (see notify).
local function setStatus(para, text)
    if para then statusQueue[para] = tostring(text) end
end

-- forward declaration so the Settings button can reference it
local unload
local unloaded = false

-- ═══════════════════════ combat (Auto Farm OP) ═══════════════════════
local cdAttack, cdE, cdR = 0, 0, 0

local function abilityFor(action)
    if InputMod and type(InputMod.ability) == "function" then
        local ok, ab = pcall(InputMod.ability, action)
        if ok and type(ab) == "table" then return ab end
    end
    -- static fallback: current eye -> ability id
    local eye = Eyes.byId and (Eyes.byId[attr("Eye", Eyes.STARTER)] or Eyes.byId[Eyes.STARTER])
    if eye then
        local id = action == "attack" and eye.attack or (action == "E" and eye.skillE or eye.skillR)
        if id and abilById[id] then return abilById[id] end
    end
    return nil
end

local function pickTarget(enemies, bossFirst)
    if #enemies == 0 then return nil end
    local root = rootPart()
    if not root then return nil end
    if bossFirst or cfg.mobTarget == "Boss First" then
        for _, e in ipairs(enemies) do
            if e.boss then return e end
        end
    end
    local best, bestD = nil, math.huge
    for _, e in ipairs(enemies) do
        local d = flatDist(e.pos, root.Position)
        if d < bestD then best, bestD = e, d end
    end
    return best
end

local function bossFightActive()
    return cfg.bossOn and Workspace:GetAttribute("BossPhase") == "fight"
end

local function bossArena()
    local okC, c = pcall(function() return BossLogic.CENTRE end)
    local okR, r = pcall(function() return BossLogic.INSIDE_RADIUS end)
    return (okC and typeof(c) == "Vector3") and c or Vector3.new(-3000, 0, 300),
           (okR and type(r) == "number") and r or 125
end

-- rotate the character toward the aim point exactly like the game's Input.fire does
local function faceTarget(pos, isSkill)
    if LookMod then
        local ok = pcall(LookMod.pose, LP, pos, isSkill)
        if ok then return end
    end
    local root = rootPart()
    if not root then return end
    pcall(function()
        root.CFrame = CFrame.lookAt(root.Position, Vector3.new(pos.X, root.Position.Y, pos.Z))
    end)
end

-- ── kiting / orbiting ─────────────────────────────────────────────────
local moveState = { orbit = 1, kitePos = nil, kiteCheckAt = 0, lastFlipAt = 0, stuckAt = 0 }
-- The game's control module calls Humanoid:Move(Vector3.zero) on Heartbeat,
-- which silently cancels any Move issued from our Heartbeat loop. Movement is
-- therefore queued here and applied from RenderStepped, where it sticks.
local desiredDir = Vector3.zero
local moveRequested = false

local function moveCharacter(dir)
    if dir and dir.Magnitude > 0.05 then
        local flat = Vector3.new(dir.X, 0, dir.Z)
        if flat.Magnitude > 0.05 then
            desiredDir = flat.Unit
            moveRequested = true
            return
        end
    end
    desiredDir = Vector3.zero
end

-- set while the farm is stepping on a claim pad: combat may still attack, but
-- it must not steer the character off the pad
local padLock = false

-- ── stage / pad geometry (safe movement) ──────────────────────────────
local function sign(x)
    if x > 0 then return 1 elseif x < 0 then return -1 end
    return 0
end

local function curWorldId()
    return tonumber(attr("World", 1)) or 1
end

local function curStage()
    if attr("InStages", false) ~= true then return 0 end
    local r = rootPart()
    if not r then return 0 end
    return math.clamp(math.floor(tonumber(World.stageAt(r.Position.Z)) or 0), 1, 15)
end

-- deterministic pad centre: origin + the game's own formula. The real models
-- sit at y≈1.1, the formula uses FLOOR_Y + 0.6; only x/z matter for claims.
local function padWorldPos(w, stage, kind)
    local o = World.origin(w)
    local p = World.padPosition(stage, kind)
    if typeof(o) ~= "Vector3" or typeof(p) ~= "Vector3" then return nil end
    return Vector3.new(o.X + p.X, 1.1, o.Z + p.Z)
end

local function stageRectWorld(w, stage)
    local a, b = World.stageBounds(stage)
    if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then return nil end
    local o = World.origin(w)
    return Vector3.new(o.X + a.X, 0, o.Z + a.Z),
           Vector3.new(o.X + b.X, 0, o.Z + b.Z)
end

local PAD_AVOID_X, PAD_AVOID_Z = 10, 8

-- the client's pad watcher scans the stage under the character and both
-- neighbours, so avoid every pad it can see from this position
local function inPadZone(pos, w, marginX, marginZ)
    local s = math.floor(tonumber(World.stageAt(pos.Z)) or 0)
    if s < 1 then return false end
    s = math.clamp(s, 1, 15)
    marginX = marginX or PAD_AVOID_X
    marginZ = marginZ or PAD_AVOID_Z
    for stage = math.max(1, s - 1), math.min(15, s + 1) do
        for _, kind in ipairs({ "gold", "purple" }) do
            local p = padWorldPos(w, stage, kind)
            if p and math.abs(pos.X - p.X) <= marginX and math.abs(pos.Z - p.Z) <= marginZ then
                return true
            end
        end
    end
    return false
end

local function pointInStage(pos, w, stage, inset)
    local a, b = stageRectWorld(w, stage)
    if not a then return true end
    inset = inset or 0
    return pos.X >= a.X + inset and pos.X <= b.X - inset
        and pos.Z >= a.Z + inset and pos.Z <= b.Z - inset
end

-- a straight step is safe when every sample stays inside the current stage and
-- clear of every pad the client watcher can see from there
local function pathSafe(from, to, w, stage, allowPad)
    if stage <= 0 then return true end
    local a, b = stageRectWorld(w, stage)
    if not a then return true end
    local sx = math.clamp(from.X, a.X + 1, b.X - 1)
    local sz = math.clamp(from.Z, a.Z + 1, b.Z - 1)
    local n = math.max(1, math.ceil(flatDist(from, to) / 1.5))
    for i = 1, n do
        local t = i / n
        local px = sx + (to.X - sx) * t
        local pz = sz + (to.Z - sz) * t
        if px < a.X + 1 or px > b.X - 1 or pz < a.Z + 1 or pz > b.Z - 1 then
            return false
        end
        if not allowPad and inPadZone(Vector3.new(px, from.Y, pz), w) then
            return false
        end
    end
    return true
end

-- While a stage run is live the character may climb toward the next stage but
-- must never walk back into one already cleared. The current stage's back edge
-- is stageRectWorld(...).b.Z; a +Z step (toward the already-cleared side) is
-- clamped there, and a character already stranded past that edge is pushed
-- forward instead of being allowed to linger below the current stage.
local function stageFence(root, dir, w, stage)
    if stage <= 0 then return dir end
    local a, b = stageRectWorld(w, stage)
    if not a then return dir end
    local pos = root.Position
    if pos.Z > b.Z then return Vector3.new(0, 0, -1) end
    if not dir or dir.Magnitude < 0.05 then return dir end
    local u = Vector3.new(dir.X, 0, dir.Z)
    if u.Magnitude < 0.05 then return dir end
    u = u.Unit
    if u.Z > 0 and (b.Z - pos.Z) <= 2 then
        -- at the back wall: strip the backward component, keep the sideways one
        u = Vector3.new(u.X, 0, 0)
        if u.Magnitude < 0.05 then return Vector3.new(0, 0, -1) end
        return u.Unit
    end
    return u
end

-- pick a step that keeps the character inside the current stage and off the
-- pads. Orbit directions are tried first, so kiting still circles the target.
local function safeMoveDir(root, dir, w, stage)
    if not dir or dir.Magnitude < 0.05 then return Vector3.zero end
    if stage <= 0 then return dir.Unit end
    local u = Vector3.new(dir.X, 0, dir.Z).Unit
    local side = Vector3.new(-u.Z, 0, u.X)
    local a, b = stageRectWorld(w, stage)
    local inward = Vector3.zero
    if a then
        local cx = (a.X + b.X) * 0.5
        local cz = (a.Z + b.Z) * 0.5
        inward = Vector3.new(cx - root.Position.X, 0, cz - root.Position.Z)
        inward = inward.Magnitude > 0.05 and inward.Unit or Vector3.zero
    end
    local tries = {
        u,
        side,
        -side,
        u * 0.6 + side * 0.8,
        u * 0.6 - side * 0.8,
        inward,
        -u,
        Vector3.new(1, 0, 0),
        Vector3.new(-1, 0, 0),
        Vector3.new(0, 0, 1),
        Vector3.new(0, 0, -1),
    }
    for _, c in ipairs(tries) do
        if c.Magnitude > 0.05 then
            local cn = c.Unit
            if pathSafe(root.Position, root.Position + cn * 8, w, stage, false) then
                return cn
            end
        end
    end
    return Vector3.zero
end

-- wall-stuck while kiting: jump to a different point in the same stage, never
-- across a boundary and never onto a pad
local function stuckTeleport(root, tgt, w, stage, now)
    if stage <= 0 or now - moveState.stuckAt < 1.2 then return false end
    local p0 = root.Position
    local targetPos = tgt and tgt.pos or nil
    local want = tonumber(cfg.keepMin) or 15
    local best, bestScore = nil, -math.huge
    for i = 1, 24 do
        local ang = (i / 24) * math.pi * 2
        local rad = 10 + (i % 5) * 4
        local cand = Vector3.new(p0.X + math.cos(ang) * rad, p0.Y, p0.Z + math.sin(ang) * rad)
        if pointInStage(cand, w, stage, 3)
            and not inPadZone(cand, w, PAD_AVOID_X + 2, PAD_AVOID_Z + 2) then
            local score = targetPos and -math.abs(flatDist(cand, targetPos) - want)
                or flatDist(cand, p0)
            if score > bestScore then best, bestScore = cand, score end
        end
    end
    if not best then return false end
    moveState.stuckAt = now
    pcall(function() root.CFrame = CFrame.new(best.X, best.Y + 1.5, best.Z) end)
    moveState.kitePos, moveState.kiteCheckAt = nil, now
    return true
end

-- walk-stuck recovery: use a side lane outside the pad band instead of stepping
-- straight through a pad, and always clamp the landing inside the CURRENT stage
-- so a stuck recovery can never drop us into an already-cleared or not-yet-open
-- stage.
local function safeTeleportTo(root, target, now)
    local w, stage = curWorldId(), curStage()
    local from = root.Position
    local x, z = target.X, target.Z
    if stage > 0 then
        local a, b = stageRectWorld(w, stage)
        if a then
            x = math.clamp(x, a.X + 4, b.X - 4)
            z = math.clamp(z, a.Z + 4, b.Z - 4)
        end
    end
    local dest = Vector3.new(x, from.Y, z)
    if stage > 0 and not pathSafe(from, dest, w, stage, false) then
        local lane = (from.X >= 0) and 33 or -33
        local mid = Vector3.new(lane, from.Y, z)
        if pointInStage(mid, w, stage, 3)
            and not inPadZone(mid, w, PAD_AVOID_X + 2, PAD_AVOID_Z + 2) then
            pcall(function() root.CFrame = CFrame.new(mid.X, from.Y + 2, mid.Z) end)
            return true
        end
    end
    pcall(function() root.CFrame = CFrame.new(dest.X, from.Y + 2, dest.Z) end)
    return true
end

local function checkStuck(root, now)
    if not moveState.kitePos then moveState.kitePos, moveState.kiteCheckAt = root.Position, now; return false end
    if now - moveState.kiteCheckAt < 0.9 then return false end
    local moved = flatDist(root.Position, moveState.kitePos)
    moveState.kitePos, moveState.kiteCheckAt = root.Position, now
    if moved < 1.1 and now - moveState.lastFlipAt > 1.1 then
        moveState.orbit = -moveState.orbit
        moveState.lastFlipAt = now
        return true
    end
    return false
end

local function steerMob(tgt, root, d, range, now)
    -- Fixed 15-stud hold gap with an always-on safe orbit. Circling still
    -- happens in the band, but every step is checked against the current
    -- stage bounds and the pad zones the client watcher can see.
    local desired = math.clamp(tonumber(cfg.keepMin) or 15, 8, math.max(12, (range or 80) - 6))
    local toT = Vector3.new(tgt.pos.X - root.Position.X, 0, tgt.pos.Z - root.Position.Z)
    if toT.Magnitude < 0.05 then return end
    local toward = toT.Unit
    local side = Vector3.new(-toward.Z, 0, toward.X) * moveState.orbit
    local dir
    if d < desired - 3 then
        dir = -toward
    elseif d > desired + 12 then
        dir = toward
    else
        dir = side
    end
    local w, stage = curWorldId(), curStage()
    if stage > 0 then
        local safe = safeMoveDir(root, dir, w, stage)
        if safe.Magnitude < 0.05 then
            local alt = safeMoveDir(root, -side, w, stage)
            if alt.Magnitude < 0.05 then alt = safeMoveDir(root, toward, w, stage) end
            safe = alt
        end
        dir = stageFence(root, safe, w, stage)
    end
    if checkStuck(root, now) then
        if stage > 0 and stuckTeleport(root, tgt, w, stage, now) then return end
        moveState.orbit = -moveState.orbit
        if stage > 0 then dir = safeMoveDir(root, -dir, w, stage) end
    end
    moveCharacter(dir)
end

-- The boss fight is walk-only: no dodging teleports, no blink repositioning.
-- The character closes straight onto the boss body (cfg.bossDist, never
-- negative) and the attack loop fires until the boss drops.
local lastBossGap = 0

local function steerBoss(tgt, root, gap, range, now)
    local c, arenaR = bossArena()
    local toB = Vector3.new(tgt.pos.X - root.Position.X, 0, tgt.pos.Z - root.Position.Z)
    if toB.Magnitude < 0.05 then return end
    local toward = toB.Unit
    local safe = math.max(0, tonumber(cfg.bossDist) or 0)
    local hold = safe + 0.4

    local dir
    if gap > hold then
        dir = toward
    elseif gap < safe - 0.4 then
        dir = -toward
    else
        dir = Vector3.zero
    end

    -- stay inside the arena even while closing in
    local relC = Vector3.new(root.Position.X - c.X, 0, root.Position.Z - c.Z)
    local rim = arenaR - 14
    if relC.Magnitude > rim then
        local inward = relC.Magnitude > 0.05 and -relC.Unit or toward
        dir = inward
        if gap > hold then dir = toward * 0.7 + inward * 0.6 end
    end

    if dir.Magnitude > 0.05 and checkStuck(root, now) then
        dir = dir + Vector3.new(-toward.Z, 0, toward.X) * 0.4
    end
    moveCharacter(dir)
end

-- returns true when combat owns character movement this frame
local function combatTick(now)
    local enemies = EnemiesMod.list()
    local root, hum = rootPart(), humanoid()
    if #enemies == 0 or not root or not hum or hum.Health <= 0 then return false end
    local bossFight = bossFightActive()
    local tgt = pickTarget(enemies, bossFight)
    if not tgt then return false end

    local pos = tgt.pos
    local aimPos = pos
    if tgt.boss then
        local ok, ap = pcall(function() return BossLogic.aimPoint(root.Position.X, root.Position.Z) end)
        if ok and typeof(ap) == "Vector3" then aimPos = ap end
    end

    -- Enemies.list already reports the boss SURFACE point closest to us
    -- (BossLogic.aimPoint), so this flat distance is the true body gap.
    -- Subtracting BODY_RADIUS again used to stop the bot ~22 studs out.
    local centerD = flatDist(pos, root.Position)
    local gap = centerD
    if tgt.boss then lastBossGap = gap end

    local atkAb = abilityFor("attack")
    local range = (atkAb and atkAb.range) or 80

    -- movement: pad claim > boss close-in > safe mob orbit > approach
    if padLock then
        -- the farm is on a claim pad: attack, but do not step off it
    elseif cfg.bossOn and tgt.boss then
        steerBoss(tgt, root, gap, range, now)
    elseif cfg.stayAway then
        steerMob(tgt, root, gap, range, now)
    elseif centerD > range - 8 then
        local toward = Vector3.new(pos.X - root.Position.X, 0, pos.Z - root.Position.Z)
        local w, stage = curWorldId(), curStage()
        if stage > 0 then toward = stageFence(root, toward, w, stage) end
        moveCharacter(toward)
    end

    -- attack + skills (skills use their own range)
    if gap <= range + 8 then
        if now >= cdAttack then
            faceTarget(aimPos, false)
            pcall(function() R.Cast:FireServer("attack", aimPos, tgt.id) end)
            cdAttack = now + ((atkAb and atkAb.cooldown) or 0.25)
        end
        if cfg.autoSkills then
            local abE = abilityFor("E")
            if now >= cdE and gap <= ((abE and abE.range) or 80) + 6 then
                faceTarget(aimPos, true)
                pcall(function() R.Cast:FireServer("E", aimPos, tgt.id) end)
                cdE = now + ((abE and abE.cooldown) or 3)
            end
            local abR = abilityFor("R")
            if now >= cdR and gap <= ((abR and abR.range) or 100) + 6 then
                faceTarget(aimPos, true)
                pcall(function() R.Cast:FireServer("R", aimPos, tgt.id) end)
                cdR = now + ((abR and abR.cooldown) or 3)
            end
        end
    end
    return true
end

-- ═══════════════════════ walking / stuck recovery ════════════════════
local walk = { goal = nil, since = 0, checkAt = 0, lastPos = nil, stuckDone = false }

local function setGoal(pos)
    if walk.goal == nil or flatDist(walk.goal, pos) > 4 then
        walk.goal = pos
        walk.since = os.clock()
        walk.checkAt = os.clock()
        walk.lastPos = nil
        walk.stuckDone = false
    end
end

local function clearGoal()
    walk.goal = nil
end

local function walkTick(now)
    local root, hum = rootPart(), humanoid()
    if not walk.goal or not root or not hum or hum.Health <= 0 then return end
    local d = flatDist(root.Position, walk.goal)
    if d < 3.5 then
        clearGoal()
        return
    end
    local dir = Vector3.new(walk.goal.X - root.Position.X, 0, walk.goal.Z - root.Position.Z)
    local w, stage = curWorldId(), curStage()
    if stage > 0 then dir = stageFence(root, dir, w, stage) end
    moveCharacter(dir)

    if now - walk.checkAt >= 1.5 then
        if walk.lastPos and flatDist(root.Position, walk.lastPos) < 1.2 and not walk.stuckDone then
            walk.stuckDone = true
            safeTeleportTo(root, walk.goal, now)
        end
        walk.lastPos = root.Position
        walk.checkAt = now
    end
end

-- ═══════════════════════ stage farm state machine ════════════════════
local farm = {
    padStage = -1, padQueue = {}, padIndex = 1,
    padArriveAt = 0, padRetryAt = 0, padStartAt = 0, padTeleAt = 0,
    phase = "idle", lastStage = 0, holdAt = 0, stopRetryAt = 0,
    worldAskAt = 0, worldWarnAt = 0, hopAt = 0, nudgeAt = 0, nudged = false,
    lastClaimAt = 0, log = {},
}
local combatBusy = false
local function farmNote(s)
    farm.log[#farm.log + 1] = string.format("%.1f %s", os.clock() % 1000, tostring(s))
    if #farm.log > 40 then table.remove(farm.log, 1) end
end

local function mapName(w)
    if w == 1 then return "Map" end
    return "Map" .. tostring(w)
end

-- the world the farm is actually running in: the forced world when one is set,
-- otherwise wherever the player currently stands ("None")
local function farmWorld()
    local forced = tonumber(cfg.world) or 0
    if forced > 0 then return forced end
    return tonumber(attr("World", 1)) or 1
end

local function padPlan(stage)
    if not cfg.padsOn then return {} end
    -- The stop stage's gold pad is the run's exit: claiming it cashes out and
    -- resets the run, which is what lets a stage cap below 15 loop cleanly.
    -- Gold is always free; purple needs the wins-pad gamepass.
    local plan = { "gold" }
    if cfg.farmMode == "Jackpot" and attr("Pass_winsPad", false) == true then
        plan[#plan + 1] = "purple"
    end
    return plan
end

local function padPosition(w, stage, kind)
    -- deterministic: pads sit at x = ±20, 9 studs past the stage end. The real
    -- model is used for the visual but not for the claim position, so this
    -- keeps working when the pad model is streamed out or absent (stage 15).
    return padWorldPos(w, stage, kind)
end

local function triggerPosition(w, stage, y)
    local o = World.origin(w)
    return Vector3.new(o.X, y, o.Z + World.stageStart(stage) - 4)
end

local function ensureWorld(now)
    local forced = tonumber(cfg.world) or 0
    if forced <= 0 then return true end -- "None": stay in whatever world we are in
    local cur = attr("World", 1)
    if cur == forced then return true end
    if now - farm.worldAskAt > 1.5 then
        farm.worldAskAt = now
        pcall(function() R.Teleport:FireServer(forced) end)
        if now - farm.worldWarnAt > 20 then
            farm.worldWarnAt = now
            notify("World", "Requesting World " .. forced .. " — worlds 2+ need a Stage 15 clear to unlock", 5)
        end
    end
    return false
end

local function buildPadQueue(stage)
    local q = {}
    local w = farmWorld()
    for _, kind in ipairs(padPlan(stage)) do
        local p = padWorldPos(w, stage, kind)
        if p then q[#q + 1] = { kind = kind, pos = p, stage = stage } end
    end
    if stage >= 15 then
        -- Stage 15 has no PadGold/PadPurple model. The client watcher still
        -- accepts a positional claim, but if the server ignores it the stage 14
        -- gold pad lies inside the same scan band and still closes the run.
        for _, kind in ipairs(padPlan(14)) do
            local p = padWorldPos(w, 14, kind)
            if p then q[#q + 1] = { kind = kind, pos = p, stage = 14, fallback = true } end
        end
    end
    return q
end

local function resetFarm()
    farm.phase = "idle"
    farm.lastStage = 0
    farm.padStage = -1
    farm.padQueue, farm.padIndex = {}, 1
    farm.padArriveAt, farm.padRetryAt, farm.padStartAt = 0, 0, 0
    farm.padTeleAt = 0
    farm.holdAt = 0
    farm.stopRetryAt = 0
    farm.nudged = false
    farm.lastClaimAt = 0
    padLock = false
    clearGoal()
end

local function farmTick(now)
    if not cfg.farmOn then
        if farm.phase ~= "idle" then resetFarm() end
        padLock = false
        if not cfg.hatchOn then clearGoal() end
        return
    end
    local root, hum = rootPart(), humanoid()
    if not root or not hum or hum.Health <= 0 then return end
    padLock = false

    local inWave = attr("InWave") == true
    local inStages = attr("InStages") == true
    local runCleared = tonumber(attr("RunCleared", 0)) or 0
    local runStage = tonumber(attr("RunStage", 0)) or 0
    local y = root.Position.Y

    -- Auto Boss outranks stage farming: while a boss is live the farm stands down
    -- completely so the join / close-in / attack loop owns the character, no
    -- matter how far away the player currently is.
    if cfg.bossOn then
        local bp = Workspace:GetAttribute("BossPhase")
        if bp == "countdown" or bp == "fight" then
            clearGoal()
            return
        end
    end

    if not ensureWorld(now) then clearGoal(); return end

    local stopStage = math.clamp(math.floor(tonumber(cfg.stage) or 15), 1, 15)

    -- an active wave owns movement: remember which stage is being fought
    if inWave then
        if farm.phase ~= "fight" then farmNote("wave st=" .. runStage .. " -> fight") end
        farm.phase = "fight"
        farm.lastStage = (runStage > 0) and runStage or math.min(runCleared + 1, 15)
        farm.padArriveAt = 0
        farm.nudged = false
        clearGoal()

        -- Never step on a pad while a wave is live: the client watcher claims
        -- any live pad and pulls us home, ending the run early. Pads are only
        -- visited after the clear in the pads phase below.
        if cfg.padsOn and farm.lastStage >= 1 then
            local gp = padPosition(farmWorld(), farm.lastStage, "gold")
            local pp = padPosition(farmWorld(), farm.lastStage, "purple")
            for _, p in ipairs({ gp, pp }) do
                if p then
                    local dx = math.abs(root.Position.X - p.X)
                    local dz = math.abs(root.Position.Z - p.Z)
                    if dx < 13 and dz < 15 then
                        farmNote("pad avoid st=" .. farm.lastStage)
                        pcall(function()
                            -- Land in the SAME world: origins are offset (world 6
                            -- sits at x=15000). Using x=0 here threw the character
                            -- 15000 studs out of the stage, which the server read
                            -- as leaving the run and reset it to stage 1. Use the
                            -- world origin's X and clamp Z inside the current stage.
                            local w = farmWorld()
                            local o = World.origin(w)
                            local ox = (typeof(o) == "Vector3" and o.X) or root.Position.X
                            local safeZ = p.Z + 24
                            local a, b = stageRectWorld(w, farm.lastStage)
                            if a then
                                safeZ = math.clamp(safeZ, math.min(a.Z, b.Z) + 3, math.max(a.Z, b.Z) - 3)
                            end
                            root.CFrame = CFrame.new(ox, root.Position.Y + 1, safeZ)
                        end)
                        break
                    end
                end
            end
        end
        return
    end

    -- the wave just ended: only the selected stage's pad is worth visiting —
    -- any claim sends the player home and ends the run, so intermediate
    -- stages go straight back to travel without the 1.2s pad probe
    if farm.phase == "fight" then
        if runCleared >= stopStage then
            farm.phase = "pads"
            farm.padStage = stopStage
            farm.padRetryAt, farm.padStartAt = 0, now
            farm.padQueue, farm.padIndex = {}, 1
            farm.padArriveAt = 0
            farm.padTeleAt = 0
            farmNote("wave end -> pads st=" .. farm.padStage .. " cl=" .. runCleared)
        else
            farm.phase = "travel"
            farmNote("wave end -> travel cl=" .. runCleared)
        end
        clearGoal()
    end

    if farm.phase == "pads" then
        -- The run's exit is the selected stage's gold pad. RunCleared, not
        -- RunStage, is the source of truth: RunStage can already point at the
        -- next stage by the time the wave-end attribute lands.
        if not cfg.padsOn or not inStages then
            farmNote("pads skip on=" .. tostring(cfg.padsOn) .. " in=" .. tostring(inStages))
            farm.phase = "travel"
            clearGoal()
            return
        end
        -- Wait 100 ms after the clear registers before touching a pad. The
        -- client's segment watcher evaluates the clear on the frame it lands,
        -- and a pad stepped on inside that window can be seen as a pre-claim.
        if now - farm.padStartAt < 0.1 then
            clearGoal()
            return
        end
        if runCleared < stopStage then
            -- wave-end attributes can land a frame or two late; wait briefly
            if now - farm.padStartAt > 1.2 then
                farmNote("pads not stop st=" .. farm.padStage .. " cl=" .. runCleared)
                farm.phase = "travel"
            end
            clearGoal()
            return
        end
        farm.padStage = stopStage

        -- The client's pad watcher puts a 2-second cooldown on every claim
        -- (u154 = os.clock() + 2 in Client/Gates). A fast farm loop reaches the
        -- pad while that timer is still running, the claim is silently refused,
        -- and the run hangs — the "sometimes it will not claim" stall. Hold at
        -- the stage until the cooldown is safely over, then go for the pad.
        if now - farm.lastClaimAt < 2.05 then
            clearGoal()
            return
        end

        -- Only a real claim (run reset / pivot home, detected below) ends the
        -- phase. An exhausted queue is a retry, not a success, so rebuild it and
        -- keep the goal pinned on the gold pad instead of concluding the phase.
        if #farm.padQueue == 0 or farm.padIndex > #farm.padQueue then
            farm.padQueue = buildPadQueue(farm.padStage)
            farm.padIndex = 1
            farm.padRetryAt = now
            farmNote("pads st=" .. farm.padStage .. " q=" .. #farm.padQueue
                .. (farm.padQueue[1] and (" first=" .. tostring(farm.padQueue[1].pos)) or ""))
        end
        if #farm.padQueue == 0 then
            -- no pad position at all (streamed out / stage 15): give up this pass
            if now - farm.padStartAt > 8 then
                farmNote("pad timeout")
                farm.phase = "travel"
            end
            clearGoal()
            return
        end

        padLock = true
        local cur = farm.padQueue[farm.padIndex]
        -- the client watcher claimed it and sent us home
        if attr("InStages", false) ~= true
            or (tonumber(attr("RunCleared", 0)) or 0) == 0 then
            farmNote("pad claimed")
            farm.lastClaimAt = now
            farm.phase = "hold"
            farm.holdAt = now
            farm.padQueue, farm.padIndex = {}, 1
            clearGoal()
            return
        end
        local d = flatDist(root.Position, cur.pos)
        if d > 120 then
            farmNote("pad home d=" .. math.floor(d))
            farm.lastClaimAt = now
            farm.phase = "hold"
            farm.holdAt = now
            farm.padQueue, farm.padIndex = {}, 1
            clearGoal()
            return
        end
        -- Approach and STEP onto the pad. The client's claim watcher samples the
        -- segment between the last two positions (<=30 studs), so the final
        -- approach is on foot: a long instant teleport skips that segment and can
        -- miss the claim entirely ("it never goes to the gold pad"). We only jump
        -- the bulk of a long gap and stop ~20 studs short, then walk on.
        local onPad = math.abs(root.Position.X - cur.pos.X) <= 7
            and math.abs(root.Position.Z - cur.pos.Z) <= 5
        if onPad then
            -- on the pad: hold so the watcher fires (~100 ms), then the server
            -- returns us to the hub spawn. That return shows up at the top of this
            -- phase as InStages=false / RunCleared==0, which ends the phase.
            if farm.padArriveAt == 0 then
                farm.padArriveAt = now
                farmNote("pad step " .. cur.kind .. " st=" .. tostring(cur.stage))
            end
            if now - farm.padArriveAt > 6.0 then
                farmNote("pad dwell out st=" .. tostring(farm.padStage))
                farm.padArriveAt = 0
                farm.phase = "travel"
            end
        else
            -- jump the bulk of a long gap, but land ~20 studs short so the final
            -- approach is a walked segment the claim watcher can sample
            if d > 26 and now - farm.padTeleAt > 0.25 then
                farm.padTeleAt = now
                local flat = Vector3.new(cur.pos.X - root.Position.X, 0, cur.pos.Z - root.Position.Z)
                if flat.Magnitude > 0.05 then
                    local stop = cur.pos - flat.Unit * 20
                    farmNote("pad hop " .. cur.kind .. " d=" .. math.floor(d))
                    pcall(function() root.CFrame = CFrame.new(stop.X, root.Position.Y + 2, stop.Z) end)
                end
            end
            setGoal(cur.pos) -- walk the rest so the segment check fires on contact
        end
        return
    end

    -- run ended at the selected stage: sit at the hub until the reset, then restart
    if farm.phase == "hold" then
        if attr("InStages") ~= true and (tonumber(attr("RunCleared", 0)) or 0) == 0 then
            farmNote("hold done")
            farm.padStage = -1
            farm.padQueue, farm.padIndex = {}, 1
            farm.phase = "travel"
        elseif now - farm.holdAt > 8 then
            farmNote("hold timeout")
            farm.phase = "travel"
        else
            local o = World.origin(farmWorld())
            local home = Vector3.new(o.X, y, o.Z + 46)
            setGoal(home)
            if flatDist(root.Position, home) > 14 and now - farm.hopAt > 0.6 then
                farm.hopAt = now
                pcall(function() root.CFrame = CFrame.new(home.X, y + 2, home.Z) end)
            end
            return
        end
    end

    -- travel to the next stage trigger (the server starts the wave)
    if farm.phase ~= "travel" then farmNote("travel cl=" .. runCleared) end
    farm.phase = "travel"
    -- never farm past the selected stage: its gold pad is the run's exit.
    -- If the pads phase was skipped or timed out, retry the claim instead.
    if runCleared >= stopStage then
        clearGoal()
        if cfg.padsOn and inStages and runCleared == stopStage and now - farm.stopRetryAt > 0.8 then
            farm.stopRetryAt = now
            farm.padStage = stopStage
            farm.padQueue, farm.padIndex = {}, 1
            farm.padStartAt = now
            farm.padRetryAt = 0
            farm.phase = "pads"
            farmNote("stop retry st=" .. stopStage)
        end
        return
    end
    local goalStage = runCleared + 1
    local goal = triggerPosition(farmWorld(), goalStage, y)
    setGoal(goal)

    -- instant travel: teleport straight to the next trigger instead of walking
    if not combatBusy and now - farm.hopAt > 0.25 then
        local dGoal = flatDist(root.Position, goal)
        if dGoal > 14 then
            farm.hopAt = now
            farmNote("tp " .. math.floor(dGoal))
            pcall(function() root.CFrame = CFrame.new(goal.X, y + 2, goal.Z - 6) end)
            return
        end
    end

    -- standing on the trigger with no wave: nudge deeper once
    if not combatBusy and flatDist(root.Position, goal) < 4 then
        if not farm.nudged then
            farm.nudged, farm.nudgeAt = true, now
        elseif now - farm.nudgeAt > 1.5 then
            farm.nudged = false
            farmNote("nudge")
            pcall(function() root.CFrame = CFrame.new(goal.X, y + 1, goal.Z - 10) end)
        end
    else
        farm.nudged = false
    end
end

-- ═══════════════════════ boss ════════════════════════════════════════
local bossJoinAt = 0
local bossReturn = nil        -- { pos = CFrame, world = n } captured before the first join
local bossActiveSeen = false  -- true once we saw countdown/fight this cycle
local bossEndedAt = 0
local reviveAt = 0

local function bossTick(now)
    if not cfg.bossOn then return end
    local phase = Workspace:GetAttribute("BossPhase")
    if phase == "countdown" or phase == "fight" then
        if not bossActiveSeen then
            bossActiveSeen = true
            bossEndedAt = 0
            local r0 = rootPart()
            if r0 then
                bossReturn = { pos = r0.CFrame, world = tonumber(attr("World", 1)) or 1 }
            end
        end
        local root = rootPart()
        if not root then return end
        local c, arenaR = bossArena()
        if flatDist(root.Position, c) < arenaR then return end -- already in the arena
        if now - bossJoinAt > 0.4 then
            bossJoinAt = now
            pcall(function() R.Boss:FireServer("join") end)
        end
        return
    end
    -- phase left countdown/fight: the boss is dead or the event is over
    if bossActiveSeen then
        bossActiveSeen = false
        bossEndedAt = now
    end
end

-- Decline the revive prompt and send the player back to the lobby. The stage
-- prompt answers Revive("no"); the boss prompt answers Boss("home") because its
-- No button calls the boss controller instead of the stage one.
local function clickGuiButton(btn)
    if not (btn and btn:IsA("GuiButton")) then return false end
    local clicked = false
    if type(getconnections) == "function" then
        local okc, conns = pcall(getconnections, btn.Activated)
        if okc and type(conns) == "table" then
            for _, c in ipairs(conns) do
                local fn = c.Function
                if type(fn) == "function" then
                    if pcall(fn) then clicked = true end
                end
            end
        end
    end
    if not clicked then
        local okc, conns = pcall(getconnections, btn.MouseButton1Click)
        if okc and type(conns) == "table" then
            for _, c in ipairs(conns) do
                local fn = c.Function
                if type(fn) == "function" then
                    if pcall(fn) then clicked = true end
                end
            end
        end
    end
    if not clicked then
        local env = (type(getfenv) == "function") and getfenv() or nil
        local fireSignal = env and env.firesignal
        if type(fireSignal) == "function" then
            pcall(fireSignal, btn.Activated)
            clicked = true
        end
    end
    return clicked
end

local function reviveTick(now)
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    local rev = pg and pg:FindFirstChild("Revive")
    if not rev or not rev.Enabled then return end
    if now - reviveAt < 0.35 then return end
    reviveAt = now
    local panel = rev:FindFirstChild("Panel")
    local noBtn = panel and panel:FindFirstChild("No")
    if noBtn and clickGuiButton(noBtn) then
        -- fall through: if the game still shows the prompt next tick we will
        -- try the explicit remote below as a second line of attack
    end
    local title = panel and panel:FindFirstChild("Title")
    local bossPrompt = title and title:IsA("TextLabel") and title.Text == "KNOCKED OUT!"
    if not bossPrompt then
        local phase = Workspace:GetAttribute("BossPhase")
        local root = rootPart()
        if (phase == "countdown" or phase == "fight") and root then
            local c, arenaR = bossArena()
            bossPrompt = flatDist(root.Position, c) < arenaR + 80
        end
    end
    if bossPrompt then
        pcall(function() R.Boss:FireServer("home") end)
    else
        pcall(function() R.Revive:FireServer("no") end)
    end
end

-- After the boss dies (or the event ends) Auto Boss leaves the player wherever
-- the game put them. There is deliberately no teleport back to the pre-join
-- spot: the revive prompt is declined by reviveTick and the rest is the game's
-- own lobby / respawn handling.
local function bossReturnTick(now)
    if not bossReturn or bossEndedAt == 0 then return end
    if now - bossEndedAt < 4 then return end
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    local rev = pg and pg:FindFirstChild("Revive")
    if rev and rev.Enabled then return end
    if attr("Downed", false) == true or not rootPart() then return end
    bossReturn = nil
end

-- ═══════════════════════ economy ticks ═══════════════════════════════
local timerState = {
    rebirth = 0, hatch = 0, sell = 0, equip = 0, eyes = 0, aura = 0,
    title = 0, errAt = 0, hatchBusy = false, sellBusy = false,
    eggTpAt = 0, eggWarnAt = 0,
}
-- worlds whose Auto Multi rebirth target has already been reported, so the
-- "completed" notice fires once per world instead of on every re-enable
local rebirthDone = {}

local function eggIndexFor(world, eggId)
    local ok, list = pcall(function() return PetsCfg.eggsFor(world) end)
    if not ok or type(list) ~= "table" then return nil end
    for i, e in ipairs(list) do
        if type(e) == "table" and e.id == eggId then return i end
    end
    return nil
end

-- the server rejects hatches farther than World.EGG_REACH (7) from the egg
local function firstEggPart(model)
    if not model then return nil end
    if model:IsA("BasePart") then return model end
    local part = model:FindFirstChild("Egg", true)
    if part and part:IsA("BasePart") then return part end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end

local function eggStand(world, idx)
    -- World.EGGS holds the local stand positions (x=60,84,108,132; z=30) for
    -- every world, so reward eggs stay reachable even when the map is streaming
    local localPos = World.EGGS and World.EGGS[idx]
    if typeof(localPos) == "Vector3" then
        local o = World.origin(world)
        if typeof(o) == "Vector3" then
            return Vector3.new(o.X + localPos.X, localPos.Y + 3.5, o.Z + localPos.Z + 4)
        end
    end
    local mapName = (world == 1) and "Map" or ("Map" .. tostring(world))
    local map = Workspace:FindFirstChild(mapName)
    local hub = map and map:FindFirstChild("Hub")
    if not hub then
        -- world 1 geometry is fixed even if the map is still streaming
        if world == 1 then
            if idx == 1 then return Vector3.new(60, 3, 34) end
            if idx == 2 then return Vector3.new(84, 3, 34) end
        end
        return nil
    end
    local model = hub:FindFirstChild("Egg" .. tostring(idx))
    if not model then
        local platform = hub:FindFirstChild("EggPlatform")
        model = platform and platform:FindFirstChild("Egg" .. tostring(idx))
    end
    if not model then
        model = hub:FindFirstChild("Egg" .. tostring(idx), true)
    end
    local part = firstEggPart(model)
    if part then
        local p = part.Position
        return Vector3.new(p.X, p.Y - 3.5, p.Z + 4)
    end
    if world == 1 then
        if idx == 1 then return Vector3.new(60, 3, 34) end
        if idx == 2 then return Vector3.new(84, 3, 34) end
    end
    return nil
end

-- dropdown labels that differ from the stored value
uiHooks.display = {
    stage = function() return tostring(cfg.stage) end,
    world = function()
        return (tonumber(cfg.world) or 0) <= 0 and "None" or tostring(cfg.world)
    end,
    eggWorld = function()
        return (tonumber(cfg.eggWorld) or 0) <= 0 and "None" or tostring(cfg.eggWorld)
    end,
    farmMode = function()
        return (cfg.farmMode == "Jackpot" and "Jackpot 1-15")
            or (cfg.farmMode == "Smart" and "Smart Continuous")
            or cfg.farmMode
    end,
}

-- push the live cfg back into every registered widget (named-config load)
function uiHooks.refresh()
    for key, el in pairs(uiHooks) do
        if type(el) == "table" and type(el.__type) == "string" and cfg[key] ~= nil then
            local ok, value = pcall(function()
                local fn = uiHooks.display[key]
                return fn and fn() or cfg[key]
            end)
            if ok and value ~= nil then
                pcall(function()
                    if el.__type == "Dropdown" then
                        local present = false
                        if type(el.Values) == "table" then
                            for _, v in ipairs(el.Values) do
                                if v == value then present = true end
                            end
                        end
                        if present then el:Select(value) end
                    elseif el.__type == "Toggle" then
                        el:Set(value == true)
                    elseif el.__type == "Slider" then
                        el:Set(tonumber(value) or 0)
                    elseif el.__type == "Input" then
                        el:Set(tostring(value))
                    end
                end)
            end
        end
    end
end

-- how far the player has unlocked: world w opens once the previous world is
-- cleared to Stage 15 — the game's own WorldGate rule, read from BestStage*
local function bestStageOf(w)
    local name = (w == 1) and "BestStage" or ("BestStage" .. tostring(w))
    return math.floor(tonumber(attr(name, 0)) or 0)
end

local function furthestWorld()
    local f = 1
    pcall(function() f = WorldGate.furthest(WorldsCfg, bestStageOf) end)
    return math.clamp(math.floor(tonumber(f) or 1), 1, 9)
end

-- Highest training-plot requirement in a world, as the plot signs display it.
-- Auto Rebirth stops once the player can reach that world's best Auto Multi
-- plot (e.g. World 6 = 430, not the raw 465 config value).
local function multiMaxReq(world)
    local list = TrainingCfg[world]
    local best = 0
    if type(list) == "table" then
        for _, plot in ipairs(list) do
            local req = plotReq(plot.req)
            if req > best then best = req end
        end
    end
    return best
end

local function rebirthTick(now)
    if not cfg.rebirthOn or now < timerState.rebirth then return end
    timerState.rebirth = now + 0.6

    -- Auto Rebirth is pointless without Auto Multi — the training plot is what
    -- earns the rebirths. Turning Rebirth on therefore also turns Multi on.
    -- Turning Rebirth off deliberately leaves Multi on (the toggle mirror here
    -- is one-way): the user turns Multi off when they want it off.
    if not cfg.multiOn then
        cfg.multiOn = true
        local mui = uiHooks.multiToggle
        if mui and type(mui.Set) == "function" then
            uiRun(function() mui:Set(true) end)
        end
    end

    -- Target the furthest UNLOCKED world's Auto Multi ceiling rather than the
    -- world we happen to stand in, and never let a forced farm world lower it:
    -- farming World 4 while World 5 was unlocked used to stop rebirth at World
    -- 4's ceiling (298/298) and flip the toggle straight back off, so Auto
    -- Rebirth looked impossible to use. Re-enabling it after the next world
    -- unlocks resumes there.
    local w = math.max(tonumber(attr("World", 1)) or 1, furthestWorld())
    local target = multiMaxReq(w)
    local rebirths = tonumber(attr("Rebirths", 0)) or 0

    -- reached this world's Auto Multi ceiling: stop and report it once
    if target > 0 and rebirths >= target then
        if not rebirthDone[w] then
            rebirthDone[w] = true
            notify("Rebirth", "Rebirth World " .. tostring(w) .. " completed ("
                .. tostring(rebirths) .. "/" .. tostring(target)
                .. ") — turn it on again after the next world unlocks", 6)
        end
        cfg.rebirthOn = false
        pcall(function() R.AutoRebirth:InvokeServer(false) end)
        local ui = uiHooks.rebirthToggle
        if ui and type(ui.Set) == "function" then
            uiRun(function() ui:Set(false) end)
        end
        return
    end
    rebirthDone[w] = false

    local lvl, need = attr("Level", 0), attr("RebirthLevel", 0)
    if need > 0 and lvl >= need then
        local ok = pcall(function() return R.Rebirth:InvokeServer() end)
        if ok then
            notify("Rebirth", "Rebirth " .. tostring(rebirths + 1) .. "/" .. tostring(target)
                .. " — World " .. tostring(w), 3)
        end
    end
    if attr("AutoRebirthOn", false) ~= true then
        pcall(function() R.AutoRebirth:InvokeServer(true) end)
    end
end

local function freeEggMap()
    local raw = attr("FreeEggs", nil)
    if type(raw) == "table" then return raw end
    if type(raw) == "string" and raw ~= "" then
        local ok, t = pcall(function() return HttpService:JSONDecode(raw) end)
        if ok and type(t) == "table" then return t end
    end
    return {}
end

local function freeEggPick()
    local map = freeEggMap()
    if type(map) ~= "table" then return nil end
    if type(map[1]) == "string" then return map[1], 1, 1 end
    local bestId, bestN, total = nil, 0, 0
    for id, n in pairs(map) do
        local num = tonumber(n) or 0
        if type(id) == "string" and num > 0 then
            total = total + num
            if num > bestN then bestId, bestN = id, num end
        end
    end
    return bestId, bestN, total
end

local function hatchTick(now)
    -- Auto Boss outranks egg hatching: never teleport out of a live boss fight
    if cfg.bossOn then
        local bp = Workspace:GetAttribute("BossPhase")
        if bp == "countdown" or bp == "fight" then return end
    end
    if not cfg.hatchOn or cfg.eggId == "" then return end
    local w = tonumber(cfg.eggWorld) or 0
    if w <= 0 then w = tonumber(attr("World", 1)) or 1 end
    local idx = eggIndexFor(w, cfg.eggId)
    if not idx then return end
    if attr("InStages", false) == true then return end

    if curWorldId() ~= w then
        if now - timerState.eggTpAt > 1.0 then
            timerState.eggTpAt = now
            pcall(function() R.Teleport:FireServer(w) end)
            if now - timerState.eggWarnAt > 20 then
                timerState.eggWarnAt = now
                notify("Egg Hatch", "Teleporting to World " .. w .. " for the egg", 3)
            end
        end
        return
    end

    local stand = eggStand(w, idx)
    if not stand then return end
    local root = rootPart()
    if not root then return end
    if flatDist(root.Position, stand) > 5 then
        -- the farm owns movement when it is running; otherwise teleport to it
        if not cfg.farmOn and now - timerState.eggTpAt > 0.3 then
            timerState.eggTpAt = now
            pcall(function() root.CFrame = CFrame.new(stand.X, root.Position.Y + 2, stand.Z) end)
        end
        return
    end
    if not cfg.farmOn then clearGoal() end
    if timerState.hatchBusy or now < timerState.hatch then return end

    local delay = math.clamp(tonumber(cfg.hatchDelay) or 0.25, 0.1, 2)
    timerState.hatch = now + delay
    local count = math.clamp(math.floor(tonumber(cfg.hatchCount) or 1), 1, 3)
    local egg = cfg.eggId
    timerState.hatchBusy = true
    task.spawn(function()
        local ok, data, msg = pcall(function()
            return R.PetAction:InvokeServer("hatch", { egg = egg, count = count })
        end)
        timerState.hatchBusy = false
        if ok and type(msg) == "string" and msg ~= "" and now - timerState.errAt > 20 then
            timerState.errAt = now
            notify("Egg Hatch", msg, 3)
        end
    end)
end

local function equipBestTick(now)
    if not cfg.equipOn or now < timerState.equip then return end
    timerState.equip = now + 5
    pcall(function() R.PetAction:InvokeServer("equipBest") end)
end

local function sellTick(now)
    if not cfg.sellOn or timerState.sellBusy or now < timerState.sell then return end
    timerState.sell = now + 0.4

    local pets = decode(attr("Pets", "[]"), {})
    local n = 0
    for _ in pairs(pets) do n = n + 1 end
    local space = tonumber(attr("PetSpace", 30)) or 30
    if n < space - 2 then return end

    local tiers = decode(attr("PetTiers", "{}"), {})
    local equipped = decode(attr("Equipped", "[]"), {})
    local locked = decode(attr("LockedPets", "[]"), {})
    local skip = {}
    for k, v in pairs(equipped) do
        if v == true then skip[tostring(k)] = true else skip[tostring(v)] = true end
    end
    for k, v in pairs(locked) do
        if v == true then skip[tostring(k)] = true else skip[tostring(v)] = true end
    end

    local world = attr("World", 1)
    local cand = {}
    for uid, petId in pairs(pets) do
        if not skip[tostring(uid)] then
            local mult = 0
            pcall(function() mult = Fuse.multOf(pets, tiers, uid, world) end)
            cand[#cand + 1] = { uid = uid, mult = mult }
        end
    end
    table.sort(cand, function(a, b)
        if a.mult ~= b.mult then return a.mult < b.mult end
        return tostring(a.uid) < tostring(b.uid)
    end)

    -- keep 10 free slots so the hatch loop never stalls on a full inventory
    local target = math.max(10, space - 10)
    local toDelete = math.min(n - target, #cand, 10)
    if toDelete <= 0 then return end
    timerState.sellBusy = true
    local batch = {}
    for i = 1, toDelete do batch[#batch + 1] = cand[i].uid end
    task.spawn(function()
        for _, uid in ipairs(batch) do
            pcall(function() R.PetAction:InvokeServer("delete", { uid }) end)
        end
        timerState.sellBusy = false
    end)
end

-- Auto Multi: stand on the highest-multiplier training plot the player has
-- unlocked. Training multiplier is a plot attribute (TrainSpot/TrainMult) and
-- clears the moment the character leaves the plot, so staying put is required.
local multiState = { spot = 0, world = 0, nextTp = 0, noteAt = 0 }

local function trainingPassOwned(key)
    if key == nil or key == "" then return true end
    return attr("Pass_" .. tostring(key), false) == true
end

local function pickTrainingIn(world, rebirths)
    local list = TrainingCfg[world] or TrainingCfg[1]
    if type(list) ~= "table" then return nil, nil end
    local best, bestPlot = nil, nil
    for i, plot in ipairs(list) do
        -- compare the requirement the way the game does: the plot sign's
        -- plotRebirths(...) value, not the raw config number.
        if type(plot) == "table" and plotReq(plot.req) <= rebirths and trainingPassOwned(plot.pass) then
            if not bestPlot or plot.mult > bestPlot.mult
                or (plot.mult == bestPlot.mult and plot.req > bestPlot.req) then
                best, bestPlot = i, plot
            end
        end
    end
    return best, bestPlot
end

-- highest-mult plot the Rebirths qualify for, scanning every unlocked world
local function pickBestTraining(rebirths)
    local maxW = furthestWorld()
    local bw, bi, bp = nil, nil, nil
    for w = 1, maxW do
        local i, plot = pickTrainingIn(w, rebirths)
        if i and plot and (not bp or plot.mult > bp.mult) then
            bw, bi, bp = w, i, plot
        end
    end
    return bw, bi, bp, maxW
end

local function multiTick(now)
    if not (cfg.trainOn and cfg.multiOn) then
        multiState.spot = 0
        multiState.world = 0
        return
    end
    if cfg.farmOn or cfg.hatchOn then return end
    if attr("InStages", false) == true then return end
    local root, hum = rootPart(), humanoid()
    if not root or not hum or hum.Health <= 0 then return end
    if attr("InWave", false) == true or attr("Downed", false) == true then return end
    local bp = Workspace:GetAttribute("BossPhase")
    if bp == "countdown" or bp == "fight" then return end

    local rebirths = tonumber(attr("Rebirths", 0)) or 0
    local w, idx, plot = pickBestTraining(rebirths)
    if not w or not idx then return end
    local localPos = World.TRAINING[idx]
    if typeof(localPos) ~= "Vector3" then return end

    -- the best plot can sit in a different unlocked world: switch to it, then
    -- stand on the plot. World changes only happen while Auto Multi is on.
    local curW = tonumber(attr("World", 1)) or 1
    multiState.world = w
    if curW ~= w then
        if now - multiState.nextTp >= 0.5 then
            multiState.nextTp = now
            clearGoal()
            pcall(function() R.Teleport:FireServer(w) end)
            if now - multiState.noteAt > 8 then
                multiState.noteAt = now
                notify("Auto Multi", "World " .. w .. " — " .. tostring(plot.name)
                    .. " (x" .. shortNum(plot.mult) .. ")", 4)
            end
        end
        return
    end

    local target = World.origin(w) + localPos
    local dist = flatDist(root.Position, target)
    local onSpot = tonumber(attr("TrainSpot", 0)) == idx

    if onSpot and dist < 12 then
        multiState.spot = idx
        clearGoal()
        return
    end
    if dist < 8 and multiState.spot == idx then return end -- arrived, waiting for the attribute

    if now - multiState.nextTp >= 0.35 then
        multiState.nextTp = now
        clearGoal()
        pcall(function() root.CFrame = CFrame.new(target.X, 5, target.Z) end)
        if now - multiState.noteAt > 8 then
            multiState.noteAt = now
            notify("Auto Multi", string.format(
                "%s (x%s) — needs %d rebirths",
                tostring(plot.name), shortNum(plot.mult), plotReq(plot.req)), 4)
        end
    end
end

-- Gifts: the 5 / 15 / 60 minute playtime rewards go through ClaimReward with
-- the reward INDEX (the game's own menu passes i from its Rewards loop, not
-- the id string). Availability is derived from JoinedAt and RewardsClaimed,
-- so the remote is only touched when a gift is actually claimable.
local giftList = {}
do
    local ok, list = pcall(function() return require(Shared.Config.Rewards) end)
    if ok and type(list) == "table" then
        for i, r in ipairs(list) do
            if type(r) == "table" and tonumber(r.minutes) and tonumber(r.max) then
                giftList[#giftList + 1] = {
                    index = i,
                    id = tostring(r.id or i),
                    minutes = tonumber(r.minutes),
                    max = tonumber(r.max),
                }
            end
        end
    end
end
local giftIndex, giftNextAt = 1, 0
local giftRetryAt = {}

local function giftAvail(meta)
    local claimedStr = tostring(attr("RewardsClaimed", "") or "")
    local claimed = tonumber((string.split(claimedStr, ","))[meta.index]) or 0
    local joined = tonumber(attr("JoinedAt", 0)) or 0
    if joined <= 0 then return 0 end
    local played = Workspace:GetServerTimeNow() - joined
    local ready = math.min(meta.max, math.floor(played / (meta.minutes * 60)))
    return math.max(0, ready - claimed)
end

local function giftTick(now)
    if not cfg.giftOn or #giftList == 0 or now < giftNextAt then return end
    giftNextAt = now + 4
    local meta = giftList[giftIndex]
    giftIndex = (giftIndex % #giftList) + 1
    if now < (giftRetryAt[meta.index] or 0) then return end
    if giftAvail(meta) <= 0 then return end
    giftRetryAt[meta.index] = now + 3
    task.spawn(function()
        local ok, claimed, _, msg = pcall(function()
            return R.ClaimReward:InvokeServer(meta.index)
        end)
        if ok and claimed == true then
            notify("Gift", "Claimed the " .. meta.id .. " reward", 4)
        elseif ok and type(msg) == "string" and msg ~= "" and msg ~= "Slow down" then
            notify("Gift", meta.id .. ": " .. msg, 3)
        end
    end)
end

-- ── eye / aura comparison ─────────────────────────────────────────────
-- Boss-shop eyes carry a per-world `mults` table, so every comparison goes
-- through Eyes.multIn(eye, world) instead of the flat `eye.mult` field.
local eyeState = { mode = "mult", bestId = nil, bestScore = 0, curScore = 0 }

local function eyeMultOf(eye, world)
    if type(eye) ~= "table" then return 0 end
    if type(Eyes.multIn) == "function" then
        local ok, m = pcall(Eyes.multIn, eye, world)
        if ok and type(m) == "number" then return m end
    end
    return tonumber(eye.mult) or 0
end

local function abilityDps(id)
    local ab = id and abilById[id]
    if type(ab) ~= "table" then return 0 end
    local power, cd = tonumber(ab.power), tonumber(ab.cooldown)
    if not power or not cd or cd <= 0 then return 0 end
    return power / cd
end

-- Sustained attack DPS plus a 30-second burst allowance for E and R. Attack
-- DPS dominates, so a high-mult utility eye does not win a fight slot.
local function eyeCombatScore(eye)
    if type(eye) ~= "table" then return 0 end
    return abilityDps(eye.attack)
        + abilityDps(eye.skillE) / 30
        + abilityDps(eye.skillR) / 30
end

local function inCombatNow()
    if attr("InWave", false) == true then return true end
    local bp = Workspace:GetAttribute("BossPhase")
    if bp == "countdown" or bp == "fight" then return true end
    if attr("Downed", false) == true then return false end
    if cfg.combatOn or cfg.farmOn or cfg.bossOn then
        local ok, list = pcall(EnemiesMod.list)
        if ok and type(list) == "table" and #list > 0 then return true end
    end
    return false
end

local function eyesTick(now)
    if now < timerState.eyes then return end
    timerState.eyes = now + 2
    if not (cfg.unlockEyes or cfg.equipEyes) then return end

    local owned = decode(attr("Eyes", "{}"), {})
    local wins = attr("Wins", 0)
    local byId = Eyes.byId or {}

    if cfg.equipEyes then
        local world = curWorldId()
        local combat = inCombatNow()
        eyeState.mode = combat and "combat" or "mult"
        local curId = tostring(attr("Eye", Eyes.STARTER) or "")
        local curEye = byId[curId]
        local bestId, bestScore = nil, -math.huge
        for id, eye in pairs(byId) do
            if type(eye) == "table" and owned[id] then
                local score = combat and eyeCombatScore(eye) or eyeMultOf(eye, world)
                if type(score) == "number" and score > bestScore then
                    bestId, bestScore = id, score
                end
            end
        end
        local curScore = 0
        if type(curEye) == "table" then
            curScore = combat and eyeCombatScore(curEye) or eyeMultOf(curEye, world)
        end
        eyeState.bestId, eyeState.bestScore, eyeState.curScore = bestId, bestScore, curScore
        if bestId and bestId ~= curId then
            -- 2% in training, 3% in combat: keeps gear stable across world ticks
            local margin = combat and 0.03 or 0.02
            if curScore <= 0 or bestScore > curScore * (1 + margin) then
                pcall(function() R.Equip:FireServer(bestId) end)
            end
        end
    end

    if cfg.unlockEyes then
        local afford = nil
        for id, eye in pairs(byId) do
            if type(eye) == "table" and not owned[id]
                and type(eye.wins) == "number" and eye.wins > 0
                and wins >= eye.wins and not eye.pass and not eye.boss then
                if not afford or eye.wins < afford.wins then
                    afford = { id = id, wins = eye.wins }
                end
            end
        end
        if afford then
            pcall(function() R.UnlockEye:FireServer(afford.id) end)
        end
    end
end

-- ── aura comparison ───────────────────────────────────────────────────
local auraState = { bestId = nil, bestMult = 0, curMult = 0 }

local function auraMultOf(a, world, owned)
    if type(a) ~= "table" then return 0 end
    local ownsFn = function(x) return x ~= nil and owned[x.id] and true or false end
    if type(AuraCfg.multFor) == "function" then
        local ok, m = pcall(AuraCfg.multFor, a, world, ownsFn)
        if ok and type(m) == "number" then return m end
    end
    if type(AuraCfg.multIn) == "function" then
        local ok, m = pcall(AuraCfg.multIn, a, world)
        if ok and type(m) == "number" then return m end
    end
    return tonumber(a.mult) or 0
end

local function auraTick(now)
    if not cfg.equipAura or now < timerState.aura then return end
    timerState.aura = now + 2
    local owned = decode(attr("OwnedAuras", "{}"), {})
    if type(owned) ~= "table" then return end
    local world = curWorldId()
    local bestId, bestMult = nil, -math.huge
    for id, v in pairs(owned) do
        local a = AuraById[id]
        if v and a then
            local m = auraMultOf(a, world, owned)
            if type(m) == "number" and m > bestMult then
                bestId, bestMult = id, m
            end
        end
    end
    if not bestId then return end
    auraState.bestId, auraState.bestMult = bestId, bestMult

    local cur = tostring(attr("Aura", ""))
    if cur == "" or cur == "none" then
        auraState.curMult = 0
        pcall(function() R.EquipAura:InvokeServer(bestId) end)
        return
    end
    local curAura = AuraById[cur]
    if not curAura then return end -- unknown/event aura: never touch it
    local curMult = auraMultOf(curAura, world, owned)
    auraState.curMult = curMult
    -- never downgrade: only swap when the best owned aura beats what is on
    if bestMult > curMult * 1.005 + 0.001 then
        pcall(function() R.EquipAura:InvokeServer(bestId) end)
    end
end

-- Auto Equip Best Title: TitleList.all is already sorted highest-rank first, so
-- the first entry the player owns is the best title on offer. The pick is saved
-- through the game's own PickTitle remote.
local function equipTitleTick(now)
    if not cfg.equipTitle or now < timerState.title then return end
    timerState.title = now + 5
    local owned = TitleList.decode(attr("OwnedTitles", "") or "")
    if type(owned) ~= "table" then return end
    local bestId
    for _, t in ipairs(TitleList.all) do
        if type(t) == "table" and owned[t.id] then
            bestId = t.id
            break
        end
    end
    if not bestId then return end
    if tostring(attr("TitlePick", "")) == bestId then return end
    local ok = pcall(function() R.PickTitle:InvokeServer(bestId) end)
    if ok then notify("Title", "Equipped " .. tostring(bestId), 3) end
end

-- ═══════════════════════ Discord reporter ═════════════════════════════
-- One message per webhook: the first send POSTs with wait=true, every later
-- update PATCHes that same message id, so the channel never fills with copies.
-- Coins map to the game's own labels: Kyubi = KuramaCoins, Menoz = MenosCoins.
-- Everything below (reporter, UI and driver) lives in one function so the main
-- chunk stays under Luau's 200-local limit; the systems above become upvalues.
local function boot()
local BOSS_LABEL = { kyubi = "KYUBI · Kurama", menos = "MENOZ" }
local whPara = nil

local function fmtInt(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local sign = ""
    if s:sub(1, 1) == "-" then sign, s = "-", s:sub(2) end
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = out:gsub("^,", "")
    return sign .. out
end

local function agoText(ts)
    local d = math.max(0, os.time() - (tonumber(ts) or 0))
    if d < 5 then return "just now" end
    if d < 60 then return d .. "s ago" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then
        return math.floor(d / 3600) .. "h " .. math.floor((d % 3600) / 60) .. "m ago"
    end
    return math.floor(d / 86400) .. "d ago"
end

local function durationText(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return sec .. "s"
end

local function prettyId(id)
    id = tostring(id or "?")
    id = id:gsub("_", " ")
    return (id:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

local function defName(def, id)
    if type(def) == "table" then
        local n = def.name or def.display or def.title
        if type(n) == "string" and n ~= "" then return n end
    end
    return prettyId(id)
end

local function webhookParts(url)
    url = tostring(url or "")
    local id, token = url:match("/api/webhooks/(%d+)/([%w%-_]+)")
    if id and token then return id, token end
    return nil
end

local wh = {
    busy = false,
    nextAt = os.clock() + 5,
    messageId = nil,
    lastBoss = nil,
    bossActive = false,
    bossSnap = nil,
    bossResult = nil,     -- exact reward table pushed on the Boss remote
    drops = nil,          -- raw BossDrop pushes for the current fight
    fightEndAt = nil,     -- when the phase left the fight (finalize grace)
    bossConn = nil,
    dropConn = nil,
    lastOk = 0,
    lastErr = nil,
    urlWarnAt = 0,
    wasOff = nil,
}

local function saveWhState()
    writeJsonFile(WH_FILE, {
        url = tostring(cfg.webhookUrl or ""),
        messageId = wh.messageId,
        lastBoss = wh.lastBoss,
        savedAt = os.time(),
    })
end

do
    local st = readJsonFile(WH_FILE)
    if type(st) == "table" then
        if type(st.lastBoss) == "table" then wh.lastBoss = st.lastBoss end
        if type(st.url) == "string"
            and st.url == tostring(cfg.webhookUrl or "")
            and type(st.messageId) == "string" then
            wh.messageId = st.messageId
        end
    end
end

local function bossShare()
    -- BossBoard is a JSON *string*, decoded here into {id, name, share} rows
    -- with share a 0..1 fraction of the damage dealt. The old code compared the
    -- raw string against a table, so it always fell through to nil ("share n/a").
    local board = decode(Workspace:GetAttribute("BossBoard"), nil)
    if type(board) ~= "table" then return nil end
    local me = LP.UserId
    for _, row in ipairs(board) do
        if type(row) == "table" and tonumber(row.id) == me then
            local s = tonumber(row.share)
            if s then return s * 100 end
        end
    end
    return nil
end

local function bossSnapshot()
    return {
        kurama = tonumber(attr("KuramaCoins", 0)) or 0,
        menos = tonumber(attr("MenosCoins", 0)) or 0,
        wins = tonumber(attr("Wins", 0)) or 0,
        bossWins = tonumber(attr("BossWins", 0)) or 0,
        kind = tostring(Workspace:GetAttribute("BossKind") or "kyubi"):lower(),
        at = os.time(),
    }
end

-- ── exact boss reward capture ─────────────────────────────────────────
-- When a fight ends the server pushes the reward on the Boss remote:
--   {t = "result", won, coins, dmg, part, base, bonus, vip, total, fair, cur}
-- Events arrive batched (a final hit, the "end" marker and the "result" table
-- can share one push), so every element handed to the hook is dispatched.
-- This is the ground truth for "what I got" and "what I dealt"; the coin-delta
-- snapshot is kept only as a fallback for a fight that ended before we loaded.
local function kindOf(v)
    return tostring(v or Workspace:GetAttribute("BossKind") or "kyubi"):lower()
end

local function applyResult(e)
    wh.bossResult = {
        won = e.won == true,
        coins = math.max(0, math.floor(tonumber(e.coins) or 0)),
        dmg = tonumber(e.dmg),
        part = tonumber(e.part),
        base = tonumber(e.base),
        bonus = tonumber(e.bonus),
        vip = tonumber(e.vip),
        total = tonumber(e.total),
        fair = e.fair == true,
        kind = kindOf(e.cur),
        at = os.time(),
    }
    wh.fightEndAt = wh.fightEndAt or os.time()
end

-- Flatten one delivery into individual event/item tables, then hand each to `fn`.
local function eachEvent(fn)
    return function(...)
        local function visit(v)
            if type(v) ~= "table" then return end
            if v.t ~= nil then
                fn(v)
            elseif #v > 0 then
                for _, e in ipairs(v) do visit(e) end
            else
                fn(v)
            end
        end
        for i = 1, select("#", ...) do visit((select(i, ...))) end
    end
end

local onBossResult = eachEvent(function(e)
    if tostring(e.t) == "result" then applyResult(e) end
end)

-- BossDrop pushes {t = "mine", drops = {{id, coins, dup, luck}, ...}} for loot
-- won by this player (and t = "other"/"jackpot" for everyone else, which we
-- ignore). The drop registry only defines six ids, so names live here rather
-- than pulling in another config module for six strings.
local DROP_INFO = {
    fox_slayer    = { name = "FOX SLAYER", what = "title" },
    dark_kyubi    = { name = "Dark Kyubi", what = "aura" },
    shadow_kyubi  = { name = "Shadow Kyubi", what = "mythic pet" },
    hollow_hunter = { name = "HOLLOW HUNTER", what = "title" },
    hollowfication = { name = "Hollowfication", what = "aura" },
    vasto_beast   = { name = "Vasto Beast", what = "mythic pet" },
}

local onBossDrop = eachEvent(function(e)
    if tostring(e.t) ~= "mine" or type(e.drops) ~= "table" then return end
    for _, d in ipairs(e.drops) do
        if type(d) == "table" and type(d.id) == "string" and d.id ~= "" then
            wh.drops = wh.drops or {}
            wh.drops[#wh.drops + 1] = {
                id = d.id,
                dup = d.dup == true,
                coins = tonumber(d.coins) or 0,
            }
            if #wh.drops > 12 then table.remove(wh.drops, 1) end
        end
    end
    wh.fightEndAt = wh.fightEndAt or os.time()
end)

do
    pcall(function() wh.bossConn = R.Boss.OnClientEvent:Connect(onBossResult) end)
    pcall(function() wh.dropConn = R.BossDrop.OnClientEvent:Connect(onBossDrop) end)
end

local function dropsText(items)
    local parts = {}
    for _, item in ipairs(items or {}) do
        if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
            local info = DROP_INFO[item.id]
            local text = (info and info.name) or prettyId(item.id)
            if info and info.what then text = text .. " (" .. info.what .. ")" end
            local coins = tonumber(item.coins) or 0
            if coins > 0 then
                text = text .. " · +" .. fmtInt(coins) .. " coins"
            elseif item.dup then
                text = text .. " · dup"
            end
            parts[#parts + 1] = text
        end
    end
    return parts
end

local function toggleRows()
    return {
        { "Auto Farm OP", cfg.combatOn },
        { "Auto Skills", cfg.autoSkills },
        { "Auto Train", cfg.trainOn },
        { "Stay Away", cfg.stayAway },
        { "Auto Multi", cfg.multiOn },
        { "Auto Farm", cfg.farmOn },
        { "Auto Boss", cfg.bossOn },
        { "Equip Best Pets", cfg.equipOn },
        { "Auto Hatch", cfg.hatchOn },
        { "Auto Sell", cfg.sellOn },
        { "Unlock Eyes", cfg.unlockEyes },
        { "Best Eye", cfg.equipEyes },
        { "Best Aura", cfg.equipAura },
        { "Best Title", cfg.equipTitle },
        { "Auto Rebirth", cfg.rebirthOn },
        { "Free Pops", cfg.autoPops },
        { "Gifts", cfg.giftOn },
        { "Anti-AFK", cfg.antiAfk },
    }
end

local function equippedPetText()
    local pets = decode(attr("Pets", "[]"), {})
    local eq = decode(attr("Equipped", "[]"), {})
    local counts, order = {}, {}
    if type(eq) == "table" and type(pets) == "table" then
        for k, v in pairs(eq) do
            local uid
            if v == true then uid = tostring(k) else uid = tostring(v) end
            local id = pets[uid] or pets[tonumber(uid)]
            if type(id) == "string" then
                if not counts[id] then counts[id] = 0; order[#order + 1] = id end
                counts[id] = counts[id] + 1
            end
        end
    end
    local parts = {}
    for _, id in ipairs(order) do
        parts[#parts + 1] = prettyId(id) .. (counts[id] > 1 and (" ×" .. counts[id]) or "")
    end
    return #parts > 0 and table.concat(parts, ", ") or "none equipped"
end

local function buildEmbed()
    local world = tonumber(attr("World", 1)) or 1
    local eyeId = tostring(attr("Eye", "") or "")
    local auraId = tostring(attr("Aura", "") or "")
    local ownedAuras = decode(attr("OwnedAuras", "{}"), {})
    local eyeMult = eyeMultOf(Eyes.byId and Eyes.byId[eyeId], world)
    local auraMult = auraMultOf(AuraById[auraId], world, ownedAuras)
    local pets = decode(attr("Pets", "[]"), {})
    local petTotal = 0
    for _ in pairs(pets) do petTotal = petTotal + 1 end

    local on, off = {}, {}
    for _, row in ipairs(toggleRows()) do
        if row[2] then on[#on + 1] = row[1] else off[#off + 1] = row[1] end
    end
    local toggleText = "**ON (" .. #on .. "):** " .. ((#on > 0) and table.concat(on, ", ") or "none")
        .. "\n**OFF (" .. #off .. "):** " .. ((#off > 0) and table.concat(off, ", ") or "none")

    local lb = wh.lastBoss
    local bossText
    if type(lb) == "table" then
        local coinKind = (tostring(lb.kind) == "menos") and "Menoz" or "Kyubi"
        local loot = {}
        if (tonumber(lb.coins) or 0) > 0 then
            loot[#loot + 1] = "+" .. fmtInt(lb.coins) .. " " .. coinKind
        end
        if (tonumber(lb.kurama) or 0) > 0 then loot[#loot + 1] = "+" .. fmtInt(lb.kurama) .. " Kyubi" end
        if (tonumber(lb.menos) or 0) > 0 then loot[#loot + 1] = "+" .. fmtInt(lb.menos) .. " Menoz" end
        if (tonumber(lb.wins) or 0) > 0 then loot[#loot + 1] = "+" .. shortNum(lb.wins) .. " wins" end
        if (tonumber(lb.bossWins) or 0) > 0 then loot[#loot + 1] = "+" .. fmtInt(lb.bossWins) .. " boss win" end
        if #loot == 0 then loot[1] = "no reward recorded" end

        -- dmg arrives as either a 0..1 fraction of the boss bar or a raw
        -- number; render both sensibly.
        local dmgText = "damage n/a"
        local dmg = tonumber(lb.dmg)
        if dmg then
            dmgText = (dmg <= 1) and string.format("damage %.1f%%", dmg * 100)
                or ("damage " .. shortNum(dmg))
        end
        local shareText = "share n/a"
        if tonumber(lb.share) then
            shareText = string.format("share %.1f%%", tonumber(lb.share) or 0)
        end
        local dropList = (type(lb.drops) == "table") and lb.drops or {}
        local dropLine = ""
        if #dropList > 0 then
            local joined = table.concat(dropList, ", ")
            if #joined > 220 then joined = joined:sub(1, 217) .. "..." end
            dropLine = "\nDrops: " .. joined
        end
        bossText = string.format(
            "%s **%s** · %s\n%s · %s · fight %s · %s%s\nTotals — Kyubi **%s** / Menoz **%s**",
            lb.won and "🏆 DEFEATED" or "💀 LOST",
            BOSS_LABEL[tostring(lb.kind)] or prettyId(lb.kind),
            table.concat(loot, " · "),
            dmgText,
            shareText,
            durationText(lb.seconds),
            agoText(lb.at),
            dropLine,
            fmtInt(attr("KuramaCoins", 0)),
            fmtInt(attr("MenosCoins", 0))
        )
    else
        bossText = "No boss result recorded yet.\nTotals — Kyubi **"
            .. fmtInt(attr("KuramaCoins", 0)) .. "** / Menoz **"
            .. fmtInt(attr("MenosCoins", 0)) .. "**"
    end

    local joined = tonumber(attr("JoinedAt", 0)) or 0
    local session = joined > 0 and durationText(Workspace:GetServerTimeNow() - joined) or "?"

    local bestStage = bestStageOf(world)
    local fields = {
        {
            name = "📈 Progress",
            value = string.format(
                "Level **%s** / %s · Rebirths **%s**\nWorld **%d** · best stage **%d** · run cleared **%d**",
                fmtInt(attr("Level", 0)), fmtInt(attr("RebirthLevel", 0)),
                fmtInt(attr("Rebirths", 0)), world, bestStage,
                tonumber(attr("RunCleared", 0)) or 0
            ),
            inline = false,
        },
        {
            name = "👁 Eye",
            value = string.format("%s\nmultiplier **%s×** · mode %s",
                defName(Eyes.byId and Eyes.byId[eyeId], eyeId),
                shortNum(eyeMult), tostring(eyeState.mode or "mult")),
            inline = true,
        },
        {
            name = "🔥 Aura",
            value = string.format("%s\nmultiplier **%s×**",
                defName(AuraById[auraId], auraId), shortNum(auraMult)),
            inline = true,
        },
        {
            name = "🐾 Pets",
            value = string.format("%s× · **%d**/%d slots\n%s",
                shortNum(attr("PetMult", 0)), petTotal,
                tonumber(attr("PetSpace", 30)) or 30, equippedPetText()),
            inline = false,
        },
        {
            name = "🏷 Title",
            value = tostring(attr("Title", "none")),
            inline = true,
        },
        {
            name = "⚙️ Active Toggles",
            value = toggleText,
            inline = false,
        },
        {
            name = "☠ Last Boss",
            value = bossText,
            inline = false,
        },
        {
            name = "🪙 Coin Totals",
            value = string.format("Kyubi (Kurama) **%s**\nMenoz **%s**",
                fmtInt(attr("KuramaCoins", 0)), fmtInt(attr("MenosCoins", 0))),
            inline = true,
        },
        {
            name = "💠 Session",
            value = string.format("Chakra %s · Wins %s\nMult %s · play %s",
                shortNum(attr("Chakra", 0)), shortNum(attr("Wins", 0)),
                shortNum(attr("Mult", 0)), session),
            inline = true,
        },
    }

    return {
        title = "ANIME EYES HUB · " .. tostring(LP.DisplayName) .. " (@" .. tostring(LP.Name) .. ")",
        description = "Live profile **" .. tostring(cfg.cfgName)
            .. "** · updated <t:" .. os.time() .. ":R>",
        color = 0x57F287,
        fields = fields,
        footer = {
            text = "v2.5.0 · place " .. tostring(game.PlaceId)
                .. " · reporter " .. (cfg.webhookOn and "ON" or "OFF"),
        },
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
end

local function updateWhStatus()
    if not whPara then return end
    local state
    if not cfg.webhookOn then
        state = "off"
    elseif not webhookParts(cfg.webhookUrl) then
        state = "set a webhook URL"
    elseif wh.busy then
        state = "updating…"
    elseif wh.lastErr then
        state = "error: " .. tostring(wh.lastErr)
    else
        state = "live · message " .. tostring(wh.messageId or "will be created")
    end
    local left = math.max(0, math.floor((wh.nextAt or 0) - os.clock()))
    setStatus(whPara, string.format("Discord: %s · every %ds · next %s",
        state, math.floor(tonumber(cfg.webhookEvery) or 15), left > 0 and (left .. "s") or "now"))
end

local function httpJson(method, url, body)
    local env = (type(getfenv) == "function") and getfenv() or nil
    local synLib = env and env.syn or nil
    local fn = (type(request) == "function" and request)
        or (type(http_request) == "function" and http_request)
        or (type(synLib) == "table" and type(synLib.request) == "function" and synLib.request)
    if not fn then return nil, "executor HTTP API unavailable" end
    local ok, res = pcall(fn, {
        Url = url,
        Method = method,
        Headers = { ["Content-Type"] = "application/json" },
        Body = body,
    })
    if not ok then return nil, tostring(res) end
    if type(res) == "string" then return nil, res end
    if type(res) ~= "table" then return nil, "unexpected HTTP response" end
    return res
end

local function sendWebhook()
    if wh.busy or unloaded then return end
    local url = tostring(cfg.webhookUrl or ""):gsub("%s+$", "")
    local id, token = webhookParts(url)
    if not id then
        wh.lastErr = "invalid webhook URL"
        updateWhStatus()
        return
    end

    wh.busy = true
    wh.nextAt = os.clock() + math.max(10, tonumber(cfg.webhookEvery) or 15)
    local embed = buildEmbed()
    local base = url:gsub("[?#].*$", ""):gsub("/+$", "")
    local method, target, body
    if wh.messageId then
        method = "PATCH"
        target = base .. "/messages/" .. tostring(wh.messageId)
        body = HttpService:JSONEncode({ embeds = { embed } })
    else
        method = "POST"
        target = base .. "?wait=true"
        body = HttpService:JSONEncode({ username = "Anime Eyes Hub", embeds = { embed } })
    end

    task.spawn(function()
        local res, err = httpJson(method, target, body)
        if unloaded then wh.busy = false; return end
        wh.busy = false
        if not res then
            wh.lastErr = tostring(err)
            wh.nextAt = os.clock() + 20
            updateWhStatus()
            return
        end
        local code = tonumber(res.StatusCode) or 0
        if code == 429 then
            local wait = 6
            pcall(function()
                local d = HttpService:JSONDecode(res.Body or "{}")
                wait = tonumber(d.retry_after) or 6
            end)
            wh.lastErr = "rate limited, retry in " .. string.format("%.1f", wait) .. "s"
            wh.nextAt = os.clock() + wait + 2
        elseif code >= 200 and code < 300 then
            if method == "POST" then
                pcall(function()
                    local d = HttpService:JSONDecode(res.Body or "{}")
                    if type(d) == "table" and d.id then
                        wh.messageId = tostring(d.id)
                        saveWhState()
                    end
                end)
            end
            wh.lastOk = os.clock()
            wh.lastErr = nil
        elseif code == 404 and method == "PATCH" then
            wh.messageId = nil
            wh.lastErr = "old message gone, posting a new one"
            wh.nextAt = os.clock() + 2
            saveWhState()
        elseif code == 401 or code == 403 then
            wh.lastErr = "webhook rejected (HTTP " .. code .. ")"
            wh.nextAt = os.clock() + 60
        else
            wh.lastErr = "HTTP " .. code
            wh.nextAt = os.clock() + 30
        end
        updateWhStatus()
    end)
end

local function setWebhookUrl(v)
    v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if v == cfg.webhookUrl then return end
    cfg.webhookUrl = v
    wh.messageId = nil
    wh.lastErr = nil
    wh.nextAt = os.clock() + 1
    saveWhState()
    updateWhStatus()
end

local function webhookNow()
    wh.nextAt = 0
    wh.lastErr = nil
    updateWhStatus()
end

local function webhookTick(now)
    -- Boss result tracking. A fight is bracketed by BossPhase; when it ends the
    -- server pushes the exact reward (coins, my damage, my share) on the Boss
    -- remote. Build the report from that push, and only fall back to the coin
    -- delta when the push never arrives (a fight that ended before we loaded).
    local phase = Workspace:GetAttribute("BossPhase")
    local inFight = phase == "countdown" or phase == "fight"
    if inFight and not wh.bossActive then
        wh.bossActive = true
        wh.bossSnap = bossSnapshot()
        wh.bossResult = nil
        wh.drops = nil
        wh.fightEndAt = nil
    elseif not inFight and wh.bossActive then
        wh.bossActive = false
        wh.fightEndAt = wh.fightEndAt or os.time()
    end

    -- Wait a few seconds after the phase flips so the reward push can land,
    -- then finalize once: exact payload if we have it, delta otherwise. A
    -- result is held for ~2s because the loot arrives on a separate remote
    -- and would otherwise be missed by a report fired on the same tick.
    if wh.bossSnap and not wh.bossActive then
        local waited = os.time() - (wh.fightEndAt or os.time())
        local resAge = wh.bossResult and (os.time() - (wh.bossResult.at or 0)) or nil
        local ready
        if wh.bossResult then
            ready = resAge >= 2
        else
            ready = waited >= 4
        end
        if ready then
            local snap = wh.bossSnap
            wh.bossSnap = nil
            local res = wh.bossResult
            local curK = tonumber(attr("KuramaCoins", 0)) or 0
            local curM = tonumber(attr("MenosCoins", 0)) or 0
            local share = res and res.part or nil
            if share and share <= 1 then share = share * 100 end
            if not share then share = bossShare() end
            local won
            if res then won = res.won else won = Workspace:GetAttribute("BossWon") == true end
            wh.lastBoss = {
                won = won,
                kind = (res and res.kind) or tostring(snap.kind or "kyubi"):lower(),
                coins = res and res.coins or 0,
                kurama = (not res) and math.max(0, math.floor(curK - (snap.kurama or 0))) or 0,
                menos = (not res) and math.max(0, math.floor(curM - (snap.menos or 0))) or 0,
                dmg = res and res.dmg or nil,
                share = share,
                base = res and res.base or nil,
                bonus = res and res.bonus or nil,
                vip = res and res.vip or nil,
                drops = dropsText(wh.drops),
                wins = math.max(0, (tonumber(attr("Wins", 0)) or 0) - (snap.wins or 0)),
                bossWins = math.max(0, (tonumber(attr("BossWins", 0)) or 0) - (snap.bossWins or 0)),
                seconds = math.max(0, os.time() - (snap.at or os.time())),
                at = os.time(),
            }
            wh.bossResult = nil
            wh.drops = nil
            wh.fightEndAt = nil
            wh.nextAt = 0
            saveWhState()
        end
    end

    -- A reward can land without us ever seeing the fight (hub loaded mid-fight,
    -- or a fight that started before the snapshot): report it on its own, with
    -- the same short hold so the loot push is included.
    if wh.bossResult and not wh.bossSnap and not wh.bossActive
        and (os.time() - (wh.bossResult.at or 0)) >= 2 then
        local res = wh.bossResult
        wh.bossResult = nil
        local share = res.part
        if share and share <= 1 then share = share * 100 end
        wh.lastBoss = {
            won = res.won,
            kind = res.kind,
            coins = res.coins,
            kurama = 0,
            menos = 0,
            dmg = res.dmg,
            share = share,
            base = res.base,
            bonus = res.bonus,
            vip = res.vip,
            drops = dropsText(wh.drops),
            wins = 0,
            bossWins = 0,
            seconds = 0,
            at = os.time(),
        }
        wh.drops = nil
        wh.fightEndAt = nil
        wh.nextAt = 0
        saveWhState()
    end

    if not cfg.webhookOn then
        if not wh.wasOff then
            wh.wasOff = true
            updateWhStatus()
        end
        return
    end
    wh.wasOff = false
    if wh.busy then return end
    if not webhookParts(cfg.webhookUrl) then
        if now - (wh.urlWarnAt or 0) > 15 then
            wh.urlWarnAt = now
            updateWhStatus()
        end
        return
    end
    if now < (wh.nextAt or 0) then return end
    sendWebhook()
end


-- egg list for the hatch dropdown, grouped by world (product/admin eggs excluded)
local eggByWorld = {} -- [world] = { {id, name, cost}, ... }
do
    local eggs = (type(PetsCfg.eggs) == "table") and PetsCfg.eggs or {}
    for _, e in ipairs(eggs) do
        if type(e) == "table" and type(e.id) == "string" then
            local cost = tonumber(e.cost)
            local w = tonumber(e.world) or 1
            local usable = e.id ~= "admin" and e.id ~= "infernal_aegis"
                and not e.product and cost and cost > 0 and cost < 1e300
            if usable then
                local list = eggByWorld[w] or {}
                list[#list + 1] = {
                    id = e.id,
                    name = (type(e.name) == "string" and e.name) or e.id,
                    cost = cost,
                }
                eggByWorld[w] = list
            end
        end
    end
    for _, list in pairs(eggByWorld) do
        table.sort(list, function(a, b)
            if a.cost ~= b.cost then return a.cost < b.cost end
            return a.name < b.name
        end)
    end
end

-- ── Main tab ──────────────────────────────────────────────────────────
local TabMain = Window:Tab({ Title = "Main", Icon = "solar:bolt-bold" })
local MainStatus = makeStatus(TabMain)

local MainCombat = TabMain:Section({ Opened = true, Title = "Combat" })
uiHooks.combatOn = MainCombat:Toggle({
    Title = "Auto Farm OP",
    Desc = "Attack everything in range — works with farm and boss tabs",
    Value = cfg.combatOn,
    Callback = function(s) cfg.combatOn = s end,
})
uiHooks.autoSkills = MainCombat:Toggle({
    Title = "Auto Use Skills",
    Desc = "Fire E and R whenever they are off cooldown",
    Value = cfg.autoSkills,
    Callback = function(s) cfg.autoSkills = s end,
})

local MainSupport = TabMain:Section({ Opened = true, Title = "Support" })
uiHooks.trainOn = MainSupport:Toggle({
    Title = "Auto Train",
    Desc = "Click train for chakra (hub and stages alike)",
    Value = cfg.trainOn,
    Callback = function(s) cfg.trainOn = s end,
})
local MultiToggle = MainSupport:Toggle({
    Title = "Auto Multi",
    Desc = "Stands on the best training plot your Rebirths unlock — switches to the world that holds it",
    Value = cfg.multiOn,
    Callback = function(s)
        cfg.multiOn = s
        if not s then
            multiState.spot = 0
            multiState.world = 0
        end
    end,
})

-- ── Farm tab ──────────────────────────────────────────────────────────
local TabFarm = Window:Tab({ Title = "Farm", Icon = "solar:play-bold" })
local FarmStatus = makeStatus(TabFarm)

local stageNames, worldNames = {}, {}
for i = 1, 15 do stageNames[#stageNames + 1] = tostring(i) end
for i = 1, 9 do worldNames[#worldNames + 1] = tostring(i) end
local farmWorldNames = { "None" }
for i = 1, 9 do farmWorldNames[#farmWorldNames + 1] = tostring(i) end

local FarmSec = TabFarm:Section({ Opened = true, Title = "Auto Farm" })
uiHooks.farmOn = FarmSec:Toggle({
    Title = "Auto Farm Stages",
    Desc = "Clears stage 1 up to the selected stage, auto-fighting every wave",
    Value = cfg.farmOn,
    Callback = function(s)
        cfg.farmOn = s
        if s then resetFarm() end
        notify("Farm", s and ("Stage farming ON · " .. cfg.farmMode) or "Stage farming OFF", 3)
    end,
})
uiHooks.farmMode = FarmSec:Dropdown({
    Title = "Farm Mode",
    Desc = "All modes cap at the selected stage and claim its gold pad; Jackpot adds purple with the pass",
    Values = { "Loop", "Rush", "Jackpot 1-15", "Smart Continuous" },
    Value = (cfg.farmMode == "Jackpot" and "Jackpot 1-15")
        or (cfg.farmMode == "Smart" and "Smart Continuous")
        or cfg.farmMode,
    Callback = function(v)
        if v == "Jackpot 1-15" then cfg.farmMode = "Jackpot"
        elseif v == "Smart Continuous" then cfg.farmMode = "Smart"
        else cfg.farmMode = v end
    end,
})
uiHooks.stage = FarmSec:Dropdown({
    Title = "Stage",
    Desc = "Farm stops after this stage: claim its pads, return home, restart from 1",
    Values = stageNames,
    Value = tostring(cfg.stage),
    Callback = function(v) cfg.stage = math.clamp(tonumber(v) or 15, 1, 15) end,
})
uiHooks.world = FarmSec:Dropdown({
    Title = "World",
    Desc = "None = farm in whatever world you are in; a world is entered only while farming",
    Values = farmWorldNames,
    Value = (tonumber(cfg.world) or 0) <= 0 and "None" or tostring(cfg.world),
    Callback = function(v)
        cfg.world = (v == "None") and 0 or (tonumber(v) or 0)
        farm.worldAskAt = 0
    end,
})

local FarmKite = TabFarm:Section({ Opened = true, Title = "Kiting" })
uiHooks.stayAway = FarmKite:Toggle({
    Title = "Stay Away From Enemies",
    Desc = "Hold a 15-stud gap and orbit safely inside the current stage — never crosses down a stage or steps on a pad",
    Value = cfg.stayAway,
    Callback = function(s) cfg.stayAway = s end,
})
uiHooks.mobTarget = FarmKite:Dropdown({
    Title = "Mob Target",
    Values = { "Nearest", "Boss First" },
    Value = cfg.mobTarget,
    Callback = function(v) cfg.mobTarget = v end,
})

-- ── Boss tab ──────────────────────────────────────────────────────────
local TabBoss = Window:Tab({ Title = "Boss", Icon = "solar:bone-bold" })
local BossStatus = makeStatus(TabBoss)

local BossSec = TabBoss:Section({ Opened = true, Title = "World Boss" })
uiHooks.bossOn = BossSec:Toggle({
    Title = "Auto Boss",
    Desc = "Joins instantly, closes onto the boss (contact range) and attacks until it drops — fast re-join after a death",
    Value = cfg.bossOn,
    Callback = function(s)
        cfg.bossOn = s
        if not s then
            bossReturn = nil
            bossEndedAt = 0
        end
    end,
})
-- ── Pets tab ──────────────────────────────────────────────────────────
local TabPets = Window:Tab({ Title = "Pets", Icon = "solar:star-bold" })
local PetsStatus = makeStatus(TabPets)

local HatchSec = TabPets:Section({ Opened = true, Title = "Eggs" })
uiHooks.hatchOn = HatchSec:Toggle({
    Title = "Auto Egg Hatch",
    Desc = "Fast hatch loop — 4 tries per second by default",
    Value = cfg.hatchOn,
    Callback = function(s) cfg.hatchOn = s end,
})

local eggIdByName, eggNameById = {}, {}
local function setEggWorld(w)
    local names = {}
    eggIdByName, eggNameById = {}, {}
    for _, e in ipairs(eggByWorld[w] or {}) do
        names[#names + 1] = e.name
        eggIdByName[e.name] = e.id
        eggNameById[e.id] = e.name
    end
    return names
end

local HatchEggDrop
local hatchStartWorld = tonumber(cfg.eggWorld) or 0
if hatchStartWorld <= 0 then hatchStartWorld = tonumber(attr("World", 1)) or 1 end
local hatchInitial = setEggWorld(hatchStartWorld)
local hatchDefaultName = eggNameById[cfg.eggId] or hatchInitial[1]
if hatchDefaultName then
    cfg.eggId = eggIdByName[hatchDefaultName] or cfg.eggId
end

uiHooks.eggWorld = HatchSec:Dropdown({
    Title = "World",
    Desc = "None = hatch in the world you are in; otherwise it teleports only while hatching",
    Values = farmWorldNames,
    Value = (tonumber(cfg.eggWorld) or 0) <= 0 and "None" or tostring(cfg.eggWorld),
    Callback = function(v)
        local w = (v == "None") and 0 or (tonumber(v) or 0)
        cfg.eggWorld = w
        local names = setEggWorld(w <= 0 and (tonumber(attr("World", 1)) or 1) or w)
        if #names == 0 then
            notify("Hatch", "No hatchable eggs in World " .. w, 3)
            return
        end
        cfg.eggId = eggIdByName[names[1]] or cfg.eggId
        if HatchEggDrop then
            pcall(function()
                HatchEggDrop:Refresh(names)
                HatchEggDrop:Select(names[1])
            end)
        end
    end,
})
if #hatchInitial > 0 then
    HatchEggDrop = HatchSec:Dropdown({
        Title = "Egg",
        Values = hatchInitial,
        Value = hatchDefaultName or hatchInitial[1],
        SearchBarEnabled = true,
        Callback = function(v) cfg.eggId = eggIdByName[v] or cfg.eggId end,
    })
end
uiHooks.eggId = HatchEggDrop
uiHooks.hatchCount = HatchSec:Slider({
    Title = "Hatch Count",
    Desc = "Eggs per invoke (max 3)",
    Value = { Min = 1, Max = 3, Default = math.clamp(cfg.hatchCount, 1, 3) },
    Step = 1,
    Callback = function(v) cfg.hatchCount = math.clamp(math.floor(v), 1, 3) end,
})
uiHooks.hatchDelay = HatchSec:Slider({
    Title = "Hatch Delay",
    Desc = "Seconds between hatches — lower is faster",
    Value = { Min = 0.1, Max = 2, Default = cfg.hatchDelay },
    Step = 0.05,
    Callback = function(v) cfg.hatchDelay = v end,
})

local PetManage = TabPets:Section({ Opened = true, Title = "Manage" })
uiHooks.equipOn = PetManage:Toggle({
    Title = "Auto EquipBest",
    Desc = "Server-side best-pet equipping every 5s",
    Value = cfg.equipOn,
    Callback = function(s) cfg.equipOn = s end,
})
uiHooks.sellOn = PetManage:Toggle({
    Title = "Auto Sell",
    Desc = "Free slots every 0.4s: delete the lowest-mult unlocked pets",
    Value = cfg.sellOn,
    Callback = function(s) cfg.sellOn = s end,
})

-- ── ALL MAX tab ───────────────────────────────────────────────────────
local TabMax = Window:Tab({ Title = "ALL MAX", Icon = "solar:refresh-bold" })
local MaxStatus = makeStatus(TabMax)

local MaxSec = TabMax:Section({ Opened = true, Title = "Progress" })
local RebirthToggle = MaxSec:Toggle({
    Title = "Auto Rebirth",
    Desc = "Rebirth until the furthest unlocked world's Auto Multi requirement is met, then stop; turn it on again to continue once the next world unlocks",
    Value = cfg.rebirthOn,
    Callback = function(s) cfg.rebirthOn = s end,
})
uiHooks.rebirthToggle = RebirthToggle
uiHooks.multiToggle = MultiToggle
uiHooks.rebirthOn = RebirthToggle
uiHooks.multiOn = MultiToggle
uiHooks.unlockEyes = MaxSec:Toggle({
    Title = "Auto Unlock Eye",
    Desc = "Unlock the cheapest affordable eye you don't own yet",
    Value = cfg.unlockEyes,
    Callback = function(s) cfg.unlockEyes = s end,
})
uiHooks.equipEyes = MaxSec:Toggle({
    Title = "Auto Equip Best Eye",
    Desc = "World-aware: highest multiplier for training, best combat DPS during waves and boss fights",
    Value = cfg.equipEyes,
    Callback = function(s) cfg.equipEyes = s end,
})
uiHooks.equipTitle = MaxSec:Toggle({
    Title = "Auto Equip Best Title",
    Desc = "Pick the highest-rank title you own (game rank order), every 5s",
    Value = cfg.equipTitle,
    Callback = function(s) cfg.equipTitle = s end,
})
uiHooks.equipAura = MaxSec:Toggle({
    Title = "Auto Equip Best Aura",
    Desc = "World-aware effective multiplier (handles better-aura scaling) — never downgrades",
    Value = cfg.equipAura,
    Callback = function(s) cfg.equipAura = s end,
})

local MaxClaims = TabMax:Section({ Opened = true, Title = "Claims" })
uiHooks.autoPops = MaxClaims:Toggle({
    Title = "Auto Claim Free Pops",
    Desc = "Claims free training bubbles (x2/x3/x5/x10) - never the paid gold one",
    Value = cfg.autoPops,
    Callback = function(s) cfg.autoPops = s end,
})
uiHooks.giftOn = MaxClaims:Toggle({
    Title = "Auto Claim Gifts",
    Desc = "Claims the 5 / 15 / 60 minute playtime gifts when ready",
    Value = cfg.giftOn,
    Callback = function(s) cfg.giftOn = s end,
})

-- ── Settings tab ──────────────────────────────────────────────────────
local TabSet = Window:Tab({ Title = "Settings", Icon = "solar:settings-bold" })
local SetStatus = makeStatus(TabSet)

uiHooks.section = TabSet:Section({ Opened = true, Title = "Behaviour" })
uiHooks.antiAfk = uiHooks.section:Toggle({
    Title = "Anti-AFK",
    Desc = "Taps the virtual mouse when idle so Roblox never kicks you",
    Value = cfg.antiAfk,
    Callback = function(s) cfg.antiAfk = s end,
})

-- Named profiles: every persisted setting is written to the executor
-- workspace under AnimeEyesHub/configs.json, so Save / Load works across
-- reloads and re-executes instead of living only in getgenv().
uiHooks.cfgSection = TabSet:Section({ Opened = true, Title = "Configuration" })
uiHooks.cfgStatusPara = makeStatus(TabSet, "Config status")
uiHooks.autoLoadCfg = uiHooks.cfgSection:Toggle({
    Title = "Auto Load Config",
    Desc = "Applies the last saved profile when the hub starts",
    Value = cfg.autoLoadCfg,
    Callback = function(s) cfg.autoLoadCfg = s end,
})
uiHooks.cfgName = uiHooks.cfgSection:Input({
    Title = "Config Name",
    Desc = "Name used by Save and Load",
    Placeholder = "default",
    Value = cfg.cfgName,
    Callback = function(v) cfg.cfgName = cleanProfileName(v) end,
})
-- stored on uiHooks (chunk-level) so the buttons and getgenv().AnimeEyesHub
-- share one code path without spending extra boot() locals
uiHooks.saveNamedCfg = function()
    cfg.cfgName = cleanProfileName(cfg.cfgName)
    configStore.profiles[cfg.cfgName] = snapshotProfile()
    configStore.lastName = cfg.cfgName
    persistCfg()
    return writeJsonFile(CFG_FILE, configStore), cfg.cfgName
end
uiHooks.loadNamedCfg = function()
    local nm = cleanProfileName(cfg.cfgName)
    local prof = configStore.profiles[nm]
    if type(prof) ~= "table" then return false, nm end
    applyProfile(prof)
    cfg.cfgName = nm
    configStore.lastName = nm
    persistCfg()
    writeJsonFile(CFG_FILE, configStore)
    uiHooks.refresh()
    -- the egg dropdown is world-filtered, so rebuild it for the loaded world
    local w = (tonumber(cfg.eggWorld) or 0) <= 0
        and (tonumber(attr("World", 1)) or 1) or tonumber(cfg.eggWorld)
    local names = setEggWorld(w)
    if HatchEggDrop then
        pcall(function()
            HatchEggDrop:Refresh(names)
            if eggNameById[cfg.eggId] then HatchEggDrop:Select(eggNameById[cfg.eggId]) end
        end)
    end
    return true, nm
end
uiHooks.cfgSection:Button({
    Title = "Save Config",
    Desc = "Stores every setting under the name above",
    Callback = function()
        local ok, nm = uiHooks.saveNamedCfg()
        local text = ok and ("saved profile '" .. nm .. "'")
            or "save failed: executor file API unavailable"
        setStatus(uiHooks.cfgStatusPara, text)
        notify("Config", text, 3)
    end,
})
uiHooks.cfgSection:Button({
    Title = "Load Config",
    Desc = "Applies the saved profile with the name above",
    Callback = function()
        local ok, nm = uiHooks.loadNamedCfg()
        local text = ok and ("loaded profile '" .. nm .. "'")
            or ("no saved profile '" .. nm .. "'")
        setStatus(uiHooks.cfgStatusPara, text)
        notify("Config", text, 3)
    end,
})

-- Discord reporter: one message, edited in place (see the module above)
uiHooks.whSection = TabSet:Section({ Opened = true, Title = "Discord Reporter" })
uiHooks.webhookOn = uiHooks.whSection:Toggle({
    Title = "Reporter",
    Desc = "Sends one live message, then keeps editing it — never posts copies",
    Value = cfg.webhookOn,
    Callback = function(s)
        cfg.webhookOn = s
        wh.nextAt = 0
        updateWhStatus()
    end,
})
uiHooks.webhookUrl = uiHooks.whSection:Input({
    Title = "Webhook URL",
    Desc = "Discord → Channel → Integrations → Webhooks → Copy URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    Value = cfg.webhookUrl,
    Callback = function(v) setWebhookUrl(v) end,
})
uiHooks.webhookEvery = uiHooks.whSection:Slider({
    Title = "Update Every",
    Desc = "Seconds between edits of the same Discord message",
    Value = { Min = 10, Max = 300, Default = math.clamp(tonumber(cfg.webhookEvery) or 15, 10, 300) },
    Step = 5,
    Callback = function(v)
        cfg.webhookEvery = math.clamp(math.floor(v), 10, 300)
        updateWhStatus()
    end,
})
uiHooks.whSection:Button({
    Title = "Send / Retry Now",
    Callback = function() webhookNow() end,
})
whPara = makeStatus(TabSet, "Discord status")

local SetScript = TabSet:Section({ Opened = true, Title = "Script" })
SetScript:Button({
    Title = "Unload Hub",
    Callback = function()
        unload()
    end,
})

task.defer(function()
    local names = {}
    for nm in pairs(configStore.profiles) do names[#names + 1] = nm end
    table.sort(names)
    setStatus(uiHooks.cfgStatusPara, "profile '" .. cfg.cfgName .. "' · saved: "
        .. (#names > 0 and table.concat(names, ", ") or "none"))
    updateWhStatus()
end)

-- ═══════════════════════════ driver ══════════════════════════════════
local acc = { train = 0, status = 0 }
local conn = nil
unloaded = false
local antiConns = {}

-- run a system tick in isolation so one failure can never starve the others
local lastWarnAt = {}
local function guard(name, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        local t = os.clock()
        if not lastWarnAt[name] or t - lastWarnAt[name] > 5 then
            lastWarnAt[name] = t
            warn("[AnimeEyesHub] " .. name .. ": " .. tostring(res))
        end
        return nil
    end
    return res
end

-- ── anti-AFK ──────────────────────────────────────────────────────────
local VU = game:GetService("VirtualUser")
local UIS = game:GetService("UserInputService")
local antiAfkAt = os.clock() + 240
local function antiAfkBump()
    antiAfkAt = os.clock() + 240 + math.random(-20, 20)
end
local function antiAfkClick()
    antiAfkBump()
    if not cfg.antiAfk then return end
    pcall(function()
        VU:CaptureController()
        VU:ClickButton2(Vector2.new(6, 6))
    end)
end
table.insert(antiConns, UIS.InputBegan:Connect(antiAfkBump))
table.insert(antiConns, UIS.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.MouseWheel then
        antiAfkBump()
    end
end))
table.insert(antiConns, LP.Idled:Connect(function() antiAfkClick() end))

-- free training pops: the server pushes {kind="free", id=...} to Pops; claim
-- it straight away. Gold pops are product purchases, so they are never touched.
table.insert(antiConns, R.Pops.OnClientEvent:Connect(function(kind, data)
    if kind ~= "bubble" or type(data) ~= "table" then return end
    if not cfg.autoPops or data.kind ~= "free" then return end
    local id = data.id
    if type(id) ~= "number" then return end
    if (tonumber(attr("TrainSpot", 0)) or 0) <= 0 then return end
    task.delay(0.15 + math.random() * 0.25, function()
        if cfg.autoPops and not unloaded then
            pcall(function() R.Pops:FireServer("claim", id) end)
        end
    end)
end))

-- apply queued movement from RenderStepped: the game's control module cancels
-- Humanoid:Move issued on Heartbeat, so this is the only phase that sticks
table.insert(antiConns, RunService.RenderStepped:Connect(function()
    if desiredDir.Magnitude > 0.05 then
        local hum = humanoid()
        if hum and hum.Health > 0 then
            hum:Move(desiredDir, false)
        end
    end
end))

-- Responsive window: re-fit the UI scale whenever the viewport changes (window
-- resize on desktop, rotation on mobile) or the camera is swapped.
do
    local function refit()
        local cam = workspace.CurrentCamera
        if cam then
            table.insert(antiConns, cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
                uiHooks.applyScale()
            end))
        end
        uiHooks.applyScale()
    end
    table.insert(antiConns, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(refit))
    refit()
end

unload = function()
    if unloaded then return end
    unloaded = true
    pcall(persistCfg)
    if conn then
        conn:Disconnect()
        conn = nil
    end
    for _, c in ipairs(antiConns) do
        pcall(function() c:Disconnect() end)
    end
    antiConns = {}
    pcall(function() if wh.bossConn then wh.bossConn:Disconnect() end end)
    pcall(function() if wh.dropConn then wh.dropConn:Disconnect() end end)
    wh.bossConn, wh.dropConn = nil, nil
    pcall(function()
        local h = humanoid()
        if h then h:Move(Vector3.zero, false) end
    end)
    -- remove any lock-on GUI left behind by a previous version of this hub
    pcall(function()
        local roots = {}
        if type(gethui) == "function" then
            local ok, h = pcall(gethui)
            if ok and h then roots[#roots + 1] = h end
        end
        roots[#roots + 1] = game:GetService("CoreGui")
        local pg = LP:FindFirstChildOfClass("PlayerGui")
        if pg then roots[#roots + 1] = pg end
        for _, r in ipairs(roots) do
            local sg = r:FindFirstChild("LockOnVisual")
            if sg then sg:Destroy() end
        end
    end)
    pcall(function()
        if type(getgenv) ~= "function" then return end
        local g = getgenv()
        if type(g) ~= "table" then return end
        if g.__AEH_RUN == RUN_TAG then g.__AEH_RUN = nil end
        local api = g.AnimeEyesHub
        if type(api) == "table" and api.cfg == cfg then g.AnimeEyesHub = nil end
    end)
    pcall(function() Window:Destroy() end)
end

-- claim this run; a reload replaces the tag and the previous copy kills itself
pcall(function()
    if type(getgenv) == "function" then
        getgenv().__AEH_RUN = RUN_TAG
    end
end)

-- WindUI's X button calls Window:Destroy() — without this the window vanishes
-- and every loop keeps running with no way back.
pcall(function()
    Window:OnDestroy(function() unload() end)
end)

local function runTagStillMine()
    if type(getgenv) ~= "function" then return true end
    local ok, g = pcall(getgenv)
    if not ok or type(g) ~= "table" then return true end
    return g.__AEH_RUN == nil or g.__AEH_RUN == RUN_TAG
end

-- Status writer. Spawned here, while our loader's thread still holds the Plugin
-- capability, so its CoreGui writes are allowed where the Heartbeat callback's
-- are not (see setStatus). It drains the queue each pass and writes the latest
-- text for each paragraph.
task.spawn(function()
    while not unloaded do
        local did = false
        for para, text in pairs(statusQueue) do
            statusQueue[para] = nil
            did = true
            pcall(function()
                if para.label then
                    para.label.Text = text
                elseif type(para.para.SetDesc) == "function" then
                    para.para:SetDesc(text)
                elseif type(para.para.Set) == "function" then
                    para.para:Set(text)
                end
            end)
        end
        for _ = 1, math.min(#uiJobs, 30) do
            local fn = table.remove(uiJobs, 1)
            did = true
            pcall(fn)
        end
        task.wait(did and 0.05 or 0.15)
    end
end)

conn = RunService.Heartbeat:Connect(function(dt)
    -- Re-elevate for any remaining CoreGui touches (notifications, toggle
    -- mirrors). The status labels go through the writer thread above, which is
    -- the only context observed to keep the Plugin capability.
    if type(setthreadidentity) == "function" then pcall(setthreadidentity, 8) end
    if unloaded then return end
    if not runTagStillMine() then
        unload() -- superseded by a newer load
        return
    end
    local now = os.clock()

    -- movement requests are gathered this frame and applied on RenderStepped
    moveRequested = false

    -- farm bookkeeping must run even while combat owns movement, otherwise the
    -- wave-end transition is missed and pads / looping never trigger
    guard("farmTick", farmTick, now)

    -- combat owns movement while enemies exist (farm and boss auto-fight too)
    local combatOwned = false
    if cfg.combatOn or cfg.farmOn or cfg.bossOn then
        combatOwned = guard("combatTick", combatTick, now) == true
    end
    combatBusy = combatOwned

    -- anti-AFK keepalive
    if cfg.antiAfk and now >= antiAfkAt then
        antiAfkClick()
    end

    -- walking only when combat isn't steering
    if not combatOwned then
        guard("walkTick", walkTick, now)
    end

    if not moveRequested then
        desiredDir = Vector3.zero
    end

    -- decline the revive prompt first, then re-join the boss on the next tick
    guard("reviveTick", reviveTick, now)
    guard("bossTick", bossTick, now)
    guard("bossReturnTick", bossReturnTick, now)

    -- auto multi training (teleports to the best eligible plot)
    guard("multiTick", multiTick, now)

    -- auto train: works anywhere (hub and during stage waves)
    acc.train = acc.train + dt
    if acc.train >= (1 / (Economy.autoOpRate or 8)) then
        acc.train = 0
        if cfg.trainOn and attr("Downed", false) ~= true then
            local hum = humanoid()
            if hum and hum.Health > 0 then
                pcall(function() R.Train:FireServer() end)
            end
        end
    end

    -- economy ticks
    guard("rebirthTick", rebirthTick, now)
    guard("hatchTick", hatchTick, now)
    guard("equipBestTick", equipBestTick, now)
    guard("sellTick", sellTick, now)
    guard("giftTick", giftTick, now)
    guard("eyesTick", eyesTick, now)
    guard("auraTick", auraTick, now)
    guard("equipTitleTick", equipTitleTick, now)
    guard("webhookTick", webhookTick, now)

    -- status lines
    acc.status = acc.status + dt
    if acc.status >= 1 then
        acc.status = 0
        pcall(persistCfg)
        local okList, enemies = pcall(EnemiesMod.list)
        if not okList or type(enemies) ~= "table" then enemies = {} end
        local cleared = tonumber(attr("RunCleared", 0)) or 0
        local petsN = 0
        local petsNow = decode(attr("Pets", "[]"), {})
        for _ in pairs(petsNow) do petsN = petsN + 1 end
        setStatus(MainStatus, string.format(
            "Wave: %s · enemies: %d · chakra: %s · train %s · multi %s",
            tostring(attr("InWave", false)), #enemies,
            shortNum(attr("Chakra", 0)),
            cfg.trainOn and "on" or "off",
            cfg.multiOn and (multiState.spot > 0 and ("spot " .. multiState.spot .. " · w" .. tostring(multiState.world)) or "searching") or "off"
        ))
        setStatus(FarmStatus, string.format(
            "Stage %d/15 · cleared %d · world %s · stop %d · %s · %s",
            math.min(cleared + 1, 15), cleared,
            tostring(attr("World", 1) or 1)
                .. (((tonumber(cfg.world) or 0) > 0) and (" -> W" .. tostring(cfg.world)) or " (stay)"),
            cfg.stage,
            cfg.farmOn and farm.phase or "idle",
            cfg.padsOn and (farm.padStage > 0 and ("pads " .. math.min(farm.padIndex, #farm.padQueue) .. "/" .. #farm.padQueue) or "pads ready") or "pads off"
        ))
        local bx = tonumber(Workspace:GetAttribute("BossX"))
        local bz = tonumber(Workspace:GetAttribute("BossZ"))
        local rootNow = rootPart()
        local gapTxt = string.format("%.1f", tonumber(cfg.bossDist) or 0)
        if bx and bz and rootNow then
            gapTxt = string.format("%.1f", math.max(0,
                flatDist(Vector3.new(bx, 0, bz), rootNow.Position)
                    - (tonumber(BossLogic.BODY_RADIUS) or 22)))
        end
        setStatus(BossStatus, string.format(
            "Phase: %s · HP: %s · gap %s (target %.1f) · %s",
            tostring(Workspace:GetAttribute("BossPhase") or "wait"),
            tostring(Workspace:GetAttribute("BossHp") or "-"),
            gapTxt,
            tonumber(cfg.bossDist) or 0,
            bossReturn and "fighting" or "idle"
        ))
        setStatus(PetsStatus, string.format(
            "Pets: %d/%s · hatch %s x%d @ %.2fs · equipBest %s · sell %s",
            petsN, tostring(attr("PetSpace", 30)),
            cfg.hatchOn and cfg.eggId or "off", cfg.hatchCount, tonumber(cfg.hatchDelay) or 0.25,
            cfg.equipOn and "on" or "off", cfg.sellOn and "on" or "off"
        ))
        local curW = tonumber(attr("World", 1)) or 1
        local maxW = math.max(curW, furthestWorld())
        setStatus(MaxStatus, string.format(
            "Level %s/%s · rebirths %s/%s (W%d) · wins %s · eye %s (%s) · aura %s · title %s",
            tostring(attr("Level", 0)), tostring(attr("RebirthLevel", 0)),
            tostring(attr("Rebirths", 0)), tostring(multiMaxReq(maxW)), maxW,
            shortNum(attr("Wins", 0)),
            tostring(attr("Eye", Eyes.STARTER)), eyeState.mode,
            tostring(attr("Aura", "none")),
            tostring(attr("Title", "none"))
        ))
        setStatus(SetStatus, "RightShift toggles the menu · X / Unload stops everything")

        -- lightweight runtime introspection for the external handle
        pcall(function()
            if type(getgenv) ~= "function" then return end
            local api = getgenv().AnimeEyesHub
            if type(api) ~= "table" then return end
            api.debug = {
                phase = farm.phase,
                padStage = farm.padStage,
                padQueue = #farm.padQueue,
                padIndex = farm.padIndex,
                stop = cfg.stage,
                cleared = cleared,
                world = tonumber(attr("World", 1)) or 1,
                inStage = attr("InStages") == true,
                busy = combatBusy,
                bossReturn = bossReturn ~= nil,
                multiSpot = multiState.spot,
                multiWorld = multiState.world,
                title = tostring(attr("Title", "")),
                bossGap = lastBossGap > 0 and math.floor(lastBossGap) or nil,
                stage = curStage(),
                padLock = padLock,
                eyeMode = eyeState.mode,
                eyeBest = eyeState.bestId,
                eyeScore = math.floor((eyeState.bestScore or 0) * 100) / 100,
                eyeCurScore = math.floor((eyeState.curScore or 0) * 100) / 100,
                auraBest = auraState.bestId,
                auraMult = math.floor((auraState.bestMult or 0) * 100) / 100,
                auraCurMult = math.floor((auraState.curMult or 0) * 100) / 100,
                freeEggs = select(3, freeEggPick()),
                padX = farm.padQueue[farm.padIndex] and math.floor(farm.padQueue[farm.padIndex].pos.X) or nil,
                padZ = farm.padQueue[farm.padIndex] and math.floor(farm.padQueue[farm.padIndex].pos.Z) or nil,
                goalX = walk.goal and math.floor(walk.goal.X) or nil,
                goalZ = walk.goal and math.floor(walk.goal.Z) or nil,
                log = farm.log,
            }
        end)
    end
end)

notify("Anime Eyes Hub", "Loaded — safe orbit, -2 stud boss close-in, world-aware eyes/auras and smart rebirth.", 5)

-- external control handle (iteration / scripting)
pcall(function()
    if type(getgenv) == "function" then
        getgenv().AnimeEyesHub = {
            version = "2.5.0",
            cfg = cfg,
            saveConfig = function() return uiHooks.saveNamedCfg() end,
            loadConfig = function() return uiHooks.loadNamedCfg() end,
            reportNow = function()
                wh.nextAt = 0
                updateWhStatus()
                return "queued"
            end,
            unload = function() unload() end,
            runTag = RUN_TAG,
            statuses = {
                Main = MainStatus, Farm = FarmStatus, Boss = BossStatus,
                Pets = PetsStatus, Max = MaxStatus, Set = SetStatus,
            },
        }
    end
end)

end

boot()
