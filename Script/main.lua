-- PSICOSENATICO | Drive World Vehicle Menu V4
-- Nitro infinito manual + aceleracao + 0 derrape revisado + dirigibilidade alta velocidade.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_DRIVE_MENU_STOP) == "function" then
    pcall(G.PSICO_DRIVE_MENU_STOP)
end
if type(G.PSICO_DW_NH_SCAN_STOP) == "function" then
    pcall(G.PSICO_DW_NH_SCAN_STOP)
end

local running = true
local connections = {}

local flags = {
    nitroInfinite = false,
    grip = false,
    pressure = false,
}

-- Calibracao baseada nos scans do Vulture.
local TORQUE_MULTIPLIER = 1.65
local PRESSURE_ACCEL = 58
local GRIP_MULTIPLIER = 2.15
local RELEASE_LATERAL_DAMP_MIN = 18
local RELEASE_LATERAL_DAMP_MAX = 31
local RELEASE_YAW_DAMP_MIN = 14
local RELEASE_YAW_DAMP_MAX = 25
local ACTIVE_SLIP_LIMIT = 0.12
local ACTIVE_EXCESS_DAMP = 8

local handlingPercent = 0

local currentVehicle
local currentSeat
local controller
local engineConfig
local nitroResourceTable
local resolveAccumulator = 999
local nitroSearchAccumulator = 999

local originalWheelMultiplier = setmetatable({}, {__mode = "k"})
local originalTorque = setmetatable({}, {__mode = "k"})
local originalControllerTraction = setmetatable({}, {__mode = "k"})
local originalSteering = setmetatable({}, {__mode = "k"})

