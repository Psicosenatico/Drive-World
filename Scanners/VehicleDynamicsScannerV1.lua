--[[
PSICOSENATICO | Vehicle Dynamics Scanner V1
Pesquisa client-side para montar um menu de carro com base em dados reais.

Objetivos:
  1) identificar turbo/nitro/boost
  2) identificar aderencia / deslize / drift / friction
  3) identificar aceleracao / torque / horsepower / throttle

Fluxo sugerido:
  - entre no carro antes de iniciar
  - BASE: dirija normalmente alguns segundos
  - TURBO: marque e use o turbo manualmente
  - CURVA: marque e faca uma curva onde o carro costuma deslizar
  - ACEL: marque e acelere forte a partir de baixa velocidade
  - EXPORTAR: gera JSON com telemetria, mudancas, remotes e tabelas relevantes

O scanner nao altera fisica nem valores do carro.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local LP = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_VEHICLE_SCAN_STOP) == "function" then
    pcall(G.PSICO_VEHICLE_SCAN_STOP)
end

local START_CLOCK = os.clock()
local SESSION_ID = tostring(os.time())
local FILE_NAME = "DriveWorld_VehicleScan_" .. SESSION_ID .. ".json"
local AUTOSAVE_INTERVAL = 5
local TELEMETRY_INTERVAL = 0.15
local MAX_TELEMETRY = 12000
local MAX_CHANGES = 8000
local MAX_REMOTES = 2500
local MAX_GC_HITS_PER_MARK = 600

local running = true
local phase = "START"
local vehicle = nil
local vehicleSeat = nil
local rootPart = nil
local connections = {}
local watched = setmetatable({}, {__mode = "k"})
local lastPhysical = setmetatable({}, {__mode = "k"})
local oldNamecall = nil
local remoteHookInstalled = false
local lastTelemetry = 0
local lastAutosave = 0
local statusLabel = nil

local DATA = {
    version = "VehicleDynamicsScannerV1",
    session = SESSION_ID,
    placeId = game.PlaceId,
    jobId = game.JobId,
    startedUnix = os.time(),
    player = LP and LP.Name or "?",
    phases = {},
    vehicle = {},
    changes = {},
    telemetry = {},
    remotes = {},
    gcMarks = {},
    snapshots = {},
    notes = {
        "BASE = direcao normal",
        "TURBO = usar turbo manualmente",
        "CURVA = provocar curva com deslize",
        "ACEL = acelerar forte desde baixa velocidade"
    }
}

local KEYWORDS = {
    "nitro", "nos", "turbo", "boost",
    "traction", "grip", "friction", "drift", "slide", "slip", "skid",
    "accel", "acceleration", "torque", "horsepower", "power", "throttle",
    "engine", "rpm", "gear", "speed", "velocity", "steer", "turn",
    "tire", "tyre", "wheel", "brake", "handling", "downforce"
}

local function elapsed()
    return math.floor((os.clock() - START_CLOCK) * 1000 + 0.5) / 1000
end

