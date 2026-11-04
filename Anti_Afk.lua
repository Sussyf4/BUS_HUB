--[[ Anti-AFK v4 — 5-minute proactive reset
     Clicks every 5 min of inactivity so Roblox's 20-min idle kick
     never triggers. Player.Idled kept as a backup.
     Any REAL input (keyboard/mouse/touch/gamepad) resets the 5-min clock.
]]

local CONFIG = {
    interval    = 300,      -- 5 min between proactive clicks (seconds)
    jitter      = 20,       -- ± seconds per cycle (avoids fixed-interval signature)
    firstDelay  = { 1, 4 }, -- backup path only (Player.Idled)
    secondDelay = { 2, 7 },
    clickRange  = { 50, 400 },
    maxLogLines = 2,
}

local Players          = game:GetService("Players")
local VirtualUser      = game:GetService("VirtualUser")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local old = playerGui:FindFirstChild("AntiAfkGui")
if old then old:Destroy() end

local enabled, closing = true, false
local conns = {}
local stats          = { resets = 0, lastReset = 0 }
local logEntries     = {}
local lastTick       = 0
local lastActionTime = os.clock()    -- real input OR auto-click resets this
local nextInterval   = CONFIG.interval

local gui, frame, header, statusDot, statusLabel
local counterLabel, toggleBtn, closeBtn, logFrame

local function rand(t)
    return math.random(math.floor(t[1] * 100), math.floor(t[2] * 100)) / 100
end
local function now() return os.clock() end
local function track(c) table.insert(conns, c); return c end

local function log(msg)
    print("[Anti-AFK] " .. msg)
    if not logFrame then return end
    local line = Instance.new("TextLabel")
    line.Size = UDim2.new(1, 0, 0, 13)
    line.BackgroundTransparency = 1
    line.Font = Enum.Font.Code
    line.TextSize = 10
    line.TextXAlignment = Enum.TextXAlignment.Left
    line.TextTruncate   = Enum.TextTruncate.AtEnd
    line.TextColor3     = Color3.fromRGB(165, 175, 185)
    line.Text = "> " .. msg
    line.Parent = logFrame
    table.insert(logEntries, line)
    if #logEntries > CONFIG.maxLogLines then
        logEntries[1]:Destroy()
        table.remove(logEntries, 1)
    end
    for i, l in ipairs(logEntries) do
        l.Position = UDim2.fromOffset(0, (i - 1) * 13)
    end
end

local function simulateInput()
    if not enabled or closing then return false end
    local ok = pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(
            math.random(CONFIG.clickRange[1], CONFIG.clickRange[2]),
            math.random(CONFIG.clickRange[1], CONFIG.clickRange[2])
        ))
    end)
    if not ok then log("input blocked") end
    return ok
end

-- Backup: if the 5-min loop ever fails, this still catches the 20-min kick
local function onIdled()
    if not enabled or closing then return end
    log("idle signal (backup)")
    task.wait(rand(CONFIG.firstDelay))
    if enabled and not closing and simulateInput() then
        stats.resets = stats.resets + 1
        stats.lastReset = now()
        lastActionTime = now()
    end
    task.delay(rand(CONFIG.secondDelay), function()
        if enabled and not closing then simulateInput() end
    end)
end

local function updateUI()
    if not frame then return end
    if enabled then
        statusDot.BackgroundColor3 = Color3.fromRGB(70, 200, 110)
        statusLabel.Text           = "AFK MODE: ON"
        statusLabel.TextColor3     = Color3.fromRGB(70, 200, 110)
        toggleBtn.Text             = "DISABLE"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
    else
        statusDot.BackgroundColor3 = Color3.fromRGB(140, 140, 140)
        statusLabel.Text           = "AFK MODE: OFF"
        statusLabel.TextColor3     = Color3.fromRGB(180, 180, 180)
        toggleBtn.Text             = "ENABLE"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 160, 90)
    end
end

local function setEnabled(state)
    enabled = state
    if enabled then
        lastActionTime = now()   -- fresh 5-min window on enable
        if not idleConn then idleConn = track(player.Idled:Connect(onIdled)) end
        log("enabled (5m timer)")
    else
        if idleConn then idleConn:Disconnect(); idleConn = nil end
        log("disabled")
    end
    updateUI()
end

-- ============ GUI (same compact 180×148) ============
gui = Instance.new("ScreenGui")
gui.Name = "AntiAfkGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(180, 148)
frame.Position = UDim2.new(0, 20, 0, 120)
frame.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(70, 70, 80)

header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 22)
header.BackgroundTransparency = 1
header.Active = true
header.Parent = frame

