-- language: Lua, file: hamon.lua, target: Roblox (mobile executor)
-- HAMON — Mobile aim/ESP. Snap aim, prediction, FOV that tracks camera zoom.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

if type(_G.__HamonUnload) == "function" then
    pcall(_G.__HamonUnload)
end

local Camera = workspace.CurrentCamera

local SETTINGS = {
    Aim = false, AimMode = "toggle", AimKey = Enum.KeyCode.E,
    AimFOV = 30,
    Prediction = false, PredictionAmount = 0.05,
    TargetPriority = "crosshair", LockTarget = true, LockLeeway = 1.35,
    MaxAngle = 70, Humanize = false, HumanJitter = 0.12,
    Chams = false, Skeleton = false, HealthBar = false,
    NameText = false, DistanceText = false, MaxDistance = 500,
    WallCheck = false, FFAMode = false, MultiPointVis = true,
    ColorVisible = Color3.fromRGB(0, 255, 100),
    ColorHidden  = Color3.fromRGB(255, 50, 50),
    ColorTeam    = Color3.fromRGB(80, 140, 255),
}

local aimHeld = false
local MenuOpen = false
local DrawingPool = {}
local drawKind = {}
local drawBusy = {}
local ESPData = {}
local lockedTarget = nil
local Connections = {}

local function Track(conn)
    if conn then
        table.insert(Connections, conn)
    end
    return conn
end

-- DRAWING POOL ---------------------------------------------------------------
-- State lives beside the Drawing object. Some executors throw if you add fields to it.

local function GetDrawing(className)
    local pool = DrawingPool[className]
    if not pool then
        pool = {}
        DrawingPool[className] = pool
    end
    for _, d in ipairs(pool) do
        if not drawBusy[d] then
            drawBusy[d] = true
            return d
        end
    end
    local d = Drawing.new(className)
    drawKind[d] = className
    drawBusy[d] = true
    if className == "Line" then
        d.Thickness = 1.5
        d.Transparency = 1
    elseif className == "Square" then
        d.Filled = false
        d.Transparency = 1
        d.Thickness = 1
    elseif className == "Text" then
        d.Size = 14
        d.Center = true
        d.Outline = true
        d.OutlineColor = Color3.new(0, 0, 0)
        d.Font = 2
    end
    table.insert(pool, d)
    return d
end

local function ReleaseDrawing(d)
    if not d then return end
    d.Visible = false
    drawBusy[d] = false
    local kind = drawKind[d]
    if kind == "Line" then
        d.From = Vector2.zero
        d.To = Vector2.zero
    elseif kind == "Square" then
        d.Size = Vector2.zero
        d.Position = Vector2.zero
    elseif kind == "Text" then
        d.Text = ""
    end
end

local function ReleaseAllSkeletonLines(e)
    if not e then return end
    for i = 1, e.SkeletonCount do
        ReleaseDrawing(e.SkeletonLines[i])
    end
    e.SkeletonLines = {}
    e.SkeletonCount = 0
end

local function ClearVisuals(e)
    if not e then return end
    if e.Box then ReleaseDrawing(e.Box); e.Box = nil end
    if e.HealthBar then ReleaseDrawing(e.HealthBar); e.HealthBar = nil end
    if e.NameText then ReleaseDrawing(e.NameText); e.NameText = nil end
    if e.DistText then ReleaseDrawing(e.DistText); e.DistText = nil end
    ReleaseAllSkeletonLines(e)
end

local function EnsureEntry(p)
    local e = ESPData[p]
    if not e then
        e = { SkeletonLines = {}, SkeletonCount = 0 }
        ESPData[p] = e
    end
    return e
end

local function destroyDrawing(d)
    if not d then return end
    pcall(function() d.Visible = false end)
    pcall(function() d:Remove() end)
    pcall(function() d:Destroy() end)
end

-- SOUND ----------------------------------------------------------------------

local KillSound = Instance.new("Sound")
KillSound.SoundId = "rbxassetid://8743762177"
KillSound.Volume = 3
KillSound.Parent = SoundService

