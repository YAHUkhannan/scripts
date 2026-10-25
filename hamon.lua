-- language: Lua, file: hamon.lua, target: Roblox (mobile executor)
-- HAMON — Mobile aim/ESP. Snap aim, prediction, FOV that tracks camera zoom.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local VERSION = "1.2"

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
    ESPEnabled = false, Chams = false, Skeleton = true, HealthBar = false,
    NameText = false, DistanceText = false, MaxDistance = 500,
    WallCheck = false, FFAMode = false, MultiPointVis = true,
    ColorVisible = Color3.fromRGB(0, 255, 100),
    ColorHidden  = Color3.fromRGB(255, 50, 50),
    ColorTeam    = Color3.fromRGB(255, 190, 70),
}
local BOX_COLOR = Color3.fromRGB(235, 235, 235)

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
        d.Thickness = 1
        d.Transparency = 1
    elseif className == "Square" then
        d.Filled = false
        d.Transparency = 1
        d.Thickness = 1
    elseif className == "Text" then
        d.Size = 12
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
    table.clear(e.SkeletonLines)
    e.SkeletonCount = 0
    e.SkeletonPending = false
    e.SkeletonColor = nil
end

local function ReleaseAllBoxLines(e)
    if not e then return end
    for _, line in ipairs(e.BoxLines) do ReleaseDrawing(line) end
    table.clear(e.BoxLines)
end

local function ClearVisuals(e)
    if not e then return end
    ReleaseAllBoxLines(e)
    if e.HealthBar then ReleaseDrawing(e.HealthBar); e.HealthBar = nil end
    if e.NameText then ReleaseDrawing(e.NameText); e.NameText = nil end
    if e.DistText then ReleaseDrawing(e.DistText); e.DistText = nil end
    ReleaseAllSkeletonLines(e)
    e.DrawPending = false
end

local function EnsureEntry(p)
    local e = ESPData[p]
    if not e then
        e = { SkeletonLines = {}, SkeletonCount = 0, BoxLines = {} }
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
local MENU_W = 138
local MENU_H = 176
local moveMenuUnderButton

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
Scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
Scroll.ScrollingDirection = Enum.ScrollingDirection.Y
Scroll.Active = true
Scroll.Selectable = false
Scroll.ClipsDescendants = true
Scroll.ZIndex = 12
Scroll.Parent = MenuFrame

local Layout = Instance.new("UIListLayout")
Layout.Padding = UDim.new(0, 3)
Layout.SortOrder = Enum.SortOrder.LayoutOrder
Layout.Parent = Scroll

local function resizeCanvas()
    Scroll.CanvasSize = UDim2.fromOffset(0, Layout.AbsoluteContentSize.Y + 4)
    if moveMenuUnderButton then moveMenuUnderButton() end
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
local pointerStarts = {}

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
    if not gui then return false end
    local ancestor = gui
    while ancestor do
        if ancestor:IsA("GuiObject") then
            if not ancestor.Visible then return false end
            if ancestor.ClipsDescendants then
                local pos, size = ancestor.AbsolutePosition, ancestor.AbsoluteSize
                if x < pos.X or y < pos.Y or x > pos.X + size.X or y > pos.Y + size.Y then
                    return false
                end
            end
        end
        ancestor = ancestor.Parent
    end
    local pos = gui.AbsolutePosition
    local size = gui.AbsoluteSize
    return x >= pos.X and y >= pos.Y and x <= pos.X + size.X and y <= pos.Y + size.Y
end

