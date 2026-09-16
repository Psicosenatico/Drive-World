-- PSICOSENATICO | Drive World Vehicle Menu V2
-- Construido a partir dos scans focados do controlador do carro.
-- Recursos: Turbo infinito, Zero Deslize e Pressao+ (torque).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_DRIVE_MENU_STOP) == "function" then
    pcall(G.PSICO_DRIVE_MENU_STOP)
end

local running = true
local connections = {}

local flags = {
    turbo = false,
    grip = false,
    pressure = false,
}

local GRIP_MULTIPLIER = 4
local TORQUE_MULTIPLIER = 1.65

local currentVehicle = nil
local controller = nil
local engineConfig = nil
local resolveAccumulator = 999

local originalWheelMultiplier = setmetatable({}, {__mode = "k"})
local originalTorque = setmetatable({}, {__mode = "k"})
local originalControllerTraction = setmetatable({}, {__mode = "k"})

local function addConnection(conn)
    connections[#connections + 1] = conn
    return conn
end

local function getCharacter()
    return LocalPlayer.Character
end

local function getCurrentVehicle()
    local char = getCharacter()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if not seat then
        return nil
    end

    local cars = workspace:FindFirstChild("Cars")
    if cars then
        local node = seat
        while node and node.Parent and node.Parent ~= cars do
            node = node.Parent
        end
        if node and node.Parent == cars and node:IsA("Model") then
            return node
        end
    end

    local node = seat
    while node and node ~= workspace do
        if node:IsA("Model")
        and node:FindFirstChild("Main")
        and node:FindFirstChild("Wheels") then
            return node
        end
        node = node.Parent
    end

    return seat:FindFirstAncestorOfClass("Model")
end

local function getGCObjects()
    local fn = rawget(G, "getgc") or getgc
    if type(fn) ~= "function" then
        return {}
    end

    local ok, result = pcall(fn, true)
    if not ok or type(result) ~= "table" then
        ok, result = pcall(fn)
    end

    if ok and type(result) == "table" then
        return result
    end
    return {}
end

local function scoreController(t, vehicle)
    if type(t) ~= "table" or not vehicle then
        return -1
    end

    local score = 0
    local model = rawget(t, "model")
    local carName = rawget(t, "carName")
    local wheelData = rawget(t, "wheelData")
    local config = rawget(t, "config")

    if model == vehicle then score += 140 end
    if carName == vehicle.Name then score += 35 end
    if type(wheelData) == "table" then score += 35 end
    if type(config) == "table" then score += 25 end
    if type(rawget(t, "engineSound")) == "table" then score += 20 end
    if rawget(t, "currentDriver") == LocalPlayer then score += 45 end
    if rawget(t, "owner") == LocalPlayer then score += 20 end

    return score
end

local function findController(vehicle)
    if controller and scoreController(controller, vehicle) >= 200 then
        return controller
    end

    local best, bestScore = nil, -1
    for _, obj in ipairs(getGCObjects()) do
        if type(obj) == "table" then
            local score = scoreController(obj, vehicle)
            if score > bestScore then
                bestScore = score
                best = obj
            end
        end
    end

    if bestScore >= 180 then
        return best
    end
    return nil
end

local function scoreEngine(t, ctrl)
    if type(t) ~= "table" or type(ctrl) ~= "table" then
        return -1
    end

    local curve = rawget(t, "TorqueCurve")
    if type(curve) ~= "table" then
        return -1
    end

    local score = 15
    local selected = rawget(t, "selectedMods")
    local config = rawget(ctrl, "config")
    local stockEngine = type(config) == "table" and rawget(config, "StockEngine") or nil

    if type(selected) == "table" then
        score += 25
        if stockEngine and rawget(selected, "Profile") == stockEngine then
            score += 160
        end
    end

    if type(rawget(t, "GetTorqueAtRPM")) == "function" then score += 35 end
    if type(rawget(t, "GetMaxTorque")) == "function" then score += 20 end
    if type(rawget(t, "GetMaxPower")) == "function" then score += 20 end
    if type(rawget(t, "ApplyUpgradesFromTuning")) == "function" then score += 20 end

    local soundProfile = rawget(ctrl, "soundProfile")
    if soundProfile and rawget(t, "SoundProfile") == soundProfile then
        score += 12
    end

    return score
end

local function findEngine(ctrl)
    if engineConfig and scoreEngine(engineConfig, ctrl) >= 180 then
        return engineConfig
    end

    local best, bestScore = nil, -1
    for _, obj in ipairs(getGCObjects()) do
        if type(obj) == "table" then
            local score = scoreEngine(obj, ctrl)
            if score > bestScore then
                bestScore = score
                best = obj
            end
        end
    end

    if bestScore >= 180 then
        return best
    end
    return nil
end

local function rememberTarget()
    if type(controller) == "table" then
        if originalControllerTraction[controller] == nil then
            local value = rawget(controller, "traction")
            if type(value) == "number" then
                originalControllerTraction[controller] = value
            end
        end

        local wheels = rawget(controller, "wheelData")
        if type(wheels) == "table" then
            for _, wheel in pairs(wheels) do
                if type(wheel) == "table"
                and originalWheelMultiplier[wheel] == nil then
                    local mult = rawget(wheel, "tractionMultiplier")
                    if type(mult) == "number" then
                        originalWheelMultiplier[wheel] = mult
                    end
                end
            end
        end
    end

    if type(engineConfig) == "table" and originalTorque[engineConfig] == nil then
        local curve = rawget(engineConfig, "TorqueCurve")
        if type(curve) == "table" then
            local copy = {}
            for k, value in pairs(curve) do
                if type(value) == "number" then
                    copy[k] = value
                end
            end
            originalTorque[engineConfig] = copy
        end
    end
end

local function resolveTargets(force)
    local vehicle = getCurrentVehicle()

    if vehicle ~= currentVehicle then
        currentVehicle = vehicle
        controller = nil
        engineConfig = nil
    end

    if not currentVehicle then
        return
    end

    if force or not controller then
        controller = findController(currentVehicle)
    end

    if controller and (force or not engineConfig) then
        engineConfig = findEngine(controller)
    end

    rememberTarget()
end

local function setTurboState(value)
    local vehicle = currentVehicle or getCurrentVehicle()
    if not vehicle then return end

    local states = vehicle:FindFirstChild("States")
    local nitrous = states and states:FindFirstChild("Nitrous")
    if nitrous and nitrous:IsA("BoolValue") then
        pcall(function()
            nitrous.Value = value
        end)
    end
end

local function applyGrip()
    if type(controller) ~= "table" then
        return
    end

    local wheels = rawget(controller, "wheelData")
    if type(wheels) == "table" then
        for _, wheel in pairs(wheels) do
            if type(wheel) == "table" then
                local original = originalWheelMultiplier[wheel]
                if flags.grip then
                    rawset(wheel, "tractionMultiplier", GRIP_MULTIPLIER)
                elseif original ~= nil then
                    rawset(wheel, "tractionMultiplier", original)
                end
            end
        end
    end

    if flags.grip then
        rawset(controller, "traction", 1)
    end
end

local function restoreGrip()
    if type(controller) ~= "table" then
        return
    end

    local wheels = rawget(controller, "wheelData")
    if type(wheels) == "table" then
        for _, wheel in pairs(wheels) do
            if type(wheel) == "table" then
                local original = originalWheelMultiplier[wheel]
                if original ~= nil then
                    rawset(wheel, "tractionMultiplier", original)
                end
            end
        end
    end

    local originalTraction = originalControllerTraction[controller]
    if originalTraction ~= nil then
        rawset(controller, "traction", originalTraction)
    end
end

local function applyPressure()
    if type(engineConfig) ~= "table" then
        return
    end

    local originals = originalTorque[engineConfig]
    local curve = rawget(engineConfig, "TorqueCurve")
    if type(originals) ~= "table" or type(curve) ~= "table" then
        return
    end

    for key, base in pairs(originals) do
        if flags.pressure then
            curve[key] = base * TORQUE_MULTIPLIER
        else
            curve[key] = base
        end
    end
end

local function restorePressure()
    if type(engineConfig) ~= "table" then
        return
    end

    local originals = originalTorque[engineConfig]
    local curve = rawget(engineConfig, "TorqueCurve")
    if type(originals) ~= "table" or type(curve) ~= "table" then
        return
    end

    for key, base in pairs(originals) do
        curve[key] = base
    end
end

-- UI -------------------------------------------------------------------------

local oldGui = CoreGui:FindFirstChild("PsicoDriveMenuV2")
if not oldGui then
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    oldGui = pg and pg:FindFirstChild("PsicoDriveMenuV2")
end
if oldGui then
    pcall(function() oldGui:Destroy() end)
end

local gui = Instance.new("ScreenGui")
gui.Name = "PsicoDriveMenuV2"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false

local okParent = pcall(function()
    gui.Parent = CoreGui
end)
if not okParent or not gui.Parent then
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(310, 258)
frame.Position = UDim2.new(0.5, -155, 0.5, -129)
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
title.Text = "PSICOSENATICO • DRIVE WORLD"
title.TextColor3 = Color3.fromRGB(240, 242, 255)
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
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
    button.Size = UDim2.new(1, -28, 0, 44)
    button.Position = UDim2.fromOffset(14, y)
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.TextSize = 14
    button.TextColor3 = Color3.new(1, 1, 1)
    button.AutoButtonColor = true
    button.Parent = frame

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 10)
    c.Parent = button

    local function paint(on, suffix)
        button.Text = label .. ": " .. (on and "ON" or "OFF") .. (suffix or "")
        button.BackgroundColor3 = on
            and Color3.fromRGB(38, 115, 82)
            or Color3.fromRGB(70, 75, 92)
    end

    return button, paint
