-- PSICOSENATICO | Drive World Vehicle Menu V5.4
-- Base V5.3.1 + barra de forca do freio baseada no estado real controller.isBraking.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_DRIVE_V54_STOP) == "function" then
    pcall(G.PSICO_DRIVE_V54_STOP)
end

-- Carrega a V5.3.1 que ja esta funcionando: Nitro, 0 Derrape,
-- Pressao+, Dirigibilidade e minimizar permanecem nela.
local BASE_URL = "https://raw.githubusercontent.com/Psicosenatico/Drive-World/2d8282c5fe14023512d44458da5e0af6576987c1/Script/main.lua"
local okSource, baseSource = pcall(function()
    return game:HttpGet(BASE_URL)
end)
if not okSource or type(baseSource) ~= "string" or #baseSource < 1000 then
    error("Drive World V5.4: falha ao baixar a base V5.3.1")
end

local baseFn, compileError = loadstring(baseSource)
if not baseFn then
    error("Drive World V5.4: base V5.3.1 nao compilou: " .. tostring(compileError))
end

local okBase, baseError = pcall(baseFn)
if not okBase then
    error("Drive World V5.4: base V5.3.1 falhou: " .. tostring(baseError))
end

local running = true
local connections = {}
local brakePercent = 0
local currentVehicle = nil
local currentSeat = nil
local controller = nil
local resolveTimer = 999
local menuGui = nil
local menuFrame = nil
local brakePanel = nil
local originalFrameSize = nil
local statusLabel = nil
local originalStatusPosition = nil
local originalStatusSize = nil

-- Assistencia adicional. 0% nao altera nada; 100% acrescenta
-- amortecimento longitudinal forte somente enquanto o jogo esta freando.
local BRAKE_EXTRA_DAMP_MAX = 9

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
    if rawget(t, "model") == vehicle then score = score + 150 end
    if rawget(t, "carName") == vehicle.Name then score = score + 35 end
    if rawget(t, "currentDriver") == LocalPlayer then score = score + 50 end
    if rawget(t, "owner") == LocalPlayer then score = score + 20 end
    if type(rawget(t, "wheelData")) == "table" then score = score + 30 end
    if rawget(t, "isBraking") ~= nil then score = score + 20 end
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

local function resolveTargets(force)
    local vehicle, seat = getVehicleAndSeat()
    if vehicle ~= currentVehicle then
        currentVehicle = vehicle
        currentSeat = seat
        controller = nil
    else
        currentSeat = seat
    end

    if currentVehicle and (force or not controller) then
        controller = findController(currentVehicle)
    end
end

local function isBrakePressed(forwardSpeed)
    -- Fonte principal confirmada pelo scan do controlador.
    if type(controller) == "table" then
        local state = rawget(controller, "isBraking")
        if type(state) == "boolean" then
            return state
        end
    end

    -- Fallback apenas se o controlador nao expuser isBraking.
    -- Throttle negativo so conta como freio quando o carro ainda esta
    -- deslocando-se para frente, para nao atrapalhar a re.
    if currentSeat and currentSeat:IsA("VehicleSeat") and forwardSpeed > 1 then
        local ok, throttle = pcall(function()
            return currentSeat.ThrottleFloat
        end)
        if ok and type(throttle) == "number" then
            return throttle < -0.04
        end
    end

    return false
end

local function applyBrakeAssist(dt)
    if brakePercent <= 0 then return end
    if not currentVehicle or not controller then return end

    local main = getMainPart(currentVehicle)
    if not main or not main:IsDescendantOf(workspace) then return end

    local cf = main.CFrame
    local velocity = main.AssemblyLinearVelocity
    local forward = velocity:Dot(cf.LookVector)

    if not isBrakePressed(forward) then return end

    local right = velocity:Dot(cf.RightVector)
    local up = velocity:Dot(cf.UpVector)
    local p = math.clamp(brakePercent / 100, 0, 1)
    local damp = BRAKE_EXTRA_DAMP_MAX * p

    -- Aproxima a velocidade longitudinal de zero sem inverter o sentido.
    local newForward = forward * math.exp(-damp * dt)
    if math.abs(newForward) < 0.08 then newForward = 0 end

    main.AssemblyLinearVelocity =
        cf.LookVector * newForward
        + cf.RightVector * right
        + cf.UpVector * up
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