local grip = Instance.new("TextLabel")
grip.Size = UDim2.fromOffset(14, 22)
grip.Position = UDim2.fromOffset(8, 0)
grip.BackgroundTransparency = 1
grip.Font = Enum.Font.GothamBold
grip.TextSize = 12
grip.TextColor3 = Color3.fromRGB(130, 130, 140)
grip.Text = "≡"
grip.Parent = header

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -50, 0, 22)
title.Position = UDim2.fromOffset(24, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(230, 230, 230)
title.Text = "Anti-AFK"
title.Parent = header

closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(18, 18)
closeBtn.Position = UDim2.new(1, -22, 0, 2)
closeBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
closeBtn.BorderSizePixel = 0
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 11
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.Text = "X"
closeBtn.Parent = header
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

statusDot = Instance.new("Frame")
statusDot.Size = UDim2.fromOffset(8, 8)
statusDot.Position = UDim2.fromOffset(10, 30)
statusDot.BorderSizePixel = 0
statusDot.BackgroundColor3 = Color3.fromRGB(70, 200, 110)
statusDot.Parent = frame
Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)

statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -30, 0, 16)
statusLabel.Position = UDim2.fromOffset(22, 26)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextColor3 = Color3.fromRGB(70, 200, 110)
statusLabel.Text = "AFK MODE: ON"
statusLabel.Parent = frame

counterLabel = Instance.new("TextLabel")
counterLabel.Size = UDim2.new(1, -20, 0, 13)
counterLabel.Position = UDim2.fromOffset(10, 44)
counterLabel.BackgroundTransparency = 1
counterLabel.Font = Enum.Font.Gotham
counterLabel.TextSize = 10
counterLabel.TextXAlignment = Enum.TextXAlignment.Left
counterLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
counterLabel.Text = "Resets: 0  ·  Idle: 0s"
counterLabel.Parent = frame

toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(1, -20, 0, 26)
toggleBtn.Position = UDim2.fromOffset(10, 62)
toggleBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
toggleBtn.BorderSizePixel = 0
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 12
toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleBtn.Text = "DISABLE"
toggleBtn.Parent = frame
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 5)

local logBg = Instance.new("Frame")
logBg.Size = UDim2.new(1, -20, 0, 40)
logBg.Position = UDim2.fromOffset(10, 96)
logBg.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
logBg.BorderSizePixel = 0
logBg.Parent = frame
Instance.new("UICorner", logBg).CornerRadius = UDim.new(0, 5)

logFrame = Instance.new("Frame")
logFrame.Size = UDim2.new(1, -8, 1, -6)
logFrame.Position = UDim2.fromOffset(5, 3)
logFrame.BackgroundTransparency = 1
logFrame.Parent = logBg

-- ============ WIRING ============
toggleBtn.MouseButton1Click:Connect(function() setEnabled(not enabled) end)

closeBtn.MouseButton1Click:Connect(function()
    closing, enabled = true, false
    for _, c in ipairs(conns) do c:Disconnect() end
    table.clear(conns)
    if gui then gui:Destroy() end
    print("[Anti-AFK] Closed.")
end)

local dragging, dragStart, startPos
local function getXY(pos) return Vector2.new(pos.X, pos.Y) end

header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging  = true
        dragStart = getXY(input.Position)
        startPos  = frame.Position
    end
end)

track(UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch then
        local d = getXY(input.Position) - dragStart
        frame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y
        )
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end))

-- Real input tracking: any user activity resets the 5-min idle clock
track(UserInputService.InputBegan:Connect(function()
    if closing then return end
    lastActionTime = now()
end))

track(UserInputService.InputChanged:Connect(function(input)
    if closing then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Gamepad1 then
        lastActionTime = now()
    end
end))

-- ============ AUTO LOOP (5-min proactive click) ============
task.spawn(function()
    while not closing do
        task.wait(1)
        if closing then break end
        if not enabled then continue end

        local t = now()
        if t - lastActionTime >= nextInterval then
            if simulateInput() then
                lastActionTime = t
                stats.resets   = stats.resets + 1
                stats.lastReset = t
                nextInterval   = CONFIG.interval
                    + math.random(-CONFIG.jitter, CONFIG.jitter)
                log(string.format("auto %dm", CONFIG.interval / 60))
            end
        end
    end
end)

-- ============ LIVE UPDATER ============
track(RunService.Heartbeat:Connect(function()
    local t = now()
    if t - lastTick < 0.25 then return end
    lastTick = t
    if not frame or not frame.Parent then return end

    local idle = t - lastActionTime
    counterLabel.Text = string.format(
        "Resets: %d  ·  Idle: %ds", stats.resets, math.floor(idle)
    )

    if enabled then
        local pulse = 0.55 + 0.45 * math.abs(math.sin(t * 2))
        statusDot.BackgroundTransparency = 1 - pulse
    else
        statusDot.BackgroundTransparency = 0
    end
end))

-- ============ START ============
log("loaded (5m)")
setEnabled(true)