local sections = {}
local function MakeSection(title, masterKey)
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, -4, 0, 22)
    header.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    header.BorderSizePixel = 0
    header.LayoutOrder = nextOrder()
    header.ZIndex = 14
    header.Parent = Scroll
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 4)

    local disclosure = Instance.new("TextButton")
    disclosure.Size = UDim2.new(1, masterKey and -40 or 0, 1, 0)
    disclosure.BackgroundTransparency = 1
    disclosure.Font = FONT
    disclosure.TextSize = 10
    disclosure.TextXAlignment = Enum.TextXAlignment.Left
    disclosure.TextColor3 = WHITE
    disclosure.TextStrokeTransparency = 1
    disclosure.AutoButtonColor = false
    disclosure.Active = true
    disclosure.ZIndex = 15
    disclosure.Parent = header

    local body = Instance.new("Frame")
    body.Name = title .. "Settings"
    body.Size = UDim2.new(1, -4, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.Visible = false
    body.LayoutOrder = nextOrder()
    body.ZIndex = 14
    body.Parent = Scroll
    local bodyLayout = Instance.new("UIListLayout", body)
    bodyLayout.Padding = UDim.new(0, 2)
    bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder

    local section = { body = body }
    sections[#sections + 1] = section
    function section.expand(open)
        body.Visible = open
        disclosure.Text = (open and "  - " or "  + ") .. title
    end
    function section.open()
        for _, other in ipairs(sections) do
            other.expand(other == section)
        end
        Scroll.CanvasPosition = Vector2.zero
        task.defer(resizeCanvas)
    end
    section.expand(false)
    bindPress(disclosure, function()
        if body.Visible then
            section.expand(false)
            task.defer(resizeCanvas)
        else
            section.open()
        end
    end)

    if masterKey then
        local toggle = Instance.new("TextButton")
        toggle.Size = UDim2.fromOffset(36, 20)
        toggle.Position = UDim2.new(1, -38, 0, 1)
        toggle.Font = FONT
        toggle.TextSize = 10
        toggle.TextStrokeTransparency = 1
        toggle.AutoButtonColor = false
        toggle.Active = true
        toggle.ZIndex = 15
        toggle.Parent = header
        Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 3)
        local function updateToggle()
            local on = SETTINGS[masterKey]
            toggle.Text = on and "ON" or "OFF"
            toggle.TextColor3 = WHITE
            toggle.BackgroundColor3 = on and Color3.fromRGB(55, 55, 55) or BLACK
        end
        updateToggle()
        bindPress(toggle, function()
            SETTINGS[masterKey] = not SETTINGS[masterKey]
            updateToggle()
            if SETTINGS[masterKey] then
                section.open()
            else
                section.expand(false)
                task.defer(resizeCanvas)
            end
        end)
    end
    return body
end

local function MakeRow(parent, text, toggleKey, cycleValues)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 20)
    btn.BackgroundColor3 = BLACK
    btn.BorderSizePixel = 0
    btn.Font = FONT
    btn.TextSize = 10
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextColor3 = WHITE
    btn.TextStrokeTransparency = 1
    btn.AutoButtonColor = false
    btn.Active = true
    btn.Selectable = false
    btn.ZIndex = 14
    btn.LayoutOrder = nextOrder()
    btn.Parent = parent
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

local function snap(value, step, minv, maxv)
    local clamped = math.clamp(value, minv, maxv)
    local snapped = math.floor((clamped / step) + 0.5) * step
    return tonumber(string.format("%.4f", snapped)) or clamped
end

local function MakeNumericRow(parent, label, field, minv, maxv, step, fmt)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 20)
    row.BackgroundColor3 = BLACK
    row.BorderSizePixel = 0
    row.Active = false
    row.ZIndex = 14
    row.LayoutOrder = nextOrder()
    row.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -52, 1, 0)
    lbl.Position = UDim2.new(0, 6, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = FONT
    lbl.TextSize = 10
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

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -4, 0, 14)
title.BackgroundTransparency = 1
title.Font = FONT
title.TextSize = 9
title.TextColor3 = Color3.fromRGB(180, 180, 180)
title.TextStrokeTransparency = 1
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "  HAMON v" .. VERSION
title.LayoutOrder = nextOrder()
title.ZIndex = 14
title.Parent = Scroll

local aimSection = MakeSection("AIM", "Aim")
MakeRow(aimSection, "PREDICT", "Prediction")
MakeRow(aimSection, "HUMANIZE", "Humanize")
MakeRow(aimSection, "LOCK", "LockTarget")
MakeRow(aimSection, "VISIBLE ONLY", "WallCheck")
MakeNumericRow(aimSection, "FOV", "AimFOV", 2, 80, 1, "%s  %.0f")
MakeNumericRow(aimSection, "LEAD", "PredictionAmount", 0.0, 0.4, 0.01, "%s  %.2fs")

local wallsSection = MakeSection("WALLS", "ESPEnabled")
MakeRow(wallsSection, "BONES", "Skeleton")
MakeRow(wallsSection, "BOXES", "Chams")
MakeRow(wallsSection, "HEALTH", "HealthBar")
MakeRow(wallsSection, "NAMES", "NameText")
MakeRow(wallsSection, "DISTANCE", "DistanceText")