local function addConnection(conn)
    connections[#connections + 1] = conn
    return conn
end

local function getCharacter()
    return LocalPlayer.Character
end

local function getVehicleAndSeat()
    local char = getCharacter()
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
    if rawget(t, "model") == vehicle then score += 140 end
    if rawget(t, "carName") == vehicle.Name then score += 35 end
    if type(rawget(t, "wheelData")) == "table" then score += 35 end
    if type(rawget(t, "config")) == "table" then score += 25 end
    if type(rawget(t, "engineSound")) == "table" then score += 20 end
    if rawget(t, "currentDriver") == LocalPlayer then score += 45 end
    if rawget(t, "owner") == LocalPlayer then score += 20 end
    return score
end

local function findController(vehicle)
    if controller and scoreController(controller, vehicle) >= 200 then return controller end

    local best, bestScore
    bestScore = -1
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
    local curve = rawget(t, "TorqueCurve")
    if type(curve) ~= "table" then return -1 end

    local score = 15
    local selected = rawget(t, "selectedMods")
    local config = rawget(ctrl, "config")
    local stockEngine = type(config) == "table" and rawget(config, "StockEngine") or nil

    if type(selected) == "table" then
        score += 25
        if stockEngine and rawget(selected, "Profile") == stockEngine then score += 160 end
    end
    if type(rawget(t, "GetTorqueAtRPM")) == "function" then score += 35 end
    if type(rawget(t, "GetMaxTorque")) == "function" then score += 20 end
    if type(rawget(t, "GetMaxPower")) == "function" then score += 20 end
    if type(rawget(t, "ApplyUpgradesFromTuning")) == "function" then score += 20 end
    if rawget(ctrl, "soundProfile") and rawget(t, "SoundProfile") == rawget(ctrl, "soundProfile") then score += 12 end
    return score
end

local function findEngine(ctrl)
    if engineConfig and scoreEngine(engineConfig, ctrl) >= 180 then return engineConfig end

    local best, bestScore
    bestScore = -1
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

local function findNitroResource()
    if type(nitroResourceTable) == "table" then
        local v = rawget(nitroResourceTable, "currentNitrousPercent")
        if type(v) == "number" then return nitroResourceTable end
    end

    local found
    for _, obj in ipairs(getGCObjects()) do
        if type(obj) == "table" then
            local v = rawget(obj, "currentNitrousPercent")
            if type(v) == "number" and v >= -0.05 and v <= 1.05 then
                found = obj
                break
            end
        end
    end
    nitroResourceTable = found
    return found
end

local function rememberTargets()
    if type(controller) == "table" then
        if originalControllerTraction[controller] == nil then
            local value = rawget(controller, "traction")
            if type(value) == "number" then originalControllerTraction[controller] = value end
        end

        local wheels = rawget(controller, "wheelData")
        if type(wheels) == "table" then
            for _, wheel in pairs(wheels) do
                if type(wheel) == "table" and originalWheelMultiplier[wheel] == nil then
                    local mult = rawget(wheel, "tractionMultiplier")
                    if type(mult) == "number" then originalWheelMultiplier[wheel] = mult end
                end
            end
        end

        if originalSteering[controller] == nil then
            local info = {}
            local cfg = rawget(controller, "config")
            if type(cfg) == "table" and type(rawget(cfg, "SteerAngle")) == "number" then
                info.config = cfg
                info.configAngle = rawget(cfg, "SteerAngle")
            end

            local vehicle = rawget(controller, "model")
            local tuning = typeof(vehicle) == "Instance" and vehicle:FindFirstChild("Tuning") or nil
            local suspension = tuning and tuning:FindFirstChild("SuspensionSettings")
            local mod = suspension and suspension:FindFirstChild("SteerModifier")
            local angle = suspension and suspension:FindFirstChild("SteerAngle")
            if mod and (mod:IsA("NumberValue") or mod:IsA("IntValue")) then
                info.modObj = mod
                info.modValue = mod.Value
            end
            if angle and (angle:IsA("NumberValue") or angle:IsA("IntValue")) then
                info.angleObj = angle
                info.angleValue = angle.Value
            end
            originalSteering[controller] = info
        end
    end

    if type(engineConfig) == "table" and originalTorque[engineConfig] == nil then
        local curve = rawget(engineConfig, "TorqueCurve")
        if type(curve) == "table" then
            local copy = {}
            for k, value in pairs(curve) do
                if type(value) == "number" then copy[k] = value end
            end
            originalTorque[engineConfig] = copy
        end
    end
end

local function restoreGripFor(ctrl)
    if type(ctrl) ~= "table" then return end
    local wheels = rawget(ctrl, "wheelData")
    if type(wheels) == "table" then
        for _, wheel in pairs(wheels) do
            if type(wheel) == "table" then
                local original = originalWheelMultiplier[wheel]
                if original ~= nil then rawset(wheel, "tractionMultiplier", original) end
            end
        end
    end
    local tr = originalControllerTraction[ctrl]
    if tr ~= nil then rawset(ctrl, "traction", tr) end
end

local function restorePressureFor(engine)
    if type(engine) ~= "table" then return end
    local originals = originalTorque[engine]
    local curve = rawget(engine, "TorqueCurve")
    if type(originals) == "table" and type(curve) == "table" then
        for k, base in pairs(originals) do curve[k] = base end
    end
end

local function restoreHandlingFor(ctrl)
    local info = type(ctrl) == "table" and originalSteering[ctrl] or nil
    if type(info) ~= "table" then return end
    if info.config and info.configAngle then rawset(info.config, "SteerAngle", info.configAngle) end
    if info.modObj and info.modObj.Parent then pcall(function() info.modObj.Value = info.modValue end) end
    if info.angleObj and info.angleObj.Parent then pcall(function() info.angleObj.Value = info.angleValue end) end
end

local function resolveTargets(force)
    local vehicle, seat = getVehicleAndSeat()
    if vehicle ~= currentVehicle then
        if controller then
            restoreGripFor(controller)
            restoreHandlingFor(controller)
        end
        if engineConfig then restorePressureFor(engineConfig) end

        currentVehicle = vehicle
        currentSeat = seat
        controller = nil
        engineConfig = nil
        nitroResourceTable = nil
    else
        currentSeat = seat
    end

    if not currentVehicle then return end
    if force or not controller then controller = findController(currentVehicle) end
    if controller and (force or not engineConfig) then engineConfig = findEngine(controller) end
    rememberTargets()
end

local function getBaseTopSpeed()
    if type(controller) ~= "table" then return 280 end

    local cached = rawget(controller, "cachedGears")
    local top = type(cached) == "table" and rawget(cached, "topSpeeds") or nil
    local maxSpeed = 0
    if type(top) == "table" then
        for _, v in pairs(top) do
            if type(v) == "number" and v > maxSpeed then maxSpeed = v end
        end
    end
    if maxSpeed > 0 then return maxSpeed end

    local calc = rawget(controller, "calculatedTopSpeed")
    if type(calc) == "number" and calc > 0 then return calc end
    return 280
end

local function getThrottleIntent()
    if currentSeat and currentSeat:IsA("VehicleSeat") then
        local ok, value = pcall(function() return currentSeat.ThrottleFloat end)
        if ok and type(value) == "number" and math.abs(value) > 0.01 then return value end
    end
    if type(controller) == "table" then
        local sound = rawget(controller, "engineSound")
        local value = type(sound) == "table" and rawget(sound, "throttle") or nil
        if type(value) == "number" then return value end
    end
    return 0
end

local function getSteerIntent()
    local seatValue = 0
    if currentSeat and currentSeat:IsA("VehicleSeat") then
        pcall(function() seatValue = currentSeat.SteerFloat end)
    end
    local ctrlValue = type(controller) == "table" and tonumber(rawget(controller, "steerInput")) or 0
    ctrlValue = ctrlValue or 0
    if math.abs(seatValue) >= math.abs(ctrlValue) then return seatValue end
    return ctrlValue
end

local function applyNitroInfinite()
    if not flags.nitroInfinite then return end
    local t = findNitroResource()
    if type(t) == "table" then
        rawset(t, "currentNitrousPercent", 1)
    end
end

local function applyGripSettings()
    if type(controller) ~= "table" then return end
    local wheels = rawget(controller, "wheelData")
    if type(wheels) == "table" then
        for _, wheel in pairs(wheels) do
            if type(wheel) == "table" then
                local base = originalWheelMultiplier[wheel]
                if flags.grip then
                    rawset(wheel, "tractionMultiplier", GRIP_MULTIPLIER)
                elseif base ~= nil then
                    rawset(wheel, "tractionMultiplier", base)
                end
            end
        end
    end
    if not flags.grip then
        local tr = originalControllerTraction[controller]
        if tr ~= nil then rawset(controller, "traction", tr) end
    end
end

local function applyPressureSettings()
    if type(engineConfig) ~= "table" then return end
    local originals = originalTorque[engineConfig]
    local curve = rawget(engineConfig, "TorqueCurve")
    if type(originals) ~= "table" or type(curve) ~= "table" then return end
    for key, base in pairs(originals) do
        curve[key] = flags.pressure and (base * TORQUE_MULTIPLIER) or base
    end
end

local function applyHandlingSettings()
    if type(controller) ~= "table" then return end
    local info = originalSteering[controller]
    if type(info) ~= "table" then return end

    local p = math.clamp(handlingPercent / 100, 0, 1)
    if info.config and info.configAngle then
        rawset(info.config, "SteerAngle", info.configAngle + (52 - info.configAngle) * p)
    end
    if info.modObj and info.modObj.Parent then
        local target = info.modValue + (1 - info.modValue) * p
        pcall(function() info.modObj.Value = target end)
    end
    if info.angleObj and info.angleObj.Parent then
        local target = info.angleValue + (52 - info.angleValue) * p
        pcall(function() info.angleObj.Value = target end)
    end
end

local function applyPressureAssist(dt, main, cf, forwardSpeed)
    if not flags.pressure then return end
    local throttle = getThrottleIntent()
    if throttle <= 0.04 or forwardSpeed < -1 then return end

    local baseTop = getBaseTopSpeed()
    local startTaper = baseTop * 0.68
    local factor = 1
    if forwardSpeed > startTaper then
        factor = math.clamp((baseTop - forwardSpeed) / math.max(baseTop - startTaper, 1), 0, 1)
    end
    if factor > 0 then
        main.AssemblyLinearVelocity += cf.LookVector * (PRESSURE_ACCEL * factor * dt)
    end
end

local function applyHandlingAssist(dt, main, cf, speed)
    if handlingPercent <= 0 then return end
    local steer = getSteerIntent()
    if math.abs(steer) < 0.06 then return end

    local baseTop = getBaseTopSpeed()
    local p = math.clamp(handlingPercent / 100, 0, 1)
    local highSpeed = math.clamp((speed - 65) / math.max(baseTop * 0.65, 1), 0, 1)
    local strength = p * highSpeed
    if strength <= 0 then return end

    local av = main.AssemblyAngularVelocity
    local currentYaw = av:Dot(cf.UpVector)
    local forwardA = av:Dot(cf.LookVector)
    local rightA = av:Dot(cf.RightVector)

    local targetYaw = -steer * (0.85 + 0.75 * highSpeed) * (0.55 + 0.45 * p)
    local alpha = 1 - math.exp(-(4 + 7 * strength) * dt)
    local newYaw = currentYaw + (targetYaw - currentYaw) * alpha

    main.AssemblyAngularVelocity = cf.LookVector * forwardA + cf.RightVector * rightA + cf.UpVector * newYaw
end

local function applyGripAssist(dt, main, cf)
    if not flags.grip then return end

    local v = main.AssemblyLinearVelocity
    local f = v:Dot(cf.LookVector)
    local r = v:Dot(cf.RightVector)
    local u = v:Dot(cf.UpVector)
    local speed = v.Magnitude
    local steer = getSteerIntent()
    local absSteer = math.abs(steer)
    local baseTop = getBaseTopSpeed()
    local speedAlpha = math.clamp(speed / math.max(baseTop, 1), 0, 1.25)

    if absSteer < 0.07 then
        local damp = RELEASE_LATERAL_DAMP_MIN + (RELEASE_LATERAL_DAMP_MAX - RELEASE_LATERAL_DAMP_MIN) * math.clamp(speedAlpha, 0, 1)
        r *= math.exp(-damp * dt)
        main.AssemblyLinearVelocity = cf.LookVector * f + cf.RightVector * r + cf.UpVector * u

        local av = main.AssemblyAngularVelocity
        local yaw = av:Dot(cf.UpVector)
        local rightA = av:Dot(cf.RightVector)
        local forwardA = av:Dot(cf.LookVector)
        local yawDamp = RELEASE_YAW_DAMP_MIN + (RELEASE_YAW_DAMP_MAX - RELEASE_YAW_DAMP_MIN) * math.clamp(speedAlpha, 0, 1)
        yaw *= math.exp(-yawDamp * dt)
        main.AssemblyAngularVelocity = cf.LookVector * forwardA + cf.RightVector * rightA + cf.UpVector * yaw
    else
        local allowed = math.max(4, math.abs(f) * ACTIVE_SLIP_LIMIT)
        local absR = math.abs(r)
        if absR > allowed then
            local excess = absR - allowed
            local retained = excess * math.exp(-ACTIVE_EXCESS_DAMP * dt)
            r = (r < 0 and -1 or 1) * (allowed + retained)
            main.AssemblyLinearVelocity = cf.LookVector * f + cf.RightVector * r + cf.UpVector * u
        end
    end
end

local function applyPhysicalAssists(dt)
    local main = getMainPart(currentVehicle)
    if not main or not main:IsDescendantOf(workspace) then return end
    local cf = main.CFrame
    local velocity = main.AssemblyLinearVelocity
    local forwardSpeed = velocity:Dot(cf.LookVector)

    applyPressureAssist(dt, main, cf, forwardSpeed)
    applyHandlingAssist(dt, main, cf, velocity.Magnitude)
    applyGripAssist(dt, main, cf)
end

-- UI -------------------------------------------------------------------------
local oldGui = CoreGui:FindFirstChild("PsicoDriveMenuV4") or CoreGui:FindFirstChild("PsicoDriveMenuV3") or CoreGui:FindFirstChild("PsicoDriveMenuV2")
if not oldGui then
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    oldGui = pg and (pg:FindFirstChild("PsicoDriveMenuV4") or pg:FindFirstChild("PsicoDriveMenuV3") or pg:FindFirstChild("PsicoDriveMenuV2"))
end
if oldGui then pcall(function() oldGui:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = "PsicoDriveMenuV4"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false

local okParent = pcall(function() gui.Parent = CoreGui end)
if not okParent or not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(320, 350)
frame.Position = UDim2.new(0.5, -160, 0.5, -175)
frame.BackgroundColor3 = Color3.fromRGB(16, 19, 28)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Thickness = 1
stroke.Transparency = 0.35
stroke.Color = Color3.fromRGB(80, 125, 255)
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 8)
title.Size = UDim2.new(1, -58, 0, 25)
title.Font = Enum.Font.GothamBold
title.Text = "PSICOSENATICO • DRIVE WORLD V4"
title.TextColor3 = Color3.fromRGB(240, 242, 255)
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Active = true
title.Parent = frame

local close = Instance.new("TextButton")
close.Size = UDim2.fromOffset(30, 30)
close.Position = UDim2.new(1, -38, 0, 5)
close.BackgroundTransparency = 1
close.Font = Enum.Font.GothamBold
close.Text = "×"
close.TextColor3 = Color3.fromRGB(220, 225, 245)
close.TextSize = 22
close.Parent = frame

local function makeToggle(y, label)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, -28, 0, 42)
    button.Position = UDim2.fromOffset(14, y)
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.TextSize = 14
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Parent = frame
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 10)
    c.Parent = button
    local function paint(on)
        button.Text = label .. ": " .. (on and "ON" or "OFF")
        button.BackgroundColor3 = on and Color3.fromRGB(38, 115, 82) or Color3.fromRGB(70, 75, 92)
    end
    return button, paint
