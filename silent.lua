-- language: Lua, file: silent.lua, target: Roblox (mobile executor)
-- Silent aim for every gun that fires GunFramework's ProjectileRender.
-- A shot is redirected only when a player's head is inside the FOV circle.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

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
    rays = { n = 0, ok = 0, short = 0, far = 0, off = 0, bad = 0 },
    others = {},
    queue = {},
}
local LOG_URL = "https://ntfy.sh/yh-s4e8c2a91f7b"
local original = {}
local conns = {}

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
local MENU_W = 220
local MENU_H = 96

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

local LogLabel = Instance.new("TextLabel")
LogLabel.Size = UDim2.new(1, -8, 0, 36)
LogLabel.Position = UDim2.fromOffset(4, 54)
LogLabel.BackgroundTransparency = 1
LogLabel.Font = FONT
LogLabel.TextSize = 10
LogLabel.TextXAlignment = Enum.TextXAlignment.Left
LogLabel.TextYAlignment = Enum.TextYAlignment.Top
LogLabel.TextWrapped = true
LogLabel.TextColor3 = WHITE
LogLabel.TextStrokeTransparency = 1
LogLabel.Text = "log: waiting"
LogLabel.ZIndex = 15
LogLabel.Parent = MenuFrame

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

local function refreshUi()
    local on = state.enabled
    ToggleRow.Text = on and "  SILENT  ON" or "  SILENT  OFF"
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
local function bindPress(guiObj, fn)
    local last = 0
    local function go()
        local now = os.clock()
        if now - last < 0.2 then return end
        last = now
        fn()
    end
    pressAt[guiObj] = go
    track(guiObj.Activated:Connect(go))
    pcall(function()
        track(guiObj.TouchTap:Connect(function()
            go()
        end))
    end)
end