end

local turboButton, paintTurbo = makeToggle(42, "TURBO INFINITO")
local gripButton, paintGrip = makeToggle(92, "0 DESLIZE")
local pressureButton, paintPressure = makeToggle(142, "PRESSAO +")

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.fromOffset(14, 195)
status.Size = UDim2.new(1, -28, 0, 50)
status.Font = Enum.Font.Gotham
status.TextColor3 = Color3.fromRGB(165, 172, 195)
status.TextSize = 12
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = frame

local function refreshUI()
    paintTurbo(flags.turbo)
    paintGrip(flags.grip, flags.grip and "  • 4x grip" or "")
    paintPressure(flags.pressure, flags.pressure and "  • 1.65x torque" or "")

    local car = currentVehicle and currentVehicle.Name or "nenhum"
    local c = controller and "OK" or "--"
    local e = engineConfig and "OK" or "--"
    status.Text = string.format(
        "Carro: %s\nControlador: %s   Motor: %s",
        car, c, e
    )
end

addConnection(turboButton.MouseButton1Click:Connect(function()
    flags.turbo = not flags.turbo
    if flags.turbo then
        resolveTargets(true)
        setTurboState(true)
    else
        setTurboState(false)
    end
    refreshUI()
end))

addConnection(gripButton.MouseButton1Click:Connect(function()
    flags.grip = not flags.grip
    resolveTargets(true)
    if flags.grip then
        applyGrip()
    else
        restoreGrip()
    end
    refreshUI()
end))