local function HookKillSound(p)
    if p == LocalPlayer then return end
    Track(p.CharacterAdded:Connect(function(char)
        local hum = char:WaitForChild("Humanoid", 5)
        if hum then
            Track(hum.Died:Connect(function()
                SoundService:PlayLocalSound(KillSound)
            end))
        end
    end))
end

for _, p in pairs(Players:GetPlayers()) do
    HookKillSound(p)
end
Track(Players.PlayerAdded:Connect(HookKillSound))

-- UI -------------------------------------------------------------------------

local FONT = Enum.Font.SourceSans
pcall(function()
    FONT = Enum.Font.Gotham
end)

local BTN = 32
local MENU_W = 150
local MENU_H = 204

local function sweepOldGui(root)
    if typeof(root) ~= "Instance" then return end
    for _, child in ipairs(root:GetChildren()) do
        if child.Name == "HamonUI" then
            child:Destroy()
        end
    end
end

local function resolveGuiParent()
    local okHui, hui = pcall(function()
        if type(gethui) == "function" then
            return gethui()
        end
    end)
    if okHui and typeof(hui) == "Instance" then
        return hui
    end
    local okCore, core = pcall(function()
        return game:GetService("CoreGui")
    end)
    if okCore and typeof(core) == "Instance" then
        local probe = Instance.new("Folder")
        probe.Name = "HamonProbe"
        local can = pcall(function()
            probe.Parent = core
        end)
        if can then
            probe:Destroy()
            return core
        end
    end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local guiParent = resolveGuiParent()
pcall(function() sweepOldGui(LocalPlayer:FindFirstChild("PlayerGui")) end)
pcall(function() sweepOldGui(guiParent) end)
pcall(function() sweepOldGui(game:GetService("CoreGui")) end)

local sg = Instance.new("ScreenGui")
sg.Name = "HamonUI"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 100000
sg.Enabled = true
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
    sg.ScreenInsets = Enum.ScreenInsets.None
end)
sg.Parent = guiParent

local MainBtn = Instance.new("TextButton")
MainBtn.Name = "HamonButton"
MainBtn.Size = UDim2.new(0, BTN, 0, BTN)
MainBtn.Position = UDim2.new(0, 16, 0, 60)
MainBtn.BackgroundColor3 = Color3.new(0, 0, 0)
MainBtn.BackgroundTransparency = 0
MainBtn.Text = ""
MainBtn.AutoButtonColor = false
MainBtn.Active = true
MainBtn.Selectable = false
MainBtn.ClipsDescendants = true
MainBtn.ZIndex = 20
MainBtn.Parent = sg
Instance.new("UICorner", MainBtn).CornerRadius = UDim.new(1, 0)
local MainStroke = Instance.new("UIStroke", MainBtn)
MainStroke.Color = Color3.new(1, 1, 1)
MainStroke.Thickness = 2
pcall(function()
    MainStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
end)

local function crosshairBar(w, h)
    local bar = Instance.new("Frame")
    bar.AnchorPoint = Vector2.new(0.5, 0.5)
    bar.Position = UDim2.fromScale(0.5, 0.5)
    bar.Size = UDim2.fromOffset(w, h)
    bar.BackgroundColor3 = Color3.new(1, 1, 1)
    bar.BorderSizePixel = 0
    bar.Active = false
    bar.ZIndex = 21
    bar.Parent = MainBtn
    return bar
end
local crossH = crosshairBar(14, 2)
local crossV = crosshairBar(2, 14)
local rgbHue = 0
Track(RunService.RenderStepped:Connect(function(dt)
    rgbHue = (rgbHue + dt * 0.35) % 1
    local color = Color3.fromHSV(rgbHue, 1, 1)
    MainStroke.Color = color
    crossH.BackgroundColor3 = color
    crossV.BackgroundColor3 = color
end))

local MenuFrame = Instance.new("Frame")
MenuFrame.Name = "HamonMenu"
MenuFrame.Size = UDim2.fromOffset(MENU_W, MENU_H)
MenuFrame.Position = UDim2.fromOffset(16, 100)
MenuFrame.BackgroundColor3 = Color3.new(0, 0, 0)
MenuFrame.BackgroundTransparency = 0
MenuFrame.BorderSizePixel = 0
MenuFrame.Visible = false
MenuFrame.Active = true
MenuFrame.ClipsDescendants = true
MenuFrame.ZIndex = 10
MenuFrame.Parent = sg
Instance.new("UICorner", MenuFrame).CornerRadius = UDim.new(0, 6)
local MenuStroke = Instance.new("UIStroke", MenuFrame)
MenuStroke.Color = Color3.fromRGB(255, 255, 255)
MenuStroke.Transparency = 0.65
MenuStroke.Thickness = 1