local gameSection = MakeSection("GAME")
MakeRow(gameSection, "FFA", "FFAMode")
MakeNumericRow(gameSection, "RANGE", "MaxDistance", 100, 2000, 100, "%s  %.0f")
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

moveMenuUnderButton = function()
    local x, y, vp = buttonOffset()
    MainBtn.Position = UDim2.fromOffset(x, y)
    local mw = math.min(MENU_W, math.max(0, vp.X - 16))
    local mh = math.min(math.max(80, Layout.AbsoluteContentSize.Y + 8), MENU_H, math.max(0, vp.Y - 16))
    MenuFrame.Size = UDim2.fromOffset(mw, mh)
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
    if not dragInput or not dragStartPos or not startBtnPos then return end
    local isMouseMove = dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseMovement
    if input ~= dragInput and not isMouseMove then return end
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
    pointerStarts[input] = Vector2.new(input.Position.X, input.Position.Y)
end))

Track(UserInputService.InputEnded:Connect(function(input)
    local kind = input.UserInputType
    local isPointer = kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1
    local start = pointerStarts[input]
    pointerStarts[input] = nil
    local cancelled = input.UserInputState == Enum.UserInputState.Cancel
    if input == dragInput then
        dragInput = nil
        if not dragMoved and not cancelled then
            toggleMenu()
        end
    end
    if not isPointer or not start or cancelled or not MenuFrame.Visible then
        return
    end
    local here = Vector2.new(input.Position.X, input.Position.Y)
    local delta = here - start
    if math.abs(delta.X) > 18 or math.abs(delta.Y) > 18 then return end
    if pointIn(MainBtn, here.X, here.Y) then return end
    if not pointIn(Scroll, here.X, here.Y) then return end
    local best, bestArea = nil, math.huge
    for _, entry in ipairs(pressables) do
        if pointIn(entry.gui, here.X, here.Y) and pointIn(entry.gui, start.X, start.Y) then
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

local function setBoxLine(e, index, x1, y1, x2, y2, opacity)
    local line = e.BoxLines[index]
    if not line then
        line = GetDrawing("Line")
        e.BoxLines[index] = line
    end
    line.From = Vector2.new(x1, y1)
    line.To = Vector2.new(x2, y2)
    line.Thickness = 1
    line.Transparency = opacity
    line.Color = BOX_COLOR
    line.Visible = true
end

local function drawBox(e, x, y, width, height)
    -- At tiny screen sizes, let bones carry the information instead of merging
    -- eight corner strokes with them. Size-based fading also follows zoom.
    if width < 4 or height < (SETTINGS.Skeleton and 24 or 10) then
        ReleaseAllBoxLines(e)
        return
    end
    local length = math.min(width * 0.22, height * 0.12, 10)
    local opacity = math.clamp(height / 100, 0.28, 0.7)
    if SETTINGS.Skeleton then opacity = opacity * 0.8 end
    local left, right = x - 2, x + width + 2
    local top, bottom = y - 2, y + height + 2
    setBoxLine(e, 1, left, top, left + length, top, opacity)
    setBoxLine(e, 2, left, top, left, top + length, opacity)
    setBoxLine(e, 3, right - length, top, right, top, opacity)
    setBoxLine(e, 4, right, top, right, top + length, opacity)
    setBoxLine(e, 5, left, bottom, left + length, bottom, opacity)
    setBoxLine(e, 6, left, bottom - length, left, bottom, opacity)
    setBoxLine(e, 7, right - length, bottom, right, bottom, opacity)
    setBoxLine(e, 8, right, bottom - length, right, bottom, opacity)
end

local function drawSkeleton(e, char, color)
    local count = 0
    local boneMap = char:FindFirstChild("UpperTorso") and R15Bones or R6Bones
    for _, pair in ipairs(boneMap) do
        local p1 = char:FindFirstChild(pair[1])
        local p2 = char:FindFirstChild(pair[2])
        if p1 and p2 then
            local s1, v1 = Camera:WorldToViewportPoint(p1.Position)
            local s2, v2 = Camera:WorldToViewportPoint(p2.Position)
            if v1 and v2 then
                count += 1
                local line = e.SkeletonLines[count]
                if not line then
                    line = GetDrawing("Line")
                    e.SkeletonLines[count] = line
                end
                line.From = Vector2.new(s1.X, s1.Y)
                line.To = Vector2.new(s2.X, s2.Y)
                -- Box and bone lines share a pool; reset the box's faded style.
                line.Thickness = 1
                line.Transparency = 1
                line.Color = color
                line.Visible = true
            end
        end
    end
    for i = count + 1, e.SkeletonCount do
        ReleaseDrawing(e.SkeletonLines[i])
        e.SkeletonLines[i] = nil
    end
    e.SkeletonCount = count
end

-- MAIN LOOP ------------------------------------------------------------------

local function refreshDrawings()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local e = ESPData[p]
            local char = p.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local head = char and char:FindFirstChild("Head")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if e and e.DrawPending and hrp and head and hum then
                local rootPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
                local headPos = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.5, 0))
                local legPos = Camera:WorldToViewportPoint(hrp.Position - Vector3.new(0, 3, 0))
                if onScreen and headPos.Z > 0 and legPos.Z > 0 then
                    local height = math.abs(headPos.Y - legPos.Y)
                    local width = height * 0.5
                    local boxX = rootPos.X - width * 0.5
                    local boxY = math.min(headPos.Y, legPos.Y)
                    if SETTINGS.Chams then
                        drawBox(e, boxX, boxY, width, height)
                    else
                        ReleaseAllBoxLines(e)
                    end

                    if SETTINGS.Skeleton then
                        drawSkeleton(e, char, e.SkeletonColor)
                    else
                        ReleaseAllSkeletonLines(e)
                    end

                    if SETTINGS.HealthBar and height > 4 then
                        local hp = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                        if not e.HealthBar then
                            e.HealthBar = GetDrawing("Square")
                            e.HealthBar.Filled = true
                        end
                        e.HealthBar.Size = Vector2.new(2, height * hp)
                        e.HealthBar.Position = Vector2.new(boxX - 6, boxY + height * (1 - hp))
                        e.HealthBar.Color = Color3.fromHSV(hp * 0.33, 1, 1)
                        e.HealthBar.Visible = true
                    elseif e.HealthBar then
                        ReleaseDrawing(e.HealthBar)
                        e.HealthBar = nil
                    end

                    if SETTINGS.NameText then
                        if not e.NameText then e.NameText = GetDrawing("Text") end
                        e.NameText.Text = p.Name
                        e.NameText.Position = Vector2.new(rootPos.X, boxY - 13)
                        e.NameText.Color = BOX_COLOR
                        e.NameText.Visible = true
                    elseif e.NameText then
                        ReleaseDrawing(e.NameText)
                        e.NameText = nil
                    end

                    if SETTINGS.DistanceText then
                        if not e.DistText then e.DistText = GetDrawing("Text") end
                        e.DistText.Text = string.format("%d studs", math.floor(e.DrawDistance))
                        e.DistText.Position = Vector2.new(rootPos.X, boxY + height + 3)
                        e.DistText.Color = BOX_COLOR
                        e.DistText.Visible = true
                    elseif e.DistText then
                        ReleaseDrawing(e.DistText)
                        e.DistText = nil
                    end
                else
                    ClearVisuals(e)
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
    local wallsActive = SETTINGS.ESPEnabled and (SETTINGS.Chams or SETTINGS.Skeleton
        or SETTINGS.HealthBar or SETTINGS.NameText or SETTINGS.DistanceText)
    local needsVisibility = (aiming and SETTINGS.WallCheck) or (wallsActive and SETTINGS.Skeleton)

    local filterLen = 0
    if LocalPlayer.Character then
        filterLen += 1
        scratchFilter[filterLen] = LocalPlayer.Character
    end
    if needsVisibility and not SETTINGS.FFAMode and LocalPlayer.Team ~= nil then
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
            if not wallsActive then ClearVisuals(e) end
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
                            if needsVisibility then
                                scratchFilter[baseLen + 1] = char
                                RayParams.FilterDescendantsInstances = scratchFilter
                            end

                            local visible = not needsVisibility or IsVisible(hrp, head)
                            local color = allied and SETTINGS.ColorTeam
                                or (visible and SETTINGS.ColorVisible or SETTINGS.ColorHidden)

                            if wallsActive then
                                e.DrawPending = true
                                e.DrawDistance = dist
                                e.SkeletonPending = SETTINGS.Skeleton
                                e.SkeletonColor = color
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
    elseif FOVCircle then
        FOVCircle.Color = Color3.fromRGB(255, 50, 50)
    end
    -- Project every overlay once from the final camera, after any aim snap.
    if wallsActive then
        refreshDrawings()
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
    table.clear(pointerStarts)
    dragInput = nil
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