addConnection(pressureButton.MouseButton1Click:Connect(function()
    flags.pressure = not flags.pressure
    resolveTargets(true)
    if flags.pressure then
        applyPressure()
    else
        restorePressure()
    end
    refreshUI()
end))

-- Arrastar por mouse ou toque.
do
    local dragging = false
    local dragStart
    local startPos
    local dragInput

    addConnection(frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
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

    addConnection(frame.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end))

    addConnection(UserInputService.InputChanged:Connect(function(input)
        if dragging and input == dragInput and dragStart and startPos then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end))
end

local function restoreAll()
    flags.turbo = false
    flags.grip = false
    flags.pressure = false

    setTurboState(false)
    restoreGrip()
    restorePressure()
end

local function stop()
    if not running then return end
    running = false
    restoreAll()

    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end

    pcall(function()
        gui:Destroy()
    end)

    if G.PSICO_DRIVE_MENU_STOP == stop then
        G.PSICO_DRIVE_MENU_STOP = nil
    end
end

G.PSICO_DRIVE_MENU_STOP = stop
addConnection(close.MouseButton1Click:Connect(stop))

addConnection(RunService.Heartbeat:Connect(function(dt)
    if not running then return end

    resolveAccumulator += dt
    if resolveAccumulator >= 1 then
        resolveAccumulator = 0
        resolveTargets(false)
        refreshUI()
    end

    if flags.turbo then
        setTurboState(true)
    end

    if flags.grip then
        applyGrip()
    end

    if flags.pressure then
        applyPressure()
    end
end))

resolveTargets(true)
refreshUI()