local Scroll = Instance.new("ScrollingFrame")
Scroll.Size = UDim2.new(1, -8, 1, -8)
Scroll.Position = UDim2.new(0, 4, 0, 4)
Scroll.BackgroundTransparency = 1
Scroll.BorderSizePixel = 0
Scroll.ScrollBarThickness = 3
Scroll.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
Scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
Scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
Scroll.ScrollingDirection = Enum.ScrollingDirection.Y
Scroll.Active = true
Scroll.Selectable = false
Scroll.ZIndex = 12
Scroll.Parent = MenuFrame

local Layout = Instance.new("UIListLayout")
Layout.Padding = UDim.new(0, 3)
Layout.SortOrder = Enum.SortOrder.LayoutOrder
Layout.Parent = Scroll

local function resizeCanvas()
    Scroll.CanvasSize = UDim2.new(0, 0, 0, Layout.AbsoluteContentSize.Y + 12)
end
Track(Layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resizeCanvas))

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

local rowOrder = 0
local function nextOrder()
    rowOrder += 1
    return rowOrder
end

-- Row presses go through one hit-test on touch end. Button.Activated is wired to
-- the same debounce. Mobile executors often deliver only one of those.
local pressables = {}
local fingerStart = nil

local function bindPress(guiObj, fn)
    local entry = { gui = guiObj, fn = fn, last = 0 }
    pressables[#pressables + 1] = entry
    local function go()
        local now = os.clock()
        if now - entry.last < 0.2 then return end
        entry.last = now
        fn()
    end
    entry.go = go
    Track(guiObj.Activated:Connect(go))
    pcall(function()
        Track(guiObj.TouchTap:Connect(function()
            go()
        end))
    end)
end

local function pointIn(gui, x, y)
    if not gui or not gui.Visible then return false end
    local pos = gui.AbsolutePosition
    local size = gui.AbsoluteSize
    return x >= pos.X and y >= pos.Y and x <= pos.X + size.X and y <= pos.Y + size.Y
end

local function MakeRow(text, toggleKey, cycleValues)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -4, 0, 22)
    btn.BackgroundColor3 = BLACK
    btn.BorderSizePixel = 0
    btn.Font = FONT
    btn.TextSize = 11
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextColor3 = WHITE
    btn.TextStrokeTransparency = 1
    btn.AutoButtonColor = false
    btn.Active = true
    btn.Selectable = false
    btn.ZIndex = 14
    btn.LayoutOrder = nextOrder()
    btn.Parent = Scroll
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

    local function Update()
        if cycleValues then
            btn.Text = "  " .. text .. ": " .. tostring(SETTINGS[toggleKey]):upper()
            btn.BackgroundColor3 = BLACK
            btn.TextColor3 = WHITE
        else
            local on = SETTINGS[toggleKey]
            btn.Text = "  " .. text .. (on and "  ON" or "  OFF")
            btn.BackgroundColor3 = on and WHITE or BLACK
            btn.TextColor3 = on and BLACK or WHITE
        end
    end
    Update()

    bindPress(btn, function()
        if cycleValues then
            local cur = SETTINGS[toggleKey]
            local idx = 1
            for i, v in ipairs(cycleValues) do
                if v == cur then
                    idx = i
                    break
                end
            end
            SETTINGS[toggleKey] = cycleValues[(idx % #cycleValues) + 1]
        else
            SETTINGS[toggleKey] = not SETTINGS[toggleKey]
        end
        Update()
    end)
end

MakeRow("AIM", "Aim")
MakeRow("PREDICT", "Prediction")
MakeRow("HUMANIZE", "Humanize")
MakeRow("LOCK", "LockTarget")
MakeRow("WALLS", "WallCheck")
MakeRow("FFA", "FFAMode")
MakeRow("BOX", "Chams")
MakeRow("BONES", "Skeleton")
MakeRow("HP", "HealthBar")
MakeRow("NAME", "NameText")
MakeRow("DIST", "DistanceText")

local function snap(value, step, minv, maxv)
    local clamped = math.clamp(value, minv, maxv)
    local snapped = math.floor((clamped / step) + 0.5) * step
    return tonumber(string.format("%.4f", snapped)) or clamped
end

local function MakeNumericRow(label, field, minv, maxv, step, fmt)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -4, 0, 22)
    row.BackgroundColor3 = BLACK
    row.BorderSizePixel = 0
    row.Active = false
    row.ZIndex = 14
    row.LayoutOrder = nextOrder()
    row.Parent = Scroll

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -52, 1, 0)
    lbl.Position = UDim2.new(0, 6, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = FONT
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextColor3 = WHITE
    lbl.TextStrokeTransparency = 1
    lbl.ZIndex = 15
    lbl.Parent = row

    local function makeStepButton(text, xOff)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(18, 18)
        b.Position = UDim2.new(1, xOff, 0.5, -9)
        b.BackgroundColor3 = WHITE
        b.Text = text
        b.TextColor3 = BLACK
        b.TextStrokeTransparency = 1
        b.Font = FONT
        b.TextSize = 14
        b.AutoButtonColor = false
        b.Active = true
        b.Selectable = false
        b.ZIndex = 16
        b.Parent = row
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 3)
        return b
    end

    local minus = makeStepButton("-", -42)
    local plus = makeStepButton("+", -20)

    local function Update()
        lbl.Text = string.format(fmt, label, SETTINGS[field])
        lbl.TextColor3 = WHITE
    end
    Update()

    bindPress(minus, function()
        SETTINGS[field] = snap(SETTINGS[field] - step, step, minv, maxv)
        Update()
    end)
    bindPress(plus, function()
        SETTINGS[field] = snap(SETTINGS[field] + step, step, minv, maxv)
        Update()
    end)
