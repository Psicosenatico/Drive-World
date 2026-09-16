-- PSICOSENATICO | Drive World Vehicle Menu V5.3
-- Base: V5 original comprovadamente funcional.
-- Correcao: PRESSAO+ substituido por implementacao independente, sem patch/gsub em runtime.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_DRIVE_V53_STOP) == "function" then
    pcall(G.PSICO_DRIVE_V53_STOP)
end

local BASE_URL = "https://raw.githubusercontent.com/Psicosenatico/Drive-World/8a326ee9a89d7080667d5a4a40ddfc6506a1869b/Script/main.lua"
local okSource, baseSource = pcall(function()
    return game:HttpGet(BASE_URL)
end)
if not okSource or type(baseSource) ~= "string" or #baseSource < 1000 then
    error("Drive World V5.3: falha ao baixar a base V5")
end

local baseFn, baseCompileError = loadstring(baseSource)
if not baseFn then
    error("Drive World V5.3: base V5 nao compilou: " .. tostring(baseCompileError))
end

local okBase, baseRunError = pcall(baseFn)
if not okBase then
    error("Drive World V5.3: base V5 falhou: " .. tostring(baseRunError))
end

local running = true
local connections = {}
local pressureEnabled = false
local currentVehicle = nil
local currentSeat = nil
local controller = nil
local engineConfig = nil
local resolveTimer = 999
local customPressureButton = nil
local originalPressureButton = nil
local menuGui = nil

local TORQUE_MULTIPLIER = 1.65
local PRESSURE_ACCEL = 58
local START_FORWARD_ASSIST = 0.75

local originalTorque = setmetatable({}, {__mode = "k"})