end

local nitroButton, paintNitro = makeToggle(42, "NITRO INFINITO")
local gripButton, paintGrip = makeToggle(90, "0 DERRAPE")
local pressureButton, paintPressure = makeToggle(138, "PRESSAO +")

local handlingLabel = Instance.new("TextLabel")
handlingLabel.BackgroundTransparency = 1
handlingLabel.Position = UDim2.fromOffset(14, 190)
handlingLabel.Size = UDim2.new(1, -28, 0, 22)
handlingLabel.Font = Enum.Font.GothamBold
handlingLabel.TextColor3 = Color3.fromRGB(230, 233, 245)
handlingLabel.TextSize = 12
handlingLabel.TextXAlignment = Enum.TextXAlignment.Left
handlingLabel.Parent = frame

local slider = Instance.new("Frame")
slider.Position = UDim2.fromOffset(14, 220)
slider.Size = UDim2.new(1, -28, 0, 16)
slider.BackgroundColor3 = Color3.fromRGB(52, 57, 72)
slider.BorderSizePixel = 0
slider.Active = true
slider.Parent = frame
local sliderCorner = Instance.new("UICorner")
sliderCorner.CornerRadius = UDim.new(1, 0)
sliderCorner.Parent = slider

local fill = Instance.new("Frame")
fill.Size = UDim2.new(0, 0, 1, 0)
fill.BackgroundColor3 = Color3.fromRGB(70, 130, 255)
fill.BorderSizePixel = 0
fill.Parent = slider
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill

