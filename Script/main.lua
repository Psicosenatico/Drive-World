-- PSICOSENATICO | Drive World Vehicle Menu V5.5.1
-- Hotfix: transicao RE -> FRENTE sem Pressao+ empurrar no sentido antigo.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_DRIVE_V551_STOP) == "function" then
    pcall(G.PSICO_DRIVE_V551_STOP)
end

-- V5.5 comprovadamente funcional como base: freio, nitro, 0 derrape,
-- dirigibilidade e minimizar permanecem intactos.
local BASE_URL = "https://raw.githubusercontent.com/Psicosenatico/Drive-World/427359c972821929b28f666b1cc6165d7e4cd8b7/Script/main.lua"
local okSource, baseSource = pcall(function()
    return game:HttpGet(BASE_URL)
end)
if not okSource or type(baseSource) ~= "string" or #baseSource < 1000 then
    error("Drive World V5.5.1: falha ao baixar a base V5.5")
end

local baseFn, compileError = loadstring(baseSource)
if not baseFn then
    error("Drive World V5.5.1: base V5.5 nao compilou: " .. tostring(compileError))
end

local okBase, baseError = pcall(baseFn)
if not okBase then
    error("Drive World V5.5.1: base V5.5 falhou: " .. tostring(baseError))
end

local running = true
local connections = {}
local pressureEnabled = false
local currentVehicle = nil
local currentSeat = nil
local controller = nil
local engineConfig = nil
local resolveTimer = 999
local menuGui = nil
local originalPressureButton = nil
local customPressureButton = nil

local TORQUE_MULTIPLIER = 1.65
local PRESSURE_ACCEL = 58
local originalTorque = setmetatable({}, {__mode = "k"})

local forwardButtonsBound = setmetatable({}, {__mode = "k"})
local activeForwardInputs = setmetatable({}, {__mode = "k"})

