-- language: Lua, file: silent.lua, target: Roblox (mobile executor)
-- Silent aim. The menu picks the game.
-- GUNGROUNDS FFA rewrites CheckShot. URBAN RELOAD only sniffs, until that gun is known.
-- A Gungrounds shot is redirected only when a player's head is inside the FOV circle.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local VERSION = "2.1"

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
local GAME_LABEL = {
    gungrounds = "GUNGROUNDS FFA",
    urban = "URBAN RELOAD",
}

local function detectGame()
    local name = ""
    pcall(function()
        name = string.lower(tostring(game.Name))
    end)
    if string.find(name, "gunground", 1, true) then
        return "gungrounds"
    end
    if string.find(name, "urban", 1, true) then
        return "urban"
    end
    return "urban"
end

local state = {
    running = true,
    enabled = true,
    game = detectGame(),
    urbanAim = false,
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
local ensureGameHook = nil
local installSniffHook = nil
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
local MENU_W = 168
local MENU_H = 162

local function clearTarget()
    state.aim = nil
    state.part = nil
    state.head = nil
    state.eye = nil
    state.root = nil
    state.covered = false
    state.vel = Vector3.zero
    if circle then
        pcall(function()
            circle.Visible = false
            circle.Color = WHITE
        end)
    end
end

-- LOCAL SHOT CAPTURE ---------------------------------------------------------
-- Any FireServer / InvokeServer. Property reads only, never : methods, so the
-- pending namecall is not replaced. Pings are also posted so they can be read
-- without a copy.
local LOG_URL = "https://ntfy.sh/yh-urban-4e8c2a91f7"
local capture = { enabled = false, groups = {}, order = {}, count = 0, dropped = 0,
    pings = {}, number = 0, error = nil, lastSent = false }
local CAPTURE_MAX, CAPTURE_WINDOW = 64, 15
local pathCache = setmetatable({}, { __mode = "k" })

local function instancePath(value)
    if not value then
        return ""
    end
    local cached = pathCache[value]
    if cached then
        return cached
    end
    local key = value
    local names = {}
    for _ = 1, 16 do
        if not value then break end
        table.insert(names, 1, value.Name)
        value = value.Parent
    end
    local path = table.concat(names, ".")
    pathCache[key] = path
    return path
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
    capture.groups = {}
    capture.order = {}
    capture.count, capture.dropped, capture.error = 0, 0, nil
end

local function captureRemote(stage, remote, ...)
    local path = instancePath(remote)
    local key = stage .. "\0" .. path
    local argc, lines = select("#", ...), {}
    for i = 1, math.min(argc, 24) do
        lines[#lines + 1] = "  [" .. i .. "] " .. preview(select(i, ...), 0)
    end
    if argc > 24 then lines[#lines + 1] = "  ... arguments truncated" end
    local sample = "argc=" .. argc .. "\n" .. table.concat(lines, "\n")
    local now = os.clock()
    local group = capture.groups[key]
    if group then
        group.count = group.count + 1
        group.t = now
        if #group.samples < 2 then
            group.samples[#group.samples + 1] = sample
        end
        return
    end
    if #capture.order >= CAPTURE_MAX then
        local old = table.remove(capture.order, 1)
        capture.groups[old] = nil
        capture.dropped = capture.dropped + 1
    end
    capture.groups[key] = {
        t = now, count = 1, samples = { sample }, stage = stage, path = path,
    }
    capture.order[#capture.order + 1] = key
    capture.count = #capture.order
end

local function recordRemote(stage, remote, ...)
    if not capture.enabled then return end
    local ok, err = pcall(captureRemote, stage, remote, ...)
    if not ok then capture.error = tostring(err) end
end

local function postLog(line)
    if type(line) ~= "string" or line == "" then
        return false
    end
    if #line > 3500 then
        line = line:sub(1, 3500) .. "\n...truncated"
    end
    local function try(fn)
        if type(fn) ~= "function" then
            return false
        end
        return pcall(fn, {
            Url = LOG_URL,
            Method = "POST",
            Body = line,
            Headers = { ["Content-Type"] = "text/plain", ["Title"] = "silent" },
        })
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

-- ntfy rejects bodies over 4096 bytes, so long text goes out in pieces.
local function postText(text)
    local pieces, current = {}, ""
    for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
        if #current + #line + 1 > 3300 and current ~= "" then
            pieces[#pieces + 1] = current
            current = ""
        end
        current = current .. line:sub(1, 3200) .. "\n"
    end
    if current ~= "" then
        pieces[#pieces + 1] = current
    end
    local first = false
    for i, piece in ipairs(pieces) do
        local ok = postLog(piece)
        if i == 1 then
            first = ok
        end
        if i < #pieces and task then
            pcall(task.wait, 0.4)
        end
    end
    return first
end

local function pingCapture()
    capture.number = capture.number + 1
    local now = os.clock()
    local labels = type(GAME_LABEL) == "table" and GAME_LABEL or nil
    local mode = (labels and labels[state.game]) or tostring(state.game or "gungrounds")
    local lines = { "===== PING " .. capture.number .. "  " .. mode .. " =====" }
    if state.game == "urban" then
        lines[#lines + 1] = "aim=" .. tostring(state.urbanAim) .. " target=" .. tostring(state.part ~= nil)
            .. " covered=" .. tostring(state.covered) .. " by=" .. tostring(state.coverBy)
    end
    local ranked = {}
    for i = 1, #capture.order do
        local group = capture.groups[capture.order[i]]
        if group and now - group.t <= CAPTURE_WINDOW then
            ranked[#ranked + 1] = group
        end
    end
    table.sort(ranked, function(a, b)
        if a.count ~= b.count then
            return a.count < b.count
        end
        return a.t > b.t
    end)
    if #ranked == 0 then
        lines[#lines + 1] = "No new remotes in the last " .. CAPTURE_WINDOW .. " seconds."
    end
    for _, group in ipairs(ranked) do
        lines[#lines + 1] = string.format("%s %s  x%d  %.3fs", group.stage, group.path, group.count, now - group.t)
        for _, sample in ipairs(group.samples) do
            lines[#lines + 1] = "  " .. sample
        end
    end
    if capture.dropped > 0 then lines[#lines + 1] = "Buffer overflow: " .. capture.dropped .. " earlier remotes dropped." end
    if capture.error then lines[#lines + 1] = "Capture error: " .. capture.error end
    capture.pings[#capture.pings + 1] = table.concat(lines, "\n")
    if #capture.pings > 4 then table.remove(capture.pings, 1) end
    resetCaptureEvents()
    local text = "SILENT v" .. VERSION .. " | " .. mode .. " | original=game, sent=rewritten\n"
        .. "Rarest remote is listed first. Each PING consumes fresh reports.\n\n"
        .. table.concat(capture.pings, "\n\n")
    capture.lastSent = postText(capture.pings[#capture.pings])
    return text
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

local GameRow = makeRow(4, "  URBAN RELOAD")
local ToggleRow = makeRow(30, "  SILENT  ON")
local FovRow = Instance.new("Frame")
FovRow.Size = UDim2.new(1, -8, 0, 22)
FovRow.Position = UDim2.fromOffset(4, 56)
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
local CaptureBtn = makeRow(82, "  CAPTURE  OFF")
local ScanBtn = makeRow(134, "  SCAN")
local PingBtn = makeRow(108, "  PING")
PingBtn.Size = UDim2.new(0.6, -4, 0, 22)
local LogBtn = makeRow(108, "  LOG")
LogBtn.Position = UDim2.new(0.6, 0, 0, 108)
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
LogText.Text = "CAPTURE, shoot or switch guns, then PING within 15 seconds. The log is sent automatically."
LogText.ZIndex = 32
pcall(function() LogText.TextEditable = false end)

local function refreshUi()
    local on = state.enabled
    if state.game == "gungrounds" then
        ToggleRow.Text = "  SILENT v" .. VERSION .. (on and "  ON" or "  OFF")
    else
        on = state.urbanAim
        ToggleRow.Text = "  AIM v" .. VERSION .. (on and "  ON" or "  OFF")
    end
    ToggleRow.BackgroundColor3 = on and WHITE or BLACK
    ToggleRow.TextColor3 = on and BLACK or WHITE
    MainBtn.Text = on and "S" or "s"
    MainStroke.Transparency = on and 0 or 0.6
    FovLabel.Text = string.format("FOV  %.0f", state.fov)
    GameRow.Text = "  " .. (GAME_LABEL[state.game] or "URBAN RELOAD")
    CaptureBtn.Text = capture.enabled and "  CAPTURE  ON" or "  CAPTURE  OFF"
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

bindPress(GameRow, function()
    state.game = state.game == "gungrounds" and "urban" or "gungrounds"
    clearTarget()
    if state.game == "gungrounds" and ensureGameHook then
        local ok, why = ensureGameHook()
        if not ok then
            MainBtn.Text = "NO"
            LogText.Text = "Gungrounds needs a namecall hook: " .. tostring(why)
        end
    end
    refreshUi()
end)

-- Reads the gun's own scripts. No hook is installed, so the game is untouched.
local function scanGame(progress)
    local mode = GAME_LABEL[state.game] or tostring(state.game)
    local out = { "===== DEEP SCAN  " .. mode .. " =====" }
    local function add(text) out[#out + 1] = text end
    local remoteClass = { RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true }
    local scriptClass = { LocalScript = true, ModuleScript = true, Script = true }
    local gunWord = { "gun", "weapon", "shoot", "fire", "projectile", "bullet", "ammo", "reload", "combat", "tool" }

    local candidates, seen = {}, setmetatable({}, { __mode = "k" })
    local defaultScripts = { "PlayerModule", "RbxCharacterSounds", "BubbleChat", "ChatScript",
        "PlayerScriptsLoader", "ControlModule", "CameraModule", "AnimateScript" }
    local sourceRank = { ReplicatedStorage = 1, PlayerScripts = 2, Character = 3, Backpack = 3, loaded = 5 }
    local function candidate(script, source)
        if not script or seen[script] or not scriptClass[script.ClassName] then return end
        seen[script] = true
        local path = instancePath(script)
        for _, name in ipairs(defaultScripts) do
            if path:find(name, 1, true) then return end
        end
        local rank = sourceRank[source] or 4
        local lowerName = script.Name:lower()
        for _, word in ipairs(gunWord) do
            if lowerName:find(word, 1, true) then
                rank = 0
                break
            end
        end
        candidates[#candidates + 1] = { script = script, source = source, rank = rank, path = path }
    end
    local function descendants(container, source)
        if not container then return end
        for _, d in ipairs(container:GetDescendants()) do
            candidate(d, source)
        end
    end

    -- PlayerScripts is where Urban Reload keeps its gun controller. Also scan
    -- character/backpack scripts and every loaded module the executor exposes.
    descendants(LocalPlayer:FindFirstChild("PlayerScripts"), "PlayerScripts")
    descendants(LocalPlayer.Character, "Character")
    descendants(LocalPlayer:FindFirstChildOfClass("Backpack"), "Backpack")
    if type(getloadedmodules) == "function" then
        local ok, loaded = pcall(getloadedmodules)
        if ok and type(loaded) == "table" then
            for _, module in ipairs(loaded) do candidate(module, "loaded") end
        end
    end

    local closure = type(getscriptclosure) == "function" and getscriptclosure
        or (type(getscriptfunction) == "function" and getscriptfunction or nil)
    local getconstantsFn = type(getconstants) == "function" and getconstants
        or (type(debug) == "table" and type(debug.getconstants) == "function" and debug.getconstants or nil)
    local getprotosFn = type(getprotos) == "function" and getprotos
        or (type(debug) == "table" and type(debug.getprotos) == "function" and debug.getprotos or nil)
    local interesting = { "fire", "hit", "shoot", "reload", "ray", "remote", "damage", "bullet",
        "gun", "weapon", "spread", "recoil", "head", "muzzle", "ammo" }

    -- Reads string constants only. Nothing is decompiled.
    -- Returns the relevant strings and whether a remote call name was present.
    local function constants(script)
        if not closure or not getconstantsFn then return nil end
        local okFn, root = pcall(closure, script)
        if not okFn or type(root) ~= "function" then return nil end
        local found, used, hasRemote, protos = {}, {}, false, 0
        local function visit(fn, depth)
            local okC, values = pcall(getconstantsFn, fn)
            if okC and type(values) == "table" then
                for _, value in ipairs(values) do
                    if type(value) == "string" and #value <= 60 then
                        if value == "FireServer" or value == "InvokeServer" then
                            hasRemote = true
                        end
                        local lower = value:lower()
                        for _, word in ipairs(interesting) do
                            if lower:find(word, 1, true) then
                                local clean = value:gsub("%c", " ")
                                if not used[clean] and #found < 40 then
                                    used[clean] = true
                                    found[#found + 1] = clean
                                end
                                break
                            end
                        end
                    end
                end
            end
            if getprotosFn and depth < 3 and protos < 60 then
                local okP, children = pcall(getprotosFn, fn)
                if okP and type(children) == "table" then
                    for _, child in ipairs(children) do
                        protos = protos + 1
                        if protos > 60 then break end
                        if type(child) == "function" then visit(child, depth + 1) end
                    end
                end
            end
        end
        visit(root, 0)
        return found, hasRemote
    end

    local tools = {}
    local function addTools(container)
        if not container then return end
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") then
                tools[#tools + 1] = child
            end
        end
    end
    local char = LocalPlayer.Character
    addTools(char)
    addTools(LocalPlayer:FindFirstChildOfClass("Backpack"))
    add("Tools: " .. #tools .. " (equipped first)")
    for i = 1, math.min(#tools, 4) do
        local tool = tools[i]
        add("TOOL " .. instancePath(tool) .. (tool.Parent == char and "  [equipped]" or ""))
        for _, d in ipairs(tool:GetDescendants()) do
            if remoteClass[d.ClassName] then
                add("  " .. d.ClassName .. " " .. instancePath(d))
            end
        end
    end

    local storage = game:GetService("ReplicatedStorage")
    local remotes, modules = {}, {}
    for _, d in ipairs(storage:GetDescendants()) do
        if remoteClass[d.ClassName] then
            remotes[#remotes + 1] = d.ClassName .. " " .. instancePath(d)
        elseif d.ClassName == "ModuleScript" then
            local lower = d.Name:lower()
            for _, word in ipairs(gunWord) do
                if lower:find(word, 1, true) then
                    modules[#modules + 1] = d
                    candidate(d, "ReplicatedStorage")
                    break
                end
            end
        end
    end
    add("Likely remotes:")
    for _, remote in ipairs(remotes) do
        local lower = remote:lower()
        if lower:find(".fire", 1, true) or lower:find(".hit", 1, true)
            or lower:find(".shoot", 1, true) or lower:find("headshot", 1, true)
            or lower:find("damage", 1, true) then
            add("  " .. remote)
        end
    end
    add("Scripts considered: " .. #candidates .. "; gun-looking modules: " .. #modules)
    add("Executor: closure=" .. tostring(closure ~= nil) .. " constants=" .. tostring(getconstantsFn ~= nil)
        .. " protos=" .. tostring(getprotosFn ~= nil))
    if not closure or not getconstantsFn then
        add("This executor cannot read script constants, so only names are listed.")
        for i = 1, math.min(#candidates, 40) do
            add("  " .. candidates[i].path)
        end
    else
        table.sort(candidates, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.path < b.path
        end)
        local started = os.clock()
        local checked, matched, unreadable, stopped = 0, 0, 0, nil
        for i, entry in ipairs(candidates) do
            if checked >= 330 then stopped = "330 scripts"; break end
            if matched >= 30 then stopped = "30 matches"; break end
            if os.clock() - started > 40 then stopped = "40 seconds"; break end
            checked = checked + 1
            if progress then
                progress(string.format("Scanning %d/%d  %s", i, #candidates, entry.script.Name))
            end
            local strings, hasRemote = constants(entry.script)
            if strings == nil then
                unreadable = unreadable + 1
                if entry.rank == 0 then
                    add("SCRIPT [" .. entry.source .. "] " .. entry.path .. "  (could not read)")
                end
            elseif hasRemote or entry.rank == 0 then
                matched = matched + 1
                add("SCRIPT [" .. entry.source .. "] " .. entry.path .. (hasRemote and "  (calls a remote)" or ""))
                add("  " .. (#strings > 0 and table.concat(strings, " | ") or "(no matching strings)"))
            end
            task.wait(0.03)
        end
        add(string.format("Checked %d of %d scripts; listed %d; unreadable %d.", checked, #candidates, matched, unreadable))
        if stopped then add("Stopped early at " .. stopped .. ".") end
    end
    return table.concat(out, "\n")
end

bindPress(ScanBtn, function()
    LogText.Text = "Scanning..."
    LogPanel.Visible = true
    task.spawn(function()
        local ok, text = pcall(scanGame, function(message)
            LogText.Text = message
        end)
        if not ok then
            text = "Scan failed: " .. tostring(text)
        end
        LogText.Text = text
        ScanBtn.Text = postText(text) and "  SENT" or "  LOCAL"
        task.delay(1.2, function()
            ScanBtn.Text = "  SCAN"
        end)
    end)
end)

bindPress(CaptureBtn, function()
    if capture.enabled then
        capture.enabled = false
        resetCaptureEvents()
        refreshUi()
        return
    end
    if state.game == "urban" and installSniffHook then
        local ok, why = installSniffHook()
        if not ok then
            LogText.Text = "CAPTURE needs hookfunction, and this executor has none: " .. tostring(why)
                .. "\nSCAN still works and installs no hook."
            LogPanel.Visible = true
            CaptureBtn.Text = "  NO HOOK"
            return
        end
    end
    capture.enabled = true
    resetCaptureEvents()
    refreshUi()
end)
bindPress(PingBtn, function()
    if not capture.enabled then
        LogText.Text = "CAPTURE is OFF. Enable it before the next test shot."
    else
        LogText.Text = pingCapture()
        PingBtn.Text = capture.lastSent and "  SENT" or "  LOCAL"
        pcall(function()
            task.delay(1.2, function()
                PingBtn.Text = "  PING"
            end)
        end)
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
    if state.game == "urban" then
        if not state.urbanAim and installSniffHook then
            local ok, why = installSniffHook()
            if not ok then
                LogText.Text = "AIM needs hookfunction, and this executor has none: " .. tostring(why)
                LogPanel.Visible = true
                return
            end
        end
        state.urbanAim = not state.urbanAim
        if not state.urbanAim then clearTarget() end
    else
        state.enabled = not state.enabled
        if not state.enabled then clearTarget() end
    end
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

local coverParams = RaycastParams.new()
coverParams.FilterType = Enum.RaycastFilterType.Exclude
coverParams.IgnoreWater = true

-- True when a ray from our head does not reach their head first.
-- That includes walls and a torso sitting in front of the head.
local function blocksHead(eye, headPart, myChar)
    if typeof(eye) ~= "Vector3" or not headPart then
        return false
    end
    local delta = headPart.Position - eye
    if delta.Magnitude < 0.05 then
        return false
    end
    local filter = { myChar }
    coverParams.FilterDescendantsInstances = filter
    local model = headPart.Parent
    for _ = 1, 6 do
        local hit = workspace:Raycast(eye, delta, coverParams)
        if not hit then
            state.coverBy = nil
            return false
        end
        local inst = hit.Instance
        if inst == headPart or (state.game == "urban" and model and inst:IsDescendantOf(model)) then
            state.coverBy = nil
            return false
        end
        if state.game ~= "urban" or inst.CanCollide or inst.Transparency < 0.9 then
            state.coverBy = inst:GetFullName()
            return true
        end
        filter[#filter + 1] = inst
        coverParams.FilterDescendantsInstances = filter
    end
    state.coverBy = "too many see-through parts"
    return true
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

-- A reported point ahead of the head makes the server count a body shot.
-- Always name the head center. Lead is only for the local bullet graphic.
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

-- Covered shots cannot start at our head: the server ray hits the wall, or
-- their body, first. Start just outside their head so that short ray hits it.
local function reportRay(eye, headPos, covered)
    if typeof(eye) ~= "Vector3" or typeof(headPos) ~= "Vector3" then
        return nil
    end
    local delta = headPos - eye
    local dist = delta.Magnitude
    if dist < 0.05 then
        return nil
    end
    local origin = eye
    if covered then
        origin = headPos - delta * (2 / dist)
    end
    if (headPos - origin).Magnitude < 0.05 then
        return nil
    end
    return origin, headPos
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

-- CheckShot is the Gungrounds hit report. Urban Reload is not rewritten.
-- The hook must restore the namecall method before every forward, and must
-- not call Instance methods, or taps and gun switching die.
local function onNamecall(self, ...)
    local method = getnamecallmethod()
    local callOld = original[1]
    if not callOld then
        return
    end
    local function forward(...)
        if type(setnamecallmethod) == "function" and method ~= nil then
            pcall(setnamecallmethod, method)
        end
        return callOld(self, ...)
    end
    if state.busy or (isOurCall and isOurCall()) or not state.running then
        return forward(...)
    end
    if method ~= "FireServer" and method ~= "InvokeServer" then
        return forward(...)
    end
    if typeof(self) ~= "Instance" then
        return forward(...)
    end
    state.busy = true
    local args, argc, rewrite = nil, 0, false
    pcall(function(...)
        recordRemote(method .. " original", self, ...)
        if not state.enabled or (state.game or "gungrounds") ~= "gungrounds" or method ~= "FireServer" then
            return
        end
        local name = self.Name
        if name == "ProjectileRender" then
            local speed = select(5, ...)
            if typeof(speed) == "number" and speed >= 30 and speed <= 5000 then
                state.speed = speed
            end
            return
        end
        if name ~= "CheckShot" or not state.part or not state.head or typeof(state.eye) ~= "Vector3" then
            return
        end
        argc = select("#", ...)
        local cf = select(5, ...)
        if argc < 7 or typeof(cf) ~= "CFrame" then
            return
        end
        local origin, aimPos = reportRay(state.eye, state.head, state.covered)
        if not origin then
            return
        end
        args = { ... }
        args[5] = CFrame.new(origin, aimPos)
        args[6] = aimPos
        args[7] = state.part
        rewrite = true
        recordRemote(method .. " sent", self, table.unpack(args, 1, argc))
    end, ...)
    state.busy = false
    if rewrite and args then
        if type(setnamecallmethod) == "function" then
            pcall(setnamecallmethod, method)
        end
        return callPacked(callOld, self, method, args, argc)
    end
    return forward(...)
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
        local mode = state.game or "gungrounds"
        local aimOn = (mode == "gungrounds" and state.enabled) or (mode == "urban" and state.urbanAim)
        if not aimOn then
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
            state.covered = blocksHead(state.eye, part, myChar)
            circle.Color = state.covered and Color3.fromRGB(255, 196, 40) or Color3.fromRGB(80, 255, 120)
        else
            state.aim = nil
            state.part = nil
            state.head = nil
            state.vel = Vector3.zero
            state.covered = false
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

ensureGameHook = installHook

-- Remotes.Fire carries the aim twice: a direction from the gun to a point (2, 5)
-- and from the camera to a point (12, 13). Point all four at the head.
local function urbanFireArgs(...)
    local argc = select("#", ...)
    if argc < 13 or not state.part or typeof(state.head) ~= "Vector3" then
        return nil
    end
    local muzzle, camPos = select(1, ...), select(11, ...)
    if typeof(muzzle) ~= "Vector3" or typeof(camPos) ~= "Vector3" then
        return nil
    end
    local head = state.head
    local toHead, fromCamera = head - muzzle, head - camPos
    if toHead.Magnitude < 0.5 or fromCamera.Magnitude < 0.5 then
        return nil
    end
    local args = { ... }
    args[2] = toHead.Unit
    args[5] = head
    args[12] = fromCamera.Unit
    args[13] = head
    return args, argc
end

-- Urban Reload: hook only the two remote methods, never every game call.
-- A hook on all namecalls sits in the path of WaitForChild and other yielding
-- calls, which is the likely reason equipping the gun broke.
installSniffHook = function()
    if state.sniffHooked then
        return true
    end
    if type(hookfunction) ~= "function" then
        return false, "no hookfunction"
    end
    local ok, err = pcall(function()
        local function wrap(target)
            local old
            old = hookfunction(target, function(self, ...)
                if state.running and state.game == "urban" and typeof(self) == "Instance"
                    and not (isOurCall and isOurCall()) then
                    if capture.enabled then
                        pcall(recordRemote, "call", self, ...)
                    end
                    if state.urbanAim and self.Name == "Fire" then
                        local okArgs, args, argc = pcall(urbanFireArgs, ...)
                        if okArgs and args then
                            if capture.enabled then
                                pcall(recordRemote, "call sent", self, table.unpack(args, 1, argc))
                            end
                            return old(self, table.unpack(args, 1, argc))
                        end
                    end
                end
                return old(self, ...)
            end)
            return old
        end
        local event = Instance.new("RemoteEvent")
        local func = Instance.new("RemoteFunction")
        local ok1 = pcall(wrap, event.FireServer)
        local ok2 = pcall(wrap, func.InvokeServer)
        local ok3 = pcall(function()
            local unreliable = Instance.new("UnreliableRemoteEvent")
            wrap(unreliable.FireServer)
            unreliable:Destroy()
        end)
        event:Destroy()
        func:Destroy()
        if not ok1 and not ok2 and not ok3 then
            error("hookfunction rejected every remote method")
        end
    end)
    if not ok then
        return false, tostring(err)
    end
    state.sniffHooked = true
    return true
end

local hooked, why = true, nil
if state.game == "gungrounds" then
    hooked, why = installHook()
end
if not hooked then
    MainBtn.Text = "NO"
    warn("[Silent] " .. tostring(why))
else
    print("[Silent v" .. VERSION .. "] " .. (GAME_LABEL[state.game] or state.game)
        .. ". Nothing is hooked until you use CAPTURE (Urban) or pick Gungrounds. SCAN never hooks.")
    pcall(function()
        task.defer(function()
            postLog("ready v" .. VERSION .. " game=" .. tostring(state.game) .. " capture=" .. tostring(capture.enabled))
        end)
    end)
end

local function unload()
    if not state.running then
        return
    end
    state.running = false
    state.enabled = false
    state.urbanAim = false
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