end

MakeNumericRow("FOV",  "AimFOV",           2, 80,  1,    "%s  %.0f")
MakeNumericRow("LEAD", "PredictionAmount", 0.0, 0.4, 0.01, "%s  %.2fs")
task.defer(resizeCanvas)

-- DRAG + TAP ------------------------------------------------------------------
-- Only the finger that went down on the button can drag it. Mobile also emits a
-- fake mouse alongside every touch; treating that as a drag froze the button
-- once the menu was open.

local dragInput = nil
local dragMoved = false
local dragStartPos = nil
local startBtnPos = nil
local lastToggle = 0
local lastTouchAt = 0
local DRAG_THRESHOLD = 16

local function buttonOffset()
    local vp = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(800, 600)
    local x = MainBtn.Position.X.Offset
    local y = MainBtn.Position.Y.Offset
    if MainBtn.Position.X.Scale ~= 0 or MainBtn.Position.Y.Scale ~= 0 then
        x = MainBtn.AbsolutePosition.X
        y = MainBtn.AbsolutePosition.Y
    end
    x = math.clamp(x, 0, math.max(0, vp.X - BTN))
    y = math.clamp(y, 0, math.max(0, vp.Y - BTN))
    return x, y, vp
end

local function moveMenuUnderButton()
    local x, y, vp = buttonOffset()
    MainBtn.Position = UDim2.fromOffset(x, y)
    local mw, mh = MENU_W, MENU_H
    local mx = math.clamp(x, 0, math.max(0, vp.X - mw))
    local my = y + BTN + 6
    if my + mh > vp.Y - 8 then
        my = y - mh - 8
    end
    my = math.clamp(my, 0, math.max(0, vp.Y - mh))
    MenuFrame.Position = UDim2.fromOffset(mx, my)
end

local function toggleMenu()
    local now = os.clock()
    if now - lastToggle < 0.28 then return end
    lastToggle = now
    MenuOpen = not MenuOpen
    if MenuOpen then
        moveMenuUnderButton()
    end
    MenuFrame.Visible = MenuOpen
end

