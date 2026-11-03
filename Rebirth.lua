--// Rebirth Toggle GUI  (Toggle = rebirth every 25s | Stop = kill everything)
local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--// config
local DELAY        = 25   -- seconds between rebirths
local REBIRTH_COST = 100  -- argument sent to the remote

--// clean up an old copy if re-executed
local old = playerGui:FindFirstChild("RebirthGui")
if old then old:Destroy() end

--// state
local connections = {}
local running     = false
local alive       = true

local function track(conn)
    table.insert(connections, conn)
    return conn
end

--// full kill: stop loop, disconnect everything, nuke the GUI
local function killAll()
    alive   = false
    running = false

    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}

    local gui = playerGui:FindFirstChild("RebirthGui")
    if gui then gui:Destroy() end
end

--// ---------------- GUI ----------------
local gui = Instance.new("ScreenGui")
gui.Name            = "RebirthGui"
gui.ResetOnSpawn    = false
gui.IgnoreGuiInset  = true
gui.DisplayOrder    = 999
gui.Parent          = playerGui

local frame = Instance.new("Frame")
frame.Size             = UDim2.new(0, 220, 0, 140)
frame.Position         = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Draggable        = true          -- (deprecated but still works)
frame.Parent           = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent       = frame

local title = Instance.new("TextLabel")
title.Size               = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.Text               = "Rebirth"
title.TextColor3         = Color3.new(1, 1, 1)
title.Font               = Enum.Font.GothamBold
title.TextSize           = 16
title.Parent             = frame

local status = Instance.new("TextLabel")
status.Size               = UDim2.new(1, 0, 0, 20)
status.Position           = UDim2.new(0, 0, 0, 32)
status.BackgroundTransparency = 1
status.Text               = "Idle"
status.TextColor3         = Color3.fromRGB(180, 180, 190)
status.Font               = Enum.Font.Gotham
status.TextSize           = 13
status.Parent             = frame

local toggleBtn = Instance.new("TextButton")
toggleBtn.Size             = UDim2.new(0.45, 0, 0, 40)
toggleBtn.Position         = UDim2.new(0.03, 0, 1, -50)
toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
toggleBtn.Text             = "Toggle: OFF"
toggleBtn.TextColor3       = Color3.new(1, 1, 1)
toggleBtn.Font             = Enum.Font.GothamBold
toggleBtn.TextSize         = 14
toggleBtn.AutoButtonColor  = false
toggleBtn.Parent           = frame

local stopBtn = Instance.new("TextButton")
stopBtn.Size             = UDim2.new(0.45, 0, 0, 40)
stopBtn.Position         = UDim2.new(0.52, 0, 1, -50)
stopBtn.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
stopBtn.Text             = "STOP"
stopBtn.TextColor3       = Color3.new(1, 1, 1)
stopBtn.Font             = Enum.Font.GothamBold
stopBtn.TextSize         = 14
stopBtn.AutoButtonColor  = false
stopBtn.Parent           = frame

for _, b in ipairs({toggleBtn, stopBtn}) do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent       = b
end

--// ---------------- logic ----------------
local function setToggleUI(on)
    if not alive then return end
    toggleBtn.Text             = on and "Toggle: ON" or "Toggle: OFF"
    toggleBtn.BackgroundColor3 = on and Color3.fromRGB(0, 150, 80) or Color3.fromRGB(60, 60, 72)
end

local function getRemote()
    local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
    if not remotes then return nil end
    return remotes:WaitForChild("Rebirth", 15)
end

local function rebirthLoop()
    local remote = getRemote()
    if not remote then
        status.Text = "Remote not found"
        running = false
        setToggleUI(false)
        return
    end

    while running and alive do
        -- fire rebirth
        local ok, result = pcall(function()
            return remote:InvokeServer(REBIRTH_COST)
        end)

        if not alive then break end

        if ok then
            status.Text = "Rebirthed ✓  (" .. tostring(result) .. ")"
        else
            status.Text = "Error (retrying)"
        end

        -- responsive 25s countdown (stops instantly on STOP)
        local left = DELAY
        while running and alive and left > 0 do
            status.Text = (status.Text:gsub("  %- %d+s$", "")) .. "  - " .. left .. "s"
            task.wait(1)
            left -= 1
        end
    end
end

--// toggle
track(toggleBtn.MouseButton1Click:Connect(function()
    if not alive then return end
    running = not running
    setToggleUI(running)
    status.Text = running and "Starting..." or "Idle"
    if running then
        task.spawn(rebirthLoop)
    end
end))

--// stop (kill all trace)
track(stopBtn.MouseButton1Click:Connect(function()
    killAll()
end))

--// optional: also kill on player leaving
track(Players.PlayerRemoving:Connect(function(p)
    if p == player then killAll() end
end))

setToggleUI(false)