local function addConn(c)
    if c then
        connections[#connections + 1] = c
    end
    return c
end

local function norm(s)
    return string.lower(tostring(s or "")):gsub("[%s_%-%./]", "")
end

local function relevantName(s)
    local n = norm(s)
    for _, k in ipairs(KEYWORDS) do
        if n:find(k, 1, true) then
            return true
        end
    end
    return false
end

local function primitive(v)
    local t = typeof(v)
    if t == "number" or t == "boolean" or t == "string" then
        local s = tostring(v)
        if #s > 180 then s = s:sub(1, 180) .. "..." end
        return s
    elseif t == "Vector3" then
        return {x=v.X, y=v.Y, z=v.Z}
    elseif t == "CFrame" then
        local p = v.Position
        return {x=p.X, y=p.Y, z=p.Z}
    elseif t == "PhysicalProperties" then
        return {
            density=v.Density,
            friction=v.Friction,
            elasticity=v.Elasticity,
            frictionWeight=v.FrictionWeight,
            elasticityWeight=v.ElasticityWeight
        }
    elseif t == "Instance" then
        local ok, full = pcall(function() return v:GetFullName() end)
        return ok and full or tostring(v)
    end
    return tostring(v)
end

local function safePath(obj)
    if not obj then return "nil" end
    local ok, path = pcall(function() return obj:GetFullName() end)
    return ok and path or tostring(obj)
end

local function setStatus(text)
    if statusLabel then
        statusLabel.Text = text
    end
    print("[VEHICLE-SCAN] " .. tostring(text))
end

local function pushLimited(list, item, max)
    if #list >= max then
        table.remove(list, 1)
    end
    list[#list + 1] = item
end

local function logChange(kind, obj, key, value, extra)
    pushLimited(DATA.changes, {
        t = elapsed(),
        phase = phase,
        kind = kind,
        path = safePath(obj),
        key = tostring(key),
        value = primitive(value),
        extra = extra
    }, MAX_CHANGES)
end

local function encodeData()
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(DATA)
    end)
    return ok and encoded or nil
end

local function saveFile()
    local encoded = encodeData()
    if not encoded then return false end
    if type(writefile) == "function" then
        local ok = pcall(writefile, FILE_NAME, encoded)
        return ok
    end
    return false
end

local function findVehicle()
    if not LP then return nil, nil end
    local char = LP.Character
    if not char then return nil, nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or not hum.SeatPart then return nil, nil end

    local seat = hum.SeatPart
    local model = seat:FindFirstAncestorOfClass("Model")
    if not model then return nil, seat end

    -- Se o primeiro Model for apenas um submodelo pequeno, sobe ate achar um modelo de veiculo mais completo.
    local cur = model
    for _ = 1, 4 do
        local parentModel = cur.Parent and cur.Parent:FindFirstAncestorOfClass("Model")
        if not parentModel or parentModel == workspace then break end
        local countCur, countParent = 0, 0
        pcall(function() countCur = #cur:GetDescendants() end)
        pcall(function() countParent = #parentModel:GetDescendants() end)
        if countParent > countCur + 10 then
            cur = parentModel
        else
            break
        end
    end

    return cur, seat
end

local function pickRoot(model, seat)
    if not model then return nil end
    if model.PrimaryPart then return model.PrimaryPart end
    if seat and seat:IsA("BasePart") then return seat end
    for _, name in ipairs({"Chassis", "Main", "Body", "Root", "HumanoidRootPart"}) do
        local p = model:FindFirstChild(name, true)
        if p and p:IsA("BasePart") then return p end
    end
    return model:FindFirstChildWhichIsA("BasePart", true)
end

local function vehicleSummary(model, seat)
    local out = {
        model = safePath(model),
        seat = safePath(seat),
        descendants = 0,
        relevant = {}
    }
    if not model then return out end
    local ok, desc = pcall(function() return model:GetDescendants() end)
    if ok then
        out.descendants = #desc
        for _, obj in ipairs(desc) do
            if relevantName(obj.Name) then
                out.relevant[#out.relevant + 1] = {
                    path = safePath(obj),
                    class = obj.ClassName
                }
                if #out.relevant >= 300 then break end
            end
        end
    end
    return out
end

local function snapshotRelevant(label)
    local snap = {
        t = elapsed(),
        phase = phase,
        label = label,
        values = {},
        attributes = {},
        physical = {}
    }

    if vehicle then
        for _, obj in ipairs(vehicle:GetDescendants()) do
            if obj:IsA("ValueBase") and relevantName(obj.Name) then
                snap.values[#snap.values + 1] = {
                    path = safePath(obj),
                    class = obj.ClassName,
                    value = primitive(obj.Value)
                }
            end

            local attrs = obj:GetAttributes()
            for k, v in pairs(attrs) do
                if relevantName(k) or relevantName(obj.Name) then
                    snap.attributes[#snap.attributes + 1] = {
                        path = safePath(obj),
                        key = k,
                        value = primitive(v)
                    }
                end
            end

            if obj:IsA("BasePart") and relevantName(obj.Name) then
                local cp = obj.CustomPhysicalProperties
                if cp then
                    snap.physical[#snap.physical + 1] = {
                        path = safePath(obj),
                        value = primitive(cp)
                    }
                end
            end
        end
    end

    DATA.snapshots[#DATA.snapshots + 1] = snap
end

local function watchObject(obj)
    if watched[obj] then return end
    watched[obj] = true

    if obj:IsA("ValueBase") then
        local shouldWatch = relevantName(obj.Name)
        if shouldWatch then
            logChange("initial-value", obj, "Value", obj.Value)
            addConn(obj.Changed:Connect(function(v)
                if running then logChange("value", obj, "Value", v) end
            end))
        end
    end

    local attrs = obj:GetAttributes()
    for key, value in pairs(attrs) do
        if relevantName(key) or relevantName(obj.Name) then
            logChange("initial-attribute", obj, key, value)
            addConn(obj:GetAttributeChangedSignal(key):Connect(function()
                if running then
                    logChange("attribute", obj, key, obj:GetAttribute(key))
                end
            end))
        end
    end

    if obj:IsA("VehicleSeat") then
        for _, prop in ipairs({"Throttle", "ThrottleFloat", "Steer", "SteerFloat", "MaxSpeed", "Torque", "TurnSpeed"}) do
            pcall(function()
                logChange("seat-initial", obj, prop, obj[prop])
                addConn(obj:GetPropertyChangedSignal(prop):Connect(function()
                    if running then logChange("seat-property", obj, prop, obj[prop]) end
                end))
            end)
        end
    end

    if obj:IsA("BasePart") then
        local cp = obj.CustomPhysicalProperties
        if cp then
            lastPhysical[obj] = tostring(cp)
        end
    end
end

local function bindVehicle(model, seat)
    vehicle = model
    vehicleSeat = seat
    rootPart = pickRoot(model, seat)
    DATA.vehicle = vehicleSummary(model, seat)
    DATA.vehicle.root = safePath(rootPart)

    if not model then
        setStatus("Nenhum carro detectado. Entre no carro e reinicie o scanner.")
        return
    end

    for _, obj in ipairs(model:GetDescendants()) do
        watchObject(obj)
    end
    watchObject(model)

    addConn(model.DescendantAdded:Connect(function(obj)
        if running then
            watchObject(obj)
            if relevantName(obj.Name) then
                logChange("descendant-added", obj, "ClassName", obj.ClassName)
            end
        end
    end))

    addConn(model.DescendantRemoving:Connect(function(obj)
        if running and relevantName(obj.Name) then
            logChange("descendant-removing", obj, "ClassName", obj.ClassName)
        end
    end))

    setStatus("Carro detectado: " .. model.Name)
end

local function safeArg(v, depth)
    depth = depth or 0
    if depth > 2 then return "<depth>" end
    local t = typeof(v)
    if t == "Instance" then return safePath(v) end
    if t == "number" or t == "boolean" then return v end
    if t == "string" then
        if #v > 160 then return v:sub(1,160) .. "..." end
        return v
    end
    if t == "Vector3" then return {x=v.X,y=v.Y,z=v.Z} end
    if t == "CFrame" then local p=v.Position return {x=p.X,y=p.Y,z=p.Z} end
    if type(v) == "table" then
        local out, n = {}, 0
        for k, x in pairs(v) do
            n += 1
            if n > 16 then out["..."] = "truncated" break end
            out[tostring(k)] = safeArg(x, depth + 1)
        end
        return out
    end
    return tostring(v)
end

local function installRemoteHook()
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return false
    end

    local handler
    handler = function(self, ...)
        local method = getnamecallmethod()
        if running and (method == "FireServer" or method == "InvokeServer") then
            local okRemote = typeof(self) == "Instance" and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction"))
            if okRemote then
                local args = {...}
                local packed = {}
                for i = 1, math.min(#args, 10) do packed[i] = safeArg(args[i]) end
                pushLimited(DATA.remotes, {
                    t = elapsed(),
                    phase = phase,
                    method = method,
                    remote = safePath(self),
                    args = packed
                }, MAX_REMOTES)
            end
        end
        return oldNamecall(self, ...)
    end

    local ok, original = pcall(function()
        return hookmetamethod(game, "__namecall", (newcclosure and newcclosure(handler)) or handler)
    end)
    if ok and type(original) == "function" then
        oldNamecall = original
        remoteHookInstalled = true
        return true
    end
    return false
end

local function scanGC(label)
    local mark = {
        t = elapsed(),
        phase = phase,
        label = label,
        supported = type(getgc) == "function",
        hits = {}
    }
    DATA.gcMarks[#DATA.gcMarks + 1] = mark

    if type(getgc) ~= "function" then return end

    local ok, objects = pcall(getgc, true)
    if not ok or type(objects) ~= "table" then return end

    local seenTables = setmetatable({}, {__mode = "k"})
    for _, obj in ipairs(objects) do
        if type(obj) == "table" and not seenTables[obj] then
            seenTables[obj] = true
            local hit = nil
            local n = 0
            local okTable = pcall(function()
                for k, v in pairs(obj) do
                    n += 1
                    if n > 220 then break end
                    if type(k) == "string" and relevantName(k) then
                        hit = hit or {id=tostring(obj), entries={}}
                        if #hit.entries < 28 then
                            hit.entries[#hit.entries + 1] = {
                                key = k,
                                value = safeArg(v, 0)
                            }
                        end
                    end
                end
            end)
            if okTable and hit then
                mark.hits[#mark.hits + 1] = hit
                if #mark.hits >= MAX_GC_HITS_PER_MARK then break end
            end
        end
    end
end

local function markPhase(newPhase, instruction)
    phase = newPhase
    DATA.phases[#DATA.phases + 1] = {
        t = elapsed(),
        phase = newPhase,
        instruction = instruction
    }
    snapshotRelevant(newPhase)
    scanGC(newPhase)
    saveFile()
    setStatus("FASE: " .. newPhase .. " | " .. instruction)
end

local function telemetryStep()
    if not rootPart or not rootPart.Parent then
        if vehicle then rootPart = pickRoot(vehicle, vehicleSeat) end
        if not rootPart then return end
    end

    local lv = rootPart.AssemblyLinearVelocity
    local av = rootPart.AssemblyAngularVelocity
    local cf = rootPart.CFrame
    local forward = lv:Dot(cf.LookVector)
    local lateral = lv:Dot(cf.RightVector)

    local row = {
        t = elapsed(),
        phase = phase,
        speed = lv.Magnitude,
        forward = forward,
        lateral = lateral,
        vertical = lv.Y,
        angular = av.Magnitude,
        yawRate = av.Y
    }

    if vehicleSeat then
        pcall(function() row.throttle = vehicleSeat.ThrottleFloat end)
        pcall(function() row.steer = vehicleSeat.SteerFloat end)
    end

    pushLimited(DATA.telemetry, row, MAX_TELEMETRY)
end

local function pollPhysical()
    if not vehicle then return end
    for obj, prev in pairs(lastPhysical) do
        if obj and obj.Parent and obj:IsA("BasePart") then
            local cp = obj.CustomPhysicalProperties
            local now = cp and tostring(cp) or "nil"
            if now ~= prev then
                lastPhysical[obj] = now
                logChange("physical", obj, "CustomPhysicalProperties", cp)
            end
        end
    end
end

-- ================= UI =================

local gui = Instance.new("ScreenGui")
gui.Name = "PsicoVehicleDynamicsScanner"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false

local parentOk = pcall(function() gui.Parent = CoreGui end)
if not parentOk or not gui.Parent then
    gui.Parent = LP:WaitForChild("PlayerGui")
end

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.Size = UDim2.fromOffset(390, 245)
frame.Position = UDim2.new(0.5, -195, 0.12, 0)
frame.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 34)
title.Position = UDim2.fromOffset(10, 6)
title.BackgroundTransparency = 1
title.Text = "VEHICLE DYNAMICS SCANNER V1"
title.TextColor3 = Color3.fromRGB(235, 240, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -20, 0, 42)
statusLabel.Position = UDim2.fromOffset(10, 38)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Detectando carro..."
statusLabel.TextColor3 = Color3.fromRGB(185, 205, 230)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Parent = frame

local buttons = Instance.new("Frame")
buttons.Size = UDim2.new(1, -20, 0, 148)
buttons.Position = UDim2.fromOffset(10, 86)
buttons.BackgroundTransparency = 1
buttons.Parent = frame

local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.new(0.32, 0, 0, 42)
grid.CellPadding = UDim2.new(0.02, 0, 0, 7)
grid.FillDirectionMaxCells = 3
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = buttons

local function addButton(text, order, callback)
    local b = Instance.new("TextButton")
    b.LayoutOrder = order
    b.BackgroundColor3 = Color3.fromRGB(36, 45, 61)
    b.BorderSizePixel = 0
    b.TextColor3 = Color3.fromRGB(245, 247, 255)
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 12
    b.Text = text
    b.Parent = buttons
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 8)
    c.Parent = b
    addConn(b.MouseButton1Click:Connect(callback))
    return b
end

addButton("1 BASE", 1, function()
    markPhase("BASE", "Dirija normalmente por alguns segundos")
end)

addButton("2 TURBO", 2, function()
    markPhase("TURBO", "Agora use o turbo manualmente")
end)

addButton("3 CURVA", 3, function()
    markPhase("CURVA", "Faca uma curva onde o carro costuma deslizar")
end)

addButton("4 ACEL", 4, function()
    markPhase("ACEL", "Acelere forte desde baixa velocidade")
end)

addButton("EXPORTAR", 5, function()
    snapshotRelevant("EXPORT")
    scanGC("EXPORT")
    local ok = saveFile()
    local encoded = encodeData()
    if encoded and type(setclipboard) == "function" then
        pcall(setclipboard, encoded)
    end
    setStatus(ok and ("Exportado: " .. FILE_NAME) or "JSON pronto; writefile indisponivel")
end)

addButton("PARAR", 6, function()
    if type(G.PSICO_VEHICLE_SCAN_STOP) == "function" then
        G.PSICO_VEHICLE_SCAN_STOP()
    end
end)

-- Drag simples, compativel com mouse/toque
local dragging, dragStart, startPos, dragInput
addConn(frame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = frame.Position
        addConn(input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end))
    end
end))
addConn(frame.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end))
addConn(UserInputService.InputChanged:Connect(function(input)
    if dragging and input == dragInput then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end))

-- ================= START =================

local detectedVehicle, detectedSeat = findVehicle()
bindVehicle(detectedVehicle, detectedSeat)
local hookOk = installRemoteHook()
DATA.remoteHook = hookOk

snapshotRelevant("START")
scanGC("START")
DATA.phases[#DATA.phases + 1] = {t=elapsed(), phase="START", instruction="scanner iniciado"}
saveFile()

addConn(RunService.Heartbeat:Connect(function()
    if not running then return end
    local now = os.clock()
    if now - lastTelemetry >= TELEMETRY_INTERVAL then
        lastTelemetry = now
        telemetryStep()
    end
    if now - lastAutosave >= AUTOSAVE_INTERVAL then
        lastAutosave = now
        pollPhysical()
        saveFile()
    end
end))

G.PSICO_VEHICLE_SCAN_DATA = DATA
G.PSICO_VEHICLE_SCAN_FILE = FILE_NAME
G.PSICO_VEHICLE_SCAN_STOP = function()
    if not running then return end
    running = false
    phase = "STOP"
    DATA.phases[#DATA.phases + 1] = {t=elapsed(), phase="STOP", instruction="scanner encerrado"}
    snapshotRelevant("STOP")
    scanGC("STOP")
    saveFile()

    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end

    if remoteHookInstalled and oldNamecall and type(hookmetamethod) == "function" then
        pcall(function()
            hookmetamethod(game, "__namecall", oldNamecall)
        end)
    end

    pcall(function() gui:Destroy() end)
    print("[VEHICLE-SCAN] Encerrado. Arquivo: " .. FILE_NAME)
end

setStatus((vehicle and ("Pronto | " .. vehicle.Name) or "Sem carro detectado") .. (hookOk and " | Remote hook ON" or " | Remote hook OFF"))
print("[VEHICLE-SCAN] Arquivo de saida: " .. FILE_NAME)
