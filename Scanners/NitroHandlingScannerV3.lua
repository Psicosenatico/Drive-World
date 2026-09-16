-- PSICOSENATICO | Drive World Nitro + Handling Scanner V3
-- Foco: descobrir o recurso real do nitro e medir esterco/estabilidade em alta velocidade.
-- Nao altera fisica nem ativa nitro. Para evitar contaminacao, fecha o menu principal se estiver ativo.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LP = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_DRIVE_MENU_STOP) == "function" then pcall(G.PSICO_DRIVE_MENU_STOP) end
if type(G.PSICO_DW_NH_SCAN_STOP) == "function" then pcall(G.PSICO_DW_NH_SCAN_STOP) end

local START = os.clock()
local SESSION = tostring(os.time())
local FILE_NAME = "DriveWorld_NitroHandlingScan_" .. SESSION .. ".json"
local running = true
local phase = "START"
local conns = {}
local vehicle, seat, main, controller
local telemetryAcc = 0
local monitorAcc = 0
local resolveAcc = 999
local nitroValue
local lastNitro = false

local DATA = {
    version = "DriveWorldNitroHandlingScannerV3",
    session = SESSION,
    placeId = game.PlaceId,
    jobId = game.JobId,
    vehicle = {},
    phases = {},
    nitroEvents = {},
    telemetry = {},
    candidates = {},
    errors = {},
}

local runtimeCandidates = {}
local candidateKeys = {}
local candidateCount = 0
local controllerId

local function now()
    return math.floor((os.clock() - START) * 1000 + 0.5) / 1000
end

