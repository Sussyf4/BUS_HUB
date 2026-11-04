--[[
    BUS HUB — Train / Punch / Wall Breaker / Rebirth / Eggs / Pets / Relics
    UI: WindUI (Footagesus)

    Verified game mechanics (reverse-engineered from the live client):
      Remotes.Train                 :FireServer()                       -> +strength
      Remotes.Punch                 :FireServer("LeftHand"/"RightHand")  -> wall damage
      Remotes.Rebirth               :InvokeServer(1/10/100)              -> true on success
      Remotes.TeleportLoadUI:Fire() then Remotes.Teleport:FireServer(w)  -> switch world 1..5
      Remotes.PetRemotes.HatchEgg   :InvokeServer(eggName, amount, {petNamesToDelete})
      Remotes.PetRemotes.GetPetInventory :InvokeServer() -> { Owned = {[uid]={Name,Variant}}, Equipped = {uid}, MaxStorage, MaxEquipped }
      Remotes.PetRemotes.DeletePets :InvokeServer({petUid, ...})
      Remotes.Relics.GetRelicShop   :InvokeServer() -> { Items = {name,...}, Purchased = {[name]=bool} }
      Remotes.Relics.BuyRelic       :InvokeServer(shopIndex) -> true on success

    Walls: a wall dies when its health hits 0 -> CanCollide=false, Transparency=1.
    Claiming a stage = firetouchinterest on WinPad.GuiPart.
    Eggs only hatch while you stand within ~18 studs of the egg model, in that egg's world.

    Window: RightShift toggles · minimize keeps farming + floating button · close (X) stops the script.
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LP = Players.LocalPlayer
local Remotes = RS:WaitForChild("Remotes")

local CONFIG_FILE = "bushub-config.json"

-- ------------------------------------------------------------------ teardown of any previous run

for _, key in ipairs({ "WallFarm", "BusHub" }) do
	local prev = getgenv()[key]
	if prev and prev.Unload then
		pcall(function() prev.Unload() end)
	end
end

local function winduiInstances()
	local out = {}
	local roots = { game:GetService("CoreGui") }
	if gethui then pcall(function() table.insert(roots, gethui()) end) end
	for _, root in ipairs(roots) do
		pcall(function()
			local host = root:FindFirstChild("RobloxGui") or root
			for _, g in ipairs(host:GetChildren()) do
				if g.Name == "WindUI" or g.Name:match("^WindUI/") then
					table.insert(out, g)
				end
			end
		end)
	end
	return out
end

for _, g in ipairs(winduiInstances()) do
	pcall(function() g:Destroy() end)
end

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
if gethui then pcall(function() WindUI:SetParent(gethui()) end) end

-- ------------------------------------------------------------------ game data

local okPet, PetStats = pcall(function() return require(RS.Modules.PetStats) end)
local okRelic, RelicModule = pcall(function() return require(RS.Modules.RelicModule) end)

PetStats = okPet and PetStats or { EggStats = {}, Pets = {}, Rarities = {} }
RelicModule = okRelic and RelicModule or { RelicStats = {}, RarityStats = {} }

local RARITY_ORDER = {}
do
	local n = 0
	for name in pairs(PetStats.Rarities) do
		n = n + 1
		RARITY_ORDER[name] = n
	end
	for name in pairs(RelicModule.RarityStats) do
		if not RARITY_ORDER[name] then
			n = n + 1
			RARITY_ORDER[name] = n
		end
	end
end

local function rarityRank(name)
	return RARITY_ORDER[name] or 99
end

-- ------------------------------------------------------------------ state

local State = {
	Dead = false,
	Ticks = 0,
	TrainFires = 0,
	LastError = nil,
	Status = "idle",
	HatchStatus = "idle",
	PetStatus = "idle",
	RelicStatus = "idle",

	AutoTrain = false,
	AutoPunch = false,
	Delay = 0.05,

	AutoBreak = false,
	AutoAdvance = false,
	ReturnToSpot = true,
	World = LP:GetAttribute("CurrentWorldNumber") or 4,
	Stage = (LP:GetAttribute("CompletedStage") or 0) + 1,

	Rebirth = 0,

	AutoHatch = false,
	HatchDelay = 0.45,
	Eggs = {},
	EggWorldCache = {},

	AutoDelete = false,
	KeepPets = {},
	DeleteCooldown = 6,

	AutoBuy = false,
	Relics = {},

	TeleportWorld = 1,
	AutoLoad = false,

	Busy = false,
}

local Threads = {}

getgenv().BusHub = State

-- ------------------------------------------------------------------ helpers

local function getChar()
	local c = LP.Character
	if not c then return nil end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local hrp = c:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 and hrp.Parent then return c, hrp end
	return nil
end

local function stat(name)
	local ls = LP:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return v and v.Value or 0
end

local function fire(name, ...)
	local r = Remotes:FindFirstChild(name)
	if not r then return end
	local args = table.pack(...)
	pcall(function() r:FireServer(table.unpack(args, 1, args.n)) end)
end

local function short(n)
	n = tonumber(n) or 0
	local units = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 0
	while n >= 1000 and i < #units do
		n = n / 1000
		i = i + 1
	end
	return string.format("%.2f%s", n, i == 0 and "" or units[i])
end

local function worldOf(stageNo)
	return math.clamp(math.ceil(stageNo / 15), 1, 5)
end

local function inList(list, value)
	for _, v in ipairs(list or {}) do
		if v == value then return true end
	end
	return false
end

local function labelName(label)
	local head = tostring(label):match("^(.-) ·")
	return head or tostring(label)
end

-- ---- stages

local function stagesOf(worldNo)
	local w = workspace:FindFirstChild("World" .. worldNo)
	local stages = w and w:FindFirstChild("Stages")
	local out = {}
	if not stages then return out end
	for _, f in ipairs(stages:GetChildren()) do
		local wp = f:FindFirstChild("WinPad")
		local num = wp and wp:GetAttribute("StageNumber")
		if num then
			table.insert(out, {
				folder = f,
				number = num,
				reward = wp:GetAttribute("WinsReward") or 0,
				name = f.Name,
			})
		end
	end
	table.sort(out, function(a, b) return a.number < b.number end)
	return out
end

local function findStage(worldNo, stageNo)
	for _, s in ipairs(stagesOf(worldNo)) do
		if s.number == stageNo then return s end
	end
	return nil
end

local function wallsOf(stage)
	local wf = stage and stage.folder:FindFirstChild("WallFolder")
	local out = {}
	if not wf then return out end
	for _, c in ipairs(wf:GetChildren()) do
		if c:IsA("BasePart") then table.insert(out, c) end
	end
	table.sort(out, function(a, b) return a.Position.Z > b.Position.Z end)
	return out
end

local function ensureWorld(worldNo)
	if (LP:GetAttribute("CurrentWorldNumber") or 0) == worldNo then return true end
	pcall(function() Remotes.TeleportLoadUI:Fire() end)
	task.wait(0.7)
	fire("Teleport", worldNo)
	for _ = 1, 60 do
		task.wait(0.25)
		if State.Dead then return false end
		if (LP:GetAttribute("CurrentWorldNumber") or 0) == worldNo then
			task.wait(1.2)
			return true
		end
	end
	return false
end

local function breakWall(wall, timeout)
	local t0 = os.clock()
	local spot = wall.Position + Vector3.new(0, 0, 10)

	while wall.CanCollide and (os.clock() - t0) < (timeout or 4) do
		if State.Dead then return false end
		local _, hrp = getChar()
		if not hrp then return false end
		hrp.CFrame = CFrame.new(spot)
		task.wait(0.04)
		fire("Punch", "LeftHand")
		fire("Punch", "RightHand")
		task.wait(State.Delay)
	end
	return wall.CanCollide == false
end

local function claim(stage)
	local _, hrp = getChar()
	local wp = stage.folder:FindFirstChild("WinPad")
	local gp = wp and wp:FindFirstChild("GuiPart")
	if not gp or not hrp then return false end

	local winsBefore = stat("Wins")
	local completedBefore = LP:GetAttribute("CompletedStage")

	hrp.CFrame = CFrame.new(gp.Position + Vector3.new(0, 2.5, 0))
	task.wait(0.25)
	pcall(function() firetouchinterest(hrp, gp, 0) end)
	task.wait(0.1)
	pcall(function() firetouchinterest(hrp, gp, 1) end)
	task.wait(0.7)

	return stat("Wins") > winsBefore or LP:GetAttribute("CompletedStage") ~= completedBefore
end

local runStage

do
	local function run(stageNo)
		local _, hrp0 = getChar()
		local startCF = hrp0 and hrp0.CFrame

		local worldNo = worldOf(stageNo)
		local broken, total = 0, 0

		if not ensureWorld(worldNo) then
			return false, "world " .. worldNo .. " did not load"
		end

		local stage = findStage(worldNo, stageNo)
		if not stage then
			return false, "stage " .. stageNo .. " not found in world " .. worldNo
		end

		local walls = wallsOf(stage)
		total = #walls
		for i, wall in ipairs(walls) do
			if State.Dead then return false, "stopped" end
			State.Status = string.format("stage %d — wall %d/%d", stageNo, i, total)
			if wall.CanCollide then breakWall(wall) end
			if not wall.CanCollide then broken = broken + 1 end
		end

		State.Status = string.format("stage %d — claiming", stageNo)
		local claimed = claim(stage)

		if State.ReturnToSpot and startCF then
			local _, hrp = getChar()
			if hrp then hrp.CFrame = startCF end
		end

		State.Status = string.format("stage %d — %d/%d walls, claim %s", stageNo, broken, total, claimed and "OK" or "FAILED")
		return claimed, State.Status
	end

	runStage = function(stageNo, keepPosition)
		if State.Busy then return false, "busy" end
		State.Busy = true

		local wasReturn = State.ReturnToSpot
		if keepPosition ~= nil then State.ReturnToSpot = keepPosition end

		local ok, a = pcall(run, stageNo)

		State.ReturnToSpot = wasReturn
		State.Busy = false

		if not ok then
			State.LastError = "runner: " .. tostring(a)
			State.Status = "runner error"
			return false, tostring(a)
		end
		return a, State.Status
	end
end

State.RunStage = runStage

-- ---- eggs / pets

local function eggList()
	local out = {}
	for name, info in pairs(PetStats.EggStats) do
		table.insert(out, {
			name = name,
			world = info.WorldNumber or 1,
			cost = info.Cost or 0,
			currency = info.Currency or "Wins",
		})
	end
	table.sort(out, function(a, b)
		if a.world ~= b.world then return a.world < b.world end
		return a.cost < b.cost
	end)
	return out
end

local function eggLabels()
	local out = {}
	for _, e in ipairs(eggList()) do
		table.insert(out, string.format("%s · W%d · %s %s", e.name, e.world, short(e.cost), e.currency))
	end
	return out
end

local function eggInfo(name)
	return PetStats.EggStats[name]
end

local function petPools()
	local seen, out = {}, {}
	for _, info in pairs(PetStats.Pets) do
		if not seen[info.Rarity] then
			seen[info.Rarity] = true
		end
	end
	for name, info in pairs(PetStats.Pets) do
		table.insert(out, { name = name, rarity = info.Rarity or "Common", mult = info.Multiplier or 1 })
	end
	table.sort(out, function(a, b)
		local ra, rb = rarityRank(a.rarity), rarityRank(b.rarity)
		if ra ~= rb then return ra < rb end
		if a.mult ~= b.mult then return a.mult < b.mult end
		return a.name < b.name
	end)
	return out
end

local function petLabels()
	local out = {}
	for _, p in ipairs(petPools()) do
		table.insert(out, string.format("%s · %s · x%.2f", p.name, p.rarity, p.mult))
	end
	return out
end

local function findEggModel(name, worldNo)
	local world = workspace:FindFirstChild("World" .. worldNo)
	if not world then return nil end
	for _, d in ipairs(world:GetDescendants()) do
		if d.Name == name and d:IsA("Model") then
			return d
		end
	end
	return nil
end

local function petInventory()
	local ok, inv = pcall(function() return Remotes.PetRemotes.GetPetInventory:InvokeServer() end)
	if ok and type(inv) == "table" and inv.Owned then return inv end
	return nil
end

local function equippedNames(inv)
	local set = {}
	if not inv then return set end
	for _, uid in pairs(inv.Equipped or {}) do
		local info = inv.Owned[uid]
		if info then set[info.Name] = true end
	end
	return set
end

-- ---- hatch / delete

local function hatchOnce()
	local selected = {}
	for _, label in ipairs(State.Eggs) do
		local name = labelName(label)
		if eggInfo(name) then table.insert(selected, name) end
	end
	if #selected == 0 then
		State.HatchStatus = "no egg selected"
		return false
	end

	local wins = stat("Wins")
	local target
	for _, name in ipairs(selected) do
		local info = eggInfo(name)
		if info.Currency == "Wins" and wins >= info.Cost then
			target = name
			break
		end
	end

	if not target then
		State.HatchStatus = "cannot afford selected eggs"
		return false
	end

	local info = eggInfo(target)
	local worldNo = info.WorldNumber or 1

	if not ensureWorld(worldNo) then
		State.HatchStatus = "world " .. worldNo .. " did not load"
		return false
	end

	local eggModel = findEggModel(target, worldNo)
	if not eggModel then
		State.HatchStatus = "egg model not found in world " .. worldNo
		return false
	end

	local _, hrp = getChar()
	if not hrp then return false end

	hrp.CFrame = CFrame.new(eggModel:GetPivot().Position + Vector3.new(0, 4, 9))
	task.wait(0.3)

	local deleteList = {}
	if State.AutoDelete then
		local inv = petInventory()
		local equipped = equippedNames(inv)
		for petName in pairs(info.Pets or {}) do
			if not inList(State.KeepPets, petName) and not equipped[petName] then
				table.insert(deleteList, petName)
			end
		end
	end

	local ok, result = pcall(function()
		return Remotes.PetRemotes.HatchEgg:InvokeServer(target, 1, deleteList)
	end)

	if ok and result then
		State.HatchStatus = string.format("%s hatched%s", target, State.AutoDelete and (" (auto-delete " .. #deleteList .. " types)") or "")
		return true
	end

	State.HatchStatus = string.format("%s failed (%s)", target, tostring(result))
	return false
end

local function deleteSweep()
	local inv = petInventory()
	if not inv then
		State.PetStatus = "inventory unavailable"
		return 0
	end

	local equipped = {}
	for _, uid in pairs(inv.Equipped or {}) do
		equipped[uid] = true
	end

	local doomed = {}
	for uid, info in pairs(inv.Owned) do
		if not equipped[uid] and not inList(State.KeepPets, info.Name) then
			table.insert(doomed, uid)
			if #doomed >= 40 then break end
		end
	end

	if #doomed == 0 then
		State.PetStatus = "nothing to delete"
		return 0
	end

	local ok, result = pcall(function()
		return Remotes.PetRemotes.DeletePets:InvokeServer(doomed)
	end)

	if ok then
		State.PetStatus = string.format("deleted %d pets", #doomed)
		return #doomed
	end

	State.PetStatus = "delete failed"
	return 0
end

-- ---- relics

local function relicLabels()
	local out = {}
	for name, info in pairs(RelicModule.RelicStats) do
		local mult = info.StrengthMultiplier or 1
		table.insert(out, {
			label = string.format("%s · %s · +%d%% · %s wins", name, info.Rarity or "?",
				math.floor((mult - 1) * 100 + 0.5), short(info.WinsCost or 0)),
			name = name,
			rarity = info.Rarity or "?",
			cost = info.WinsCost or math.huge,
		})
	end
	table.sort(out, function(a, b)
		local ra, rb = rarityRank(a.rarity), rarityRank(b.rarity)
		if ra ~= rb then return ra < rb end
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.name < b.name
	end)
	local labels = {}
	for _, r in ipairs(out) do table.insert(labels, r.label) end
	return labels
end

local function buyRelicOnce()
	if #State.Relics == 0 then
		State.RelicStatus = "no relic selected"
		return false
	end

	local okShop, shop = pcall(function() return Remotes.Relics.GetRelicShop:InvokeServer() end)
	if not okShop or type(shop) ~= "table" or not shop.Items then
		State.RelicStatus = "shop unavailable"
		return false
	end

	local okInv, inv = pcall(function() return Remotes.Relics.GetRelicInventory:InvokeServer() end)
	if okInv and type(inv) == "table" and inv.MaxSlots and inv.Relics and #inv.Relics >= inv.MaxSlots then
		State.RelicStatus = string.format("relic slots full (%d/%d)", #inv.Relics, inv.MaxSlots)
		return false
	end

	local wanted = {}
	for _, label in ipairs(State.Relics) do
		wanted[labelName(label)] = true
	end

	local wins = stat("Wins")
	for index, name in ipairs(shop.Items) do
		if wanted[name] and not (shop.Purchased and shop.Purchased[name]) then
			local info = RelicModule.RelicStats[name]
			local cost = info and info.WinsCost or math.huge
			if wins >= cost then
				local okBuy, bought = pcall(function() return Remotes.Relics.BuyRelic:InvokeServer(index) end)
				State.RelicStatus = string.format("%s %s", name, (okBuy and bought) and "bought" or "buy failed")
				return okBuy and bought or false
			else
				State.RelicStatus = string.format("%s too expensive (%s wins)", name, short(cost))
				return false
			end
		end
	end

	State.RelicStatus = "nothing to buy in this shop"
	return false
end

-- ------------------------------------------------------------------ unload

function State.Unload()
	if State.Dead then return end
	State.Dead = true
	State.AutoTrain = false
	State.AutoPunch = false
	State.AutoBreak = false
	State.AutoAdvance = false
	State.Rebirth = 0
	State.AutoHatch = false
	State.AutoDelete = false
	State.AutoBuy = false

	for _, t in ipairs(Threads) do
		pcall(task.cancel, t)
	end
	table.clear(Threads)

	if getgenv().BusHub == State then
		getgenv().BusHub = nil
		for _, g in ipairs(winduiInstances()) do
			pcall(function() g:Destroy() end)
		end
	end
end

-- ------------------------------------------------------------------ UI

local Window = WindUI:CreateWindow({
	Title = "BUS HUB",
	Folder = "BusHub",
	Icon = "solar:bone-bold",
	Theme = "Dark",
	Size = UDim2.fromOffset(560, 620),
	NewElements = true,
	Topbar = { Height = 44, ButtonsType = "Mac" },
	OpenButton = {
		Title = "BUS HUB",
		Icon = "solar:bone-bold",
		CornerRadius = UDim.new(0, 12),
		StrokeThickness = 2,
		OnlyMobile = false,
		Enabled = true,
		Draggable = true,
	},
})

pcall(function() Window:SetToggleKey(Enum.KeyCode.RightShift) end)

Window:Tag({ Title = "v3", Icon = "github", Color = Color3.fromHex("#1c1c1c"), Border = true })

local TabFarm = Window:Tab({ Title = "Farm", Icon = "solar:play-bold" })
local TabWalls = Window:Tab({ Title = "Walls", Icon = "solar:bricks-bold" })
local TabRebirth = Window:Tab({ Title = "Rebirth", Icon = "solar:refresh-bold" })
local TabPets = Window:Tab({ Title = "Pets & Relics", Icon = "solar:star-bold" })
local TabSettings = Window:Tab({ Title = "Settings", Icon = "solar:settings-bold" })

-- ---- Farm

local StatsLabel = TabFarm:Paragraph({
	Title = "—",
	Desc = "loading",
})

local FarmSection = TabFarm:Section({ Title = "Automation" })

local ToggleTrain = FarmSection:Toggle({
	Title = "Auto Train",
	Desc = "Fires Remotes.Train every tick",
	Value = false,
	Callback = function(v) State.AutoTrain = v end,
})

FarmSection:Space()

local TogglePunch = FarmSection:Toggle({
	Title = "Auto Punch",
	Desc = "Alternates LeftHand / RightHand on Remotes.Punch",
	Value = false,
	Callback = function(v) State.AutoPunch = v end,
})

FarmSection:Space()

local DelaySlider = FarmSection:Slider({
	Title = "Tick delay",
	Desc = "Seconds between remote fires",
	Value = { Min = 0.01, Max = 0.2, Default = 0.05 },
	Step = 0.01,
	IsTooltip = true,
	Callback = function(v) State.Delay = v end,
})

-- ---- Walls

local WallsSection = TabWalls:Section({ Title = "Target" })

local StageDropdown

local function stageLabels(worldNo)
	local labels = {}
	local byNumber = {}
	for _, s in ipairs(stagesOf(worldNo)) do
		byNumber[s.number] = s
	end

	for n = (worldNo - 1) * 15 + 1, worldNo * 15 do
		local s = byNumber[n]
		if s then
			table.insert(labels, string.format("%d · %s · +%s", n, s.name, short(s.reward)))
		else
			table.insert(labels, string.format("%d · stage", n))
		end
	end
	return labels
end

local WorldDropdown = WallsSection:Dropdown({
	Title = "World",
	Values = { "World 1", "World 2", "World 3", "World 4", "World 5" },
	Value = "World " .. State.World,
	Callback = function(option)
		State.World = tonumber(tostring(option):match("%d+")) or State.World
		pcall(function() StageDropdown:Refresh(stageLabels(State.World)) end)
	end,
})

WallsSection:Space()

StageDropdown = WallsSection:Dropdown({
	Title = "Stage",
	Values = stageLabels(State.World),
	Value = stageLabels(State.World)[math.clamp(State.Stage - (State.World - 1) * 15, 1, 15)],
	Callback = function(option)
		local n = tonumber(tostring(option):match("^(%d+)"))
		if n then State.Stage = n end
	end,
})

local RunSection = TabWalls:Section({ Title = "Runner" })

RunSection:Button({
	Title = "Break & Win Now",
	Icon = "solar:play-circle-bold",
	Justify = "Center",
	Callback = function()
		if State.Busy then
			WindUI:Notify({ Title = "Busy", Content = "A run is already in progress", Icon = "clock", Duration = 3 })
			return
		end
		task.spawn(function()
			local ok, msg = runStage(State.Stage, State.ReturnToSpot)
			WindUI:Notify({
				Title = ok and "Stage cleared" or "Stage failed",
				Content = msg,
				Icon = ok and "check" or "x",
				Duration = 4,
			})
		end)
	end,
})

RunSection:Space()

local ToggleAutoBreak = RunSection:Toggle({
	Title = "Auto Break (selected stage)",
	Desc = "Repeats the stage above until it is claimed",
	Value = false,
	Callback = function(v) State.AutoBreak = v end,
})

RunSection:Space()

local ToggleAutoAdvance = RunSection:Toggle({
	Title = "Auto Advance",
	Desc = "Always targets CompletedStage + 1 and keeps going",
	Value = false,
	Callback = function(v) State.AutoAdvance = v end,
})

RunSection:Space()

local ToggleReturn = RunSection:Toggle({
	Title = "Return to spot after win",
	Value = true,
	Callback = function(v) State.ReturnToSpot = v end,
})

-- ---- Rebirth

local RebSection = TabRebirth:Section({ Title = "Auto Rebirth" })

local function setRebirth(amount, value, otherA, otherB)
	if value then
		State.Rebirth = amount
		if otherA then pcall(function() otherA:Set(false) end) end
		if otherB then pcall(function() otherB:Set(false) end) end
	elseif State.Rebirth == amount then
		State.Rebirth = 0
	end
end

local T1, T10, T100

T1 = RebSection:Toggle({
	Title = "Auto Rebirth x1",
	Value = false,
	Callback = function(v) setRebirth(1, v, T10, T100) end,
})

RebSection:Space()

T10 = RebSection:Toggle({
	Title = "Auto Rebirth x10",
	Value = false,
	Callback = function(v) setRebirth(10, v, T1, T100) end,
})

RebSection:Space()

T100 = RebSection:Toggle({
	Title = "Auto Rebirth x100",
	Value = false,
	Callback = function(v) setRebirth(100, v, T1, T10) end,
})

TabRebirth:Space()

local RebInfo = TabRebirth:Section({ Title = "Info" })
RebInfo:Paragraph({
	Title = "How it works",
	Desc = "Invokes Remotes.Rebirth with the tier amount every 0.8s. The server returns false while you are short on strength — the loop just retries.",
})

-- ---- Pets & Relics

local HatchSection = TabPets:Section({ Title = "Auto Hatch" })

local EggDropdown = HatchSection:Dropdown({
	Title = "Eggs to hatch",
	Desc = "Multi-select. Eggs from every world — the script travels to the right world and egg.",
	Values = eggLabels(),
	Multi = true,
	Value = {},
	Callback = function(selected)
		State.Eggs = {}
		for _, v in ipairs(selected or {}) do table.insert(State.Eggs, v) end
	end,
})

HatchSection:Space()

local ToggleAutoHatch = HatchSection:Toggle({
	Title = "Auto Hatch",
	Desc = "Buys and hatches the selected eggs, cheapest first",
	Value = false,
	Callback = function(v) State.AutoHatch = v end,
})

HatchSection:Space()

local HatchDelaySlider = HatchSection:Slider({
	Title = "Hatch delay",
	Desc = "Seconds between hatches",
	Value = { Min = 0.2, Max = 2, Default = 0.45 },
	Step = 0.05,
	IsTooltip = true,
	Callback = function(v) State.HatchDelay = v end,
})

TabPets:Space()

local DeleteSection = TabPets:Section({ Title = "Auto Delete Pets" })

local KeepDropdown = DeleteSection:Dropdown({
	Title = "Keep pets",
	Desc = "Multi-select. Equipped pets are always kept.",
	Values = petLabels(),
	Multi = true,
	Value = {},
	Callback = function(selected)
		State.KeepPets = {}
		for _, v in ipairs(selected or {}) do table.insert(State.KeepPets, v) end
	end,
})

DeleteSection:Space()

local ToggleAutoDelete = DeleteSection:Toggle({
	Title = "Auto Delete",
	Desc = "Deletes every pet that is NOT equipped and NOT in the keep list (also used while hatching)",
	Value = false,
	Callback = function(v) State.AutoDelete = v end,
})

DeleteSection:Space()

DeleteSection:Paragraph({
	Title = "Careful",
	Desc = "With an empty keep list this deletes everything you do not have equipped. Fill the keep list first.",
})

TabPets:Space()

local RelicSection = TabPets:Section({ Title = "Auto Buy Relic" })

local RelicDropdown = RelicSection:Dropdown({
	Title = "Relics to buy",
	Desc = "Multi-select. Buys them from the rotating relic shop when they appear.",
	Values = relicLabels(),
	Multi = true,
	Value = {},
	Callback = function(selected)
		State.Relics = {}
		for _, v in ipairs(selected or {}) do table.insert(State.Relics, v) end
	end,
})

RelicSection:Space()

local ToggleAutoBuy = RelicSection:Toggle({
	Title = "Auto Buy Relic",
	Desc = "Checks the relic shop every few seconds and buys anything selected",
	Value = false,
	Callback = function(v) State.AutoBuy = v end,
})

RelicSection:Space()

RelicSection:Paragraph({
	Title = "Storage",
	Desc = "Relic slots are limited. When they are full nothing more can be bought — the status line says so.",
})

-- ---- Settings

local ConfigSection = TabSettings:Section({ Title = "Config" })

local ToggleAutoLoad = ConfigSection:Toggle({
	Title = "Auto load config on start",
	Desc = "Loads " .. CONFIG_FILE .. " whenever this script runs",
	Value = false,
	Callback = function(v) State.AutoLoad = v end,
})

ConfigSection:Space()

ConfigSection:Button({
	Title = "Save config",
	Icon = "solar:diskette-bold",
	Justify = "Center",
	Callback = function()
		local data = {
			autoTrain = State.AutoTrain,
			autoPunch = State.AutoPunch,
			delay = State.Delay,
			autoBreak = State.AutoBreak,
			autoAdvance = State.AutoAdvance,
			returnToSpot = State.ReturnToSpot,
			rebirth = State.Rebirth,
			autoHatch = State.AutoHatch,
			hatchDelay = State.HatchDelay,
			eggs = State.Eggs,
			autoDelete = State.AutoDelete,
			keepPets = State.KeepPets,
			autoBuy = State.AutoBuy,
			relics = State.Relics,
			teleportWorld = State.TeleportWorld,
			autoLoad = State.AutoLoad,
		}
		local ok = pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(data)) end)
		WindUI:Notify({
			Title = ok and "Config saved" or "Save failed",
			Content = CONFIG_FILE,
			Icon = ok and "check" or "x",
			Duration = 3,
		})
	end,
})

ConfigSection:Space()

ConfigSection:Button({
	Title = "Load config",
	Icon = "solar:folder-open-bold",
	Justify = "Center",
	Callback = function()
		loadConfig(true)
	end,
})

TabSettings:Space()

local TPSection = TabSettings:Section({ Title = "Teleport" })

local TeleportDropdown = TPSection:Dropdown({
	Title = "World",
	Values = { "World 1", "World 2", "World 3", "World 4", "World 5" },
	Value = "World " .. State.TeleportWorld,
	Callback = function(option)
		State.TeleportWorld = tonumber(tostring(option):match("%d+")) or State.TeleportWorld
	end,
})

TPSection:Space()

TPSection:Button({
	Title = "Teleport to world",
	Icon = "solar:map-arrow-right-bold",
	Justify = "Center",
	Callback = function()
		task.spawn(function()
			local ok = ensureWorld(State.TeleportWorld)
			WindUI:Notify({
				Title = ok and ("World " .. State.TeleportWorld) or "Teleport failed",
				Content = ok and "arrived" or "world did not load",
				Icon = ok and "check" or "x",
				Duration = 3,
			})
		end)
	end,
})

TabSettings:Space()

local ScriptSection = TabSettings:Section({ Title = "Script" })

ScriptSection:Paragraph({
	Title = "Window",
	Desc = "RightShift toggles the menu. Minimize keeps everything running and leaves a floating button. Close (X) stops the script.",
})

ScriptSection:Space()

ScriptSection:Button({
	Title = "Stop & Unload script",
	Icon = "solar:power-bold",
	Justify = "Center",
	Callback = function() State.Unload() end,
})

-- ------------------------------------------------------------------ config load

local applyUI

function loadConfig(showToast)
	if not (isfile and isfile(CONFIG_FILE)) then
		if showToast then
			WindUI:Notify({ Title = "No config found", Content = CONFIG_FILE, Icon = "x", Duration = 3 })
		end
		return false
	end

	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
	if not ok or type(data) ~= "table" then
		if showToast then
			WindUI:Notify({ Title = "Config unreadable", Content = CONFIG_FILE, Icon = "x", Duration = 3 })
		end
		return false
	end

	State.AutoTrain = data.autoTrain == true
	State.AutoPunch = data.autoPunch == true
	State.Delay = tonumber(data.delay) or 0.05
	State.AutoBreak = data.autoBreak == true
	State.AutoAdvance = data.autoAdvance == true
	State.ReturnToSpot = data.returnToSpot ~= false
	State.Rebirth = tonumber(data.rebirth) or 0
	State.AutoHatch = data.autoHatch == true
	State.HatchDelay = tonumber(data.hatchDelay) or 0.45
	State.AutoDelete = data.autoDelete == true
	State.AutoBuy = data.autoBuy == true
	State.TeleportWorld = tonumber(data.teleportWorld) or 1
	State.AutoLoad = data.autoLoad == true

	State.Eggs = type(data.eggs) == "table" and data.eggs or {}
	State.KeepPets = type(data.keepPets) == "table" and data.keepPets or {}
	State.Relics = type(data.relics) == "table" and data.relics or {}

	if applyUI then applyUI() end

	if showToast then
		WindUI:Notify({ Title = "Config loaded", Content = CONFIG_FILE, Icon = "check", Duration = 3 })
	end
	return true
end

function applyUI()
	pcall(function() ToggleTrain:Set(State.AutoTrain) end)
	pcall(function() TogglePunch:Set(State.AutoPunch) end)
	pcall(function() DelaySlider:Set(State.Delay) end)
	pcall(function() ToggleAutoBreak:Set(State.AutoBreak) end)
	pcall(function() ToggleAutoAdvance:Set(State.AutoAdvance) end)
	pcall(function() ToggleReturn:Set(State.ReturnToSpot) end)

	pcall(function() T1:Set(State.Rebirth == 1) end)
	pcall(function() T10:Set(State.Rebirth == 10) end)
	pcall(function() T100:Set(State.Rebirth == 100) end)

	pcall(function() ToggleAutoHatch:Set(State.AutoHatch) end)
	pcall(function() HatchDelaySlider:Set(State.HatchDelay) end)
	pcall(function() EggDropdown:Select(State.Eggs) end)

	pcall(function() ToggleAutoDelete:Set(State.AutoDelete) end)
	pcall(function() KeepDropdown:Select(State.KeepPets) end)

	pcall(function() ToggleAutoBuy:Set(State.AutoBuy) end)
	pcall(function() RelicDropdown:Select(State.Relics) end)

	pcall(function() ToggleAutoLoad:Set(State.AutoLoad) end)
	pcall(function() TeleportDropdown:Set("World " .. State.TeleportWorld) end)
end

-- ------------------------------------------------------------------ loops

local function supervise(name, fn)
	local thread = task.spawn(function()
		while not State.Dead do
			local ok, err = pcall(fn)
			if State.Dead or ok then break end
			State.LastError = name .. ": " .. tostring(err)
			task.wait(1)
		end
	end)
	table.insert(Threads, thread)
	return thread
end

supervise("train/punch", function()
	while true do
		task.wait(State.Delay)
		State.Ticks = State.Ticks + 1
		if State.AutoTrain then
			State.TrainFires = State.TrainFires + 1
			fire("Train")
		end
		if State.AutoPunch then
			fire("Punch", (os.clock() * 100) % 2 < 1 and "LeftHand" or "RightHand")
		end
	end
end)

supervise("rebirth", function()
	while true do
		task.wait(0.8)
		if State.Rebirth > 0 then
			pcall(function() Remotes.Rebirth:InvokeServer(State.Rebirth) end)
		end
	end
end)

supervise("wall runner", function()
	while true do
		task.wait(0.4)
		if State.AutoAdvance and not State.Busy then
			local nextStage = (LP:GetAttribute("CompletedStage") or 0) + 1
			if nextStage <= 75 then
				runStage(nextStage, State.ReturnToSpot)
			else
				State.Status = "all stages complete"
				State.AutoAdvance = false
			end
		elseif State.AutoBreak and not State.Busy then
			runStage(State.Stage, State.ReturnToSpot)
		end
	end
end)

supervise("hatch", function()
	while true do
		task.wait(State.AutoHatch and 0.05 or 0.5)
		if State.AutoHatch then
			pcall(hatchOnce)
			task.wait(State.HatchDelay)
		end
	end
end)

supervise("pet delete", function()
	while true do
		task.wait(State.DeleteCooldown)
		if State.AutoDelete and not State.AutoHatch then
			pcall(deleteSweep)
		end
	end
end)

supervise("relic buy", function()
	while true do
		task.wait(3)
		if State.AutoBuy then
			pcall(buyRelicOnce)
		end
	end
end)

supervise("stats", function()
	local prevTicks, prevClock = State.Ticks, os.clock()
	while true do
		task.wait(1)
		local now = os.clock()
		local rate = math.floor((State.Ticks - prevTicks) / math.max(now - prevClock, 0.001))
		prevTicks, prevClock = State.Ticks, now

		local head = string.format("Wins %s  ·  Strength %s", short(stat("Wins")), short(stat("Strength")))
		local desc = string.format(
			"Rebirth %d  ·  Stage %s  ·  loop %d/s  ·  walls: %s  ·  eggs: %s  ·  pets: %s  ·  relics: %s",
			math.floor(stat("Rebirth")),
			tostring(LP:GetAttribute("CompletedStage")),
			rate,
			State.Status,
			State.HatchStatus,
			State.PetStatus,
			State.RelicStatus
		)
		if State.LastError then
			desc = desc .. "  ·  ERR " .. State.LastError:sub(1, 40)
		end
		pcall(function() StatsLabel:Set({ Title = head, Desc = desc }) end)
	end
end)

-- ------------------------------------------------------------------ watchdog + startup

local function findWindowGui()
	local roots = { game:GetService("CoreGui") }
	if gethui then pcall(function() table.insert(roots, gethui()) end) end
	local found = nil

	local function scan(node, depth)
		if found or depth > 4 then return end
		for _, c in ipairs(node:GetChildren()) do
			if found then return end
			if c.Name == "WindUI" and c:IsA("ScreenGui") then
				found = c
				return
			end
			pcall(scan, c, depth + 1)
		end
	end

	for _, root in ipairs(roots) do
		pcall(scan, root, 0)
		if found then break end
	end
	return found
end

local windowGui = findWindowGui()

if windowGui then
	windowGui.Destroying:Connect(function()
		State.Unload()
	end)
end

supervise("watchdog", function()
	local misses = 0
	while true do
		task.wait(0.5)
		if getgenv().BusHub ~= State then break end
		local alive = windowGui and windowGui.Parent ~= nil
		if not alive and windowGui == nil then
			windowGui = findWindowGui()
			alive = windowGui ~= nil
		end
		if alive then
			misses = 0
		else
			misses = misses + 1
			if misses >= 3 then
				State.Unload()
				break
			end
		end
	end
end)

if State.AutoLoad or (isfile and isfile(CONFIG_FILE)) then
	task.defer(function()
		local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
		if ok and type(data) == "table" and data.autoLoad == true then
			loadConfig(false)
			WindUI:Notify({ Title = "Config auto-loaded", Content = CONFIG_FILE, Icon = "check", Duration = 4 })
		end
	end)
end

WindUI:Notify({
	Title = "BUS HUB loaded",
	Content = "RightShift toggles the menu. Close (X) stops the script.",
	Icon = "check",
	Duration = 5,
})
