-- PSICOSENATICO | Infinite Turbo Menu
-- Cliente adaptativo: procura valores/atributos comuns de nitro/turbo no carro atual.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_TURBO_STOP) == "function" then
    pcall(G.PSICO_TURBO_STOP)
end

local enabled = true
local running = true
local connections = {}
local touched = setmetatable({}, {__mode = "k"})
local touchedAttributes = setmetatable({}, {__mode = "k"})
local targetCount = 0
local RESOURCE_VALUE = 1000000

local function addConnection(conn)
    connections[#connections + 1] = conn
    return conn
end

local function normalize(text)
    return string.lower(tostring(text or "")):gsub("[%s_%-%./]", "")
end

local function isTurboKey(name)
    local n = normalize(name)
    if n == "nitro" or n == "turbo" or n == "boost" or n == "nos" then
        return true
    end

    if not (n:find("nitro", 1, true) or n:find("turbo", 1, true) or n:find("boost", 1, true) or n:find("nos", 1, true)) then
        return false
    end

    -- Evita transformar potência/velocidade do veículo em valores absurdos.
    if n:find("power", 1, true)
    or n:find("force", 1, true)
    or n:find("speed", 1, true)
    or n:find("torque", 1, true)
    or n:find("multiplier", 1, true)
    or n:find("mult", 1, true) then
        return false
    end

    return n:find("amount", 1, true)
        or n:find("fuel", 1, true)
        or n:find("charge", 1, true)
        or n:find("capacity", 1, true)
        or n:find("level", 1, true)
        or n:find("meter", 1, true)
        or n:find("time", 1, true)
        or n:find("duration", 1, true)
        or n:find("remaining", 1, true)
        or n:find("left", 1, true)
        or n:find("value", 1, true)
        or n:find("current", 1, true)
        or n:find("max", 1, true)
end

local function getCharacter()
    return LocalPlayer.Character
end

local function getVehicle()
    local character = getCharacter()
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local seat = humanoid and humanoid.SeatPart

    if seat then
        local model = seat:FindFirstAncestorOfClass("Model")
        if model then
            return model
        end
        return seat.Parent
    end

    return nil
end

local function markObject(obj)
    if not touched[obj] then
        touched[obj] = true
        targetCount += 1
    end
end

local function patchValueObject(obj)
    if not isTurboKey(obj.Name) then
        return
    end

    if obj:IsA("NumberValue") or obj:IsA("IntValue") then
        markObject(obj)
        pcall(function()
            if obj.Value < RESOURCE_VALUE then
                obj.Value = RESOURCE_VALUE
            end
        end)
    elseif obj:IsA("BoolValue") then
        markObject(obj)
        pcall(function()
            obj.Value = true
        end)
    end
end

local function patchAttributes(obj)
    local ok, attrs = pcall(function()
        return obj:GetAttributes()
    end)
    if not ok or type(attrs) ~= "table" then
        return
    end

    for key, value in pairs(attrs) do
        if isTurboKey(key) then
            touchedAttributes[obj] = touchedAttributes[obj] or {}
            if not touchedAttributes[obj][key] then
                touchedAttributes[obj][key] = true
                targetCount += 1
            end

            if type(value) == "number" then
                pcall(function()
                    if value < RESOURCE_VALUE then
                        obj:SetAttribute(key, RESOURCE_VALUE)
                    end
                end)
            elseif type(value) == "boolean" then
                pcall(function()
                    obj:SetAttribute(key, true)
                end)
            end
        end
    end
end

local function patchObject(obj)
    patchValueObject(obj)
    patchAttributes(obj)
end

local function scanRoot(root)
    if not root then
        return
    end

    patchObject(root)
    for _, obj in ipairs(root:GetDescendants()) do
        patchObject(obj)
    end
end

local function applyInfiniteTurbo()
    if not enabled then
        return
    end

    scanRoot(LocalPlayer)
    scanRoot(getCharacter())
    scanRoot(getVehicle())
end

-- UI -------------------------------------------------------------------------
local oldGui
pcall(function()
    oldGui = game:GetService("CoreGui"):FindFirstChild("PsicoInfiniteTurbo")
end)
if not oldGui and LocalPlayer:FindFirstChildOfClass("PlayerGui") then
    oldGui = LocalPlayer.PlayerGui:FindFirstChild("PsicoInfiniteTurbo")
end
if oldGui then
    pcall(function() oldGui:Destroy() end)
end

local gui = Instance.new("ScreenGui")
gui.Name = "PsicoInfiniteTurbo"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false

local parented = pcall(function()
    gui.Parent = game:GetService("CoreGui")
end)
if not parented or not gui.Parent then
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(260, 126)
frame.Position = UDim2.new(0.5, -130, 0.72, -63)
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
stroke.Color = Color3.fromRGB(90, 130, 255)
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 8)
title.Size = UDim2.new(1, -58, 0, 25)
title.Font = Enum.Font.GothamBold
title.Text = "PSICOSENATICO • TURBO"
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

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.new(1, -28, 0, 44)
toggle.Position = UDim2.fromOffset(14, 42)
toggle.BorderSizePixel = 0
toggle.Font = Enum.Font.GothamBold
toggle.TextSize = 15
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.Parent = frame

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 10)
toggleCorner.Parent = toggle

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.fromOffset(14, 91)
status.Size = UDim2.new(1, -28, 0, 24)
status.Font = Enum.Font.Gotham
status.TextColor3 = Color3.fromRGB(165, 172, 195)
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame

local function refreshUI()
    if enabled then
        toggle.Text = "TURBO INFINITO: ON"
        toggle.BackgroundColor3 = Color3.fromRGB(38, 115, 82)
        status.Text = string.format("Ativo • alvos detectados: %d", targetCount)
    else
        toggle.Text = "TURBO INFINITO: OFF"
        toggle.BackgroundColor3 = Color3.fromRGB(95, 49, 57)
        status.Text = string.format("Pausado • alvos detectados: %d", targetCount)
    end
end

addConnection(toggle.MouseButton1Click:Connect(function()
    enabled = not enabled
    if enabled then
        applyInfiniteTurbo()
    end
    refreshUI()
end))

-- Arrastar no mouse/toque.
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

local accumulator = 0
addConnection(RunService.Heartbeat:Connect(function(dt)
    if not running then
        return
    end
    accumulator += dt
    if accumulator >= 0.08 then
        accumulator = 0
        applyInfiniteTurbo()
        refreshUI()
    end
end))

local function stop()
    if not running then
        return
    end
    running = false
    enabled = false

    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)

    pcall(function()
        if gui then gui:Destroy() end
    end)

    if G.PSICO_TURBO_STOP == stop then
        G.PSICO_TURBO_STOP = nil
    end
end

G.PSICO_TURBO_STOP = stop

addConnection(close.MouseButton1Click:Connect(stop))

applyInfiniteTurbo()
refreshUI()