local function addConn(c)
    conns[#conns + 1] = c
    return c
end

local function norm(s)
    return string.lower(tostring(s or "")):gsub("[%s_%-%./]", "")
end

local function resourceish(s)
    local n = norm(s)
    return n:find("nitro",1,true) or n:find("nitrous",1,true) or n == "nos"
        or n:find("boost",1,true) or n:find("charge",1,true)
        or n:find("capacity",1,true) or n:find("remaining",1,true)
        or n:find("fuel",1,true) or n:find("amount",1,true)
        or n:find("duration",1,true) or n:find("meter",1,true)
end

local function getVehicle()
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local s = hum and hum.SeatPart
    if not s then return nil, nil end
    local cars = workspace:FindFirstChild("Cars")
    if cars then
        local n = s
        while n and n.Parent and n.Parent ~= cars do n = n.Parent end
        if n and n.Parent == cars and n:IsA("Model") then return n, s end
    end
    local n = s
    while n and n ~= workspace do
        if n:IsA("Model") and n:FindFirstChild("Main") and n:FindFirstChild("Wheels") then return n, s end
        n = n.Parent
    end
    return s:FindFirstAncestorOfClass("Model"), s
end

local function getGC()
    local fn = rawget(G,"getgc") or getgc
    if type(fn) ~= "function" then return {} end
    local ok, r = pcall(fn,true)
    if not ok or type(r) ~= "table" then ok, r = pcall(fn) end
    return ok and type(r) == "table" and r or {}
end

local function scoreController(t, car)
    if type(t) ~= "table" or not car then return -1 end
    local s = 0
    if rawget(t,"model") == car then s += 140 end
    if rawget(t,"carName") == car.Name then s += 35 end
    if type(rawget(t,"wheelData")) == "table" then s += 35 end
    if type(rawget(t,"config")) == "table" then s += 25 end
    if rawget(t,"currentDriver") == LP then s += 45 end
    if rawget(t,"owner") == LP then s += 20 end
    return s
end

local function findController(car)
    local best, score = nil, -1
    for _,o in ipairs(getGC()) do
        if type(o) == "table" then
            local s = scoreController(o,car)
            if s > score then best, score = o, s end
        end
    end
    return score >= 180 and best or nil
end

local function candidateKey(kind, owner, key)
    return kind .. "|" .. tostring(owner) .. "|" .. tostring(key)
end

local function addCandidate(kind, owner, key, label, getter)
    local id = candidateKey(kind,owner,key)
    if candidateKeys[id] then return end
    local ok, v = pcall(getter)
    if not ok or type(v) ~= "number" or v ~= v or math.abs(v) > 1e12 then return end

    candidateCount += 1
    local stats = {
        id = candidateCount,
        kind = kind,
        label = label,
        start = v,
        last = v,
        min = v,
        max = v,
        dropsNitro = 0,
        risesNitro = 0,
        changesOff = 0,
        deltaNitro = 0,
        deltaOff = 0,
        samples = 0,
        changes = {},
    }
    DATA.candidates[#DATA.candidates + 1] = stats
    runtimeCandidates[#runtimeCandidates + 1] = {stats=stats,get=getter}
    candidateKeys[id] = true
end

local function tableHasNitroMarker(t)
    local n = 0
    for k,v in pairs(t) do
        n += 1
        if n > 100 then break end
        if resourceish(k) then return true end
        if type(v) == "string" and resourceish(v) then return true end
    end
    return false
end

local function discoverTableCandidates()
    local scanned = 0
    for _,o in ipairs(getGC()) do
        if type(o) == "table" and tableHasNitroMarker(o) then
            scanned += 1
            local count = 0
            for k,v in pairs(o) do
                count += 1
                if count > 120 then break end
                if type(v) == "number" and resourceish(k) then
                    local kk = k
                    addCandidate("table",o,kk,"table."..tostring(kk),function() return rawget(o,kk) end)
                end
            end
            if scanned > 350 then break end
        end
    end
end

local function discoverInstanceCandidates(root, rootLabel)
    if not root then return end
    local ok, list = pcall(function() return root:GetDescendants() end)
    if not ok then return end
    for _,o in ipairs(list) do
        if o:IsA("NumberValue") or o:IsA("IntValue") then
            local parent = o.Parent and o.Parent.Name or ""
            if resourceish(o.Name) or resourceish(parent) then
                addCandidate("value",o,"Value",rootLabel..":"..o:GetFullName(),function() return o.Value end)
            end
        end
    end
end

local function getInfo(fn)
    local dbg = debug
    local infoFn = (dbg and dbg.getinfo) or rawget(G,"getinfo") or getinfo
    if type(infoFn) ~= "function" then return nil end
    local ok,r = pcall(infoFn,fn)
    return ok and r or nil
end

local function getUpvalues(fn)
    local dbg = debug
    local f = (dbg and dbg.getupvalues) or rawget(G,"getupvalues") or getupvalues
    if type(f) ~= "function" then return nil end
    local ok,r = pcall(f,fn)
    return ok and type(r) == "table" and r or nil
end

local function discoverUpvalueCandidates()
    local funcs = 0
    for _,o in ipairs(getGC()) do
        if type(o) == "function" then
            local info = getInfo(o)
            local src = info and tostring(info.source or info.short_src or "") or ""
            local name = info and tostring(info.name or "") or ""
            local ns = norm(src .. " " .. name)
            if ns:find("cars",1,true) or ns:find("vehicle",1,true) or ns:find("nitro",1,true) then
                funcs += 1
                local ups = getUpvalues(o)
                if ups then
                    for k,v in pairs(ups) do
                        if type(v) == "number" and (resourceish(k) or ns:find("nitro",1,true)) then
                            local kk = k
                            addCandidate("upvalue",o,kk,"upvalue:"..name.."@"..src..":"..tostring(kk),function()
                                local cur = getUpvalues(o)
                                return cur and cur[kk]
                            end)
                        elseif type(v) == "table" and tableHasNitroMarker(v) then
                            for tk,tv in pairs(v) do
                                if type(tv) == "number" and resourceish(tk) then
                                    local tkk = tk
                                    addCandidate("up_table",v,tkk,"up_table:"..name..":"..tostring(tkk),function() return rawget(v,tkk) end)
                                end
                            end
                        end
                    end
                end
                if funcs > 220 then break end
            end
        end
    end
end

local function discoverAll()
    discoverTableCandidates()
    discoverUpvalueCandidates()
    discoverInstanceCandidates(vehicle,"vehicle")
    discoverInstanceCandidates(LP,"player")
    local pd = workspace:FindFirstChild("PlayerData")
    if pd then discoverInstanceCandidates(pd:FindFirstChild(LP.Name),"playerdata") end
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if pg then discoverInstanceCandidates(pg,"playergui") end
end

local function resolve()
    local car,s = getVehicle()
    if car ~= vehicle then
        vehicle,seat = car,s
        main = car and car:FindFirstChild("Main") or nil
        controller = nil
        controllerId = nil
        table.clear(runtimeCandidates)
        table.clear(candidateKeys)
        table.clear(DATA.candidates)
        candidateCount = 0
    else
        seat = s
        main = car and car:FindFirstChild("Main") or main
    end
    if vehicle and not controller then
        controller = findController(vehicle)
        controllerId = controller and tostring(controller) or nil
        DATA.vehicle = {
            name = vehicle.Name,
            path = vehicle:GetFullName(),
            seat = seat and seat:GetFullName() or nil,
            controller = controllerId,
        }
        nitroValue = vehicle:FindFirstChild("States") and vehicle.States:FindFirstChild("Nitrous") or nil
        discoverAll()
    end
end

local function nitroOn()
    return nitroValue and nitroValue:IsA("BoolValue") and nitroValue.Value == true or false
end

local function monitorCandidates()
    local nOn = nitroOn()
    for _,c in ipairs(runtimeCandidates) do
        local ok,v = pcall(c.get)
        if ok and type(v) == "number" and v == v then
            local s = c.stats
            local old = s.last
            local d = v - old
            s.samples += 1
            if v < s.min then s.min = v end
            if v > s.max then s.max = v end
            if math.abs(d) > math.max(1e-7, math.max(math.abs(old),1) * 1e-6) then
                if nOn then
                    s.deltaNitro += d
                    if d < 0 then s.dropsNitro += 1 else s.risesNitro += 1 end
                else
                    s.deltaOff += d
                    s.changesOff += 1
                end
                if #s.changes < 24 then
                    s.changes[#s.changes + 1] = {t=now(),phase=phase,nitro=nOn,old=old,value=v,delta=d}
                end
            end
            s.last = v
        end
    end
end

local function telemetry()
    if not main or not main:IsA("BasePart") then return end
    local cf = main.CFrame
    local lv = main.AssemblyLinearVelocity
    local av = main.AssemblyAngularVelocity
    local steerInput = type(controller)=="table" and tonumber(rawget(controller,"steerInput")) or nil
    local traction = type(controller)=="table" and tonumber(rawget(controller,"traction")) or nil
    local seatSteer
    if seat and seat:IsA("VehicleSeat") then pcall(function() seatSteer = seat.SteerFloat end) end
    DATA.telemetry[#DATA.telemetry + 1] = {
        t=now(),phase=phase,nitro=nitroOn(),
        speed=lv.Magnitude,
        forward=lv:Dot(cf.LookVector),
        lateral=lv:Dot(cf.RightVector),
        vertical=lv:Dot(cf.UpVector),
        yawRate=av:Dot(cf.UpVector),
        angular=av.Magnitude,
        steerInput=steerInput,
        seatSteer=seatSteer,
        traction=traction,
    }
end

local function mark(newPhase,instruction)
    phase = newPhase
    DATA.phases[#DATA.phases + 1] = {t=now(),phase=newPhase,instruction=instruction}
end

local function hookNitro()
    if not nitroValue or not nitroValue:IsA("BoolValue") then return end
    addConn(nitroValue:GetPropertyChangedSignal("Value"):Connect(function()
        local v = nitroValue.Value
        DATA.nitroEvents[#DATA.nitroEvents + 1] = {t=now(),phase=phase,value=v}
        if v then discoverAll() end
        lastNitro = v
    end))
    lastNitro = nitroValue.Value
end

-- UI -------------------------------------------------------------------------
local old = CoreGui:FindFirstChild("PsicoNitroHandlingScannerV3")
if old then pcall(function() old:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = "PsicoNitroHandlingScannerV3"
gui.ResetOnSpawn = false
local okParent = pcall(function() gui.Parent = CoreGui end)
if not okParent or not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(330,320)
frame.Position = UDim2.new(.5,-165,.5,-160)
frame.BackgroundColor3 = Color3.fromRGB(16,19,28)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
Instance.new("UICorner",frame).CornerRadius = UDim.new(0,14)

local title = Instance.new("TextLabel")
title.BackgroundTransparency=1
title.Position=UDim2.fromOffset(12,7)
title.Size=UDim2.new(1,-50,0,28)
title.Font=Enum.Font.GothamBold
title.Text="PSICO • NITRO/HANDLING SCAN V3"
title.TextColor3=Color3.new(1,1,1)
title.TextSize=13
title.TextXAlignment=Enum.TextXAlignment.Left
title.Active=true
title.Parent=frame

local close=Instance.new("TextButton")
close.Position=UDim2.new(1,-38,0,4)
close.Size=UDim2.fromOffset(32,32)
close.BackgroundTransparency=1
close.Text="×"
close.TextColor3=Color3.new(1,1,1)
close.TextSize=22
close.Parent=frame

local status=Instance.new("TextLabel")
status.BackgroundTransparency=1
status.Position=UDim2.fromOffset(12,38)
status.Size=UDim2.new(1,-24,0,50)
status.Font=Enum.Font.Gotham
status.TextColor3=Color3.fromRGB(180,185,205)
status.TextSize=11
status.TextWrapped=true
status.TextXAlignment=Enum.TextXAlignment.Left
status.TextYAlignment=Enum.TextYAlignment.Top
status.Parent=frame

local function button(y,text,callback)
    local b=Instance.new("TextButton")
    b.Position=UDim2.fromOffset(12,y)
    b.Size=UDim2.new(1,-24,0,38)
    b.BackgroundColor3=Color3.fromRGB(58,68,92)
    b.BorderSizePixel=0
    b.Font=Enum.Font.GothamBold
    b.Text=text
    b.TextColor3=Color3.new(1,1,1)
    b.TextSize=12
    b.Parent=frame
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,9)
    addConn(b.MouseButton1Click:Connect(callback))
    return b
end

button(92,"1 • BASE / PARADO",function() mark("BASE","parado ou conduza normalmente alguns segundos") end)
button(136,"2 • NITRO MANUAL",function() mark("NITRO","ative o nitro normalmente e SEGURE por 8-10s; nao use menu de turbo") discoverAll() end)
button(180,"3 • CURVA BAIXA",function() mark("LOW_TURN","faca curvas esquerda/direita em baixa velocidade") end)
button(224,"4 • CURVA ALTA",function() mark("HIGH_TURN","ganhe velocidade alta e faca curvas esquerda/direita") end)

local exportButton
exportButton=button(268,"5 • EXPORTAR JSON",function()
    phase="EXPORT"
    local ranked={}
    for _,s in ipairs(DATA.candidates) do
        if s.dropsNitro>0 or s.risesNitro>0 or s.changesOff>0 then ranked[#ranked+1]=s end
    end
    table.sort(ranked,function(a,b)
        local sa=math.abs(a.deltaNitro)+(a.dropsNitro*10)
        local sb=math.abs(b.deltaNitro)+(b.dropsNitro*10)
        return sa>sb
    end)
    DATA.rankedCandidates={}
    for i=1,math.min(#ranked,80) do DATA.rankedCandidates[i]=ranked[i] end
    DATA.finished=now()
    local encoded=HttpService:JSONEncode(DATA)
    local ok=false
    if type(writefile)=="function" then ok=pcall(writefile,FILE_NAME,encoded) end
    if not ok and type(setclipboard)=="function" then pcall(setclipboard,encoded) end
    exportButton.Text=ok and ("SALVO: "..FILE_NAME) or "JSON COPIADO / EXPORTADO"
end)

-- Drag pelo titulo.
local dragging=false
local dragStart,startPos,dragInput
addConn(title.InputBegan:Connect(function(input)
    if input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseButton1 then
        dragging=true dragStart=input.Position startPos=frame.Position
        local e e=input.Changed:Connect(function() if input.UserInputState==Enum.UserInputState.End then dragging=false if e then e:Disconnect() end end end)
    end
end))
addConn(title.InputChanged:Connect(function(input)
    if input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseMovement then dragInput=input end
end))
addConn(UserInputService.InputChanged:Connect(function(input)
    if dragging and input==dragInput and dragStart then
        local d=input.Position-dragStart
        frame.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y)
    end
end))

local function stop()
    if not running then return end
    running=false
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(function() gui:Destroy() end)
    if G.PSICO_DW_NH_SCAN_STOP==stop then G.PSICO_DW_NH_SCAN_STOP=nil end
end
G.PSICO_DW_NH_SCAN_STOP=stop
addConn(close.MouseButton1Click:Connect(stop))

resolve()
hookNitro()
mark("START","scanner iniciado; menu principal foi fechado")

addConn(RunService.Heartbeat:Connect(function(dt)
    if not running then return end
    resolveAcc += dt
    telemetryAcc += dt
    monitorAcc += dt
    if resolveAcc>=1 then
        resolveAcc=0
        local oldNitro=nitroValue
        resolve()
        if nitroValue and nitroValue~=oldNitro then hookNitro() end
        status.Text=string.format("Fase: %s | carro: %s | ctrl: %s\nNitro: %s | candidatos monitorados: %d",phase,vehicle and vehicle.Name or "nenhum",controller and "OK" or "--",nitroOn() and "ATIVO" or "off",#runtimeCandidates)
    end
    if telemetryAcc>=0.05 then telemetryAcc=0 telemetry() end
    if monitorAcc>=0.10 then monitorAcc=0 monitorCandidates() end
end))