local function connect(signal, fn)
    local c = signal:Connect(fn)
    connections[#connections + 1] = c
    return c
end

local function getVehicleAndSeat()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if not seat then return nil, nil end

    local cars = workspace:FindFirstChild("Cars")
    if cars then
        local node = seat
        while node and node.Parent and node.Parent ~= cars do
            node = node.Parent
        end
        if node and node.Parent == cars and node:IsA("Model") then
            return node, seat
        end
    end

    local node = seat
    while node and node ~= workspace do
        if node:IsA("Model") and node:FindFirstChild("Main") and node:FindFirstChild("Wheels") then
            return node, seat
        end
        node = node.Parent
    end

    return seat:FindFirstAncestorOfClass("Model"), seat
end

local function getMainPart(vehicle)
    if not vehicle then return nil end
    local main = vehicle:FindFirstChild("Main")
    if main and main:IsA("BasePart") then return main end
    if vehicle.PrimaryPart and vehicle.PrimaryPart:IsA("BasePart") then return vehicle.PrimaryPart end
    return vehicle:FindFirstChildWhichIsA("BasePart", true)
end

local function getGCObjects()
    local fn = rawget(G, "getgc") or getgc
    if type(fn) ~= "function" then return {} end

    local ok, result = pcall(fn, true)
    if not ok or type(result) ~= "table" then
        ok, result = pcall(fn)
    end
    if ok and type(result) == "table" then return result end
    return {}
end

local function scoreController(t, vehicle)
    if type(t) ~= "table" or not vehicle then return -1 end
    local score = 0
    if rawget(t, "model") == vehicle then score = score + 140 end
    if rawget(t, "carName") == vehicle.Name then score = score + 35 end
    if type(rawget(t, "wheelData")) == "table" then score = score + 35 end
    if type(rawget(t, "config")) == "table" then score = score + 25 end
    if type(rawget(t, "engineSound")) == "table" then score = score + 20 end
    if rawget(t, "currentDriver") == LocalPlayer then score = score + 45 end
    if rawget(t, "owner") == LocalPlayer then score = score + 20 end
    return score
end

local function findController(vehicle)
    if controller and scoreController(controller, vehicle) >= 200 then return controller end
    local best, bestScore = nil, -1
    for _, obj in ipairs(getGCObjects()) do
        if type(obj) == "table" then
            local score = scoreController(obj, vehicle)
            if score > bestScore then
                best, bestScore = obj, score
            end
        end
    end
    if bestScore >= 180 then return best end
    return nil
end

local function scoreEngine(t, ctrl)
    if type(t) ~= "table" or type(ctrl) ~= "table" then return -1 end
    if type(rawget(t, "TorqueCurve")) ~= "table" then return -1 end
    local score = 15
    local selected = rawget(t, "selectedMods")
    local config = rawget(ctrl, "config")
    local stockEngine = type(config) == "table" and rawget(config, "StockEngine") or nil
    if type(selected) == "table" then
        score = score + 25
        if stockEngine and rawget(selected, "Profile") == stockEngine then score = score + 160 end
    end
    if type(rawget(t, "GetTorqueAtRPM")) == "function" then score = score + 35 end
    if type(rawget(t, "GetMaxTorque")) == "function" then score = score + 20 end
    if type(rawget(t, "GetMaxPower")) == "function" then score = score + 20 end
    if type(rawget(t, "ApplyUpgradesFromTuning")) == "function" then score = score + 20 end
    return score
end

local function findEngine(ctrl)
    if engineConfig and scoreEngine(engineConfig, ctrl) >= 180 then return engineConfig end
    local best, bestScore = nil, -1
    for _, obj in ipairs(getGCObjects()) do
        if type(obj) == "table" then
            local score = scoreEngine(obj, ctrl)
            if score > bestScore then
                best, bestScore = obj, score
            end
        end
    end
    if bestScore >= 180 then return best end
    return nil
end

local function rememberTorque(engine)
    if type(engine) ~= "table" or originalTorque[engine] ~= nil then return end
    local curve = rawget(engine, "TorqueCurve")
    if type(curve) ~= "table" then return end
    local copy = {}
    for k, v in pairs(curve) do
        if type(v) == "number" then copy[k] = v end
    end
    originalTorque[engine] = copy
end

local function restoreTorque(engine)
    if type(engine) ~= "table" then return end
    local saved = originalTorque[engine]
    local curve = rawget(engine, "TorqueCurve")
    if type(saved) ~= "table" or type(curve) ~= "table" then return end
    for k, v in pairs(saved) do curve[k] = v end
end

local function applyTorque(engine)
    if type(engine) ~= "table" then return end
    rememberTorque(engine)
    local saved = originalTorque[engine]
    local curve = rawget(engine, "TorqueCurve")
    if type(saved) ~= "table" or type(curve) ~= "table" then return end
    for k, v in pairs(saved) do
        curve[k] = pressureEnabled and (v * TORQUE_MULTIPLIER) or v
    end
end

local function resolveTargets(force)
    local vehicle, seat = getVehicleAndSeat()
    if vehicle ~= currentVehicle then
        if engineConfig then restoreTorque(engineConfig) end
        currentVehicle = vehicle
        currentSeat = seat
        controller = nil
        engineConfig = nil
    else
        currentSeat = seat
    end
    if not currentVehicle then return end
    if force or not controller then controller = findController(currentVehicle) end
    if controller and (force or not engineConfig) then engineConfig = findEngine(controller) end
    if engineConfig then
        rememberTorque(engineConfig)
        applyTorque(engineConfig)
    end
end

local function getBaseTopSpeed()
    if type(controller) ~= "table" then return 280 end
    local cached = rawget(controller, "cachedGears")
    local tops = type(cached) == "table" and rawget(cached, "topSpeeds") or nil
    local maxSpeed = 0
    if type(tops) == "table" then
        for _, v in pairs(tops) do
            if type(v) == "number" and v > maxSpeed then maxSpeed = v end
        end
    end
    if maxSpeed > 0 then return maxSpeed end
    local calc = rawget(controller, "calculatedTopSpeed")
    if type(calc) == "number" and calc > 0 then return calc end
    return 280
end

local function gearText()
    if type(controller) ~= "table" then return nil end
    local instrument = rawget(controller, "instrumentScreen")
    local label = type(instrument) == "table" and rawget(instrument, "currentGearLabel") or nil
    local text = nil
    if typeof(label) == "Instance" then
        pcall(function()
            if label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox") then
                text = label.Text
            end
        end)
    elseif type(label) == "string" then
        text = label
    end
    if type(text) == "string" then
        return string.lower(text):gsub("[%s%._%-]", "")
    end
    return nil
end

local function reverseOrNeutralConfirmed(forwardSpeed)
    if currentSeat and currentSeat:IsA("VehicleSeat") then
        local ok, seatThrottle = pcall(function() return currentSeat.ThrottleFloat end)
        if ok and type(seatThrottle) == "number" and seatThrottle < -0.04 then
            return true
        end
    end
    local text = gearText()
    if text then
        if text == "r" or text == "re" or text == "ré" or text:find("reverse", 1, true) then return true end
        if text == "n" or text:find("neutral", 1, true) then return true end
    end
    if type(controller) == "table" then
        local gear = tonumber(rawget(controller, "gear"))
        if gear and gear <= 0 then return true end
    end
    if forwardSpeed < -0.25 then return true end
    return false
end

local function applyForwardAssist(dt)
    if not pressureEnabled then return end
    if not currentVehicle or not controller then return end
    local main = getMainPart(currentVehicle)
    if not main or not main:IsDescendantOf(workspace) then return end
    local cf = main.CFrame
    local forwardSpeed = main.AssemblyLinearVelocity:Dot(cf.LookVector)
    if reverseOrNeutralConfirmed(forwardSpeed) then return end
    if forwardSpeed <= START_FORWARD_ASSIST then return end
    local baseTop = getBaseTopSpeed()
    local startTaper = baseTop * 0.68
    local factor = 1
    if forwardSpeed > startTaper then
        factor = math.clamp((baseTop - forwardSpeed) / math.max(baseTop - startTaper, 1), 0, 1)
    end
    if factor > 0 then
        main.AssemblyLinearVelocity = main.AssemblyLinearVelocity + cf.LookVector * (PRESSURE_ACCEL * factor * dt)
    end
end

local function locateMenu()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, root in ipairs({CoreGui, pg}) do
        if root then
            local candidate = root:FindFirstChild("PsicoDriveMenuV5")
            if candidate then return candidate end
        end
    end
    return nil
end

local function locatePressureButton(root)
    if not root then return nil end
    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("TextButton") then
            local text = string.upper(tostring(obj.Text or ""))
            if text:find("PRESSAO", 1, true) then return obj end
        end
    end
    return nil
end

local function installUIOverride()
    menuGui = locateMenu()
    if not menuGui then error("Drive World V5.3: menu V5 base nao foi encontrado") end
    for _, obj in ipairs(menuGui:GetDescendants()) do
        if obj:IsA("TextLabel") and tostring(obj.Text):find("DRIVE WORLD V5", 1, true) then
            obj.Text = "PSICOSENATICO • DRIVE WORLD V5.3"
            break
        end
    end
    originalPressureButton = locatePressureButton(menuGui)
    if not originalPressureButton then error("Drive World V5.3: botao PRESSAO+ da V5 nao foi encontrado") end
    originalPressureButton.Visible = false
    local button = originalPressureButton:Clone()
    button.Name = "PressureV53"
    button.Visible = true
    button.Text = "PRESSAO +: OFF"
    button.ZIndex = originalPressureButton.ZIndex + 10
    button.Parent = originalPressureButton.Parent
    customPressureButton = button
    connect(button.MouseButton1Click, function()
        pressureEnabled = not pressureEnabled
        button.Text = pressureEnabled and "PRESSAO +: ON" or "PRESSAO +: OFF"
        button.BackgroundColor3 = pressureEnabled and Color3.fromRGB(38, 115, 82) or Color3.fromRGB(70, 75, 92)
        resolveTargets(true)
        if engineConfig then applyTorque(engineConfig) end
    end)
end

local function stop()
    if not running then return end
    running = false
    pressureEnabled = false
    if engineConfig then restoreTorque(engineConfig) end
    if originalPressureButton and originalPressureButton.Parent then
        pcall(function() originalPressureButton.Visible = true end)
    end
    if customPressureButton and customPressureButton.Parent then
        pcall(function() customPressureButton:Destroy() end)
    end
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    if G.PSICO_DRIVE_V53_STOP == stop then G.PSICO_DRIVE_V53_STOP = nil end
end

G.PSICO_DRIVE_V53_STOP = stop

installUIOverride()
resolveTargets(true)

connect(RunService.Heartbeat, function(dt)
    if not running then return end
    resolveTimer = resolveTimer + dt
    if resolveTimer >= 1 then
        resolveTimer = 0
        resolveTargets(false)
        if engineConfig then applyTorque(engineConfig) end
        if menuGui and not menuGui.Parent then
            stop()
            return
        end
    end
    applyForwardAssist(dt)
end)