local function connect(signal, fn)
    local c = signal:Connect(fn)
    connections[#connections + 1] = c
    return c
end

local function normalize(text)
    return string.lower(tostring(text or "")):gsub("[%s_%-%./]", "")
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
    if rawget(t, "model") == vehicle then score = score + 150 end
    if rawget(t, "carName") == vehicle.Name then score = score + 35 end
    if rawget(t, "currentDriver") == LocalPlayer then score = score + 50 end
    if rawget(t, "owner") == LocalPlayer then score = score + 20 end
    if type(rawget(t, "wheelData")) == "table" then score = score + 30 end
    if type(rawget(t, "config")) == "table" then score = score + 20 end
    if rawget(t, "gear") ~= nil then score = score + 20 end
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
        if stockEngine and rawget(selected, "Profile") == stockEngine then
            score = score + 160
        end
    end
    if type(rawget(t, "GetTorqueAtRPM")) == "function" then score = score + 35 end
    if type(rawget(t, "GetMaxTorque")) == "function" then score = score + 20 end
    if type(rawget(t, "GetMaxPower")) == "function" then score = score + 20 end
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

local function restoreTorque(engine)
    if type(engine) ~= "table" then return end
    local saved = originalTorque[engine]
    local curve = rawget(engine, "TorqueCurve")
    if type(saved) ~= "table" or type(curve) ~= "table" then return end
    for k, v in pairs(saved) do curve[k] = v end
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
    if engineConfig then applyTorque(engineConfig) end
end

local function getGearText()
    if type(controller) ~= "table" then return nil end
    local screen = rawget(controller, "instrumentScreen")
    local label = type(screen) == "table" and rawget(screen, "currentGearLabel") or nil
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

    if type(text) == "string" then return normalize(text) end
    return nil
end

local function getGearDirection()
    local text = getGearText()
    if text then
        if text == "r" or text == "re" or text == "ré" or text:find("reverse", 1, true) then return -1 end
        if text == "n" or text:find("neutral", 1, true) then return 0 end
        local n = tonumber(text)
        if n then
            if n < 0 then return -1 end
            if n > 0 then return 1 end
            return 0
        end
    end

    if type(controller) == "table" then
        local gear = tonumber(rawget(controller, "gear"))
        if gear then
            if gear < 0 then return -1 end
            if gear > 0 then return 1 end
        end
    end
    return 0
end

local function getSpeedCap(direction)
    if type(controller) ~= "table" then return direction < 0 and 45 or 280 end
    local cached = rawget(controller, "cachedGears")
    local tops = type(cached) == "table" and rawget(cached, "topSpeeds") or nil

    if type(tops) == "table" then
        if direction < 0 then
            for k, v in pairs(tops) do
                if (k == -1 or tostring(k) == "-1") and type(v) == "number" then
                    return math.max(math.abs(v), 10)
                end
            end
        else
            local maxSpeed = 0
            for k, v in pairs(tops) do
                if type(v) == "number" and tonumber(k) and tonumber(k) > 0 and v > maxSpeed then
                    maxSpeed = v
                end
            end
            if maxSpeed > 0 then return maxSpeed end
        end
    end

    local calc = rawget(controller, "calculatedTopSpeed")
    if direction > 0 and type(calc) == "number" and calc > 0 then return calc end
    return direction < 0 and 45 or 280
end

local function forwardCandidate(obj)
    if not obj or not obj:IsA("GuiButton") then return false end
    local screen = obj:FindFirstAncestorOfClass("ScreenGui")
    if screen and normalize(screen.Name):find("psicodrivemenu", 1, true) then return false end

    local parts = {obj.Name}
    if obj:IsA("TextButton") then parts[#parts + 1] = obj.Text end
    local node = obj.Parent
    for _ = 1, 4 do
        if not node then break end
        parts[#parts + 1] = node.Name
        node = node.Parent
    end

    local text = normalize(table.concat(parts, " "))
    local keywords = {
        "accelerate", "accel", "accelerator", "acelerar", "acelerador",
        "throttle", "gas", "forward", "gaspedal", "pedalgas"
    }
    for _, word in ipairs(keywords) do
        if text:find(word, 1, true) then return true end
    end
    return false
end

local function bindForwardButton(obj)
    if forwardButtonsBound[obj] or not forwardCandidate(obj) then return end
    forwardButtonsBound[obj] = true

    connect(obj.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then
            activeForwardInputs[input] = true
        end
    end)

    connect(obj.InputEnded, function(input)
        activeForwardInputs[input] = nil
    end)
end

local function watchForwardButtons(root)
    if not root then return end
    for _, obj in ipairs(root:GetDescendants()) do
        bindForwardButton(obj)
    end
    connect(root.DescendantAdded, bindForwardButton)
end

local function forwardHeld()
    return next(activeForwardInputs) ~= nil
end

local function keyDown(key)
    local ok, value = pcall(function() return UserInputService:IsKeyDown(key) end)
    return ok and value or false
end

local function keyboardForward()
    if keyDown(Enum.KeyCode.W) or keyDown(Enum.KeyCode.Up) then return true end
    local okPad, pad = pcall(function()
        return UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonR2)
    end)
    return okPad and pad or false
end

local function keyboardReverse()
    return keyDown(Enum.KeyCode.S) or keyDown(Enum.KeyCode.Down)
end

local function seatThrottle()
    if not currentSeat or not currentSeat:IsA("VehicleSeat") then return nil end
    local ok, throttle = pcall(function() return currentSeat.ThrottleFloat end)
    if ok and type(throttle) == "number" then return throttle end
    return nil
end

local function forwardCommandActive()
    if forwardHeld() or keyboardForward() then return true end
    local throttle = seatThrottle()
    return throttle ~= nil and throttle > 0.04
end

local function reverseCommandActive()
    -- REGRA CRITICA V5.5.1:
    -- enquanto o usuario estiver tentando ir PARA FRENTE, uma marcha R atrasada
    -- nunca pode autorizar impulso para tras.
    if forwardHeld() or keyboardForward() then return false end

    local throttle = seatThrottle()
    if throttle ~= nil and throttle < -0.04 then return true end
    if keyboardReverse() then return true end

    -- No mobile do Drive World o comando de re passa pelo estado de frenagem.
    return type(controller) == "table" and rawget(controller, "isBraking") == true
end

local function applyPressureAssist(dt)
    if not pressureEnabled or not currentVehicle or not controller then return end

    local direction = getGearDirection()
    if direction == 0 then return end

    if direction > 0 then
        if not forwardCommandActive() then return end
    else
        if not reverseCommandActive() then return end
    end

    local main = getMainPart(currentVehicle)
    if not main or not main:IsDescendantOf(workspace) then return end

    local cf = main.CFrame
    local forwardSpeed = main.AssemblyLinearVelocity:Dot(cf.LookVector)
    local directionalSpeed = forwardSpeed * direction
    local cap = getSpeedCap(direction)
    if directionalSpeed >= cap then return end

    local startTaper = cap * 0.68
    local factor = 1
    if directionalSpeed > startTaper then
        factor = math.clamp((cap - directionalSpeed) / math.max(cap - startTaper, 1), 0, 1)
    end

    if factor > 0 then
        main.AssemblyLinearVelocity = main.AssemblyLinearVelocity
            + cf.LookVector * (PRESSURE_ACCEL * factor * dt * direction)
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

local function locateVisiblePressureButton(root)
    if not root then return nil end
    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("TextButton") and obj.Visible then
            local text = string.upper(tostring(obj.Text or ""))
            if text:find("PRESSAO", 1, true) then return obj end
        end
    end
    return nil
end

local function installPressureOverride()
    menuGui = locateMenu()
    if not menuGui then error("Drive World V5.5.1: menu base nao encontrado") end

    for _, obj in ipairs(menuGui:GetDescendants()) do
        if obj:IsA("TextLabel") and tostring(obj.Text):find("DRIVE WORLD V5", 1, true) then
            obj.Text = "PSICOSENATICO • DRIVE WORLD V5.5.1"
            break
        end
    end

    originalPressureButton = locateVisiblePressureButton(menuGui)
    if not originalPressureButton then
        error("Drive World V5.5.1: botao PRESSAO+ base nao encontrado")
    end

    -- Mantem a Pressao+ da V5.5 desligada; esta revisao assume o controle.
    originalPressureButton.Visible = false

    local button = originalPressureButton:Clone()
    button.Name = "PressureV551"
    button.Visible = true
    button.Text = "PRESSAO +: OFF"
    button.ZIndex = originalPressureButton.ZIndex + 30
    button.Parent = originalPressureButton.Parent
    customPressureButton = button

    connect(button.MouseButton1Click, function()
        pressureEnabled = not pressureEnabled
        button.Text = pressureEnabled and "PRESSAO +: ON" or "PRESSAO +: OFF"
        button.BackgroundColor3 = pressureEnabled
            and Color3.fromRGB(38, 115, 82)
            or Color3.fromRGB(70, 75, 92)

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

    if G.PSICO_DRIVE_V551_STOP == stop then
        G.PSICO_DRIVE_V551_STOP = nil
    end
end

G.PSICO_DRIVE_V551_STOP = stop

installPressureOverride()
resolveTargets(true)

local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
watchForwardButtons(playerGui)
pcall(function() watchForwardButtons(CoreGui) end)

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

    applyPressureAssist(dt)
end)