local knob = Instance.new("Frame")
knob.AnchorPoint = Vector2.new(0.5, 0.5)
knob.Position = UDim2.new(0, 0, 0.5, 0)
knob.Size = UDim2.fromOffset(22, 22)
knob.BackgroundColor3 = Color3.fromRGB(235, 238, 250)
knob.BorderSizePixel = 0
knob.Parent = slider
local knobCorner = Instance.new("UICorner")
knobCorner.CornerRadius = UDim.new(1, 0)
knobCorner.Parent = knob

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.fromOffset(14, 252)
status.Size = UDim2.new(1, -28, 0, 82)
status.Font = Enum.Font.Gotham
status.TextColor3 = Color3.fromRGB(165, 172, 195)
status.TextSize = 11
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = frame

local function refreshUI()
    paintNitro(flags.nitroInfinite)
    paintGrip(flags.grip)
    paintPressure(flags.pressure)
    handlingLabel.Text = string.format("DIRIGIBILIDADE / ESTERCO: %d%%", handlingPercent)
    fill.Size = UDim2.new(handlingPercent / 100, 0, 1, 0)
    knob.Position = UDim2.new(handlingPercent / 100, 0, 0.5, 0)

    local car = currentVehicle and currentVehicle.Name or "nenhum"
    local nitroFound = findNitroResource() and "OK" or "--"
    status.Text = string.format(
        "Carro: %s | Ctrl: %s | Motor: %s | Nitro: %s\nNitro infinito nao ativa sozinho.\n0 derrape libera a curva e estabiliza ao centralizar.",
        car, controller and "OK" or "--", engineConfig and "OK" or "--", nitroFound
    )
