-- PSICOSENATICO | Scam Drive World + minimizador de interface
-- Mantem o SAFE FLOW SCANNER original intacto e adiciona minimizar/restaurar
-- somente a janela principal nova criada pelo script-alvo.

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local LP = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_SCAM_MIN_STOP) == "function" then
    pcall(G.PSICO_SCAM_MIN_STOP)
end

local running = true
local conns = {}
local candidates = setmetatable({}, {__mode = "k"})
local baseline = setmetatable({}, {__mode = "k"})
local attachedFrame
local minimizeButton
local restoreButton

local function addConn(c)
    conns[#conns + 1] = c
    return c
end

local function rememberBaseline(root)
    if not root then return end
    baseline[root] = true
    for _, obj in ipairs(root:GetDescendants()) do
        baseline[obj] = true
    end
end

local playerGui = LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui")
rememberBaseline(playerGui)
pcall(function() rememberBaseline(CoreGui) end)

local function validFrame(frame)
    if not frame or not frame.Parent or not frame:IsA("Frame") then return false end
    if baseline[frame] then return false end
    if frame.Name == "PsicoScamRestore" or frame:FindFirstAncestor("PsicoScamRestore") then return false end

    local size = frame.AbsoluteSize
    if size.X < 180 or size.Y < 120 then return false end
    return true
end

local function scoreFrame(frame)
    if not validFrame(frame) then return -1 end
    local size = frame.AbsoluteSize
    local area = size.X * size.Y

    local depth = 0
    local p = frame.Parent
    while p and not p:IsA("ScreenGui") do
        depth += 1
        p = p.Parent
    end

    return area - depth * 15000
end

local function track(obj)
    if obj and obj:IsA("Frame") and not baseline[obj] then
        candidates[obj] = true
    end
end

for _, root in ipairs({playerGui, CoreGui}) do
    pcall(function()
        addConn(root.DescendantAdded:Connect(track))
    end)
end

local function makeRestoreButton(screenGui, frame)
    local b = Instance.new("TextButton")
    b.Name = "PsicoScamRestore"
    b.Size = UDim2.fromOffset(48, 48)
    b.Position = UDim2.new(1, -62, 0.48, 0)
    b.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.Text = "SC"
    b.TextColor3 = Color3.fromRGB(245, 245, 250)
    b.TextSize = 13
    b.Visible = false
    b.Active = true
    b.ZIndex = 100000
    b.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = b

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.35
    stroke.Color = Color3.fromRGB(105, 120, 175)
    stroke.Parent = b

    local dragging = false
    local moved = false
    local startInput
    local startPos
    local dragInput

    addConn(b.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            moved = false
            startInput = input.Position
            startPos = b.Position
        end
    end))

    addConn(b.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseMovement then
            dragInput = input
        end
    end))

    addConn(UserInputService.InputChanged:Connect(function(input)
        if dragging and input == dragInput and startInput and startPos then
            local delta = input.Position - startInput
            if delta.Magnitude > 5 then moved = true end
            b.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end))

    addConn(UserInputService.InputEnded:Connect(function(input)
        if dragging
        and (input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1) then
            dragging = false
            if not moved and frame and frame.Parent then
                frame.Visible = true
                b.Visible = false
            end
        end
    end))

    return b
end

local function attach(frame)
    if attachedFrame or not validFrame(frame) then return false end

    local screenGui = frame:FindFirstAncestorOfClass("ScreenGui")
    if not screenGui then return false end

    attachedFrame = frame

    local b = Instance.new("TextButton")
    b.Name = "PsicoScamMinimize"
    b.AnchorPoint = Vector2.new(1, 0)
    b.Position = UDim2.new(1, -8, 0, 6)
    b.Size = UDim2.fromOffset(32, 28)
    b.BackgroundColor3 = Color3.fromRGB(35, 38, 48)
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.Text = "—"
    b.TextColor3 = Color3.fromRGB(240, 240, 245)
    b.TextSize = 18
    b.ZIndex = math.max(frame.ZIndex + 100, 1000)
    b.Parent = frame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = b

    minimizeButton = b
    restoreButton = makeRestoreButton(screenGui, frame)

    addConn(b.MouseButton1Click:Connect(function()
        if frame and frame.Parent then
            frame.Visible = false
            if restoreButton then restoreButton.Visible = true end
        end
    end))

    return true
end

local function chooseBest()
    if attachedFrame and attachedFrame.Parent then return end
    attachedFrame = nil

    local best, bestScore = nil, -1
    for frame in pairs(candidates) do
        local score = scoreFrame(frame)
        if score > bestScore then
            best = frame
            bestScore = score
        end
    end

    if best then attach(best) end
end

task.spawn(function()
    while running do
        task.wait(0.75)
        chooseBest()
    end
end)

local function stop()
    if not running then return end
    running = false
    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end
    pcall(function() if minimizeButton then minimizeButton:Destroy() end end)
    pcall(function() if restoreButton then restoreButton:Destroy() end end)
    if G.PSICO_SCAM_MIN_STOP == stop then
        G.PSICO_SCAM_MIN_STOP = nil
    end
end

G.PSICO_SCAM_MIN_STOP = stop

local originalUrl = "https://raw.githubusercontent.com/Psicosenatico/Drive-World/0594fd24c7d113c3c985c65170ab6a12646d07a3/Scam%20Drive%20World"
local source = game:HttpGet(originalUrl)
local fn, err = loadstring(source)
if not fn then
    stop()
    error("Scam Drive World compile error: " .. tostring(err))
end
return fn()