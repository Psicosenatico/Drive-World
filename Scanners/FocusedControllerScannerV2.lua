--[[
PSICOSENATICO | Drive World Focused Controller Scanner V2

Objetivo:
- localizar o controlador Lua EXATO do carro em que o jogador está sentado
- relacionar wheelData / traction / engineSound / engine / TorqueCurve
- registrar campos que mudam durante TURBO, CURVA e ACEL
- capturar automaticamente o instante em que States.Nitrous muda

Nao altera valores do carro.
Exporta JSON para analise.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local LP = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_DW_FOCUSED_STOP) == "function" then
    pcall(G.PSICO_DW_FOCUSED_STOP)
end

local START = os.clock()
local SESSION = tostring(os.time())
local FILE_NAME = "DriveWorld_FocusedScan_" .. SESSION .. ".json"
local running = true
local phase = "START"
local conns = {}
local vehicle, seat, root
local controller
local controllerId
local liveLast = {}
local tableIds = setmetatable({}, {__mode = "k"})
local idCounter = 0

local DATA = {
    version = "DriveWorldFocusedControllerScannerV2",
    session = SESSION,
    placeId = game.PlaceId,
    jobId = game.JobId,
    phases = {},
    vehicle = {},
    discoveries = {},
    captures = {},
    liveChanges = {},
    nitrousEvents = {},
    errors = {},
}

local function tnow()
    return math.floor((os.clock() - START) * 1000 + 0.5) / 1000
end

local function addConn(c)
    conns[#conns+1] = c
    return c
end

local function safe(v)
    local ok, r = pcall(function()
        if typeof(v) == "Instance" then
            return v:GetFullName()
        end
        return tostring(v)
    end)
    return ok and r or "<error>"
end

local function getId(tbl)
    if type(tbl) ~= "table" then return nil end
    local id = tableIds[tbl]
    if not id then
        idCounter += 1
        id = "T" .. tostring(idCounter) .. ":" .. tostring(tbl)
        tableIds[tbl] = id
    end
    return id
end

local function isDesc(inst, model)
    if typeof(inst) ~= "Instance" or not model then return false end
    local ok, result = pcall(function()
        return inst == model or inst:IsDescendantOf(model)
    end)
    return ok and result
end

local function findVehicle()
    local char = LP and LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local s = hum and hum.SeatPart
    if not s then return nil end

    local cars = workspace:FindFirstChild("Cars")
    local p = s
    while p and p ~= workspace do
        if p:IsA("Model") and ((cars and p.Parent == cars) or p:FindFirstChild("Wheels") or p:FindFirstChild("Tuning")) then
            return p, s, p:FindFirstChild("Main") or p.PrimaryPart
        end
        p = p.Parent
    end
    return nil
end

local function serialize(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local tv = typeof(v)

    if tv == "nil" or tv == "boolean" or tv == "number" or tv == "string" then
        if tv == "string" and #v > 500 then
            return v:sub(1,500) .. "...<truncated>"
        end
        return v
    end

    if tv == "Instance" then return safe(v) end
    if tv == "Vector3" then return {x=v.X, y=v.Y, z=v.Z} end
    if tv == "CFrame" then local p = v.Position return {x=p.X, y=p.Y, z=p.Z} end
    if tv == "Color3" then return {r=v.R, g=v.G, b=v.B} end

    if tv == "function" then
        local out = {id=tostring(v)}
        if debug and type(debug.getinfo) == "function" then
            pcall(function()
                local info = debug.getinfo(v)
                if type(info) == "table" then
                    out.name = info.name
                    out.source = info.source or info.short_src
                    out.linedefined = info.linedefined
                end
            end)
        end
        return out
    end

    if tv == "table" then
        if seen[v] then return {ref=getId(v)} end
        if depth >= 3 then return {ref=getId(v), truncated=true} end
        seen[v] = true
        local out = {__id=getId(v)}
        local n = 0
        for k,val in pairs(v) do
            n += 1
            if n > 100 then out["..."] = "truncated" break end
            out[tostring(k)] = serialize(val, depth+1, seen)
        end
        seen[v] = nil
        return out
    end

    return safe(v)
end

local function tableHasVehicleRef(tbl, depth, seen)
    if type(tbl) ~= "table" or not vehicle then return false end
    depth = depth or 0
    seen = seen or {}
    if seen[tbl] or depth > 2 then return false end
    seen[tbl] = true

    local checked = 0
    for k,v in pairs(tbl) do
        checked += 1
        if checked > 120 then break end
        if isDesc(k, vehicle) or isDesc(v, vehicle) then seen[tbl] = nil return true end
        if type(v) == "string" and string.find(v, vehicle:GetFullName(), 1, true) then seen[tbl] = nil return true end
        if type(v) == "table" and tableHasVehicleRef(v, depth+1, seen) then seen[tbl] = nil return true end
    end
    seen[tbl] = nil
    return false
end

local function wheelDataMatches(wd)
    if type(wd) ~= "table" or not vehicle then return false end
    local hits = 0
    for _, w in pairs(wd) do
        if type(w) == "table" then
            for _,v in pairs(w) do
                if isDesc(v, vehicle) then
                    hits += 1
                    break
                elseif type(v) == "string" and string.find(v, vehicle:GetFullName(), 1, true) then
                    hits += 1
                    break
                end
            end
        end
    end
    return hits >= 2
end

local function scoreController(tbl)
    if type(tbl) ~= "table" then return -1 end
    local score = 0
    local ok = pcall(function()
        if type(rawget(tbl, "wheelData")) == "table" then
            score += 20
            if wheelDataMatches(rawget(tbl, "wheelData")) then score += 100 end
        end
        if rawget(tbl, "traction") ~= nil then score += 8 end
        if rawget(tbl, "gear") ~= nil then score += 5 end
        if rawget(tbl, "steer") ~= nil then score += 4 end
        if rawget(tbl, "steerInput") ~= nil then score += 4 end
        if type(rawget(tbl, "engineSound")) == "table" then score += 8 end
        if type(rawget(tbl, "cachedGears")) == "table" then score += 5 end
        if type(rawget(tbl, "nitrousEffects")) == "table" then score += 6 end
        if tableHasVehicleRef(tbl, 1) then score += 20 end
    end)
    return ok and score or -1
end

local function discoverController(reason)
    vehicle, seat, root = findVehicle()
    if not vehicle then
        DATA.errors[#DATA.errors+1] = {t=tnow(), phase=phase, where="discover", error="vehicle not found"}
        return nil
    end

    DATA.vehicle = {name=vehicle.Name, path=safe(vehicle), seat=safe(seat), root=safe(root)}

    if type(getgc) ~= "function" then
        DATA.errors[#DATA.errors+1] = {t=tnow(), phase=phase, where="discover", error="getgc unavailable"}
        return nil
    end

    local ok, objects = pcall(getgc, true)
    if not ok or type(objects) ~= "table" then ok, objects = pcall(getgc) end
    if not ok or type(objects) ~= "table" then return nil end

    local best, bestScore = nil, -1
    local candidates = {}
    for _,obj in ipairs(objects) do
        if type(obj) == "table" then
            local s = scoreController(obj)
            if s >= 20 then candidates[#candidates+1] = {id=getId(obj), score=s} end
            if s > bestScore then best, bestScore = obj, s end
        end
    end

    table.sort(candidates, function(a,b) return a.score > b.score end)
    while #candidates > 20 do table.remove(candidates) end

    if best and bestScore >= 50 then
        controller = best
        controllerId = getId(best)
    end

    DATA.discoveries[#DATA.discoveries+1] = {
        t=tnow(), phase=phase, reason=reason,
        selected=controllerId, selectedScore=bestScore, candidates=candidates,
    }
    return controller
end

local function scalarSnapshot(tbl)
    local out = {}
    if type(tbl) ~= "table" then return out end
    local count = 0
    for k,v in pairs(tbl) do
        count += 1
        if count > 180 then break end
        local tv = typeof(v)
        if tv == "number" or tv == "boolean" or tv == "string" then
            out[tostring(k)] = v
        elseif tv == "Instance" then
            out[tostring(k)] = safe(v)
        end
    end
    return out
end

local function capture(label, deep)
    if not controller or not vehicle or not vehicle.Parent then
        discoverController("capture:" .. tostring(label))
    end

    local item = {
        t=tnow(), phase=phase, label=label,
        vehicle=vehicle and safe(vehicle) or nil,
        controllerId=controllerId,
        controllerScalars=controller and scalarSnapshot(controller) or {},
    }

    if controller then
        local wheelData = rawget(controller, "wheelData")
        local engineSound = rawget(controller, "engineSound")
        item.relations = {
            wheelData=type(wheelData)=="table" and getId(wheelData) or safe(wheelData),
            engineSound=type(engineSound)=="table" and getId(engineSound) or safe(engineSound),
        }
        if deep then
            item.controller = serialize(controller, 0, {})
        else
            item.wheelData = type(wheelData)=="table" and serialize(wheelData,0,{}) or nil
            item.engineSound = type(engineSound)=="table" and serialize(engineSound,0,{}) or nil
        end
    end

    if type(getgc) == "function" then
        local ok, objects = pcall(getgc, true)
        if not ok then ok, objects = pcall(getgc) end
        if ok and type(objects) == "table" then
            local special = {}
            for _,obj in ipairs(objects) do
                if type(obj) == "table" then
                    local torque = rawget(obj,"TorqueCurve")
                    local setNitrous = rawget(obj,"SetNitrous")
                    local tractionMultiplier = rawget(obj,"tractionMultiplier")
                    if type(torque)=="table" or type(setNitrous)=="function" or tractionMultiplier ~= nil then
                        local relevant = tableHasVehicleRef(obj,2)
                        if type(setNitrous)=="function" then
                            local parent = rawget(obj,"parent")
                            relevant = relevant or isDesc(parent, vehicle)
                        end
                        if type(torque)=="table" then relevant = true end
                        if relevant then
                            special[#special+1] = {id=getId(obj), data=serialize(obj,0,{})}
                            if #special >= 30 then break end
                        end
                    end
                end
            end
            item.specialTables = special
        end
    end

    DATA.captures[#DATA.captures+1] = item
end

local function mark(newPhase, instruction)
    phase = newPhase
    DATA.phases[#DATA.phases+1] = {phase=newPhase, instruction=instruction, t=tnow()}
    discoverController("mark:" .. newPhase)
    capture("MARK_" .. newPhase, true)
end

local function save()
    local ok, encoded = pcall(HttpService.JSONEncode, HttpService, DATA)
    if ok and type(writefile) == "function" then pcall(writefile, FILE_NAME, encoded) end
    return ok, encoded
end

discoverController("start")
capture("START", true)

local nitrousBound = nil
local function bindNitrous()
    if not vehicle then return end
    local states = vehicle:FindFirstChild("States")
    local nit = states and states:FindFirstChild("Nitrous")
    if nit and nit:IsA("BoolValue") and nit ~= nitrousBound then
        nitrousBound = nit
        addConn(nit:GetPropertyChangedSignal("Value"):Connect(function()
            DATA.nitrousEvents[#DATA.nitrousEvents+1] = {t=tnow(), phase=phase, value=nit.Value}
            task.defer(function()
                capture("NITROUS_" .. tostring(nit.Value), true)
                save()
            end)
        end))
    end
end
bindNitrous()

local lastTick = 0
addConn(RunService.Heartbeat:Connect(function()
    if not running then return end
    local now = os.clock()
    if now - lastTick < 0.12 then return end
    lastTick = now

    if (not vehicle) or (not vehicle.Parent) or (not controller) then
        discoverController("heartbeat")
        bindNitrous()
    end

    if controller then
        local s = scalarSnapshot(controller)
        for k,v in pairs(s) do
            local old = liveLast[k]
            if old ~= nil and old ~= v then
                DATA.liveChanges[#DATA.liveChanges+1] = {t=tnow(), phase=phase, key=k, old=old, value=v}
                if #DATA.liveChanges > 5000 then table.remove(DATA.liveChanges, 1) end
            end
            liveLast[k] = v
        end
    end
end))

local old = CoreGui:FindFirstChild("PSICO_DW_FOCUSED_V2")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "PSICO_DW_FOCUSED_V2"
gui.ResetOnSpawn = false
gui.Parent = CoreGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(330, 310)
frame.Position = UDim2.new(0.5, -165, 0.5, -155)
frame.BackgroundColor3 = Color3.fromRGB(15,18,28)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0,12)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,-20,0,42)
title.Position = UDim2.fromOffset(10,7)
title.BackgroundTransparency = 1
title.Text = "Drive World Focused Scanner V2"
title.TextColor3 = Color3.new(1,1,1)
title.TextSize = 18
title.Font = Enum.Font.GothamBold
title.Parent = frame

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1,-20,0,40)
status.Position = UDim2.fromOffset(10,46)
status.BackgroundTransparency = 1
status.TextWrapped = true
status.TextColor3 = Color3.fromRGB(190,205,255)
status.TextSize = 12
status.Font = Enum.Font.Gotham
status.Parent = frame

local function refresh()
    status.Text = string.format(
        "Carro: %s | Controller: %s\nFase: %s | Capturas: %d | Mudancas: %d",
        vehicle and vehicle.Name or "?",
        controllerId and "OK" or "NAO ENCONTRADO",
        phase,
        #DATA.captures,
        #DATA.liveChanges
    )
end
refresh()

local function button(text, y, callback)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1,-20,0,37)
    b.Position = UDim2.fromOffset(10,y)
    b.BackgroundColor3 = Color3.fromRGB(30,40,65)
    b.BorderSizePixel = 0
    b.TextColor3 = Color3.new(1,1,1)
    b.TextSize = 14
    b.Font = Enum.Font.GothamSemibold
    b.Text = text
    b.Parent = frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,8)
    b.MouseButton1Click:Connect(function()
        callback()
        refresh()
    end)
end

button("1. BASE", 92, function()
    mark("BASE", "parado ou dirigindo normal")
end)

button("2. TURBO — depois segure o nitro", 135, function()
    mark("TURBO", "ative e segure o nitro alguns segundos")
end)

button("3. CURVA — provoque o deslize", 178, function()
    mark("CURVA", "faca curva forte onde costuma deslizar")
end)

button("4. ACEL — acelere forte do zero", 221, function()
    mark("ACEL", "acelere forte desde baixa velocidade")
end)

button("5. EXPORTAR JSON", 264, function()
    capture("EXPORT", true)
    local ok = save()
    if ok then
        status.Text = "EXPORTADO: " .. FILE_NAME
    else
        status.Text = "Falha ao exportar; veja console."
    end
end)

task.spawn(function()
    while running do
        task.wait(2)
        refresh()
        save()
    end
end)

G.PSICO_DW_FOCUSED_STOP = function()
    if not running then return end
    running = false
    phase = "STOP"
    capture("STOP", true)
    save()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    if gui and gui.Parent then gui:Destroy() end
end

print("[PSICO] Focused Controller Scanner V2 ativo")
print("[PSICO] Arquivo:", FILE_NAME)