Track(MainBtn.InputBegan:Connect(function(input)
    local kind = input.UserInputType
    if kind == Enum.UserInputType.Touch then
        lastTouchAt = os.clock()
    elseif kind == Enum.UserInputType.MouseButton1 then
        if os.clock() - lastTouchAt < 0.45 then
            return
        end
    else
        return
    end
    if dragInput then return end
    dragInput = input
    dragMoved = false
    dragStartPos = Vector2.new(input.Position.X, input.Position.Y)
    startBtnPos = MainBtn.Position
end))

Track(UserInputService.InputChanged:Connect(function(input)
    if input ~= dragInput or not dragStartPos or not startBtnPos then return end
    local here = Vector2.new(input.Position.X, input.Position.Y)
    local delta = here - dragStartPos
    if math.abs(delta.X) > DRAG_THRESHOLD or math.abs(delta.Y) > DRAG_THRESHOLD then
        dragMoved = true
    end
    if dragMoved then
        MainBtn.Position = UDim2.new(
            startBtnPos.X.Scale, startBtnPos.X.Offset + delta.X,
            startBtnPos.Y.Scale, startBtnPos.Y.Offset + delta.Y)
        if MenuOpen then
            moveMenuUnderButton()
        end
    end
end))

Track(UserInputService.InputBegan:Connect(function(input)
    local kind = input.UserInputType
    if kind ~= Enum.UserInputType.Touch and kind ~= Enum.UserInputType.MouseButton1 then
        return
    end
    fingerStart = Vector2.new(input.Position.X, input.Position.Y)
end))

Track(UserInputService.InputEnded:Connect(function(input)
    local kind = input.UserInputType
    local isPointer = kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1
    if input == dragInput then
        dragInput = nil
        if not dragMoved then
            toggleMenu()
        end
    end
    if not isPointer or not fingerStart or not MenuFrame.Visible then
        if isPointer then fingerStart = nil end
        return
    end
    local here = Vector2.new(input.Position.X, input.Position.Y)
    local delta = here - fingerStart
    fingerStart = nil
    if math.abs(delta.X) > 18 or math.abs(delta.Y) > 18 then return end
    if pointIn(MainBtn, here.X, here.Y) then return end
    if not pointIn(Scroll, here.X, here.Y) then return end
    local best, bestArea = nil, math.huge
    for _, entry in ipairs(pressables) do
        if pointIn(entry.gui, here.X, here.Y) then
            local size = entry.gui.AbsoluteSize
            local area = size.X * size.Y
            if area < bestArea then
                best = entry
                bestArea = area
            end
        end
    end
    if best then
        best.go()
    end
end))

-- AIM KEY --------------------------------------------------------------------

Track(UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == SETTINGS.AimKey and SETTINGS.AimMode == "hold" then
        aimHeld = true
    end
end))
Track(UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == SETTINGS.AimKey and SETTINGS.AimMode == "hold" then
        aimHeld = false
    end
end))

local function AimActive()
    if SETTINGS.AimMode == "hold" then return aimHeld end
    return SETTINGS.Aim
end

-- FOV CIRCLE -----------------------------------------------------------------

local FOVCircle = nil
pcall(function()
    FOVCircle = Drawing.new("Circle")
    FOVCircle.Transparency = 1
    FOVCircle.Thickness = 1.5
    FOVCircle.Visible = false
    FOVCircle.Filled = false
    FOVCircle.Color = Color3.fromRGB(255, 50, 50)
end)

-- BONES ----------------------------------------------------------------------

local R15Bones = {
    {"Head","UpperTorso"},{"UpperTorso","LowerTorso"},
    {"UpperTorso","LeftUpperArm"},{"LeftUpperArm","LeftLowerArm"},{"LeftLowerArm","LeftHand"},
    {"UpperTorso","RightUpperArm"},{"RightUpperArm","RightLowerArm"},{"RightLowerArm","RightHand"},
    {"LowerTorso","LeftUpperLeg"},{"LeftUpperLeg","LeftLowerLeg"},{"LeftLowerLeg","LeftFoot"},
    {"LowerTorso","RightUpperLeg"},{"RightUpperLeg","RightLowerLeg"},{"RightLowerLeg","RightFoot"}
}
local R6Bones = {
    {"Head","Torso"},{"Torso","Left Arm"},{"Torso","Right Arm"},
    {"Torso","Left Leg"},{"Torso","Right Leg"}
}

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude
RayParams.IgnoreWater = true

