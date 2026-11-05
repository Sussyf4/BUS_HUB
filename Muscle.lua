--[[
    BUS HUB — Train / Punch / Wall Breaker / Rebirth / Eggs / Relics
    UI: WindUI (Footagesus)

    Movement is pure client-side CFrame (no game Teleport remote):
      World anchors = Workspace.World<N>.Content.Spawn.SpawnLocation
      Stage pads    = spawnX + 36 , z = 10 - 90 * stageIndexInWorld

    Verified remotes:
      Remotes.Train                 :FireServer()                       -> +strength
      Remotes.Punch                 :FireServer("LeftHand"/"RightHand")  -> wall damage
      Remotes.Rebirth               :InvokeServer(1/10/100)
      Remotes.PetRemotes.HatchEgg   :InvokeServer(eggName, amount, {petNamesToDelete})  (must stand near egg)
      Remotes.PetRemotes.GetPetInventory :InvokeServer() -> { Owned, Equipped, MaxStorage, MaxEquipped }
      Remotes.Relics.GetRelicShop   :InvokeServer() -> { Items, Purchased, Cycle, RestockTime }
      Remotes.Relics.GetRelicInventory :InvokeServer() -> { Relics, EquippedRelics, MaxSlots }
      Remotes.Relics.BuyRelic       :InvokeServer(relicName)   -- NAME, not slot number
      Remotes.Relics.DeleteRelic    :InvokeServer({ uid, ... })

    Eggs live in Workspace.MainEggs and are always replicated, so teleporting
    next to the model satisfies the server's proximity check for hatching.

    Window: RightShift toggles · minimize keeps farming + floating button · close (X) stops the script.
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local VU = game:GetService("VirtualUser")
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
local okProgress, ProgressStats = pcall(function() return require(RS.Modules.ProgressStats) end)

PetStats = okPet and PetStats or { EggStats = {}, Pets = {}, Rarities = {} }
RelicModule = okRelic and RelicModule or { RelicStats = {}, RarityStats = {} }
ProgressStats = okProgress and ProgressStats or { StageStats = {}, WorldStats = {} }

-- ------------------------------------------------------------------ state

local State = {
	Dead = false,
	Ticks = 0,
	LastError = nil,
	Status = "idle",
	HatchStatus = "idle",
	RelicStatus = "idle",

	AutoTrain = false,
	AutoPunch = false,
	Delay = 0.05,

	AutoBreak = false,
	AutoAdvance = false,
	ReturnToSpot = true,
	World = 4,
	Stage = 1,

	Rebirth = 0,

	AutoHatch = false,
	HatchDelay = 0.45,
	Eggs = {},

	UnwantedEgg = nil,
	UnwantedByEgg = {},
	ShownUnwantedEgg = nil,

	AutoBuy = false,
	Relics = {},
	ReplaceRelic = true,
	ForceReplace = false,
	RelicBusy = false,

	TeleportWorld = 1,
	AutoLoad = false,

	AntiAfk = true,
	AntiAfkLast = 0,
	AntiAfkNext = 0,
	AntiAfkResets = 0,
	AntiAfkConns = nil,

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
	if i == 0 then
		return string.format("%d", math.floor(n))
	end
	return string.format("%.1f%s", n, units[i])
end

local function worldOf(stageNo)
	return math.clamp(math.ceil(stageNo / 15), 1, 5)
end

-- Default the picker to the next stage the player has not claimed yet, so the
-- World/Stage pair is always consistent on startup.
do
	local completed = LP:GetAttribute("CompletedStage") or 0
	local nextStage = math.clamp(completed + 1, 1, 75)
	State.Stage = nextStage
	State.World = worldOf(nextStage)
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

-- ------------------------------------------------------------------ world / movement

local function worldAnchor(worldNo)
	local root = workspace:FindFirstChild("World" .. worldNo)
	if not root then return nil end
	local content = root:FindFirstChild("Content")
	local spawnFolder = content and content:FindFirstChild("Spawn")
	local loc = spawnFolder and spawnFolder:FindFirstChild("SpawnLocation")
	if loc and loc:IsA("BasePart") then return loc.Position end
	local lobby = root:FindFirstChild("Lobby")
	if lobby and lobby:IsA("BasePart") then return lobby.Position end
	return nil
end

local function currentWorld()
	local _, hrp = getChar()
	if not hrp then return nil, math.huge end
	local p = hrp.Position
	local best, bestD = nil, math.huge
	for n = 1, 5 do
		local a = worldAnchor(n)
		if a then
			local d = (a - p).Magnitude
			if d < bestD then best, bestD = n, d end
		end
	end
	return best, bestD
end

-- stage pads sit on a fixed grid: x = spawnX + 36, z = 10 - 90 * indexInWorld
local function stageAnchor(stageNo)
	local worldNo = worldOf(stageNo)
	local spawnPos = worldAnchor(worldNo)
	if not spawnPos then return nil end
	local index = ((stageNo - 1) % 15) + 1
	return Vector3.new(spawnPos.X + 36, spawnPos.Y + 4, 10 - 90 * index)
end

local function teleportTo(position)
	local _, hrp = getChar()
	if not hrp then return false end
	hrp.CFrame = CFrame.new(position)
	return true
end

local function ensureWorld(worldNo)
	local cur, dist = currentWorld()
	if cur == worldNo and dist < 900 then return true end
	local anchor = worldAnchor(worldNo)
	if not anchor then return false end
	if not teleportTo(anchor + Vector3.new(0, 4, 0)) then return false end
	task.wait(1.0)
	return true
end

-- ------------------------------------------------------------------ stages

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

local function waitForStage(worldNo, stageNo, timeout)
	local t0 = os.clock()
	repeat
		local s = findStage(worldNo, stageNo)
		if s then
			local wp = s.folder:FindFirstChild("WinPad")
			if wp and wp:FindFirstChild("GuiPart") then return s end
		end
		task.wait(0.25)
	until State.Dead or (os.clock() - t0) > (timeout or 6)
	return nil
end

-- ------------------------------------------------------------------ combat

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

-- ------------------------------------------------------------------ runner

local runStage

do
	local function run(stageNo)
		local _, hrp0 = getChar()
		local startCF = hrp0 and hrp0.CFrame

		local worldNo = worldOf(stageNo)
		local anchor = stageAnchor(stageNo)
		if not anchor then
			return false, "world " .. worldNo .. " anchor missing"
		end

		State.Status = string.format("stage %d — moving to world %d", stageNo, worldNo)
		if not teleportTo(anchor + Vector3.new(0, 6, 0)) then
			return false, "teleport failed"
		end

		local stage = waitForStage(worldNo, stageNo, 6)
		if not stage then
			return false, "stage " .. stageNo .. " did not stream in"
		end

		task.wait(0.4)
		local walls = wallsOf(stage)
		local broken, total = 0, #walls

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

-- ------------------------------------------------------------------ eggs

local function eggList()
	local out = {}
	for name, info in pairs(PetStats.EggStats) do
		table.insert(out, {
			name = name,
			world = info.WorldNumber or 1,
			cost = info.Cost or 0,
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
		table.insert(out, string.format("%s · W%d · %s", e.name, e.world, short(e.cost)))
	end
	return out
end

local function eggInfo(name)
	return PetStats.EggStats[name]
end

local function findEggModels(name)
	local out = {}
	-- The game keeps one MainEggs model per visited world directly under
	-- Workspace, so the same egg name can exist in more than one copy. Look
	-- through all of them instead of trusting FindFirstChild.
	for _, main in ipairs(workspace:GetChildren()) do
		if main.Name == "MainEggs" then
			for _, m in ipairs(main:GetChildren()) do
				if m.Name == name and m:IsA("Model") then
					table.insert(out, m)
				end
			end
		end
	end
	return out
end

local function findEggModel(name, near)
	local best, bestD
	for _, m in ipairs(findEggModels(name)) do
		local d = near and (m:GetPivot().Position - near).Magnitude or 0
		if not bestD or d < bestD then
			best, bestD = m, d
		end
	end
	return best
end

-- Pets that can come out of one specific egg, weakest multiplier first.
local function eggPets(eggName)
	local info = eggInfo(eggName)
	local out = {}
	if not info or not info.Pets then return out end
	for petName, chance in pairs(info.Pets) do
		local p = PetStats.Pets[petName] or {}
		table.insert(out, {
			name = petName,
			rarity = p.Rarity or "Common",
			mult = p.Multiplier or 1,
			chance = tonumber(chance) or 0,
		})
	end
	table.sort(out, function(a, b)
		if a.mult ~= b.mult then return a.mult < b.mult end
		return a.name < b.name
	end)
	return out
end

local function eggPetLabels(eggName)
	local labels = {}
	for _, p in ipairs(eggPets(eggName)) do
		table.insert(labels, string.format("%s · %s · x%.2f", p.name, p.rarity, p.mult))
	end
	return labels
end

-- Display labels for the pets currently marked unwanted on one egg.
local function unwantedLabelsFor(eggName)
	local marked = State.UnwantedByEgg[eggName]
	local out = {}
	if not marked then return out end
	for _, p in ipairs(eggPets(eggName)) do
		if marked[p.name] then
			table.insert(out, string.format("%s · %s · x%.2f", p.name, p.rarity, p.mult))
		end
	end
	return out
end

-- WindUI runs a dropdown callback inside task.spawn and reads the element's
-- Value at execution time, so queued callbacks can land after the list has
-- already been swapped. The live selection is therefore read from the widget
-- and only written to State at explicit moments: leaving an egg, saving the
-- config, or hatching.
local function widgetUnwantedSet()
	local set = {}
	local d = State.UI and State.UI.UnwantedDropdown
	if not d then return set end
	for _, v in ipairs(d.Value or {}) do
		set[labelName(v)] = true
	end
	return set
end

local function snapshotUnwanted()
	if not State.UnwantedEgg then return end
	if not (State.UI and State.UI.UnwantedDropdown) then return end
	local set = widgetUnwantedSet()
	-- A blank widget during a list swap must never erase marks that are
	-- already stored for this egg. Only a real selection is written.
	if next(set) then
		State.UnwantedByEgg[State.UnwantedEgg] = set
	end
end

local function unwantedSetFor(eggName)
	if eggName == State.UnwantedEgg and State.UI and State.UI.UnwantedDropdown then
		return widgetUnwantedSet()
	end
	return State.UnwantedByEgg[eggName] or {}
end

-- Which egg the pet dropdown is currently showing. Kept separate from
-- State.UnwantedEgg so the sync below can tell "already showing" from "switch".
-- WindUI runs element callbacks inside task.spawn and reads the element's
-- Value at execution time, so the callback argument cannot be trusted to say
-- which egg was clicked. Everything is derived from the widget's live value.
local function syncUnwantedUI()
	local ui = State.UI
	if not (ui and ui.UnwantedEggDropdown and ui.UnwantedDropdown) then return end
	local shown = labelName(ui.UnwantedEggDropdown.Value)
	if not eggInfo(shown) then return end
	if shown == State.ShownUnwantedEgg then return end

	local leaving = State.ShownUnwantedEgg
	if leaving then
		local set = widgetUnwantedSet()
		if next(set) then
			State.UnwantedByEgg[leaving] = set
		end
	end

	State.ShownUnwantedEgg = shown
	State.UnwantedEgg = shown
	ui.UnwantedDropdown.Values = eggPetLabels(shown)
	pcall(function() ui.UnwantedDropdown:Select(unwantedLabelsFor(shown)) end)
end

local function hatchOnce()
	syncUnwantedUI()
	local picks = {}
	for _, label in ipairs(State.Eggs) do
		local name = labelName(label)
		if eggInfo(name) then table.insert(picks, name) end
	end
	if #picks == 0 then
		State.HatchStatus = "no egg selected"
		return false
	end

	local wins = stat("Wins")
	local target
	for _, name in ipairs(picks) do
		local info = eggInfo(name)
		if wins >= (info.Cost or 0) then
			target = name
			break
		end
	end
	if not target then
		State.HatchStatus = "cannot afford selected eggs"
		return false
	end

	local info = eggInfo(target)
	local _, hrp = getChar()
	if not hrp then return false end

	local model = findEggModel(target, hrp.Position)
	if not model then
		-- Egg belongs to a world that has not replicated yet: move there and
		-- give the MainEggs copy a moment to appear.
		local anchor = worldAnchor(info.WorldNumber or 1)
		if anchor then
			hrp.CFrame = CFrame.new(anchor + Vector3.new(0, 5, 0))
			local t0 = os.clock()
			repeat
				task.wait(0.2)
				model = findEggModel(target, hrp.Position)
			until model or State.Dead or (os.clock() - t0) > 6
		end
	end

	if not model then
		State.HatchStatus = "egg model missing"
		return false
	end

	local eggPos = model:GetPivot().Position
	if (hrp.Position - eggPos).Magnitude > 12 then
		hrp.CFrame = CFrame.new(eggPos + Vector3.new(0, 4, 9))
		task.wait(0.35)
	end

	-- Only pets that belong to the egg being hatched are ever sent, and only
	-- when they were marked unwanted for that specific egg machine.
	local deleteList = {}
	local marked = unwantedSetFor(target)
	if marked and info.Pets then
		for petName in pairs(info.Pets) do
			if marked[petName] then
				table.insert(deleteList, petName)
			end
		end
	end

	local ok, success, results, err = pcall(function()
		return Remotes.PetRemotes.HatchEgg:InvokeServer(target, 1, deleteList)
	end)

	if ok and success then
		local count = type(results) == "table" and #results or 0
		State.HatchStatus = string.format("%s hatched · %d pet%s%s", target,
			count, count == 1 and "" or "s",
			#deleteList > 0 and (" · trimmed " .. #deleteList) or "")
		return true
	end

	if ok and not success and err then
		State.HatchStatus = string.format("%s refused · %s", target, tostring(err))
	elseif not ok then
		State.HatchStatus = string.format("%s error · %s", target, tostring(success))
	else
		State.HatchStatus = string.format("%s failed", target)
	end
	return false
end

-- ------------------------------------------------------------------ relics

local function relicLabels()
	local rows = {}
	for name, info in pairs(RelicModule.RelicStats) do
		local mult = info.StrengthMultiplier or 1
		table.insert(rows, {
			label = string.format("%s · %s · +%d%% · %s", name, info.Rarity or "?",
				math.floor((mult - 1) * 100 + 0.5), short(info.WinsCost or 0)),
			rarity = info.Rarity or "?",
			mult = mult,
			cost = info.WinsCost or math.huge,
		})
	end
	-- Sorted by strength percentage first, weakest to strongest.
	table.sort(rows, function(a, b)
		if a.mult ~= b.mult then return a.mult < b.mult end
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.label < b.label
	end)
	local labels = {}
	for _, r in ipairs(rows) do table.insert(labels, r.label) end
	return labels
end

local function shopSummary(shop)
	local parts = {}
	for _, name in ipairs(shop.Items or {}) do
		local info = RelicModule.RelicStats[name]
		local mult = info and info.StrengthMultiplier or 1
		table.insert(parts, string.format("%s %.2f", name, mult))
	end
	if #parts == 0 then return "empty" end
	return table.concat(parts, ", ")
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
	if not okInv or type(inv) ~= "table" then
		State.RelicStatus = "inventory unavailable"
		return false
	end

	local wanted = {}
	for _, label in ipairs(State.Relics) do
		wanted[labelName(label)] = true
	end

	local wins = stat("Wins")
	local reason

	for _, name in ipairs(shop.Items) do
		if wanted[name] then
			local info = RelicModule.RelicStats[name] or {}
			local cost = info.WinsCost or math.huge
			local mult = info.StrengthMultiplier or 1

			if shop.Purchased and shop.Purchased[name] then
				reason = name .. " already bought this cycle"
			elseif wins < cost then
				reason = string.format("%s needs %s", name, short(cost))
			else
				-- BuyRelic takes the relic NAME, not the slot number: the game's
				-- own shop script calls BuyRelic:InvokeServer(relicName).
				local okBuy, bought = pcall(function()
					return Remotes.Relics.BuyRelic:InvokeServer(name)
				end)

				if okBuy and bought then
					State.RelicStatus = string.format("bought %s · x%.2f", name, mult)
					return true
				end

				reason = name .. " buy failed"
			end
		end
	end

	local owned = #(inv.Relics or {})
	if reason then
		State.RelicStatus = reason .. " · owned " .. owned .. " · shop: " .. shopSummary(shop)
	else
		State.RelicStatus = "shop: " .. shopSummary(shop) .. " · none picked · owned " .. owned
	end
	return false
end

State.BuyRelicNow = buyRelicOnce

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
	State.AutoBuy = false
	State.AntiAfk = false

	for _, c in ipairs(State.AntiAfkConns or {}) do
		pcall(function() c:Disconnect() end)
	end
	State.AntiAfkConns = nil

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

Window:Tag({ Title = "v4", Icon = "github", Color = Color3.fromHex("#1c1c1c"), Border = true })

local TabFarm = Window:Tab({ Title = "Farm", Icon = "solar:play-bold" })
local TabWalls = Window:Tab({ Title = "Walls", Icon = "solar:bricks-bold" })
local TabRebirth = Window:Tab({ Title = "Rebirth", Icon = "solar:refresh-bold" })
local TabPets = Window:Tab({ Title = "Pets & Relics", Icon = "solar:star-bold" })
local TabSettings = Window:Tab({ Title = "Settings", Icon = "solar:settings-bold" })

pcall(function() Window:SelectTab(1) end)

-- WindUI's dropdown value box is a fixed 150px wide with TextTruncate=AtEnd, so
-- the raw option text it writes there - several "Basic Egg · W1 · 100, Spike
-- Egg · W1 · 1.0K" entries joined together - truncates to just the first egg
-- and an ellipsis. Every pick repaints it that way, even while the menu is
-- still open, which made a multi-select look like it only ever held one pick.
-- WindUI's repaint goes through a copy of the element that cannot be wrapped,
-- so the label itself is watched and rewritten to a short summary the instant
-- it changes. The 0.2s pass below only covers a label that was missing at
-- setup time.
local compactDisplays = {}

local function dropdownLabel(dropdown)
	local element = dropdown and dropdown.UIElements and dropdown.UIElements.Dropdown
	local holder = element and element:FindFirstChild("Frame")
	local inner = holder and holder:FindFirstChild("Frame")
	return inner and inner:FindFirstChild("TextLabel")
end

local function applyCompactText(dropdown, summarize)
	local label = dropdownLabel(dropdown)
	if not label then return end
	local ok, text = pcall(summarize, dropdown)
	if not ok or type(text) ~= "string" or text == "" then return end
	if label.Text ~= text then
		label.Text = text
	end
end

local function compactDropdownDisplay(dropdown, summarize)
	if not dropdown then return end
	table.insert(compactDisplays, { dropdown = dropdown, summarize = summarize })

	local label = dropdownLabel(dropdown)
	if label then
		local rewriting = false
		label:GetPropertyChangedSignal("Text"):Connect(function()
			if rewriting then return end
			rewriting = true
			applyCompactText(dropdown, summarize)
			rewriting = false
		end)
	end

	applyCompactText(dropdown, summarize)
end

local function refreshCompactDisplays()
	for _, entry in ipairs(compactDisplays) do
		if entry.dropdown then
			applyCompactText(entry.dropdown, entry.summarize)
		end
	end
end

-- ---- Farm

local StatsLabel = TabFarm:Paragraph({
	Title = "—",
	Desc = "loading",
})

local FarmSection = TabFarm:Section({ Opened = true, Title = "Automation" })

local ToggleTrain = FarmSection:Toggle({
	Title = "Auto Train",
	Value = false,
	Callback = function(v) State.AutoTrain = v end,
})

FarmSection:Space()

local TogglePunch = FarmSection:Toggle({
	Title = "Auto Punch",
	Value = false,
	Callback = function(v) State.AutoPunch = v end,
})

FarmSection:Space()

local DelaySlider = FarmSection:Slider({
	Title = "Tick delay",
	Value = { Min = 0.01, Max = 0.2, Default = 0.05 },
	Step = 0.01,
	IsTooltip = true,
	Callback = function(v) State.Delay = v end,
})

-- ---- Walls

local WallsSection = TabWalls:Section({ Opened = true, Title = "Target" })

State.UI = {
	Window = Window,
	TabFarm = TabFarm,
	TabWalls = TabWalls,
	TabRebirth = TabRebirth,
	TabPets = TabPets,
	TabSettings = TabSettings,
	WallsSection = WallsSection,
}

local StageDropdown

local function stageLabels(worldNo)
	local rows = {}

	-- ProgressStats carries every stage of every world, whether or not that
	-- world is currently streamed in.
	for name, info in pairs(ProgressStats.StageStats or {}) do
		if info.WorldNumber == worldNo then
			table.insert(rows, {
				name = name,
				number = info.StageNumber,
				reward = info.WinsReward or 0,
			})
		end
	end

	-- Fall back to the live WinPad attributes if the module is unavailable.
	if #rows == 0 then
		for _, s in ipairs(stagesOf(worldNo)) do
			table.insert(rows, { name = s.name, number = s.number, reward = s.reward })
		end
	end

	table.sort(rows, function(a, b) return a.number < b.number end)

	local labels = {}
	for _, s in ipairs(rows) do
		table.insert(labels, string.format("%d · %s · +%s", s.number, s.name, short(s.reward)))
	end
	return labels
end

local WorldDropdown = WallsSection:Dropdown({
	Title = "World",
	Values = { "World 1", "World 2", "World 3", "World 4", "World 5" },
	Value = "World " .. State.World,
	Callback = function(option)
		local picked = tonumber(tostring(option):match("%d+")) or State.World
		-- WindUI fires a dropdown's callback once on creation, so only react
		-- when the world really changed instead of resetting the stage pick.
		if picked ~= State.World then
			State.World = picked
			local labels = stageLabels(picked)
			pcall(function() StageDropdown:Refresh(labels) end)
			-- Keep the stage picker valid for the new world instead of leaving
			-- a label from the previous one selected.
			if labels[1] then
				pcall(function() StageDropdown:Select(labels[1]) end)
				State.Stage = (picked - 1) * 15 + 1
			end
		end
	end,
})

WallsSection:Space()

local initialLabels = stageLabels(State.World)

StageDropdown = WallsSection:Dropdown({
	Title = "Stage",
	Values = initialLabels,
	Width = 240,
	MenuWidth = 300,
	Value = initialLabels[math.clamp(State.Stage - (State.World - 1) * 15, 1, 15)],
	Callback = function(option)
		local n = tonumber(tostring(option):match("^(%d+)"))
		if n then State.Stage = n end
	end,
})

local RunSection = TabWalls:Section({ Opened = true, Title = "Runner" })

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
	Value = false,
	Callback = function(v) State.AutoBreak = v end,
})

RunSection:Space()

local ToggleAutoAdvance = RunSection:Toggle({
	Title = "Auto Advance",
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

local RebSection = TabRebirth:Section({ Opened = true, Title = "Auto Rebirth" })

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

local RebInfo = TabRebirth:Section({ Opened = true, Title = "Info" })
RebInfo:Paragraph({
	Title = "How it works",
	Desc = "Invokes Remotes.Rebirth with the tier amount every 0.8s. The server returns false while you are short on strength, so the loop just retries.",
})

-- ---- Pets & Relics

local HatchSection = TabPets:Section({ Opened = true, Title = "Auto Hatch" })

local EggDropdown = HatchSection:Dropdown({
	Title = "Egg to hatch",
	Values = eggLabels(),
	MenuWidth = 280,
	Value = State.Eggs[1],
	Callback = function(selected)
		State.Eggs = selected and { selected } or {}
	end,
})

compactDropdownDisplay(EggDropdown, function(self)
	local picked = typeof(self.Value) == "table" and self.Value[1] or self.Value
	if picked == nil or picked == "" then return "none selected" end
	return labelName(picked)
end)

HatchSection:Space()

local ToggleAutoHatch = HatchSection:Toggle({
	Title = "Auto Hatch",
	Value = false,
	Callback = function(v) State.AutoHatch = v end,
})

HatchSection:Space()

local HatchDelaySlider = HatchSection:Slider({
	Title = "Hatch delay",
	Value = { Min = 0.2, Max = 2, Default = 0.45 },
	Step = 0.05,
	IsTooltip = true,
	Callback = function(v) State.HatchDelay = v end,
})

TabPets:Space()

local UnwantedSection = TabPets:Section({ Opened = true, Title = "Unwanted Pets" })

local UnwantedDropdown  -- forward declaration: the egg picker refreshes it
local ClearUnwantedButton

local unwantEggValues = eggLabels()
State.UnwantedEgg = State.UnwantedEgg or labelName(unwantEggValues[1] or "")

local UnwantedEggDropdown = UnwantedSection:Dropdown({
	Title = "Egg machine",
	Values = unwantEggValues,
	Width = 260,
	MenuWidth = 300,
	Value = unwantEggValues[1],
	Callback = function()
		syncUnwantedUI()
	end,
})

compactDropdownDisplay(UnwantedEggDropdown, function(self)
	return labelName(self.Value)
end)

UnwantedSection:Space()

UnwantedDropdown = UnwantedSection:Dropdown({
	Title = "Delete from this egg",
	Values = eggPetLabels(State.UnwantedEgg),
	Multi = true,
	AllowNone = false,
	MenuWidth = 300,
	Width = 240,
	Value = {},
	-- Marks are read straight out of this widget at hatch time, so the
	-- callback only exists to give the element its value box.
	Callback = function() end,
})

compactDropdownDisplay(UnwantedDropdown, function(self)
	local n = typeof(self.Value) == "table" and #self.Value or 0
	if n == 0 then return "none marked" end
	if n == 1 then return self.Value[1]:match("^[^·]+") or self.Value[1] end
	return n .. " pets marked"
end)

UnwantedSection:Space()

-- Marks are sticky: they survive egg switches and can never be wiped by a
-- list refresh. This is the one deliberate way to drop them again.
ClearUnwantedButton = UnwantedSection:Button({
	Title = "Clear this egg's marks",
	Icon = "solar:trash-bin-trash-bold",
	Justify = "Center",
	Callback = function()
		local eggName = State.UnwantedEgg
		if not eggName then return end
		State.UnwantedByEgg[eggName] = nil
		pcall(function() UnwantedDropdown:Select({}) end)
		WindUI:Notify({
			Title = "Marks cleared",
			Content = eggName,
			Icon = "check",
			Duration = 2,
		})
	end,
})

UnwantedSection:Space()

UnwantedSection:Paragraph({
	Title = "How it works",
	Desc = "Each egg keeps its own unwanted list. When you hatch that egg, only its marked pets are sent along for deletion, so nothing is ever swept out of your inventory.",
})

TabPets:Space()

local RelicSection = TabPets:Section({ Opened = true, Title = "Auto Buy Relic" })

local RelicDropdown = RelicSection:Dropdown({
	Title = "Relics to buy",
	Values = relicLabels(),
	Multi = true,
	MenuWidth = 300,
	Value = {},
	Callback = function(selected)
		State.Relics = {}
		for _, v in ipairs(selected or {}) do table.insert(State.Relics, v) end
	end,
})

compactDropdownDisplay(RelicDropdown, function(self)
	local n = typeof(self.Value) == "table" and #self.Value or 0
	if n == 0 then return "none selected" end
	if n == 1 then return self.Value[1]:match("^[^·]+") or self.Value[1] end
	return n .. " relics selected"
end)

RelicSection:Space()

local ToggleAutoBuy = RelicSection:Toggle({
	Title = "Auto Buy Relic",
	Value = false,
	Callback = function(v) State.AutoBuy = v end,
})

RelicSection:Space()

RelicSection:Button({
	Title = "Buy selected now",
	Icon = "solar:cart-bold",
	Justify = "Center",
	Callback = function()
		if State.RelicBusy then
			WindUI:Notify({ Title = "Busy", Content = "A relic purchase is already running", Icon = "clock", Duration = 3 })
			return
		end
		task.spawn(function()
			State.RelicBusy = true
			local ok = buyRelicOnce()
			State.RelicBusy = false
			WindUI:Notify({
				Title = ok and "Relic bought" or "No purchase",
				Content = State.RelicStatus,
				Icon = ok and "check" or "info",
				Duration = 4,
			})
		end)
	end,
})

RelicSection:Space()

RelicSection:Paragraph({
	Title = "How it works",
	Desc = "Purchases are added to your owned relics; equipping stays in the game's inventory. The shop rotates on its own timer, so auto-buy just watches for a picked relic to appear.",
})

-- ---- Anti AFK

-- Roblox drops an idle client 20 minutes after its last input. One synthetic
-- click every 5 minutes of real inactivity keeps the session alive, with
-- Player.Idled behind it in case this loop is ever starved. Every real input
-- (keyboard, mouse, gamepad) pushes the timer forward, so it never clicks
-- while you are actually playing.
local ANTI_AFK_INTERVAL = 300
local ANTI_AFK_JITTER = 20
local AntiAfkConns = {}

local function antiAfkBump()
	State.AntiAfkLast = os.clock()
	State.AntiAfkNext = State.AntiAfkLast
		+ ANTI_AFK_INTERVAL
		+ math.random(-ANTI_AFK_JITTER, ANTI_AFK_JITTER)
end

local function antiAfkClick()
	if not State.AntiAfk or State.Dead then return false end
	local ok = pcall(function()
		VU:CaptureController()
		VU:ClickButton2(Vector2.new(math.random(50, 400), math.random(50, 400)))
	end)
	if ok then
		State.AntiAfkResets = State.AntiAfkResets + 1
		antiAfkBump()
	end
	return ok
end

antiAfkBump()

table.insert(AntiAfkConns, UIS.InputBegan:Connect(function()
	antiAfkBump()
end))

table.insert(AntiAfkConns, UIS.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Gamepad1 then
		antiAfkBump()
	end
end))

table.insert(AntiAfkConns, LP.Idled:Connect(function()
	if not State.AntiAfk or State.Dead then return end
	task.wait(math.random(1, 4))
	antiAfkClick()
end))

State.AntiAfkConns = AntiAfkConns

-- ---- Settings

local ConfigSection = TabSettings:Section({ Opened = true, Title = "Config" })

local ToggleAutoLoad = ConfigSection:Toggle({
	Title = "Auto load config on start",
	Value = false,
	Callback = function(v) State.AutoLoad = v end,
})

ConfigSection:Space()

ConfigSection:Button({
	Title = "Save config",
	Icon = "solar:diskette-bold",
	Justify = "Center",
	Callback = function()
		snapshotUnwanted()
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
			unwantedEgg = State.UnwantedEgg,
			unwantedByEgg = State.UnwantedByEgg,
			autoBuy = State.AutoBuy,
			relics = State.Relics,
			replaceRelic = State.ReplaceRelic,
			forceReplace = State.ForceReplace,
			teleportWorld = State.TeleportWorld,
			autoLoad = State.AutoLoad,
			antiAfk = State.AntiAfk,
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

local TPSection = TabSettings:Section({ Opened = true, Title = "Teleport" })

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
			local anchor = worldAnchor(State.TeleportWorld)
			if not anchor then
				WindUI:Notify({ Title = "Teleport failed", Content = "world folder missing", Icon = "x", Duration = 3 })
				return
			end
			teleportTo(anchor + Vector3.new(0, 5, 0))
			WindUI:Notify({
				Title = "World " .. State.TeleportWorld,
				Content = "moved to spawn",
				Icon = "check",
				Duration = 3,
			})
		end)
	end,
})

TabSettings:Space()

local AntiAfkSection = TabSettings:Section({ Opened = true, Title = "Anti AFK" })

local ToggleAntiAfk = AntiAfkSection:Toggle({
	Title = "Anti AFK",
	Value = true,
	Callback = function(v)
		State.AntiAfk = v
		if v then antiAfkBump() end
	end,
})

TabSettings:Space()

local ScriptSection = TabSettings:Section({ Opened = true, Title = "Script" })

ScriptSection:Space()

ScriptSection:Button({
	Title = "Stop & Unload script",
	Icon = "solar:power-bold",
	Justify = "Center",
	Callback = function() State.Unload() end,
})

-- ------------------------------------------------------------------ config

State.UI.EggDropdown = EggDropdown
State.UI.UnwantedEggDropdown = UnwantedEggDropdown
State.UI.UnwantedDropdown = UnwantedDropdown
State.UI.RelicDropdown = RelicDropdown
State.UI.StageDropdown = StageDropdown
State.UI.WorldDropdown = WorldDropdown
State.UI.TeleportDropdown = TeleportDropdown
State.UI.ToggleAutoHatch = ToggleAutoHatch
State.UI.ToggleAutoBuy = ToggleAutoBuy
State.UI.ToggleAntiAfk = ToggleAntiAfk
State.UI.ClearUnwanted = ClearUnwantedButton

-- The pet list starts on this egg, so mark it as already shown.
State.ShownUnwantedEgg = State.UnwantedEgg

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
	State.AutoBuy = data.autoBuy == true
	State.ReplaceRelic = data.replaceRelic ~= false
	State.ForceReplace = data.forceReplace == true
	State.TeleportWorld = tonumber(data.teleportWorld) or 1
	State.AutoLoad = data.autoLoad == true
	State.AntiAfk = data.antiAfk ~= false

	State.Eggs = type(data.eggs) == "table" and data.eggs or {}
	if #State.Eggs > 1 then
		-- The hatch picker is single choice now; keep the first of any older
		-- multi-egg config instead of dropping the whole selection.
		State.Eggs = { State.Eggs[1] }
	end
	State.Relics = type(data.relics) == "table" and data.relics or {}

	if type(data.unwantedByEgg) == "table" then
		State.UnwantedByEgg = data.unwantedByEgg
	elseif type(data.unwanted) == "table" then
		-- Migrate the old flat unwanted list (pet labels) into per-egg lists.
		State.UnwantedByEgg = {}
		for _, label in ipairs(data.unwanted) do
			local pet = labelName(label)
			for eggName, egg in pairs(PetStats.EggStats) do
				if egg.Pets and egg.Pets[pet] then
					State.UnwantedByEgg[eggName] = State.UnwantedByEgg[eggName] or {}
					State.UnwantedByEgg[eggName][pet] = true
				end
			end
		end
	end
	if type(data.unwantedEgg) == "string" then
		State.UnwantedEgg = data.unwantedEgg
	end

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
	pcall(function() EggDropdown:Select(State.Eggs[1]) end)

	local eggLabel
	for _, label in ipairs(UnwantedEggDropdown.Values or {}) do
		if labelName(label) == State.UnwantedEgg then eggLabel = label break end
	end
	pcall(function() if eggLabel then UnwantedEggDropdown:Select(eggLabel) end end)
	pcall(function() UnwantedDropdown.Values = eggPetLabels(State.UnwantedEgg) end)
	pcall(function() UnwantedDropdown:Select(unwantedLabelsFor(State.UnwantedEgg)) end)
	State.ShownUnwantedEgg = State.UnwantedEgg
	pcall(function() ToggleAutoBuy:Set(State.AutoBuy) end)
	pcall(function() RelicDropdown:Select(State.Relics) end)

	pcall(function() ToggleAutoLoad:Set(State.AutoLoad) end)
	pcall(function() TeleportDropdown:Select("World " .. State.TeleportWorld) end)
	pcall(function() ToggleAntiAfk:Set(State.AntiAfk) end)
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

supervise("ui labels", function()
	while true do
		task.wait(0.2)
		refreshCompactDisplays()
	end
end)

supervise("train/punch", function()
	while true do
		task.wait(State.Delay)
		State.Ticks = State.Ticks + 1
		if State.AutoTrain then
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
			if State.Busy then
				-- Wall runner owns the character right now; try again on its
				-- next 0.4 s gap instead of fighting it for the CFrame.
				State.HatchStatus = "waiting for wall run"
			else
				State.Busy = true
				local ok, err = pcall(hatchOnce)
				State.Busy = false
				if not ok then State.LastError = "hatch: " .. tostring(err) end
				task.wait(State.HatchDelay)
			end
		end
	end
end)

supervise("relic buy", function()
	while true do
		task.wait(3)
		if State.AutoBuy and not State.RelicBusy then
			State.RelicBusy = true
			pcall(buyRelicOnce)
			State.RelicBusy = false
		end
	end
end)

supervise("anti-afk", function()
	while true do
		task.wait(1)
		if State.AntiAfk and not State.Dead and os.clock() >= State.AntiAfkNext then
			if not antiAfkClick() then
				-- The click was blocked this second; retry soon instead of
				-- waiting out another full interval.
				State.AntiAfkNext = os.clock() + 30
			end
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

		local curWorld = currentWorld()
		local head = string.format("%s wins · %s strength · %d rebirth · world %s",
			short(stat("Wins")), short(stat("Strength")), math.floor(stat("Rebirth")), tostring(curWorld))
		local desc = string.format(
			"stage %s · loop %d/s · walls: %s · eggs: %s · relics: %s",
			tostring(LP:GetAttribute("CompletedStage")),
			rate,
			State.Status,
			State.HatchStatus,
			State.RelicStatus
		)
		if State.LastError then
			desc = desc .. " · ERR " .. State.LastError:sub(1, 40)
		end
		local para = StatsLabel.ParagraphFrame or StatsLabel
		pcall(function() para:SetTitle(head) end)
		pcall(function() para:SetDesc(desc) end)
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

if isfile and isfile(CONFIG_FILE) then
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