bindPress(ToggleRow, function()
    state.enabled = not state.enabled
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
local lastToggle = 0
local lastTouchAt = 0

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
    if input ~= dragInput or not dragStart or not startPos then return end
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

local fingerStart = nil
track(UserInputService.InputBegan:Connect(function(input)
    local kind = input.UserInputType
    if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
        fingerStart = Vector2.new(input.Position.X, input.Position.Y)
    end
end))

local function pointIn(gui, x, y)
    if not gui or not gui.Visible then return false end
    local pos = gui.AbsolutePosition
    local size = gui.AbsoluteSize
    return x >= pos.X and y >= pos.Y and x <= pos.X + size.X and y <= pos.Y + size.Y
end

track(UserInputService.InputEnded:Connect(function(input)
    local kind = input.UserInputType
    local isPointer = kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1
    if input == dragInput then
        dragInput = nil
        if not dragMoved then
            local now = os.clock()
            if now - lastToggle >= 0.28 then
                lastToggle = now
                toggleMenu()
            end
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
    local best, bestArea = nil, math.huge
    for guiObj, go in pairs(pressAt) do
        if pointIn(guiObj, here.X, here.Y) then
            local size = guiObj.AbsoluteSize
            local area = size.X * size.Y
            if area < bestArea then
                best = go
                bestArea = area
            end
        end
    end
    if best then
        best()
    end
end))

-- FOV ----------------------------------------------------------------------

local circle = nil
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

-- 110 is the speed value the AK sent with every shot. The bullet aims where
-- the head will be after flying that long, then again with the real muzzle.
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

-- Arg 3 is the muzzle. Arg 4 is the world point the bullet flies toward,
-- about 800 studs out on the AK. Keep that length, but point it at the head.
local function retarget(origin, current, aimPoint)
    local delta = aimPoint - origin
    if delta.Magnitude < 0.05 then
        return current
    end
    local reach = (current - origin).Magnitude
    if reach < 5 then
        reach = current.Magnitude
    end
    if delta.Magnitude > reach then
        reach = delta.Magnitude
    end
    return origin + delta.Unit * reach
end

local function pushLog(line)
    local q = state.queue
    q[#q + 1] = line
end

local function fmtV(v)
    if typeof(v) ~= "Vector3" then
        return "?"
    end
    return string.format("%.0f %.0f %.0f", v.X, v.Y, v.Z)
end

-- Gun rays are long and leave the character. Camera collision rays are short.
local function rayKind(origin, dir)
    if typeof(origin) ~= "Vector3" or typeof(dir) ~= "Vector3" then
        return "bad"
    end
    if typeof(state.look) ~= "Vector3" or typeof(state.root) ~= "Vector3" or typeof(state.aim) ~= "Vector3" then
        return "bad"
    end
    if dir.Magnitude < 80 then
        return "short"
    end
    if (origin - state.root).Magnitude > 25 then
        return "far"
    end
    if dir.Unit:Dot(state.look) < 0.65 then
        return "off"
    end
    if (state.aim - origin).Magnitude < 0.05 then
        return "bad"
    end
    return "ok"
end

local function redirectDirection(origin, dir)
    if rayKind(origin, dir) ~= "ok" then
        return nil
    end
    return (state.aim - origin).Unit * dir.Magnitude
end

local function countRay(origin, dir)
    local kind = rayKind(origin, dir)
    local rays = state.rays
    rays.n += 1
    rays[kind] = (rays[kind] or 0) + 1
    return kind
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

-- The aim point is chosen on the frame thread. The shot hook must not call any
-- methods, or the gun script errors on the first shot and stays dead until respawn.
local function onNamecall(self, ...)
    local method = getnamecallmethod()
    local callOld = original[1]
    if not callOld then
        return
    end
    if not state.running or not state.enabled or not state.aim then
        return callOld(self, ...)
    end

    if method == "FireServer" and typeof(self) == "Instance" and self.Name ~= "ProjectileRender" then
        local list = state.others
        list[#list + 1] = self.Name
        if #list > 5 then
            table.remove(list, 1)
        end
    end

    if method == "Raycast" then
        countRay(select(1, ...), select(2, ...))
        local newDir = redirectDirection(select(1, ...), select(2, ...))
        if not newDir then
            return callOld(self, ...)
        end
        local argc = select("#", ...)
        local args = { ... }
        args[2] = newDir
        return callPacked(callOld, self, method, args, argc)
    end

    if method == "FindPartOnRay" or method == "FindPartOnRayWithIgnoreList" or method == "FindPartOnRayWithWhitelist" then
        local ray = select(1, ...)
        if typeof(ray) ~= "Ray" then
            return callOld(self, ...)
        end
        countRay(ray.Origin, ray.Direction)
        local newDir = redirectDirection(ray.Origin, ray.Direction)
        if not newDir then
            return callOld(self, ...)
        end
        local argc = select("#", ...)
        local args = { ... }
        args[1] = Ray.new(ray.Origin, newDir)
        return callPacked(callOld, self, method, args, argc)
    end

    if method ~= "FireServer" then
        return callOld(self, ...)
    end
    if typeof(self) ~= "Instance" or self.Name ~= "ProjectileRender" then
        return callOld(self, ...)
    end
    local className = self.ClassName
    if className ~= "RemoteEvent" and className ~= "UnreliableRemoteEvent" then
        return callOld(self, ...)
    end
    local argc = select("#", ...)
    local origin = select(3, ...)
    local current = select(4, ...)
    if argc < 4 or typeof(origin) ~= "Vector3" or typeof(current) ~= "Vector3" then
        return callOld(self, ...)
    end
    local speed = select(5, ...)
    if typeof(speed) == "number" and speed >= 30 and speed <= 5000 then
        state.speed = speed
    end
    local aim = leadAt(origin, state.head or state.aim, state.vel, state.speed)
    local args = { ... }
    args[4] = retarget(origin, current, aim)
    local oldDot, newDot = 0, 0
    local look = state.look
    if typeof(look) == "Vector3" then
        local oldDelta = current - origin
        local newDelta = args[4] - origin
        if oldDelta.Magnitude > 0.05 then
            oldDot = oldDelta.Unit:Dot(look)
        end
        if newDelta.Magnitude > 0.05 then
            newDot = newDelta.Unit:Dot(look)
        end
    end
    local rays = state.rays
    pushLog(string.format(
        "fire moved=%.0f oldDot=%.2f newDot=%.2f spd=%s rays=%d ok=%d short=%d far=%d off=%d others=%s",
        (args[4] - current).Magnitude,
        oldDot,
        newDot,
        tostring(state.speed),
        rays.n,
        rays.ok,
        rays.short,
        rays.far,
        rays.off,
        table.concat(state.others, ",")
    ))
    state.rays = { n = 0, ok = 0, short = 0, far = 0, off = 0, bad = 0 }
    state.others = {}
    return callPacked(callOld, self, method, args, argc)
end

local function postLog(line)
    local function try(fn)
        if type(fn) ~= "function" then
            return false
        end
        local ok = pcall(fn, {
            Url = LOG_URL,
            Method = "POST",
            Body = line,
            Headers = { ["Content-Type"] = "text/plain", ["Title"] = "silent" },
        })
        return ok
    end
    if try(request) or try(http_request) then
        return true
    end
    if type(syn) == "table" and try(syn.request) then
        return true
    end
    if type(http) == "table" and try(http.request) then
        return true
    end
    if type(fluxus) == "table" and try(fluxus.request) then
        return true
    end
    return false
end

local function flushLogs()
    local q = state.queue
    if not q or #q == 0 then
        return
    end
    state.queue = {}
    for i = 1, #q do
        local line = q[i]
        print("[Silent] " .. line)
        local sent = postLog(line)
        if LogLabel then
            LogLabel.Text = (sent and "sent " or "local ") .. line
        end
    end
end

local renderWarned = false
track(RunService.RenderStepped:Connect(function()
    if not state.running then
        return
    end
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
        state.root = myRoot and myRoot.Position or nil
        local part = bestTarget(cam, radius)
        if part then
            state.head = part.Position
            local model = part.Parent
            local hrp = model and model:FindFirstChild("HumanoidRootPart")
            state.vel = (hrp and hrp.AssemblyLinearVelocity) or Vector3.zero
            local from = state.root or cam.CFrame.Position
            state.aim = leadAt(from, state.head, state.vel, state.speed)
            circle.Color = Color3.fromRGB(80, 255, 120)
        else
            state.aim = nil
            state.vel = Vector3.zero
            circle.Color = WHITE
        end
        flushLogs()
    end)
    if not ok and not renderWarned then
        renderWarned = true
        warn("[Silent] render error: " .. tostring(err))
    end
end))

local function installHook()
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return false, "executor has no hookmetamethod"
    end
    local fn = onNamecall
    if type(newcclosure) == "function" then
        local okWrap, wrapped = pcall(newcclosure, onNamecall)
        if okWrap and type(wrapped) == "function" then
            fn = wrapped
        end
    end
    local ok, oldOrErr = pcall(hookmetamethod, game, "__namecall", fn)
    if not ok or type(oldOrErr) ~= "function" then
        return false, tostring(oldOrErr)
    end
    original[1] = oldOrErr
    return true
end

local hooked, why = installHook()
if not hooked then
    MainBtn.Text = "NO"
    warn("[Silent] " .. tostring(why))
else
    print("[Silent] ready. Circle is the FOV. Shots bend only while a player is inside it.")
    pushLog("ready setnc=" .. ((type(setnamecallmethod) == "function") and "yes" or "no"))
end

local function unload()
    if not state.running then
        return
    end
    state.running = false
    state.enabled = false
    for _, conn in ipairs(conns) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    table.clear(conns)
    local old = original[1]
    if old then
        local restored = false
        if type(restorefunction) == "function" then
            restored = pcall(restorefunction, old)
        end
        if not restored and type(restoreclosure) == "function" then
            restored = pcall(restoreclosure, old)
        end
        if not restored and type(hookmetamethod) == "function" then
            pcall(hookmetamethod, game, "__namecall", old)
        end
        original[1] = nil
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