-- REUSABLE SCRATCH TABLES ----------------------------------------------------

local scratchFilter = {}
local scratchPoints = {Vector3.zero, Vector3.zero, Vector3.zero}

local function ComputeFOVRadius()
    local vp = Camera.ViewportSize
    local fov = math.rad(math.max(Camera.FieldOfView, 1))
    local aim = math.rad(SETTINGS.AimFOV)
    return (vp.Y * 0.5) * math.tan(aim * 0.5) / math.tan(fov * 0.5)
end

local function IsVisible(hrp, head)
    local camPos = Camera.CFrame.Position
    if SETTINGS.MultiPointVis then
        scratchPoints[1] = head.Position
        scratchPoints[2] = hrp.Position
        scratchPoints[3] = hrp.Position - Vector3.new(0, 2.5, 0)
        for i = 1, 3 do
            if workspace:Raycast(camPos, scratchPoints[i] - camPos, RayParams) == nil then
                return true
            end
        end
        return false
    end
    return workspace:Raycast(camPos, hrp.Position - camPos, RayParams) == nil
end

local function drawSkeleton(e, char, color)
    for i = 1, e.SkeletonCount do
        ReleaseDrawing(e.SkeletonLines[i])
    end
    e.SkeletonLines = {}
    e.SkeletonCount = 0
    local boneMap = char:FindFirstChild("UpperTorso") and R15Bones or R6Bones
    for _, pair in ipairs(boneMap) do
        local p1 = char:FindFirstChild(pair[1])
        local p2 = char:FindFirstChild(pair[2])
        if p1 and p2 then
            local s1, v1 = Camera:WorldToViewportPoint(p1.Position)
            local s2, v2 = Camera:WorldToViewportPoint(p2.Position)
            if v1 and v2 then
                local line = GetDrawing("Line")
                line.From = Vector2.new(s1.X, s1.Y)
                line.To = Vector2.new(s2.X, s2.Y)
                line.Color = color
                line.Visible = true
                e.SkeletonCount += 1
                e.SkeletonLines[e.SkeletonCount] = line
            end
        end
    end
end

-- MAIN LOOP ------------------------------------------------------------------

local function refreshDrawings()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local e = ESPData[p]
            local char = p.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local head = char and char:FindFirstChild("Head")
            local hasDraw = e and (e.Box or e.HealthBar or e.NameText or e.DistText or (e.SkeletonCount and e.SkeletonCount > 0))
            if hasDraw and hrp and head then
                local rootPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
                if onScreen then
                    local headPos = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.5, 0))
                    local legPos = Camera:WorldToViewportPoint(hrp.Position - Vector3.new(0, 3, 0))
                    local height = math.abs(headPos.Y - legPos.Y)
                    local width = height * 0.5
                    local boxX = rootPos.X - width * 0.5
                    local boxY = headPos.Y
                    if e.Box then
                        e.Box.Size = Vector2.new(width, height)
                        e.Box.Position = Vector2.new(boxX, boxY)
                    end
                    if e.HealthBar and height > 4 then
                        local hum = char:FindFirstChildOfClass("Humanoid")
                        local hp = hum and math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1) or 1
                        e.HealthBar.Size = Vector2.new(3, height * hp)
                        e.HealthBar.Position = Vector2.new(boxX - 6, boxY + height * (1 - hp))
                    end
                    if e.NameText then
                        e.NameText.Position = Vector2.new(boxX + width * 0.5, boxY - 15)
                    end
                    if e.DistText then
                        e.DistText.Position = Vector2.new(boxX + width * 0.5, boxY + height + 3)
                    end
                    if SETTINGS.Skeleton and e.SkeletonCount > 0 then
                        local color = (e.Box and e.Box.Color)
                            or (e.NameText and e.NameText.Color)
                            or Color3.new(1, 1, 1)
                        drawSkeleton(e, char, color)
                    end
                end
            end
        end
    end
end

local renderWarned = false