end

addConnection(nitroButton.MouseButton1Click:Connect(function()
    flags.nitroInfinite = not flags.nitroInfinite
    if flags.nitroInfinite then
        nitroResourceTable = nil
        findNitroResource()
        applyNitroInfinite()
    end
    refreshUI()
end))

addConnection(gripButton.MouseButton1Click:Connect(function()
    flags.grip = not flags.grip
    resolveTargets(true)
    applyGripSettings()
    refreshUI()
end))

addConnection(pressureButton.MouseButton1Click:Connect(function()
    flags.pressure = not flags.pressure
    resolveTargets(true)
    applyPressureSettings()
    refreshUI()
end))

local sliderDragging = false
local function setHandlingFromX(x)
    local width = slider.AbsoluteSize.X
    if width <= 0 then return end
    local alpha = math.clamp((x - slider.AbsolutePosition.X) / width, 0, 1)
    handlingPercent = math.floor(alpha * 100 + 0.5)
    applyHandlingSettings()
    refreshUI()
end

addConnection(slider.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        sliderDragging = true
        setHandlingFromX(input.Position.X)
    end
end))
addConnection(slider.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        sliderDragging = false
    end
end))
addConnection(UserInputService.InputChanged:Connect(function(input)
    if sliderDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        setHandlingFromX(input.Position.X)
    end
end))

