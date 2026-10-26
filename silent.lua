-- language: Lua, file: silent.lua, target: Roblox (mobile executor)
-- Silent aim for GunFramework's ProjectileRender, with optional local shot capture.
-- A shot is redirected only when a player's head is inside the FOV circle.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local VERSION = "1.2"

local genv = _G
pcall(function()
    if type(getgenv) == "function" then
        genv = getgenv()
    end
end)
if type(genv.__SilentUnload) == "function" then
    pcall(genv.__SilentUnload)
end

-- Tables, not bare locals, so a newcclosure hook still sees later writes.
local state = {
    running = true,
    enabled = true,
    fov = 30,
    aim = nil,
    head = nil,
    vel = Vector3.zero,
    look = Vector3.new(0, 0, -1),
    speed = 110,
}
local original = {}
local conns = {}
local namecallBridge = nil
local circle = nil

local function track(conn)
    if conn then
        conns[#conns + 1] = conn
    end
    return conn
end

local isOurCall = nil
pcall(function()
    if type(checkcaller) == "function" then
        isOurCall = checkcaller
    end
end)

local FONT = Enum.Font.SourceSans
pcall(function()
    FONT = Enum.Font.Gotham
end)

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local BTN = 32
local MENU_W = 132
local MENU_H = 108

local function clearTarget()
    state.aim = nil
    state.part = nil
    state.head = nil
    state.eye = nil
    state.root = nil
    state.vel = Vector3.zero
    if circle then
        pcall(function()
            circle.Visible = false
            circle.Color = WHITE
        end)
    end
end

-- LOCAL SHOT CAPTURE ---------------------------------------------------------
-- No network logging. The hook records bounded previews without calling any
-- Instance methods, which would disturb the pending __namecall method.
local capture = { enabled = false, events = {}, pos = 0, count = 0, dropped = 0,
    pings = {}, number = 0, error = nil }
local CAPTURE_MAX, CAPTURE_WINDOW = 96, 15
local watchedRemotes = { ProjectileRender = true, CheckShot = true, ProjectileFinished = true }

local function instancePath(value)
    local names = {}
    for _ = 1, 16 do
        if not value then break end
        table.insert(names, 1, value.Name)
        value = value.Parent
    end
    return table.concat(names, ".")
end

local function preview(value, depth)
    local kind = typeof(value)
    if kind == "nil" then return "nil"
    elseif kind == "number" then return string.format("%.17g", value)
    elseif kind == "boolean" then return tostring(value)
    elseif kind == "string" then return string.format("%q", value:sub(1, 160))
    elseif kind == "Vector3" then
        return string.format("V3(%.3f,%.3f,%.3f)", value.X, value.Y, value.Z)
    elseif kind == "CFrame" then
        return "CF(pos=" .. preview(value.Position, 0) .. ",look=" .. preview(value.LookVector, 0) .. ")"
    elseif kind == "Instance" then
        return value.ClassName .. ":" .. instancePath(value)
    elseif kind == "table" then
        if depth >= 2 then return "{...}" end
        local items, count = {}, 0
        for key, item in next, value do
            count = count + 1
            if count > 8 then items[#items + 1] = "..."; break end
            items[#items + 1] = "[" .. preview(key, 2) .. "]=" .. preview(item, depth + 1)
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return kind
end

local function resetCaptureEvents()
    table.clear(capture.events)
    capture.pos, capture.count, capture.dropped, capture.error = 0, 0, 0, nil
end

local function captureRemote(stage, remote, ...)
    local argc, lines = select("#", ...), {}
    for i = 1, math.min(argc, 24) do
        lines[#lines + 1] = "  [" .. i .. "] " .. preview(select(i, ...), 0)
    end
    if argc > 24 then lines[#lines + 1] = "  ... arguments truncated" end
    local context = "silent=" .. (state.enabled and "ON" or "OFF")
        .. " target=" .. (state.part and instancePath(state.part) or "none")
        .. " speed=" .. tostring(state.speed)
    local entry = { t = os.clock(), text = stage .. " " .. instancePath(remote)
        .. " argc=" .. argc .. "\n" .. context .. "\n" .. table.concat(lines, "\n") }
    capture.pos = (capture.pos % CAPTURE_MAX) + 1
    if capture.count == CAPTURE_MAX then capture.dropped = capture.dropped + 1 end
    capture.events[capture.pos] = entry
    capture.count = math.min(capture.count + 1, CAPTURE_MAX)
end

local function recordRemote(stage, remote, ...)
    if not capture.enabled or not watchedRemotes[remote.Name] then return end
    local ok, err = pcall(captureRemote, stage, remote, ...)
    if not ok then capture.error = tostring(err) end
end

local function pingCapture()
    capture.number = capture.number + 1
    local now = os.clock()
    local lines = { "===== PING " .. capture.number .. " =====" }
    local found = 0
    for i = 1, capture.count do
        local index = ((capture.pos - capture.count + i - 1) % CAPTURE_MAX) + 1
        local entry = capture.events[index]
        if now - entry.t <= CAPTURE_WINDOW then
            found = found + 1
            lines[#lines + 1] = string.format("%.3fs before PING  %s", now - entry.t, entry.text)
        end
    end
    if found == 0 then
        lines[#lines + 1] = "No new watched reports in the last " .. CAPTURE_WINDOW .. " seconds."
    end
    if capture.dropped > 0 then lines[#lines + 1] = "Buffer overflow: " .. capture.dropped .. " earlier reports dropped." end
    if capture.error then lines[#lines + 1] = "Capture error: " .. capture.error end
    capture.pings[#capture.pings + 1] = table.concat(lines, "\n")
    if #capture.pings > 4 then table.remove(capture.pings, 1) end
    resetCaptureEvents()
    return "SILENT v" .. VERSION .. " | local capture | original=game, sent=rewritten\n"
        .. "Outgoing reports do not confirm damage. Each PING consumes fresh reports.\n\n"
        .. table.concat(capture.pings, "\n\n")
end

-- GUI -----------------------------------------------------------------------
local function sweepOldGui(root)
    if typeof(root) ~= "Instance" then return end
    for _, child in ipairs(root:GetChildren()) do
        if child.Name == "SilentUI" then
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
        probe.Name = "SilentProbe"
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
sg.Name = "SilentUI"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 100001
sg.Enabled = true
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
    sg.ScreenInsets = Enum.ScreenInsets.None
end)
sg.Parent = guiParent

local MainBtn = Instance.new("TextButton")
MainBtn.Name = "SilentButton"
MainBtn.Size = UDim2.fromOffset(BTN, BTN)
MainBtn.AnchorPoint = Vector2.new(1, 0)
MainBtn.Position = UDim2.new(1, -16, 0, 70)
MainBtn.BackgroundColor3 = BLACK
MainBtn.Text = "S"
MainBtn.TextColor3 = WHITE
MainBtn.TextStrokeTransparency = 1
MainBtn.Font = FONT
MainBtn.TextSize = 14
MainBtn.AutoButtonColor = false
MainBtn.Active = true
MainBtn.Selectable = false
MainBtn.ZIndex = 20
MainBtn.Parent = sg
Instance.new("UICorner", MainBtn).CornerRadius = UDim.new(1, 0)
local MainStroke = Instance.new("UIStroke", MainBtn)
MainStroke.Color = WHITE
MainStroke.Thickness = 1
MainStroke.Transparency = 0.25

local MenuFrame = Instance.new("Frame")
MenuFrame.Name = "SilentMenu"
MenuFrame.Size = UDim2.fromOffset(MENU_W, MENU_H)
MenuFrame.BackgroundColor3 = BLACK
MenuFrame.BorderSizePixel = 0
MenuFrame.Visible = false
MenuFrame.Active = true
MenuFrame.ZIndex = 10
MenuFrame.Parent = sg
Instance.new("UICorner", MenuFrame).CornerRadius = UDim.new(0, 4)
local MenuStroke = Instance.new("UIStroke", MenuFrame)
MenuStroke.Color = WHITE
MenuStroke.Transparency = 0.65
MenuStroke.Thickness = 1

local function makeRow(y, text)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -8, 0, 22)
    btn.Position = UDim2.fromOffset(4, y)
    btn.BackgroundColor3 = BLACK
    btn.BorderSizePixel = 0
    btn.Font = FONT
    btn.TextSize = 11
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.Text = text
    btn.TextColor3 = WHITE
    btn.TextStrokeTransparency = 1
    btn.AutoButtonColor = false
    btn.Active = true
    btn.Selectable = false
    btn.ZIndex = 14
    btn.Parent = MenuFrame
    return btn
end

local ToggleRow = makeRow(4, "  SILENT  ON")
local FovRow = Instance.new("Frame")
FovRow.Size = UDim2.new(1, -8, 0, 22)
FovRow.Position = UDim2.fromOffset(4, 30)
FovRow.BackgroundColor3 = BLACK
FovRow.BorderSizePixel = 0
FovRow.ZIndex = 14
FovRow.Parent = MenuFrame

local FovLabel = Instance.new("TextLabel")
FovLabel.Size = UDim2.new(1, -44, 1, 0)
FovLabel.Position = UDim2.fromOffset(6, 0)
FovLabel.BackgroundTransparency = 1
FovLabel.Font = FONT
FovLabel.TextSize = 11
FovLabel.TextXAlignment = Enum.TextXAlignment.Left
FovLabel.TextColor3 = WHITE
FovLabel.TextStrokeTransparency = 1
FovLabel.Text = "FOV  30"
FovLabel.ZIndex = 15
FovLabel.Parent = FovRow

local function stepButton(text, x)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(18, 18)
    b.Position = UDim2.new(1, x, 0.5, -9)
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
    b.Parent = FovRow
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 3)
    return b
end

local MinusBtn = stepButton("-", -40)
local PlusBtn = stepButton("+", -18)
local CaptureBtn = makeRow(56, "  CAPTURE  OFF")
local PingBtn = makeRow(82, "  PING")
PingBtn.Size = UDim2.new(0.6, -4, 0, 22)
local LogBtn = makeRow(82, "  LOG")
LogBtn.Position = UDim2.new(0.6, 0, 0, 82)
LogBtn.Size = UDim2.new(0.4, -4, 0, 22)

local LogPanel = Instance.new("Frame", sg)
LogPanel.Name = "ShotCapture"
LogPanel.Size = UDim2.fromScale(0.94, 0.65)
LogPanel.Position = UDim2.fromScale(0.03, 0.22)
LogPanel.BackgroundColor3 = BLACK
LogPanel.BorderSizePixel = 0
LogPanel.Visible = false
LogPanel.Active = true
LogPanel.ClipsDescendants = true
LogPanel.ZIndex = 30
Instance.new("UICorner", LogPanel).CornerRadius = UDim.new(0, 5)

local LogScroll = Instance.new("ScrollingFrame", LogPanel)
LogScroll.Size = UDim2.new(1, -12, 1, -36)
LogScroll.Position = UDim2.fromOffset(6, 30)
LogScroll.BackgroundTransparency = 1
LogScroll.BorderSizePixel = 0
LogScroll.ScrollBarThickness = 4
LogScroll.CanvasSize = UDim2.fromOffset(0, 0)
LogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
LogScroll.ClipsDescendants = true
LogScroll.ZIndex = 31

local LogText = Instance.new("TextBox", LogScroll)
LogText.Size = UDim2.new(1, -6, 0, 0)
LogText.AutomaticSize = Enum.AutomaticSize.Y
LogText.BackgroundTransparency = 1
LogText.TextColor3 = WHITE
LogText.Font = Enum.Font.Code
LogText.TextSize = 11
LogText.TextXAlignment = Enum.TextXAlignment.Left
LogText.TextYAlignment = Enum.TextYAlignment.Top
LogText.TextWrapped = true
LogText.MultiLine = true
LogText.ClearTextOnFocus = false
LogText.Text = "Enable CAPTURE, shoot once, wait for impact, then PING within 15 seconds of the shot."
LogText.ZIndex = 32
pcall(function() LogText.TextEditable = false end)

local function refreshUi()
    local on = state.enabled
    ToggleRow.Text = "  SILENT v" .. VERSION .. (on and "  ON" or "  OFF")
    ToggleRow.BackgroundColor3 = on and WHITE or BLACK
    ToggleRow.TextColor3 = on and BLACK or WHITE
    MainBtn.Text = on and "S" or "s"
    MainStroke.Transparency = on and 0 or 0.6
    FovLabel.Text = string.format("FOV  %.0f", state.fov)
end
refreshUi()

local menuOpen = false
local function placeMenu()
    local vp = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(800, 600)
    local bx = MainBtn.AbsolutePosition.X
    local by = MainBtn.AbsolutePosition.Y
    local mx = bx - MENU_W - 6
    if mx < 0 then
        mx = bx + BTN + 6
    end
    local my = by
    if my + MENU_H > vp.Y - 8 then
        my = vp.Y - MENU_H - 8
    end
    mx = math.clamp(mx, 0, math.max(0, vp.X - MENU_W))
    my = math.clamp(my, 0, math.max(0, vp.Y - MENU_H))
    MenuFrame.Position = UDim2.fromOffset(mx, my)
end

local function toggleMenu()
    menuOpen = not menuOpen
    if menuOpen then
        placeMenu()
    end
    MenuFrame.Visible = menuOpen
end

local pressAt = {}
local pointerStarts = {}
local function bindPress(guiObj, fn)
    pressAt[guiObj] = fn
    track(guiObj.Activated:Connect(function(input)
        if not input or input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then return end
        fn()
    end))
end

local function pointIn(gui, x, y)
    if not gui then return false end
    local ancestor = gui
    while ancestor do
        if ancestor:IsA("GuiObject") then
            if not ancestor.Visible then return false end
            if ancestor.ClipsDescendants then
                local pos, size = ancestor.AbsolutePosition, ancestor.AbsoluteSize
                if x < pos.X or y < pos.Y or x > pos.X + size.X or y > pos.Y + size.Y then return false end
            end
        end
        ancestor = ancestor.Parent
    end
    local pos, size = gui.AbsolutePosition, gui.AbsoluteSize
    return x >= pos.X and y >= pos.Y and x <= pos.X + size.X and y <= pos.Y + size.Y
end

local function pressableAt(x, y)
    local best, bestArea, bestZ = nil, math.huge, -math.huge
    local overLog = LogPanel.Visible and pointIn(LogPanel, x, y)
    for guiObj, go in pairs(pressAt) do
        if (not overLog or guiObj.Parent == LogPanel) and pointIn(guiObj, x, y) then
            local size = guiObj.AbsoluteSize
            local area, z = size.X * size.Y, guiObj.ZIndex
            if z > bestZ or (z == bestZ and area < bestArea) then
                best, bestArea, bestZ = { gui = guiObj, go = go }, area, z
            end
        end
    end
    return best
end

local function logAction(text, x, width, fn)
    local button = Instance.new("TextButton", LogPanel)
    button.Size = UDim2.fromOffset(width, 22)
    button.Position = UDim2.fromOffset(x, 4)
    button.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    button.TextColor3 = WHITE
    button.Font = FONT
    button.TextSize = 10
    button.Text = text
    button.AutoButtonColor = false
    button.ZIndex = 33
    bindPress(button, fn)
    return button
end

bindPress(CaptureBtn, function()
    capture.enabled = not capture.enabled
    resetCaptureEvents()
    CaptureBtn.Text = capture.enabled and "  CAPTURE  ON" or "  CAPTURE  OFF"
end)
bindPress(PingBtn, function()
    if not capture.enabled then
        LogText.Text = "CAPTURE is OFF. Enable it before the next test shot."
    else
        LogText.Text = pingCapture()
    end
    LogScroll.CanvasPosition = Vector2.zero
    LogPanel.Visible = true
end)
bindPress(LogBtn, function() LogPanel.Visible = not LogPanel.Visible end)
local CopyBtn
CopyBtn = logAction("COPY", 6, 44, function()
    local ok = type(setclipboard) == "function" and pcall(setclipboard, LogText.Text)
    CopyBtn.Text = ok and "COPIED" or "SELECT"
    if not ok then LogText:CaptureFocus() end
end)
logAction("CLEAR", 56, 44, function()
    resetCaptureEvents()
    table.clear(capture.pings)
    capture.number = 0
    LogText.Text = "Cleared. Shoot once, wait for the projectile to stop, then PING within 15 seconds of the shot."
end)
logAction("CLOSE", 106, 44, function() LogPanel.Visible = false end)

bindPress(ToggleRow, function()
    state.enabled = not state.enabled
    if not state.enabled then clearTarget() end
    refreshUi()
end)

local function snapFov(value)
    return math.clamp(math.floor(value + 0.5), 2, 80)
end

bindPress(MinusBtn, function()
    state.fov = snapFov(state.fov - 1)
    refreshUi()
end)
bindPress(PlusBtn, function()
    state.fov = snapFov(state.fov + 1)
    refreshUi()
end)

local dragInput = nil
local dragMoved = false
local dragStart = nil
local startPos = nil
local lastToggle = -math.huge
local lastTouchAt = -math.huge

track(MainBtn.InputBegan:Connect(function(input)
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
    dragStart = Vector2.new(input.Position.X, input.Position.Y)
    startPos = MainBtn.AbsolutePosition
end))

track(UserInputService.InputChanged:Connect(function(input)
    local press = pointerStarts[input]
    if press then
        local delta = Vector2.new(input.Position.X, input.Position.Y) - press.position
        if math.abs(delta.X) > 18 or math.abs(delta.Y) > 18 then press.moved = true end
    end
    if not dragInput or not dragStart or not startPos then return end
    local isMouseMove = dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseMovement
    if input ~= dragInput and not isMouseMove then return end
    local here = Vector2.new(input.Position.X, input.Position.Y)
    local delta = here - dragStart
    if math.abs(delta.X) > 14 or math.abs(delta.Y) > 14 then
        dragMoved = true
    end
    if dragMoved then
        local vp = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(800, 600)
        local x = math.clamp(startPos.X + delta.X, 0, math.max(0, vp.X - BTN))
        local y = math.clamp(startPos.Y + delta.Y, 0, math.max(0, vp.Y - BTN))
        MainBtn.AnchorPoint = Vector2.zero
        MainBtn.Position = UDim2.fromOffset(x, y)
        if menuOpen then
            placeMenu()
        end
    end
end))

track(UserInputService.InputBegan:Connect(function(input)
    local kind = input.UserInputType
    if kind == Enum.UserInputType.Touch then
        lastTouchAt = os.clock()
    elseif kind == Enum.UserInputType.MouseButton1 then
        if os.clock() - lastTouchAt < 0.45 then return end
    else
        return
    end
    local here = Vector2.new(input.Position.X, input.Position.Y)
    pointerStarts[input] = { position = here, entry = pressableAt(here.X, here.Y), moved = false }
end))

track(UserInputService.InputEnded:Connect(function(input)
    local kind = input.UserInputType
    local isPointer = kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1
    local start = pointerStarts[input]
    pointerStarts[input] = nil
    local cancelled = input.UserInputState == Enum.UserInputState.Cancel
    if input == dragInput then
        dragInput = nil
        if not dragMoved and not cancelled then
            local now = os.clock()
            if now - lastToggle >= 0.28 then
                lastToggle = now
                toggleMenu()
            end
        end
    end
    if not isPointer or not start or cancelled or not (MenuFrame.Visible or LogPanel.Visible) then
        return
    end
    local here = Vector2.new(input.Position.X, input.Position.Y)
    local delta = here - start.position
    if start.moved or math.abs(delta.X) > 18 or math.abs(delta.Y) > 18 then return end
    local entry = start.entry
    if entry and pointIn(entry.gui, here.X, here.Y) then
        entry.go()
    end
end))

-- FOV ----------------------------------------------------------------------

pcall(function()
    circle = Drawing.new("Circle")
    circle.Thickness = 1
    circle.Transparency = 1
    circle.Filled = false
    circle.Visible = false
    circle.Color = WHITE
end)

local function camera()
    return workspace.CurrentCamera
end

local function fovRadius(cam)
    local vp = cam.ViewportSize
    local view = math.rad(math.max(cam.FieldOfView, 1))
    local aim = math.rad(state.fov)
    return (vp.Y * 0.5) * math.tan(aim * 0.5) / math.tan(view * 0.5)
end

local function bestTarget(cam, radius)
    local vp = cam.ViewportSize
    local center = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
    local bestPart, bestDist = nil, nil
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local char = p.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local part = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
            if hum and part and hum.Health > 0 then
                local sp, onScreen = cam:WorldToViewportPoint(part.Position)
                if onScreen and sp.Z > 0 then
                    local dist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if dist <= radius and (not bestDist or dist < bestDist) then
                        bestPart = part
                        bestDist = dist
                    end
                end
            end
        end
    end
    return bestPart
end

-- Each gun sends its bullet speed on ProjectileRender. Aim where the head
-- will be when a bullet at that speed arrives.
local function leadAt(origin, head, vel, speed)
    if typeof(head) ~= "Vector3" or typeof(origin) ~= "Vector3" then
        return head
    end
    if typeof(vel) ~= "Vector3" then
        vel = Vector3.zero
    end
    if typeof(speed) ~= "number" or speed < 30 or speed > 5000 then
        speed = 110
    end
    local point = head
    for _ = 1, 3 do
        local time = math.clamp((point - origin).Magnitude / speed, 0, 2.5)
        point = head + vel * time
    end
    return point
end

local function callPacked(callOld, self, method, args, argc)
    if type(setnamecallmethod) == "function" then
        setnamecallmethod(method)
    end
    if argc == 2 then
        return callOld(self, args[1], args[2])
    elseif argc == 3 then
        return callOld(self, args[1], args[2], args[3])
    elseif argc == 4 then
        return callOld(self, args[1], args[2], args[3], args[4])
    elseif argc == 8 then
        return callOld(self, args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])
    elseif argc == 9 then
        return callOld(self, args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9])
    elseif argc == 10 then
        return callOld(self, args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10])
    end
    return callOld(self, table.unpack(args, 1, argc))
end

-- CheckShot is the hit report. The bullet graphic still follows the crosshair.
-- The hook must not call any methods, or the gun script dies until respawn.
local function onNamecall(self, ...)
    local method = getnamecallmethod()
    local callOld = original[1]
    if not callOld then
        return
    end
    if not state.running or method ~= "FireServer" or typeof(self) ~= "Instance" then
        return callOld(self, ...)
    end
    recordRemote("original", self, ...)
    if not state.enabled then return callOld(self, ...) end
    local name = self.Name
    if name == "ProjectileRender" then
        local speed = select(5, ...)
        if typeof(speed) == "number" and speed >= 30 and speed <= 5000 then
            state.speed = speed
        end
        return callOld(self, ...)
    end
    if name ~= "CheckShot" or not state.part or not state.head or typeof(state.eye) ~= "Vector3" then
        return callOld(self, ...)
    end
    local argc = select("#", ...)
    local cf = select(5, ...)
    if argc < 7 or typeof(cf) ~= "CFrame" then
        return callOld(self, ...)
    end
    local origin = state.eye
    local aimPos = leadAt(origin, state.head, state.vel, state.speed)
    if typeof(aimPos) ~= "Vector3" or (aimPos - origin).Magnitude < 0.05 then
        return callOld(self, ...)
    end
    local args = { ... }
    args[5] = CFrame.new(origin, aimPos)
    args[6] = aimPos
    args[7] = state.part
    recordRemote("sent", self, table.unpack(args, 1, argc))
    return callPacked(callOld, self, method, args, argc)
end

local renderWarned = false
track(RunService.RenderStepped:Connect(function()
    if not state.running then
        return
    end
    -- An incomplete update must never leave the previous target usable.
    clearTarget()
    local ok, err = pcall(function()
        local cam = camera()
        if not circle or not cam then
            return
        end
        if not state.enabled then
            circle.Visible = false
            state.aim = nil
            return
        end
        local radius = fovRadius(cam)
        local vp = cam.ViewportSize
        circle.Position = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
        circle.Radius = radius
        circle.Visible = true
        state.look = cam.CFrame.LookVector
        local myChar = LocalPlayer.Character
        local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
        local myHead = myChar and myChar:FindFirstChild("Head")
        state.eye = (myHead and myHead.Position) or cam.CFrame.Position
        state.root = myRoot and myRoot.Position or nil
        local part = bestTarget(cam, radius)
        if part then
            state.part = part
            state.head = part.Position
            local model = part.Parent
            local hrp = model and model:FindFirstChild("HumanoidRootPart")
            state.vel = (hrp and hrp.AssemblyLinearVelocity) or Vector3.zero
            local from = state.root or cam.CFrame.Position
            state.aim = leadAt(from, state.head, state.vel, state.speed)
            circle.Color = Color3.fromRGB(80, 255, 120)
        else
            state.aim = nil
            state.part = nil
            state.head = nil
            state.vel = Vector3.zero
            circle.Color = WHITE
        end
    end)
    if not ok then
        clearTarget()
        if not renderWarned then
            renderWarned = true
            warn("[Silent] render error: " .. tostring(err))
        end
    end
end))

local function installHook()
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return false, "executor has no hookmetamethod"
    end
    -- Reuse one forwarding hook across reloads. Unload only detaches our handler;
    -- restoring the global metamethod could remove another script's hook.
    local bridge = genv.__SilentNamecallBridge
    if type(bridge) == "table" and bridge.version == 1 and type(bridge.previous) == "function" then
        original[1] = bridge.previous
        bridge.handler = onNamecall
        namecallBridge = bridge
        return true
    end
    bridge = { version = 1 }
    local function dispatch(self, ...)
        if bridge.handler then return bridge.handler(self, ...) end
        return bridge.previous(self, ...)
    end
    local fn = dispatch
    if type(newcclosure) == "function" then
        local okWrap, wrapped = pcall(newcclosure, dispatch)
        if okWrap and type(wrapped) == "function" then
            fn = wrapped
        end
    end
    local ok, oldOrErr = pcall(hookmetamethod, game, "__namecall", fn)
    if not ok or type(oldOrErr) ~= "function" then
        return false, tostring(oldOrErr)
    end
    original[1] = oldOrErr
    bridge.previous = oldOrErr
    bridge.handler = onNamecall
    namecallBridge = bridge
    genv.__SilentNamecallBridge = bridge
    return true
end

local hooked, why = installHook()
if not hooked then
    MainBtn.Text = "NO"
    warn("[Silent] " .. tostring(why))
else
    print("[Silent v" .. VERSION .. "] ready. Circle is the FOV. Shots count only while a player is inside it.")
end

local function unload()
    if not state.running then
        return
    end
    state.running = false
    state.enabled = false
    capture.enabled = false
    resetCaptureEvents()
    table.clear(capture.pings)
    clearTarget()
    table.clear(pointerStarts)
    dragInput = nil
    for _, conn in ipairs(conns) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    table.clear(conns)
    if namecallBridge and namecallBridge.handler == onNamecall then
        namecallBridge.handler = nil
    end
    if circle then
        pcall(function()
            circle.Visible = false
        end)
        pcall(function()
            circle:Remove()
        end)
        pcall(function()
            circle:Destroy()
        end)
        circle = nil
    end
    pcall(function()
        sg:Destroy()
    end)
end

genv.__SilentUnload = unload
_G.__SilentUnload = unload