local function installBrakeUI()
    menuGui = locateMenu()
    if not menuGui then
        error("Drive World V5.4: menu base nao encontrado")
    end

    menuFrame = menuGui:FindFirstChild("Main")
    if not menuFrame or not menuFrame:IsA("Frame") then
        error("Drive World V5.4: frame principal nao encontrado")
    end

    -- Marcacao visual da revisao.
    for _, obj in ipairs(menuGui:GetDescendants()) do
        if obj:IsA("TextLabel") and tostring(obj.Text):find("DRIVE WORLD V5", 1, true) then
            obj.Text = "PSICOSENATICO • DRIVE WORLD V5.4"
            break
        end
    end

    -- Localiza o status para abrir somente o espaco necessario para a nova barra.
    for _, obj in ipairs(menuFrame:GetChildren()) do
        if obj:IsA("TextLabel") and tostring(obj.Text):find("Carro:", 1, true) then
            statusLabel = obj
            break
        end
    end

    originalFrameSize = menuFrame.Size
    menuFrame.Size = UDim2.fromOffset(320, 390)

    if statusLabel then
        originalStatusPosition = statusLabel.Position
        originalStatusSize = statusLabel.Size
        statusLabel.Position = UDim2.fromOffset(14, 300)
        statusLabel.Size = UDim2.new(1, -28, 0, 72)
    end

    brakePanel = Instance.new("Frame")
    brakePanel.Name = "BrakeStrengthV54"
    brakePanel.BackgroundTransparency = 1
    brakePanel.Position = UDim2.fromOffset(14, 246)
    brakePanel.Size = UDim2.new(1, -28, 0, 48)
    brakePanel.Parent = menuFrame

    local label = Instance.new("TextLabel")
    label.Name = "BrakeLabel"
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(0, 0)
    label.Size = UDim2.new(1, 0, 0, 20)
    label.Font = Enum.Font.GothamBold
    label.TextColor3 = Color3.fromRGB(230, 233, 245)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = brakePanel

    local slider = Instance.new("Frame")
    slider.Name = "BrakeSlider"
    slider.Position = UDim2.fromOffset(0, 28)
    slider.Size = UDim2.new(1, 0, 0, 16)
    slider.BackgroundColor3 = Color3.fromRGB(52, 57, 72)
    slider.BorderSizePixel = 0
    slider.Active = true
    slider.Parent = brakePanel

    local sliderCorner = Instance.new("UICorner")
    sliderCorner.CornerRadius = UDim.new(1, 0)
    sliderCorner.Parent = slider

    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(70, 130, 255)
    fill.BorderSizePixel = 0
    fill.Parent = slider

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(1, 0)
    fillCorner.Parent = fill

    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(0, 0, 0.5, 0)
    knob.Size = UDim2.fromOffset(22, 22)
    knob.BackgroundColor3 = Color3.fromRGB(235, 238, 250)
    knob.BorderSizePixel = 0
    knob.Parent = slider

    local knobCorner = Instance.new("UICorner")
    knobCorner.CornerRadius = UDim.new(1, 0)
    knobCorner.Parent = knob

    local function refresh()
        label.Text = string.format("FORCA DO FREIO: %d%%", brakePercent)
        fill.Size = UDim2.new(brakePercent / 100, 0, 1, 0)
        knob.Position = UDim2.new(brakePercent / 100, 0, 0.5, 0)
    end

    local dragging = false
    local function setFromX(x)
        local width = slider.AbsoluteSize.X
        if width <= 0 then return end
        local alpha = math.clamp((x - slider.AbsolutePosition.X) / width, 0, 1)
        brakePercent = math.floor(alpha * 100 + 0.5)
        refresh()
    end

    connect(slider.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)

    connect(slider.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if dragging and (
            input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch
        ) then
            setFromX(input.Position.X)
        end
    end)

    refresh()
end

local function stop()
    if not running then return end
    running = false
    brakePercent = 0

    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end

    if brakePanel and brakePanel.Parent then
        pcall(function() brakePanel:Destroy() end)
    end

    if menuFrame and menuFrame.Parent and originalFrameSize then
        pcall(function() menuFrame.Size = originalFrameSize end)
    end
    if statusLabel and statusLabel.Parent then
        if originalStatusPosition then pcall(function() statusLabel.Position = originalStatusPosition end) end
        if originalStatusSize then pcall(function() statusLabel.Size = originalStatusSize end) end
    end

    if G.PSICO_DRIVE_V54_STOP == stop then
        G.PSICO_DRIVE_V54_STOP = nil
    end
end

G.PSICO_DRIVE_V54_STOP = stop

installBrakeUI()
resolveTargets(true)

connect(RunService.Heartbeat, function(dt)
    if not running then return end

    resolveTimer = resolveTimer + dt
    if resolveTimer >= 1 then
        resolveTimer = 0
        resolveTargets(false)

        if menuGui and not menuGui.Parent then
            stop()
            return
        end
    end

    applyBrakeAssist(dt)
end)