local dragging = false
local dragStart, startPos, dragInput
addConnection(title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = frame.Position
        local ended
        ended = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                if ended then ended:Disconnect() end
            end
        end)
    end
end))
addConnection(title.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end))
addConnection(UserInputService.InputChanged:Connect(function(input)
    if dragging and input == dragInput and dragStart and startPos then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end))

local function restoreAll()
    flags.nitroInfinite = false
    flags.grip = false
    flags.pressure = false
    if controller then
        restoreGripFor(controller)
        restoreHandlingFor(controller)
    end
    if engineConfig then restorePressureFor(engineConfig) end
end

local function stop()
    if not running then return end
    running = false
    restoreAll()
    for _, conn in ipairs(connections) do pcall(function() conn:Disconnect() end) end
    pcall(function() gui:Destroy() end)
    if G.PSICO_DRIVE_MENU_STOP == stop then G.PSICO_DRIVE_MENU_STOP = nil end
end

G.PSICO_DRIVE_MENU_STOP = stop
addConnection(close.MouseButton1Click:Connect(stop))

addConnection(RunService.Heartbeat:Connect(function(dt)
    if not running then return end

    resolveAccumulator += dt
    nitroSearchAccumulator += dt
    if resolveAccumulator >= 1 then
        resolveAccumulator = 0
        resolveTargets(false)
        applyGripSettings()
        applyPressureSettings()
        applyHandlingSettings()
        refreshUI()
    end

    if nitroSearchAccumulator >= 1.5 then
        nitroSearchAccumulator = 0
        if flags.nitroInfinite and not nitroResourceTable then findNitroResource() end
    end

    applyNitroInfinite()
    applyPhysicalAssists(dt)
end))

resolveTargets(true)
findNitroResource()
applyHandlingSettings()
refreshUI()