local function renderFrame(dt)
    Camera = workspace.CurrentCamera
    if not Camera then return end

    local viewport = Camera.ViewportSize
    local center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
    local radius = ComputeFOVRadius()
    local aiming = AimActive()

    if FOVCircle then
        FOVCircle.Radius = radius
        FOVCircle.Position = center
        FOVCircle.Visible = aiming
    end

    local candidates = {}
    local alive = {}

    local filterLen = 0
    if LocalPlayer.Character then
        filterLen += 1
        scratchFilter[filterLen] = LocalPlayer.Character
    end
    if not SETTINGS.FFAMode and LocalPlayer.Team ~= nil then
        for _, other in ipairs(Players:GetPlayers()) do
            if other ~= LocalPlayer and other.Team == LocalPlayer.Team and other.Character then
                filterLen += 1
                scratchFilter[filterLen] = other.Character
            end
        end
    end
    for i = filterLen + 1, #scratchFilter do
        scratchFilter[i] = nil
    end
    local baseLen = filterLen

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            alive[p] = true
            local e = EnsureEntry(p)
            local char = p.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local head = char and char:FindFirstChild("Head")

            if not (char and hum and hrp and head) or hum.Health <= 0 then
                ClearVisuals(e)
            else
                local allied = p.Team ~= nil and p.Team == LocalPlayer.Team
                if allied and not SETTINGS.FFAMode then
                    ClearVisuals(e)
                else
                    local rootPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
                    if not onScreen then
                        ClearVisuals(e)
                    else
                        local dist = (hrp.Position - Camera.CFrame.Position).Magnitude
                        if dist > SETTINGS.MaxDistance then
                            ClearVisuals(e)
                        else
                            scratchFilter[baseLen + 1] = char
                            RayParams.FilterDescendantsInstances = scratchFilter

                            local visible = IsVisible(hrp, head)
                            local color = allied and SETTINGS.ColorTeam
                                or (visible and SETTINGS.ColorVisible or SETTINGS.ColorHidden)

                            local headPos = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.5, 0))
                            local legPos = Camera:WorldToViewportPoint(hrp.Position - Vector3.new(0, 3, 0))
                            local height = math.abs(headPos.Y - legPos.Y)
                            local width = height * 0.5
                            local boxX = rootPos.X - width * 0.5
                            local boxY = headPos.Y

                            if SETTINGS.Chams then
                                if not e.Box then
                                    e.Box = GetDrawing("Square")
                                    e.Box.Filled = false
                                end
                                e.Box.Size = Vector2.new(width, height)
                                e.Box.Position = Vector2.new(boxX, boxY)
                                e.Box.Color = color
                                e.Box.Visible = true
                            elseif e.Box then
                                ReleaseDrawing(e.Box)
                                e.Box = nil
                            end

                            if SETTINGS.Skeleton then
                                drawSkeleton(e, char, color)
                            else
                                ReleaseAllSkeletonLines(e)
                            end

                            if SETTINGS.HealthBar and height > 4 then
                                local hp = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                                if not e.HealthBar then
                                    e.HealthBar = GetDrawing("Square")
                                    e.HealthBar.Filled = true
                                end
                                e.HealthBar.Size = Vector2.new(3, height * hp)
                                e.HealthBar.Position = Vector2.new(boxX - 6, boxY + height * (1 - hp))
                                e.HealthBar.Color = Color3.fromHSV(hp * 0.33, 1, 1)
                                e.HealthBar.Visible = true
                            elseif e.HealthBar then
                                ReleaseDrawing(e.HealthBar)
                                e.HealthBar = nil
                            end

                            if SETTINGS.NameText then
                                if not e.NameText then
                                    e.NameText = GetDrawing("Text")
                                end
                                e.NameText.Text = p.Name
                                e.NameText.Position = Vector2.new(boxX + width * 0.5, boxY - 15)
                                e.NameText.Color = color
                                e.NameText.Visible = true
                            elseif e.NameText then
                                ReleaseDrawing(e.NameText)
                                e.NameText = nil
                            end

                            if SETTINGS.DistanceText then
                                if not e.DistText then
                                    e.DistText = GetDrawing("Text")
                                end
                                e.DistText.Text = string.format("%d m", math.floor(dist))
                                e.DistText.Position = Vector2.new(boxX + width * 0.5, boxY + height + 3)
                                e.DistText.Color = color
                                e.DistText.Visible = true
                            elseif e.DistText then
                                ReleaseDrawing(e.DistText)
                                e.DistText = nil
                            end

                            if aiming then
                                local hs, ho = Camera:WorldToViewportPoint(head.Position)
                                if ho then
                                    local sd = (Vector2.new(hs.X, hs.Y) - center).Magnitude
                                    local locked = lockedTarget and lockedTarget.player == p
                                    local gate = locked and (radius * SETTINGS.LockLeeway) or radius
                                    if sd < gate and ((not SETTINGS.WallCheck) or visible) then
                                        local score
                                        if SETTINGS.TargetPriority == "health" then
                                            score = hum.Health
                                        elseif SETTINGS.TargetPriority == "distance" then
                                            score = dist
                                        else
                                            score = sd
                                        end
                                        table.insert(candidates, {
                                            player = p, head = head, hrp = hrp, hum = hum,
                                            score = score, screenDist = sd,
                                        })
                                    end
                                end
                            end

                            scratchFilter[baseLen + 1] = nil
                        end
                    end
                end
            end
        end
    end

    for p, e in pairs(ESPData) do
        if not alive[p] then
            ClearVisuals(e)
            ESPData[p] = nil
        end
    end

    local target = nil
    if aiming then
        if SETTINGS.LockTarget and lockedTarget then
            local found = nil
            for _, c in ipairs(candidates) do
                if c.player == lockedTarget.player and c.head == lockedTarget.head then
                    found = c
                    break
                end
            end
            if found then
                target = found
            else
                lockedTarget = nil
            end
        end
        if not target then
            local best = nil
            for _, c in ipairs(candidates) do
                if not best or c.score < best.score then
                    best = c
                end
            end
            if best then
                target = best
                lockedTarget = { player = best.player, head = best.head }
            end
        end
    else
        lockedTarget = nil
    end

    if target then
        local hum = target.hum
        if FOVCircle and hum and hum.MaxHealth > 0 then
            FOVCircle.Color = Color3.fromHSV((hum.Health / hum.MaxHealth) * 0.35, 1, 1)
        end

        local aimPos = target.head.Position
        if SETTINGS.Prediction then
            aimPos = aimPos + target.hrp.AssemblyLinearVelocity * SETTINGS.PredictionAmount
        end

        local goal = CFrame.new(Camera.CFrame.Position, aimPos)
        if SETTINGS.Humanize then
            local jx = (math.random() - 0.5) * 2 * SETTINGS.HumanJitter * 0.01
            local jy = (math.random() - 0.5) * 2 * SETTINGS.HumanJitter * 0.01
            goal = goal * CFrame.Angles(jy, jx, 0)
        end
        Camera.CFrame = goal
        -- The snap is the camera this frame will actually show. Place the
        -- drawings again so they stay on the bodies.
        refreshDrawings()
    elseif FOVCircle then
        FOVCircle.Color = Color3.fromRGB(255, 50, 50)
    end
