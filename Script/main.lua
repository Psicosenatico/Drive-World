-- PSICOSENATICO | Drive World Vehicle Menu V5.3
-- Usa a V5 funcional como base e adiciona somente a protecao da re.

local CORE_URL = "https://raw.githubusercontent.com/Psicosenatico/Drive-World/8a326ee9a89d7080667d5a4a40ddfc6506a1869b/Script/main.lua"

local source = game:HttpGet(CORE_URL)
local fn, compileError = loadstring(source)
if not fn then
    error("Drive World V5.3: falha ao compilar a V5 base: " .. tostring(compileError))
end

local ok, runtimeError = pcall(fn)
if not ok then
    error("Drive World V5.3: falha ao executar a V5 base: " .. tostring(runtimeError))
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

if type(G.PSICO_REVERSE_GUARD_STOP) == "function" then
    pcall(G.PSICO_REVERSE_GUARD_STOP)
end

local running = true
local conns = {}
local preForwardSpeed = nil
local pressureButton = nil
local versionMarked = false

local function add(conn)
    conns[#conns + 1] = conn
    return conn
end

local function findMenu()
    local gui = CoreGui:FindFirstChild("PsicoDriveMenuV5")
    if gui then return gui end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    return pg and pg:FindFirstChild("PsicoDriveMenuV5") or nil
end

local function refreshMenuRefs()
    local gui = findMenu()
    if not gui then return end

    pressureButton = nil
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextLabel") then
            local text = tostring(obj.Text or "")
            if text:find("PSICOSENATICO", 1, true) and text:find("DRIVE WORLD", 1, true) then
                obj.Text = "PSICOSENATICO • DRIVE WORLD V5.3"
                versionMarked = true
            end
        elseif obj:IsA("TextButton") then
            local text = string.upper(tostring(obj.Text or ""))
            if text:find("PRESSAO", 1, true) or text:find("PRESSÃO", 1, true) then
                pressureButton = obj
            end
        end
    end
end

local function pressureOn()
    if not pressureButton or not pressureButton.Parent then
        refreshMenuRefs()
    end
    if not pressureButton then return false end
    return string.upper(tostring(pressureButton.Text or "")):find(": ON", 1, true) ~= nil
end

local function getVehicleSeatMain()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if not seat then return nil, nil, nil end

    local vehicle = seat:FindFirstAncestorOfClass("Model")
    local cars = workspace:FindFirstChild("Cars")
    if cars then
        local node = seat
        while node and node.Parent and node.Parent ~= cars do
            node = node.Parent
        end
        if node and node.Parent == cars and node:IsA("Model") then
            vehicle = node
        end
    end

    if not vehicle then return nil, seat, nil end
    local main = vehicle:FindFirstChild("Main")
    if not (main and main:IsA("BasePart")) then
        main = vehicle.PrimaryPart
    end
    return vehicle, seat, main
end

local function readGearText(vehicle)
    if not vehicle then return nil end

    for _, obj in ipairs(vehicle:GetDescendants()) do
        if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and string.lower(obj.Name) == "currentgear" then
            return string.upper(tostring(obj.Text or ""):gsub("%s+", ""))
        end
    end

    return nil
end

local function reverseOrNeutral(vehicle, seat, forwardSpeed)
    local gearText = readGearText(vehicle)
    if gearText == "R" or gearText == "RE" or gearText == "REVERSE" or gearText == "N" or gearText == "NEUTRAL" then
        return true
    end

    if seat and seat:IsA("VehicleSeat") then
        local throttle = nil
        pcall(function() throttle = seat.ThrottleFloat end)
        if type(throttle) == "number" and throttle < -0.04 then
            return true
        end
    end

    if forwardSpeed < -0.05 then
        return true
    end

    return false
end

local function stop()
    if not running then return end
    running = false
    for _, conn in ipairs(conns) do
        pcall(function() conn:Disconnect() end)
    end
    if G.PSICO_REVERSE_GUARD_STOP == stop then
        G.PSICO_REVERSE_GUARD_STOP = nil
    end
end

G.PSICO_REVERSE_GUARD_STOP = stop
refreshMenuRefs()

add(RunService.PreSimulation:Connect(function()
    if not running or not pressureOn() then
        preForwardSpeed = nil
        return
    end

    local _, _, main = getVehicleSeatMain()
    if main and main:IsDescendantOf(workspace) then
        preForwardSpeed = main.AssemblyLinearVelocity:Dot(main.CFrame.LookVector)
    else
        preForwardSpeed = nil
    end
end))

add(RunService.Heartbeat:Connect(function()
    if not running then return end

    if not versionMarked or not pressureButton or not pressureButton.Parent then
        refreshMenuRefs()
    end

    if not pressureOn() then return end

    local vehicle, seat, main = getVehicleSeatMain()
    if not main or not main:IsDescendantOf(workspace) then return end

    local cf = main.CFrame
    local nowForward = main.AssemblyLinearVelocity:Dot(cf.LookVector)
    local before = preForwardSpeed
    if type(before) ~= "number" then return end

    if not reverseOrNeutral(vehicle, seat, nowForward) then return end

    -- Em R/N/re, nunca permitimos que o frame termine com mais velocidade
    -- para frente do que tinha antes da simulacao. Assim removemos somente
    -- o empurrao artificial para frente e preservamos a re natural do jogo.
    if nowForward > before then
        local delta = nowForward - before
        main.AssemblyLinearVelocity = main.AssemblyLinearVelocity - cf.LookVector * delta
    end
end))

print("[PSICOSENATICO] Drive World V5.3 carregado")