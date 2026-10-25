-- Run: lua5.4 tests/maintenance.lua /path/to/Downloads
-- Exercises actual source functions with engine/executor mocks, not a live game.
local root = arg[1] or "."
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
math.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function read(name)
    local f = assert(io.open(root .. "/" .. name, "r"))
    local s = f:read("*a"); f:close()
    return (s:gsub("([^\n]+)", function(line)
        return (line:gsub("^(%s*)([%w_%.%[%]]+)%s+([+%-%*/])=%s+(.+)$",
            function(indent, lhs, op, rhs) return indent .. lhs .. " = " .. lhs .. " " .. op .. " " .. rhs end))
    end))
end
local silent, hamon, pinger = read("silent.lua"), read("hamon.lua"), read("remote_pinger.lua")
for _, s in ipairs({silent, hamon, pinger}) do assert(load(s)) end
local function section(s, first, last)
    local a = assert(s:find(first, 1, true), first)
    local b = assert(s:find(last, a + #first, true), last)
    return s:sub(a, b - 1)
end
local function env(values) return setmetatable(values or {}, {__index = _G}) end
local function compile(code, e) return assert(load(code, "maintenance-check", "t", e))() end
local function fn(s, first, last, name, e)
    return compile(section(s, first, last) .. "\nreturn " .. name, e)
end
local passed = 0
local function check(name, f) f(); passed = passed + 1; print("PASS " .. name) end
local function signal()
    local handlers = {}
    return {
        Connect = function(_, f)
            local c = {connected = true}
            function c:Disconnect() self.connected = false end
            handlers[#handlers + 1] = {f = f, c = c}; return c
        end,
        emit = function(_, ...)
            for _, h in ipairs(handlers) do if h.c.connected then h.f(...) end end
        end,
    }
end
local Vector = {}
local function vector(x, y, z) return setmetatable({X=x, Y=y, Z=z or 0}, Vector) end
Vector.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z) end
end
Vector.__add = function(a,b) return vector(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
Vector.__sub = function(a,b) return vector(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
Vector.__mul = function(a,b) return vector(a.X*b,a.Y*b,a.Z*b) end
local vectors = {new=vector, zero=vector(0,0,0)}
local inputEnum = {UserInputType={Touch="touch",MouseButton1="mouse",MouseMovement="move"},UserInputState={Cancel="cancel"}}
local function pointIn(g,x,y)
    return g.Visible and x>=g.AbsolutePosition.X and y>=g.AbsolutePosition.Y
        and x<=g.AbsolutePosition.X+g.AbsoluteSize.X and y<=g.AbsolutePosition.Y+g.AbsoluteSize.Y
end
local function gui(x,y,w,h) return {Visible=true,AbsolutePosition=vector(x,y),AbsoluteSize=vector(w,h)} end

check("reloads preserve forwarding and coexist with another hook", function()
    local installs, calls, active, shared = 0, 0, nil, {}
    active = function(_, ...) calls=calls+1; return select("#", ...), ... end
    local function instance(s, isSilent)
        local e = env({genv=shared, original={}, game={}, conns={}, connections={}, buf={}, pingLog={},
            state={running=true,enabled=true}, running=true, pointerStarts={},
            clearTarget=function() end, sg={Destroy=function() end},
            getnamecallmethod=function() return "FireServer" end,
            newcclosure=function(f) return f end,
            hookmetamethod=function(_, _, f) local old=active; active=f; installs=installs+1; return old end})
        e.onNamecall=function(self, ...) return e.original[1](self, ...) end
        local install=fn(s,"local function installHook()","local hooked, why", "installHook",e)
        local unload=fn(s,"local function unload()",isSilent and "genv.__SilentUnload" or "genv.__RemotePingerUnload","unload",e)
        assert(install()); return unload,e
    end
    local unloadSilent=instance(silent,true)
    local unloadPinger,pingerEnv=instance(pinger,false)
    local disconnected=0
    pingerEnv.connections={{Disconnect=function() disconnected=disconnected+1 end}}
    pingerEnv.dragWatch={Disconnect=function() disconnected=disconnected+1 end}
    pingerEnv.buf={}; pingerEnv.pingLog={}
    unloadSilent()
    local count,a,b,c=active({},1,nil,3)
    assert(count==3 and a==1 and b==nil and c==3 and calls==1)
    for _=1,20 do local unload=instance(silent,true); unload() end
    assert(installs==2, "reload stacked another hook")
    unloadPinger(); assert(disconnected==2)
    assert(active({},nil)==1 and calls==2)
    local unload=instance(pinger,false); unload()
    assert(installs==2 and active({},4)==1)
end)

check("camera loss, disable, and render errors clear the target", function()
    local render
    local e=env({state={running=true,enabled=true},circle={},WHITE={},Vector3=vectors,
        track=function(c) return c end, warn=function() end,
        RunService={RenderStepped={Connect=function(_,f) render=f; return {} end}},
        camera=function() return nil end})
    e.clearTarget=fn(silent,"local function clearTarget()","local function sweepOldGui", "clearTarget",e)
    compile(section(silent,"local renderWarned = false","local function installHook()"),e)
    local function dirty() e.state.part={};e.state.head={};e.state.eye={};e.circle.Visible=true end
    local function clean() assert(e.state.part==nil and e.state.head==nil and e.state.eye==nil and not e.circle.Visible) end
    dirty();render();clean()
    e.camera=function() return {} end; e.state.enabled=false
    dirty();render();clean()
    e.state.enabled=true
    e.fovRadius=function() e.state.part={};error("injected update failure") end
    dirty();render();clean()
end)

for _, item in ipairs({{silent,"track",false},{hamon,"Track",true}}) do
    check((item[3] and "Hamon" or "Silent") .. " keeps concurrent touches separate", function()
        local source, track, isHamon=item[1],item[2],item[3]
        local input={InputBegan=signal(),InputEnded=signal()}
        local left,right=gui(100,100,30,30),gui(150,100,30,30)
        local hits={0,0}
        local e=env({UserInputService=input,Enum=inputEnum,Vector2=vectors,
            MenuFrame={Visible=true},Scroll=gui(90,90,100,60),MainBtn=gui(0,0,20,20),
            pointIn=pointIn, pressables={{gui=left,go=function() hits[1]=hits[1]+1 end},{gui=right,go=function() hits[2]=hits[2]+1 end}},
            pressAt={[left]=function() hits[1]=hits[1]+1 end,[right]=function() hits[2]=hits[2]+1 end}})
        e[track]=function(c) return c end
        local code=section(source,track .. "(UserInputService.InputBegan:Connect(function(input)\n    local kind",
            isHamon and "-- AIM KEY" or "-- FOV")
        compile("local pointerStarts = {}\n" .. code,e)
        local a={UserInputType="touch",Position=vector(110,110)}
        local b={UserInputType="touch",Position=vector(160,110)}
        input.InputBegan:emit(a);input.InputBegan:emit(b)
        input.InputEnded:emit(a);input.InputEnded:emit(b)
        assert(hits[1]==1 and hits[2]==1)
        a.UserInputState="cancel";input.InputBegan:emit(a);input.InputEnded:emit(a)
        assert(hits[1]==1)
    end)
end

check("skeletons reuse lines and render only after the aim snap", function()
    local allocations, releases, draws, rays=0,0,0,0
    local e=env({Vector2=vectors,Vector3=vectors,SETTINGS={ESPEnabled=true,Skeleton=true,MaxDistance=500,LockLeeway=1.35},
        R6Bones={{"Head","Torso"}}, R15Bones={}, ESPData={}, scratchFilter={},RayParams={}, FOVCircle={},
        CFrame={new=function(origin) return {Position=origin} end},
        Color3={fromRGB=function() return {} end,fromHSV=function() return {} end},
        GetDrawing=function() allocations=allocations+1;return {} end,
        ReleaseDrawing=function(d) releases=releases+1;d.Visible=false end,
        ComputeFOVRadius=function() return 30 end, AimActive=function() return true end,
        IsVisible=function() rays=rays+1;return true end})
    local parts={Head={Position=vector(0,2,100)},Torso={Position=vector(0,1,100)},HumanoidRootPart={Position=vector(0,0,100)}}
    local hum={Health=100,MaxHealth=100}
    local char={FindFirstChild=function(_,n) return parts[n] end,FindFirstChildOfClass=function() return hum end}
    local me,other={}, {Character=char}
    e.LocalPlayer=me;e.Players={GetPlayers=function() return {me,other} end}
    e.IsTeammate=fn(hamon,"local function IsTeammate(p)","local aimHeld", "IsTeammate",e)
    local cam={ViewportSize=vector(1000,800),CFrame={Position=vector(0,0,0)}}
    local shake=0
    function cam:WorldToViewportPoint(p) return vector(500+shake,400-p.Y*10,1),true end
    e.Camera=cam;e.workspace={CurrentCamera=cam}
    local entry={SkeletonLines={},SkeletonCount=0,BoxLines={}};e.ESPData[other]=entry
    e.EnsureEntry=function() return entry end
    e.ReleaseAllSkeletonLines=fn(hamon,"local function ReleaseAllSkeletonLines(e)","local function ClearVisuals", "ReleaseAllSkeletonLines",e)
    e.ReleaseAllBoxLines=fn(hamon,"local function ReleaseAllBoxLines(e)","local function ClearVisuals", "ReleaseAllBoxLines",e)
    e.ClearVisuals=fn(hamon,"local function ClearVisuals(e)","local function EnsureEntry", "ClearVisuals",e)
    local draw=fn(hamon,"local function drawSkeleton(e, char, color)","-- MAIN LOOP", "drawSkeleton",e)
    e.drawSkeleton=function(...)
        assert(cam.CFrame.snapped, "bones were projected before aim updated the camera")
        draws=draws+1;return draw(...)
    end
    e.CFrame.new=function(origin) return {Position=origin,snapped=true} end
    e.refreshDrawings=fn(hamon,"local function refreshDrawings()","local renderWarned", "refreshDrawings",e)
    local frame=fn(hamon,"local function renderFrame(dt)","-- After the default camera", "renderFrame",e)
    frame(1/60);assert(draws==1 and allocations==1 and releases==0)
    local lines=entry.SkeletonLines
    local before=lines[1].From.X
    shake=17
    frame(1/60);assert(draws==2 and allocations==1 and releases==0 and lines==entry.SkeletonLines)
    assert(lines[1].From.X==before+17, "bones did not follow the camera shake")
    e.SETTINGS.ESPEnabled=false;rays=0
    frame(1/60);assert(draws==2 and rays==0 and releases==1 and not entry.DrawPending)
    e.SETTINGS.ESPEnabled=true
    e.SETTINGS.Skeleton=false;e.AimActive=function() return false end;rays=0
    frame(1/60);assert(rays==0 and releases==1 and lines==entry.SkeletonLines)
end)

check("FFA and neutral players stay opponents for aiming, colors, and visibility", function()
    local team, otherTeam={},{}
    local e=env({Vector2=vectors,Vector3=vectors,ESPData={},scratchFilter={},RayParams={},FOVCircle={},
        SETTINGS={ESPEnabled=true,Skeleton=true,WallCheck=true,MaxDistance=500,LockLeeway=1.35,
            ColorVisible={},ColorHidden={},ColorTeam={}},
        CFrame={new=function(origin) return {Position=origin,snapped=true} end},
        Color3={fromRGB=function() return {} end,fromHSV=function() return {} end},
        ComputeFOVRadius=function() return 30 end,AimActive=function() return true end,
        refreshDrawings=function() end})
    local parts={Head={Position=vector(0,2,100)},HumanoidRootPart={Position=vector(0,0,100)}}
    local hum={Health=100,MaxHealth=100}
    local char={FindFirstChild=function(_,n) return parts[n] end,FindFirstChildOfClass=function() return hum end}
    local me,other={Character={}}, {Character=char}
    e.LocalPlayer=me;e.Players={GetPlayers=function() return {me,other} end}
    local cam={ViewportSize=vector(1000,800),WorldToViewportPoint=function() return vector(500,400,1),true end}
    e.Camera=cam;e.workspace={CurrentCamera=cam}
    local entry={}
    e.EnsureEntry=function() return entry end
    e.ClearVisuals=function(x) x.DrawPending=false;x.SkeletonColor=nil end
    e.IsTeammate=fn(hamon,"local function IsTeammate(p)","local aimHeld", "IsTeammate",e)
    local frame=fn(hamon,"local function renderFrame(dt)","-- After the default camera", "renderFrame",e)
    local scenarios={
        {name="shared team in FFA",ffa=true,localTeam=team,otherTeam=team,opponent=true},
        {name="actual teammate",localTeam=team,otherTeam=team,opponent=false},
        {name="neutral opponent with matching team",localTeam=team,otherTeam=team,otherNeutral=true,opponent=true},
        {name="neutral local player",localTeam=team,otherTeam=team,localNeutral=true,opponent=true},
        {name="both neutral",localTeam=team,otherTeam=team,localNeutral=true,otherNeutral=true,opponent=true},
        {name="different team",localTeam=team,otherTeam=otherTeam,opponent=true},
        {name="both without a team",opponent=true},
        {name="other player without a team",localTeam=team,opponent=true},
        {name="FFA without teams",ffa=true,opponent=true},
    }
    -- Reuse one running frame across transitions to catch stale locks/filter entries.
    for _, case in ipairs(scenarios) do
        me.Team=case.localTeam;me.Neutral=case.localNeutral or false
        other.Team=case.otherTeam;other.Neutral=case.otherNeutral or false
        e.SETTINGS.FFAMode=case.ffa or false
        for _, visible in ipairs({true,false}) do
            cam.CFrame={Position=vector(0,0,0)}
            e.IsVisible=function()
                local own, ignored=0,0
                for _, ignoredChar in ipairs(e.RayParams.FilterDescendantsInstances) do
                    if ignoredChar==me.Character then own=own+1 end
                    if ignoredChar==char then ignored=ignored+1 end
                end
                assert(own==1 and ignored==1, case.name..": opponent was misclassified in the ray filter")
                return visible
            end
            frame(1/60)
            assert(not not entry.DrawPending==case.opponent,case.name..": wrong ESP eligibility")
            assert(not not cam.CFrame.snapped==(case.opponent and visible),case.name..": wrong aim eligibility")
            if case.opponent then
                assert(entry.SkeletonColor==(visible and e.SETTINGS.ColorVisible or e.SETTINGS.ColorHidden),
                    case.name..": opponent kept a teammate color")
            end
        end
    end
end)

check("corner boxes stay thin, fade at distance, and yield to tiny skeletons", function()
    local allocations, releases=0,0
    local e=env({SETTINGS={Skeleton=true},BOX_COLOR={},Vector2=vectors,
        GetDrawing=function() allocations=allocations+1;return {} end,
        ReleaseDrawing=function(d) releases=releases+1;d.Visible=false end})
    e.ReleaseAllBoxLines=fn(hamon,"local function ReleaseAllBoxLines(e)","local function ClearVisuals", "ReleaseAllBoxLines",e)
    local draw=compile(section(hamon,"local function setBoxLine(","local function drawSkeleton").."\nreturn drawBox",e)
    local entry={BoxLines={}}
    draw(entry,100,100,50,100)
    assert(allocations==8 and #entry.BoxLines==8)
    local first=entry.BoxLines[1]
    local opacity=first.Transparency
    for _, line in ipairs(entry.BoxLines) do
        assert(line.Thickness==1 and line.Color==e.BOX_COLOR and line.Visible)
    end
    assert(entry.BoxLines[1].To.X < entry.BoxLines[3].From.X, "top corners joined into a full border")
    draw(entry,100,100,20,40)
    assert(allocations==8 and entry.BoxLines[1]==first and first.Transparency<opacity)
    draw(entry,100,100,10,20)
    assert(#entry.BoxLines==0 and releases==8 and not first.Visible)
    e.SETTINGS.Skeleton=false
    draw(entry,100,100,10,20)
    assert(#entry.BoxLines==8, "small boxes should remain available without bones")
end)

check("menu sections expand independently of feature switches and hide inactive hit targets", function()
    local created, actions, deferred={}, {}, {}
    local enum={AutomaticSize={Y="Y"},SortOrder={LayoutOrder=1},TextXAlignment={Left=1}}
    local e=env({SETTINGS={Aim=false,ESPEnabled=false},Scroll={},FONT=1,WHITE={},BLACK={},Enum=enum,
        Vector2=vectors,UDim={new=function(...) return {...} end},
        UDim2={new=function(...) return {...} end,fromOffset=function(...) return {...} end},
        Color3={fromRGB=function(...) return {...} end},resizeCanvas=function() end,
        task={defer=function(f) deferred[#deferred+1]=f end},nextOrder=function() return #created end,
        bindPress=function(button,callback) actions[button]=callback end})
    e.Instance={new=function(kind,parent)
        local object=gui(0,0,100,20)
        object.Parent=parent;object.kind=kind
        function object:IsA(name) return name=="GuiObject" and self.kind~="ScreenGui" end
        created[#created+1]=object
        return object
    end}
    e.Scroll=e.Instance.new("ScrollingFrame")
    local make=compile(section(hamon,"local sections = {}","local function MakeRow").."\nreturn MakeSection",e)
    local aim=make("AIM","Aim")
    local walls=make("WALLS","ESPEnabled")
    local game=make("GAME")
    assert(not aim.Visible and not walls.Visible and not game.Visible)
    local function buttons(body)
        local header
        for _, object in ipairs(created) do
            if object.kind=="Frame" and object.Parent==e.Scroll and object.LayoutOrder<body.LayoutOrder then
                header=object
            end
        end
        local title, toggle
        for _, object in ipairs(created) do
            if object.kind=="TextButton" and object.Parent==header then
                if object.Text=="OFF" or object.Text=="ON" then toggle=object else title=object end
            end
        end
        return title,toggle
    end
    local aimTitle,aimToggle=buttons(aim)
    local wallsTitle,wallsToggle=buttons(walls)
    actions[aimToggle]();assert(e.SETTINGS.Aim and aim.Visible and not walls.Visible)
    actions[wallsTitle]();assert(e.SETTINGS.Aim and not aim.Visible and walls.Visible and not e.SETTINGS.ESPEnabled)
    actions[wallsToggle]();assert(e.SETTINGS.ESPEnabled and walls.Visible)
    actions[wallsTitle]();assert(e.SETTINGS.ESPEnabled and not walls.Visible)
    actions[aimTitle]();assert(aim.Visible and not walls.Visible)
    actions[aimToggle]();assert(not e.SETTINGS.Aim and not aim.Visible and e.SETTINGS.ESPEnabled)
    local hit=fn(hamon,"local function pointIn(gui, x, y)","local sections", "pointIn",e)
    local row=e.Instance.new("TextButton",walls)
    assert(not hit(row,10,10), "collapsed rows intercepted a touch")
    walls.Visible=true;assert(hit(row,10,10))
    walls.ClipsDescendants=true;walls.AbsoluteSize=vector(5,5)
    assert(not hit(row,10,10), "clipped rows intercepted a touch")
end)

check("pings consume fresh calls, keep newest samples, and reset cleanly", function()
    local now=100
    local e=env({buf={},bufPos=0,bufCount=0,bufSequence=0,lastSnapshotSequence=0,BUF_MAX=3,WINDOW=4,
        lifetime={},callerCache={},pingLog={},pingCount=0,MAX_PINGS=20,running=true,
        lastPingAt=0,PingBtn={},Panel={},Color3={fromRGB=function() return {} end},
        os={clock=function() return now end},task={delay=function() end},
        inspectArgs=function(args) return {score=1,lines={args[1]}} end,keywordScore=function() return 0 end,
        lastSegment=function(s) return s end,consistentRows=function() return {} end,
        publish=function() end,renderLog=function() end})
    local push=fn(pinger,"local function push(entry)","local function entriesInWindow", "push",e)
    e.entriesInWindow=fn(pinger,"local function entriesInWindow(now, window, throughSequence)","local function bufferPreview", "entriesInWindow",e)
    e.snapshot=fn(pinger,"local function snapshot(now, throughSequence)","-- UI", "snapshot",e)
    local ping=fn(pinger,"local function doPing()","Scroll:GetPropertyChangedSignal", "doPing",e)
    local function shot(label)
        push({t=now-.1,key="FireServer gun",path="gun",method="FireServer",caller="test",args={label}})
    end
    shot("one");shot("two");shot("three");ping()
    assert(e.pingLog[1].rows[1].count==3 and e.pingLog[1].rows[1].lines[1]=="two")
    now=now+1;ping();assert(#e.pingLog[2].rows==0, "same calls counted twice")
    shot("four");now=now+1;ping();assert(e.pingLog[3].rows[1].count==1)
    local clear
    e.onPress=function(_,f) clear=f end
    compile(section(pinger,"onPress(ClearBtn, function()","local function copyText"),e)
    shot("before clear");clear();now=now+1;ping();assert(#e.pingLog[1].rows==0)
    shot("after clear");now=now+1;ping();assert(e.pingLog[2].rows[1].count==1)
end)
print(string.format("%d maintenance checks passed",passed))