end

-- After the default camera and after gun recoil. RenderStepped can run before
-- that shake, which leaves the boxes on the pre-shake screen position.
pcall(function()
    RunService:UnbindFromRenderStep("HamonRender")
end)
RunService:BindToRenderStep("HamonRender", Enum.RenderPriority.Last.Value + 1, function(dt)
    local ok, err = pcall(renderFrame, dt)
    if not ok and not renderWarned then
        renderWarned = true
        warn("[Hamon] render error: " .. tostring(err))
    end
end)

Track(Players.PlayerRemoving:Connect(function(p)
    ClearVisuals(ESPData[p])
    ESPData[p] = nil
    if lockedTarget and lockedTarget.player == p then
        lockedTarget = nil
    end
end))

_G.__HamonUnload = function()
    pcall(function()
        RunService:UnbindFromRenderStep("HamonRender")
    end)
    for _, c in ipairs(Connections) do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(Connections)
    for _, pool in pairs(DrawingPool) do
        for _, d in ipairs(pool) do
            destroyDrawing(d)
        end
    end
    table.clear(DrawingPool)
    destroyDrawing(FOVCircle)
    FOVCircle = nil
    if KillSound then
        KillSound:Destroy()
    end
    if sg then
        sg:Destroy()
    end
    lockedTarget = nil
end
