-- language: Lua, file: remote_pinger.lua, target: Roblox (mobile executor)
-- Shoot, tap PING, repeat 3 or 4 times.
-- The remote that shows up every time with a UNIT-DIR / NAMED-DIR arg is the gun.
-- "tied to" is the LocalScript or ModuleScript and line that fired it.
-- Latest pick is left in _G.RemotePingerLast for the next script.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")
local LocalPlayer = Players.LocalPlayer
local VERSION = "1.1"

local genv = _G
pcall(function()
    if type(getgenv) == "function" then
        genv = getgenv()
    end
end)
if type(genv.__RemotePingerUnload) == "function" then
    pcall(genv.__RemotePingerUnload)
end

local WINDOW = 4
local MAX_PINGS = 20
local BUF_MAX = 1000
local SHOW_ROWS = 8

local MY_SOURCE = ""
pcall(function()
    MY_SOURCE = debug.info(1, "s") or ""
end)

local lifetime = {}
local callerCache = {}
local pingLog = {}
local pingCount = 0
local lastReport = ""
local hookError = nil
local running = true
local busy = false
-- Table so a newcclosure hook still sees the original after install.
local original = {}
local namecallBridge = nil
local connections = {}

local function track(conn)
    connections[#connections + 1] = conn
    return conn
end

local buf = {}
local bufPos = 0
local bufCount = 0
local bufSequence = 0
local lastSnapshotSequence = 0

local pathCache = setmetatable({}, {__mode = "k"})

local isOurCall = nil
pcall(function()
    if type(checkcaller) == "function" then
        isOurCall = checkcaller
    end
end)

local SUBSTRING_WORDS = {
    "shoot", "shot", "gun", "weapon", "bullet", "projectile",
    "muzzle", "recoil", "ammo", "hitscan", "firearm",
}
local TOKEN_WORDS = { "fire", "aim" }
local DIR_KEYS = {
    direction = true, dir = true, lookvector = true, look = true,
    velocity = true, aimdir = true, aim = true, unit = true, raydir = true,
}
local POS_KEYS = {
    origin = true, position = true, pos = true, hitposition = true,
    hitpos = true, endpos = true, startpos = true, muzzle = true,
    targetpos = true, targetposition = true, mousehit = true, hit = true,
}
local ACTION_KEYS = {
    action = true, event = true, name = true, kind = true,
    type = true, key = true, remote = true, call = true,
}
local MOUSE_KEYS = {
    mouse = true, mousepos = true, screen = true, screenpos = true, cursor = true,
}

local function hasToken(s, word)
    local start = 1
    while true do
        local i = string.find(s, word, start, true)
        if not i then return false end
        local before = i == 1 and "" or string.sub(s, i - 1, i - 1)
        local after = string.sub(s, i + #word, i + #word)
        local leftOk = before == "" or string.match(before, "[%a%d_]") == nil
        local rightOk = after == "" or string.match(after, "[%a%d_]") == nil
        if leftOk and rightOk then return true end
        start = i + 1
    end
end

local function keywordScore(text)
    local s = string.lower(text or "")
    for _, word in ipairs(SUBSTRING_WORDS) do
        if string.find(s, word, 1, true) then
            return 26
        end
    end
    for _, word in ipairs(TOKEN_WORDS) do
        if hasToken(s, word) then
            return 26
        end
    end
    return 0
end

local function lastSegment(path)
    return string.match(path or "", "([^.]+)$") or path or "?"
end

local function push(entry)
    bufSequence += 1
    entry.sequence = bufSequence
    bufPos = (bufPos % BUF_MAX) + 1
    buf[bufPos] = entry
    if bufCount < BUF_MAX then
        bufCount += 1
    end
end

local function entriesInWindow(now, window, throughSequence)
    local list = {}
    if bufCount == 0 then return list end
    local start = bufPos - bufCount + 1
    for i = 1, bufCount do
        local idx = ((start + i - 2) % BUF_MAX) + 1
        local e = buf[idx]
        if e and e.sequence > lastSnapshotSequence and e.sequence <= throughSequence
            and (now - e.t) <= window then
            list[#list + 1] = e
        end
    end
    return list
end

local function bufferPreview(bufValue)
    local ok, text = pcall(function()
        local len = buffer.len(bufValue)
        local n = math.min(len, 16)
        local parts = {}
        for i = 0, n - 1 do
            parts[#parts + 1] = string.format("%02X", buffer.readu8(bufValue, i))
        end
        local hex = table.concat(parts, " ")
        if len > n then
            hex = hex .. " ..."
        end
        return string.format("buffer[%d] %s", len, hex)
    end)
    if ok then return text end
    return "buffer"
end

local function copyValue(v, depth, seen)
    local t = typeof(v)
    if t ~= "table" then
        if t == "buffer" then
            return {__kind = "buffer", text = bufferPreview(v)}
        end
        return v
    end
    if depth >= 3 or seen[v] then
        return {__kind = "deep"}
    end
    seen[v] = true
    local out = {__kind = "table"}
    local n = 0
    for k, val in pairs(v) do
        n += 1
        if n > 18 then
            out.__more = true
            break
        end
        if type(k) == "string" or type(k) == "number" then
            out[k] = copyValue(val, depth + 1, seen)
        end
    end
    return out
end

local function capture(...)
    local total = select("#", ...)
    local n = math.min(total, 12)
    local out = {n = n}
    local seen = {}
    for i = 1, n do
        out[i] = copyValue(select(i, ...), 0, seen)
    end
    if total > n then
        out.truncated = total
    end
    return out
end

local function fieldKey(label)
    local key = string.match(label, "%.([%a_][%w_]*)$")
    if key then return string.lower(key) end
    return nil
end

local function walk(v, label, info)
    if #info.lines >= 28 then return end
    local t = typeof(v)
    if t == "nil" then
        info.lines[#info.lines + 1] = label .. " nil"
        return
    end
    if t == "table" then
        local kind = v.__kind
        if kind == "buffer" then
            info.buffer = info.buffer or v.text
            info.lines[#info.lines + 1] = label .. " " .. v.text
            return
        end
        if kind == "deep" then
            info.lines[#info.lines + 1] = label .. " ..."
            return
        end
        if kind == "table" then
            local nums, strs = {}, {}
            for k in pairs(v) do
                if k ~= "__kind" and k ~= "__more" then
                    if type(k) == "number" then
                        nums[#nums + 1] = k
                    else
                        strs[#strs + 1] = k
                    end
                end
            end
            table.sort(nums)
            table.sort(strs)
            if #nums == 0 and #strs == 0 then
                info.lines[#info.lines + 1] = label .. " {}"
                return
            end
            local function childLabel(k)
                if type(k) == "string" then
                    return label .. "." .. k
                end
                return label .. "[" .. tostring(k) .. "]"
            end
            for _, k in ipairs(nums) do
                walk(v[k], childLabel(k), info)
            end
            for _, k in ipairs(strs) do
                walk(v[k], childLabel(k), info)
            end
            if v.__more and #info.lines < 28 then
                info.lines[#info.lines + 1] = label .. " ..."
            end
            return
        end
    end

    local key = fieldKey(label)
    if t == "Vector3" then
        local mag = v.Magnitude
        local tag, add = "vec", 0
        local unit = mag > 0.85 and mag < 1.15
        if key and DIR_KEYS[key] then
            tag, add = unit and "NAMED-DIR unit" or "NAMED-DIR", unit and 55 or 40
            info.aim = info.aim or (label .. " " .. tag)
        elseif unit then
            tag, add = "UNIT-DIR", 50
            info.aim = info.aim or (label .. " UNIT-DIR")
        elseif key and POS_KEYS[key] then
            tag, add = "NAMED-POS", 14
            info.pos = info.pos or label
        elseif mag >= 8 then
            tag, add = "world-pos", 8
            info.pos = info.pos or label
        end
        info.score += add
        info.lines[#info.lines + 1] = string.format(
            "%s V3(%.2f, %.2f, %.2f) %s", label, v.X, v.Y, v.Z, tag)
        return
    elseif t == "CFrame" then
        local p = v.Position
        local look = v.LookVector
        info.score += 30
        if key and DIR_KEYS[key] then
            info.score += 15
        end
        info.aim = info.aim or (label .. " LookVector")
        info.lines[#info.lines + 1] = string.format(
            "%s CF pos(%.1f, %.1f, %.1f) look(%.2f, %.2f, %.2f)",
            label, p.X, p.Y, p.Z, look.X, look.Y, look.Z)
        return
    elseif t == "Ray" then
        local o, d = v.Origin, v.Direction
        info.score += 48
        info.aim = info.aim or (label .. " Ray.Direction")
        info.lines[#info.lines + 1] = string.format(
            "%s Ray origin(%.1f, %.1f, %.1f) dir(%.2f, %.2f, %.2f)",
            label, o.X, o.Y, o.Z, d.X, d.Y, d.Z)
        return
    elseif t == "Vector2" then
        local tag = ""
        if key and MOUSE_KEYS[key] then
            tag = " screen"
            info.score += 16
            info.aim = info.aim or (label .. " screen")
        end
        info.lines[#info.lines + 1] = string.format("%s V2(%.1f, %.1f)%s", label, v.X, v.Y, tag)
        return
    elseif t == "Instance" then
        local path, className, isPart = "?", "?", false
        pcall(function() path = v:GetFullName() end)
        pcall(function() className = v.ClassName end)
        pcall(function() isPart = v:IsA("BasePart") end)
        if isPart then
            info.score += 12
            info.target = info.target or path
        end
        info.lines[#info.lines + 1] = string.format("%s Inst:%s (%s)%s", label, path, className, isPart and " part" or "")
        return
    elseif t == "string" then
        local shown = v
        if #shown > 36 then
            shown = string.sub(shown, 1, 36) .. "..."
        end
        local ks = keywordScore(v)
        if ks > 0 then
            info.score += ks
            info.action = info.action or shown
        elseif key and ACTION_KEYS[key] then
            info.action = info.action or shown
            info.score += 8
        elseif label == "[1]" and #v > 0 and #v <= 36 then
            info.action = info.action or shown
        end
        info.lines[#info.lines + 1] = label .. ' "' .. shown .. '"'
        return
    elseif t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e9 then
            info.lines[#info.lines + 1] = label .. " " .. tostring(v)
        else
            info.lines[#info.lines + 1] = label .. " " .. string.format("%.4f", v)
        end
        return
    elseif t == "boolean" then
        info.lines[#info.lines + 1] = label .. " " .. tostring(v)
        return
    elseif t == "EnumItem" then
        info.lines[#info.lines + 1] = label .. " " .. tostring(v)
        return
    end
    info.lines[#info.lines + 1] = label .. " " .. t
end

local function inspectArgs(args)
    local info = {score = 0, lines = {}}
    if not args then return info end
    for i = 1, (args.n or 0) do
        walk(args[i], "[" .. i .. "]", info)
        if #info.lines >= 28 then break end
    end
    if args.truncated then
        info.lines[#info.lines + 1] = string.format("... %d args total", args.truncated)
    end
    info.score = math.min(info.score, 100)
    return info
end

local function computeCaller()
    local scriptPath = nil
    pcall(function()
        local s = getcallingscript()
        if typeof(s) == "Instance" then
            scriptPath = s:GetFullName()
        end
    end)
    local source, line, fname = nil, nil, nil
    if debug and debug.info then
        for level = 2, 12 do
            local ok, src, ln, name = pcall(debug.info, level, "sln")
            local ownName = type(name) == "string" and (
                name == "onNamecall" or name == "record" or name == "computeCaller"
                or name == "capture" or name == "copyValue")
            if ok and type(src) == "string" and src ~= "" and src ~= "[C]"
                and src ~= MY_SOURCE and not ownName
                and not string.find(src, "RemotePinger", 1, true)
                and not string.find(src, "remote_pinger", 1, true) then
                source, line, fname = src, ln, name
                break
            end
        end
    end
    local bits = {}
    if scriptPath then
        bits[#bits + 1] = scriptPath
    end
    if source then
        local loc = lastSegment(source)
        if type(line) == "number" then
            loc = loc .. ":" .. tostring(line)
        end
        if type(fname) == "string" and fname ~= "" then
            loc = loc .. " " .. fname
        end
        bits[#bits + 1] = loc
    end
    if #bits == 0 then return "?" end
    return table.concat(bits, " | ")
end

local function record(self, method, ...)
    if typeof(self) ~= "Instance" then return end
    local className = self.ClassName
    if className ~= "RemoteEvent"
        and className ~= "RemoteFunction"
        and className ~= "UnreliableRemoteEvent" then
        return
    end
    local path = pathCache[self]
    if not path then
        local ok, full = pcall(function()
            return self:GetFullName()
        end)
        path = (ok and full) or self.Name or "?"
        pathCache[self] = path
    end
    local key = method .. " " .. path
    local life = lifetime[key]
    if not life then
        life = {count = 0, first = os.clock()}
        lifetime[key] = life
    end
    life.count += 1
    local caller = callerCache[key]
    if not caller or caller == "?" then
        caller = computeCaller()
        if caller ~= "?" then
            callerCache[key] = caller
        end
    end
    push({
        t = os.clock(),
        method = method,
        path = path,
        className = className,
        caller = caller or "?",
        args = capture(...),
        key = key,
    })
end

local watch = { FireServer = true, InvokeServer = true }

local function onNamecall(self, ...)
    local method = getnamecallmethod()
    local callOld = original[1]
    if not callOld then return end
    if not running or busy or not watch[method] then
        return callOld(self, ...)
    end
    if isOurCall then
        local okCaller, ours = pcall(isOurCall)
        if okCaller and ours then
            return callOld(self, ...)
        end
    end
    busy = true
    pcall(record, self, method, ...)
    busy = false
    return callOld(self, ...)
end

local function snapshot(now, throughSequence)
    local groups, order = {}, {}
    for _, e in ipairs(entriesInWindow(now, WINDOW, throughSequence)) do
        local g = groups[e.key]
        if not g then
            g = {
                key = e.key, path = e.path, method = e.method, className = e.className,
                count = 0, newestT = e.t, caller = e.caller, samples = {},
            }
            groups[e.key] = g
            order[#order + 1] = e.key
        end
        g.count += 1
        if e.t >= g.newestT then
            g.newestT = e.t
            if e.caller and e.caller ~= "?" then
                g.caller = e.caller
            end
        end
        if #g.samples < 2 then
            g.samples[#g.samples + 1] = e.args
        else
            g.samples[1] = g.samples[2]
            g.samples[2] = e.args
        end
    end

    local rows = {}
    for _, key in ipairs(order) do
        local g = groups[key]
        local rendered, best = {}, nil
        for _, args in ipairs(g.samples) do
            local info = inspectArgs(args)
            rendered[#rendered + 1] = info
            if not best or info.score > best.score then
                best = info
            end
        end
        best = best or {score = 0, lines = {}}
        local score = best.score
            + keywordScore(lastSegment(g.path))
            + math.floor(keywordScore(g.caller) * 0.6)
        if g.count <= 8 then
            score += 10
        end
        local life = lifetime[g.key]
        if life and score < 40 then
            local rate = life.count / math.max(now - life.first, 0.5)
            if rate >= 4 then
                score -= 30
            end
        end
        local bufferNote = nil
        if rendered[2] and rendered[1].buffer and rendered[2].buffer and rendered[1].buffer ~= rendered[2].buffer then
            score += 18
            bufferNote = "buffer changes between calls"
        end
        local alt = nil
        if rendered[2] then
            local a = table.concat(best.lines, "\n")
            local b = table.concat(rendered[2].lines, "\n")
            if a ~= b then
                alt = rendered[2].lines
            end
        end
        rows[#rows + 1] = {
            key = g.key,
            path = g.path,
            method = g.method,
            className = g.className,
            count = g.count,
            age = now - g.newestT,
            caller = g.caller or "?",
            score = math.floor(score + 0.5),
            lines = best.lines,
            aim = best.aim,
            action = best.action,
            target = best.target,
            bufferNote = bufferNote,
            altLines = alt,
        }
    end
    table.sort(rows, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.count ~= b.count then return a.count < b.count end
        return a.path < b.path
    end)
    return rows
end

-- UI -------------------------------------------------------------------------

local FONT = Enum.Font.SourceSansBold
pcall(function()
    FONT = Enum.Font.GothamBold
end)
local CODE = Enum.Font.Code

local function sweep(root)
    if typeof(root) ~= "Instance" then return end
    for _, child in ipairs(root:GetChildren()) do
        if child.Name == "RemotePinger" then
            child:Destroy()
        end
    end
end

local function guiParent()
    local found = nil
    pcall(function()
        if type(gethui) == "function" then
            local h = gethui()
            if typeof(h) == "Instance" then
                found = h
            end
        end
    end)
    if found then return found end
    local okCore, core = pcall(function()
        return game:GetService("CoreGui")
    end)
    if okCore and typeof(core) == "Instance" then
        local probe = Instance.new("Folder")
        local can = pcall(function()
            probe.Parent = core
        end)
        probe:Destroy()
        if can then return core end
    end
    return LocalPlayer:WaitForChild("PlayerGui")
end

pcall(function() sweep(LocalPlayer:FindFirstChild("PlayerGui")) end)
pcall(function() sweep(game:GetService("CoreGui")) end)
local parent = guiParent()
pcall(function() sweep(parent) end)

local sg = Instance.new("ScreenGui")
sg.Name = "RemotePinger"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 100000
sg.Enabled = true
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
    sg.ScreenInsets = Enum.ScreenInsets.None
end)
sg.Parent = parent

local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r)
    c.Parent = inst
end

local PingBtn = Instance.new("TextButton")
PingBtn.Name = "Ping"
PingBtn.Size = UDim2.fromOffset(72, 72)
PingBtn.Position = UDim2.fromOffset(20, 200)
PingBtn.BackgroundColor3 = Color3.fromRGB(30, 10, 10)
PingBtn.BackgroundTransparency = 0.05
PingBtn.Text = "PING\n0"
PingBtn.TextColor3 = Color3.fromRGB(255, 150, 150)
PingBtn.TextTransparency = 0
PingBtn.Font = FONT
PingBtn.TextSize = 14
PingBtn.TextWrapped = true
PingBtn.AutoButtonColor = false
PingBtn.Active = true
PingBtn.Selectable = false
PingBtn.ZIndex = 40
PingBtn.Parent = sg
corner(PingBtn, 36)
local pingStroke = Instance.new("UIStroke")
pingStroke.Color = Color3.fromRGB(255, 90, 90)
pingStroke.Thickness = 2
pingStroke.Parent = PingBtn

local LogBtn = Instance.new("TextButton")
LogBtn.Name = "Log"
LogBtn.Size = UDim2.fromOffset(48, 48)
LogBtn.Position = UDim2.fromOffset(100, 214)
LogBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
LogBtn.Text = "LOG"
LogBtn.TextColor3 = Color3.fromRGB(220, 220, 235)
LogBtn.TextTransparency = 0
LogBtn.Font = FONT
LogBtn.TextSize = 12
LogBtn.AutoButtonColor = true
LogBtn.Active = true
LogBtn.Selectable = false
LogBtn.ZIndex = 40
LogBtn.Parent = sg
corner(LogBtn, 24)
local logStroke = Instance.new("UIStroke")
logStroke.Color = Color3.fromRGB(120, 120, 140)
logStroke.Thickness = 1
logStroke.Parent = LogBtn

local function placeLogBtn()
    LogBtn.Position = UDim2.new(
        PingBtn.Position.X.Scale, PingBtn.Position.X.Offset + 80,
        PingBtn.Position.Y.Scale, PingBtn.Position.Y.Offset + 14)
end

local Panel = Instance.new("Frame")
Panel.Size = UDim2.new(0.92, 0, 0.7, 0)
Panel.Position = UDim2.new(0.04, 0, 0.08, 0)
Panel.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
Panel.BackgroundTransparency = 0.02
Panel.BorderSizePixel = 0
Panel.Visible = false
Panel.Active = true
Panel.ClipsDescendants = true
Panel.ZIndex = 20
Panel.Parent = sg
corner(Panel, 8)
local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(140, 140, 160)
panelStroke.Thickness = 1
panelStroke.Parent = Panel

local Header = Instance.new("TextLabel")
Header.Size = UDim2.new(1, -130, 0, 28)
Header.Position = UDim2.fromOffset(8, 4)
Header.BackgroundTransparency = 1
Header.Font = FONT
Header.TextSize = 13
Header.TextXAlignment = Enum.TextXAlignment.Left
Header.TextColor3 = Color3.fromRGB(255, 190, 190)
Header.TextTransparency = 0
Header.Text = "PING LOG v" .. VERSION
Header.ZIndex = 24
Header.Parent = Panel

local function miniButton(text, xOff, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(52, 22)
    b.Position = UDim2.new(1, xOff, 0, 6)
    b.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    b.Text = text
    b.TextColor3 = color
    b.TextTransparency = 0
    b.Font = FONT
    b.TextSize = 11
    b.AutoButtonColor = true
    b.Active = true
    b.Selectable = false
    b.ZIndex = 26
    b.Parent = Panel
    corner(b, 4)
    return b
end

local ClearBtn = miniButton("CLEAR", -116, Color3.fromRGB(255, 190, 190))
local CopyBtn = miniButton("COPY", -58, Color3.fromRGB(210, 210, 240))

local Scroll = Instance.new("ScrollingFrame")
Scroll.Size = UDim2.new(1, -12, 1, -40)
Scroll.Position = UDim2.fromOffset(6, 34)
Scroll.BackgroundTransparency = 1
Scroll.BorderSizePixel = 0
Scroll.ScrollBarThickness = 5
Scroll.ScrollBarImageColor3 = Color3.fromRGB(160, 160, 180)
Scroll.CanvasSize = UDim2.new()
Scroll.ScrollingDirection = Enum.ScrollingDirection.Y
Scroll.Active = true
Scroll.Selectable = false
Scroll.ZIndex = 22
Scroll.Parent = Panel

local LogLabel = Instance.new("TextLabel")
LogLabel.Size = UDim2.new(1, -8, 0, 40)
LogLabel.BackgroundTransparency = 1
LogLabel.Font = CODE
LogLabel.TextSize = 13
LogLabel.TextXAlignment = Enum.TextXAlignment.Left
LogLabel.TextYAlignment = Enum.TextYAlignment.Top
LogLabel.TextWrapped = true
LogLabel.TextColor3 = Color3.fromRGB(230, 236, 245)
LogLabel.TextTransparency = 0
LogLabel.Text = ""
LogLabel.RichText = false
LogLabel.ZIndex = 23
LogLabel.Parent = Scroll

local function applyLog(text)
    LogLabel.Text = text
    local width = Scroll.AbsoluteSize.X - 10
    if width < 80 then width = 280 end
    local height = 40
    local ok, bounds = pcall(function()
        return TextService:GetTextSize(text, LogLabel.TextSize, LogLabel.Font, Vector2.new(width, 1e5))
    end)
    if ok and bounds then
        height = bounds.Y + 16
    else
        local _, n = string.gsub(text, "\n", "\n")
        height = (n + 1) * 18
    end
    LogLabel.Size = UDim2.new(1, -8, 0, height)
    Scroll.CanvasSize = UDim2.fromOffset(0, height + 8)
end

local function rowBlock(row, mark)
    local lines = {}
    local head = (mark and ">> " or "   ") .. row.method .. "  " .. row.path
    lines[#lines + 1] = head
    if row.className == "UnreliableRemoteEvent" then
        lines[#lines + 1] = "   unreliable"
    end
    local tied = row.caller ~= "?" and row.caller or "(caller hidden)"
    lines[#lines + 1] = "   tied to: " .. tied
    if row.aim then
        lines[#lines + 1] = "   aim: " .. row.aim
    end
    if row.action then
        lines[#lines + 1] = "   action: \"" .. row.action .. "\""
    end
    if row.target then
        lines[#lines + 1] = "   part: " .. row.target
    end
    if row.bufferNote then
        lines[#lines + 1] = "   " .. row.bufferNote
    end
    lines[#lines + 1] = string.format("   x%d   %.2fs before tap   score %d", row.count, row.age, row.score)
    for _, ln in ipairs(row.lines or {}) do
        lines[#lines + 1] = "   " .. ln
    end
    if mark and row.altLines then
        lines[#lines + 1] = "   other call:"
        local n = math.min(#row.altLines, 8)
        for i = 1, n do
            lines[#lines + 1] = "   " .. row.altLines[i]
        end
    end
    return table.concat(lines, "\n")
end

local function consistentRows()
    local hits = {}
    for _, ping in ipairs(pingLog) do
        local seen = {}
        for _, row in ipairs(ping.rows) do
            if not seen[row.key] then
                seen[row.key] = true
                local hit = hits[row.key]
                if not hit then
                    hit = {n = 0, row = row, maxScore = row.score}
                    hits[row.key] = hit
                end
                hit.n += 1
                if row.score >= hit.maxScore then
                    hit.maxScore = row.score
                    hit.row = row
                end
            end
        end
    end
    local list = {}
    for _, hit in pairs(hits) do
        if hit.n >= 2 then
            list[#list + 1] = hit
        end
    end
    table.sort(list, function(a, b)
        local ra = a.maxScore + a.n * 20
        local rb = b.maxScore + b.n * 20
        if ra ~= rb then return ra > rb end
        return a.row.path < b.row.path
    end)
    return list
end

local function publish(row)
    if not row then
        genv.RemotePingerLast = nil
        _G.RemotePingerLast = nil
        return
    end
    local pick = {
        path = row.path,
        method = row.method,
        className = row.className,
        caller = row.caller,
        aim = row.aim,
        action = row.action,
        score = row.score,
    }
    genv.RemotePingerLast = pick
    _G.RemotePingerLast = pick
end

local function renderLog()
    local lines = {
        "Shoot, tap PING, repeat. Same remote every time + UNIT-DIR / NAMED-DIR = the gun.",
        "Each PING includes only new calls from the last 4 seconds.",
        "",
    }
    local total = #pingLog
    if total >= 2 then
        local list = consistentRows()
        local shown = 0
        lines[#lines + 1] = string.format("REPEATS ACROSS PINGS (%d pings)", total)
        for _, hit in ipairs(list) do
            if shown >= 3 then break end
            if hit.maxScore >= 25 or shown == 0 then
                lines[#lines + 1] = string.format("(%d/%d)", hit.n, total)
                lines[#lines + 1] = rowBlock(hit.row, true)
                lines[#lines + 1] = ""
                shown += 1
            end
        end
        if shown == 0 then
            lines[#lines + 1] = "  nothing repeated yet"
            lines[#lines + 1] = ""
        end
    elseif total == 1 then
        lines[#lines + 1] = "One ping so far. Shoot again, then tap PING."
        lines[#lines + 1] = ""
    else
        lines[#lines + 1] = hookError and ("Hook failed: " .. hookError) or "Hook is live. Shoot, then tap PING."
        lines[#lines + 1] = ""
    end

    for i = #pingLog, 1, -1 do
        local ping = pingLog[i]
        lines[#lines + 1] = "──── PING " .. tostring(ping.index) .. " ────"
        if #ping.rows == 0 then
            if hookError then
                lines[#lines + 1] = "  hook failed: " .. hookError
            else
                lines[#lines + 1] = "  no new remote calls in the last " .. tostring(WINDOW) .. "s. Shoot again, then tap PING."
            end
        else
            local n = math.min(#ping.rows, SHOW_ROWS)
            for r = 1, n do
                lines[#lines + 1] = rowBlock(ping.rows[r], r == 1)
                lines[#lines + 1] = ""
            end
            if #ping.rows > n then
                lines[#lines + 1] = string.format("  +%d more", #ping.rows - n)
            end
        end
        lines[#lines + 1] = ""
    end
    lastReport = table.concat(lines, "\n")
    applyLog(lastReport)
end

local dragMoved = false
local ignoreClick = false
local clickGen = 0
local lastPingAt = 0
local function doPing()
    if not running or ignoreClick or dragMoved then return end
    local now = os.clock()
    if now - lastPingAt < 0.2 then return end
    lastPingAt = now
    pingCount += 1
    PingBtn.Text = "PING\n" .. tostring(pingCount)
    local throughSequence = bufSequence
    local rows = snapshot(now, throughSequence)
    lastSnapshotSequence = throughSequence
    pingLog[#pingLog + 1] = {rows = rows, index = pingCount, t = now}
    if #pingLog > MAX_PINGS then
        table.remove(pingLog, 1)
    end
    local list = consistentRows()
    if list[1] then
        publish(list[1].row)
    elseif rows[1] then
        publish(rows[1])
    else
        publish(nil)
    end
    renderLog()
    Panel.Visible = true
    PingBtn.BackgroundColor3 = Color3.fromRGB(90, 24, 24)
    task.delay(0.15, function()
        if running then
            PingBtn.BackgroundColor3 = Color3.fromRGB(30, 10, 10)
        end
    end)
end

Scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    if lastReport ~= "" then
        applyLog(lastReport)
    end
end)

-- Drag the PING button. Only the finger that hit it counts.
-- A phone also emits a fake mouse move; following that freezes the tap.

local dragInput = nil
local dragWatch = nil
local dragStart = nil
local startPos = nil
local lastTouchAt = 0
local DRAG_THRESHOLD = 14

local function endDrag(input)
    if input ~= dragInput then return end
    local moved = dragMoved
    dragInput = nil
    dragMoved = false
    if dragWatch then
        dragWatch:Disconnect()
        dragWatch = nil
    end
    if not running or input.UserInputState == Enum.UserInputState.Cancel then return end
    if moved then
        clickGen += 1
        local gen = clickGen
        ignoreClick = true
        task.delay(0.25, function()
            if clickGen == gen then
                ignoreClick = false
            end
        end)
        return
    end
    doPing()
end

PingBtn.InputBegan:Connect(function(input)
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
    startPos = PingBtn.Position
    if dragWatch then
        dragWatch:Disconnect()
    end
    dragWatch = input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End
            or input.UserInputState == Enum.UserInputState.Cancel then
            endDrag(input)
        end
    end)
end)

PingBtn.Activated:Connect(function()
    doPing()
end)

track(UserInputService.InputChanged:Connect(function(input)
    if not running or not dragInput or not dragStart or not startPos then return end
    local isMouseMove = dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseMovement
    if input ~= dragInput and not isMouseMove then return end
    local here = Vector2.new(input.Position.X, input.Position.Y)
    local delta = here - dragStart
    if math.abs(delta.X) > DRAG_THRESHOLD or math.abs(delta.Y) > DRAG_THRESHOLD then
        dragMoved = true
    end
    if dragMoved then
        PingBtn.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        placeLogBtn()
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    endDrag(input)
end))

local function onPress(btn, fn)
    local last = 0
    local pressInput = nil
    local origin = nil
    local function go()
        local now = os.clock()
        if now - last < 0.2 then return end
        last = now
        fn()
    end
    btn.Activated:Connect(go)
    btn.InputBegan:Connect(function(input)
        local kind = input.UserInputType
        if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
            pressInput = input
            origin = Vector2.new(input.Position.X, input.Position.Y)
        end
    end)
    btn.InputEnded:Connect(function(input)
        if input ~= pressInput or not origin then return end
        local here = Vector2.new(input.Position.X, input.Position.Y)
        local delta = here - origin
        pressInput = nil
        origin = nil
        if math.abs(delta.X) <= 16 and math.abs(delta.Y) <= 16 then
            go()
        end
    end)
    pcall(function()
        btn.TouchTap:Connect(function()
            go()
        end)
    end)
end

onPress(LogBtn, function()
    Panel.Visible = not Panel.Visible
end)

onPress(ClearBtn, function()
    pingLog = {}
    pingCount = 0
    table.clear(buf)
    bufPos = 0
    bufCount = 0
    lastSnapshotSequence = bufSequence
    table.clear(lifetime)
    table.clear(callerCache)
    PingBtn.Text = "PING\n0"
    publish(nil)
    renderLog()
end)

local function copyText(text)
    local function try(fn)
        if type(fn) ~= "function" then return false end
        local ok = pcall(fn, text)
        return ok
    end
    if try(setclipboard) or try(toclipboard) then
        return true
    end
    return false
end

onPress(CopyBtn, function()
    if lastReport == "" then
        renderLog()
    end
    if copyText(lastReport) then
        CopyBtn.Text = "OK"
    else
        CopyBtn.Text = "N/A"
    end
    task.delay(1, function()
        if running then
            CopyBtn.Text = "COPY"
        end
    end)
end)

-- Hook last, so a UI failure cannot leave a live hook behind.
local function installHook()
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return false, "executor has no hookmetamethod"
    end
    -- Keep one forwarding hook; reload only replaces its active handler.
    local bridge = genv.__RemotePingerNamecallBridge
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
    genv.__RemotePingerNamecallBridge = bridge
    return true
end

local hooked, why = installHook()
if not hooked then
    hookError = why
    PingBtn.Text = "NO\nHOOK"
    warn("[RemotePinger] " .. tostring(why))
else
    print("[RemotePinger v" .. VERSION .. "] ready. Shoot, tap PING, repeat 3 or 4 times.")
end
renderLog()

local function unload()
    if not running then return end
    running = false
    if namecallBridge and namecallBridge.handler == onNamecall then
        namecallBridge.handler = nil
    end
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)
    if dragWatch then
        pcall(function() dragWatch:Disconnect() end)
        dragWatch = nil
    end
    dragInput = nil
    dragStart = nil
    startPos = nil
    table.clear(buf)
    table.clear(pingLog)
    pcall(function()
        sg:Destroy()
    end)
end

genv.__RemotePingerUnload = unload
_G.__RemotePingerUnload = unload
