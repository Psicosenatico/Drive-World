-- ExactKeyMemoryScanner.lua
-- V3 - scanner somente leitura para localizar a chave EXATA embutida no gate SCRIPT ACCESS.
-- NAO preenche o TextBox, NAO clica UNLOCK e NAO consome tentativa.
-- Fluxo: callback direto do botao -> funcoes marcadas -> fallback amplo controlado.

local G = (getgenv and getgenv()) or _G

if type(G.EXACT_KEY_MEMORY_STOP) == "function" then
    pcall(G.EXACT_KEY_MEMORY_STOP, true)
end

local rows = {}
local hits = {}
local seen = {}
local inspectedFunctions = {}
local selfFunctions = {}
local stopRequested = false
local running = false
local finished = false
local ui, statusLabel, startButton, stopButton
local scannedGC = 0
local callbackCount = 0
local markerFunctionCount = 0
local startedAt = 0

local function safe(v)
    local ok, s = pcall(tostring, v)
    return ok and s or "<tostring error>"
end

local function log(s)
    s = tostring(s)
    rows[#rows + 1] = s
    print("[KEY-MEM-V3] " .. s)
end

local function setStatus(text)
    if statusLabel then
        pcall(function() statusLabel.Text = tostring(text) end)
    end
end

local noise = {
    ["script access"] = true,
    ["enter your access key to continue"] = true,
    ["access-key"] = true,
    ["get key"] = true,
    ["unlock"] = true,
    ["unlocked"] = true,
    ["that key is not valid."] = true,
    ["that key is not valid"] = true,
    ["access granted."] = true,
    ["access granted"] = true,
    ["copied to clipboard."] = true,
    ["mousebutton1click"] = true,
    ["activated"] = true,
    ["textbutton"] = true,
    ["textbox"] = true,
}

local function looksInterestingString(value)
    if type(value) ~= "string" then return false end
    if #value < 3 or #value > 160 then return false end
    local low = value:lower()
    if noise[low] then return false end
    if low:match("^https?://") then return false end
    if low:find("rbxasset", 1, true) then return false end
    if low:find("enum.", 1, true) then return false end
    return true
end

local function add(value, origin, score)
    if not looksInterestingString(value) then return end

    score = score or 0
    if value:match("^[%w%._%-]+$") then score = score + 2 end
    if value:match("%u") and value:match("%d") then score = score + 3 end
    if value:find("-", 1, true) then score = score + 2 end
    if #value >= 6 and #value <= 64 then score = score + 2 end
    if value:lower():find("key", 1, true) then score = score + 3 end

    hits[#hits + 1] = {
        value = value,
        origin = origin,
        score = score,
    }
end

local function getConstants(fn)
    local funcs = {
        rawget(G, "getconstants"),
        debug and debug.getconstants,
    }
    for _, f in ipairs(funcs) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local function getUpvalues(fn)
    local funcs = {
        rawget(G, "getupvalues"),
        debug and debug.getupvalues,
    }
    for _, f in ipairs(funcs) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local function getProtos(fn)
    local funcs = {
        rawget(G, "getprotos"),
        debug and debug.getprotos,
    }
    for _, f in ipairs(funcs) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local inspectValue
local inspectFunction

local function markerScoreFromConstants(c)
    if type(c) ~= "table" then return 0 end
    local score = 0
    for _, v in pairs(c) do
        if type(v) == "string" then
            local l = v:lower()
            if l:find("that key is not valid", 1, true) then score = score + 30 end
            if l:find("access granted", 1, true) then score = score + 30 end
            if l == "unlock" then score = score + 12 end
            if l == "access-key" then score = score + 12 end
            if l:find("attempt", 1, true) then score = score + 6 end
        end
    end
    return score
end

inspectValue = function(v, origin, depth, inheritedScore)
    if stopRequested then return end
    depth = depth or 0
    inheritedScore = inheritedScore or 0
    if depth > 8 then return end

    if type(v) == "string" then
        add(v, origin, inheritedScore)
        return
    end

    if type(v) == "function" then
        inspectFunction(v, origin, depth + 1, inheritedScore)
        return
    end

    if type(v) ~= "table" or seen[v] then return end
    seen[v] = true

    local n = 0
    for k, val in pairs(v) do
        if stopRequested then return end
        n = n + 1
        if n > 800 then break end

        if type(k) == "string" then
            local lk = k:lower()
            if val == true then
                add(k, origin .. "[key=true]", inheritedScore + 35)
            elseif type(val) == "string" and (
                lk:find("key", 1, true)
                or lk:find("pass", 1, true)
                or lk:find("access", 1, true)
                or lk:find("code", 1, true)
            ) then
                add(val, origin .. "[" .. k .. "]", inheritedScore + 35)
            end
        end

        if type(val) == "string" then
            add(val, origin .. "[value]", inheritedScore)
        elseif type(val) == "table" or type(val) == "function" then
            inspectValue(val, origin .. "[" .. safe(k) .. "]", depth + 1, inheritedScore)
        end
    end
end

inspectFunction = function(fn, origin, depth, inheritedScore)
    if stopRequested then return end
    if type(fn) ~= "function" or inspectedFunctions[fn] or selfFunctions[fn] then return end
    depth = depth or 0
    inheritedScore = inheritedScore or 0
    if depth > 8 then return end

    inspectedFunctions[fn] = true

    local consts = getConstants(fn)
    local markerScore = markerScoreFromConstants(consts)
    local score = inheritedScore + markerScore

    if markerScore > 0 then
        markerFunctionCount = markerFunctionCount + 1
    end

    if consts then
        for i, v in pairs(consts) do
            if type(v) == "string" then
                add(v, origin .. ".const[" .. tostring(i) .. "]", score + (markerScore > 0 and 10 or 0))
            elseif type(v) == "table" then
                inspectValue(v, origin .. ".const[" .. tostring(i) .. "]", depth + 1, score)
            end
        end
    end

    local ups = getUpvalues(fn)
    if ups then
        for k, v in pairs(ups) do
            if type(v) == "string" then
                add(v, origin .. ".upvalue[" .. safe(k) .. "]", score + 18)
            elseif type(v) == "table" or type(v) == "function" then
                inspectValue(v, origin .. ".upvalue[" .. safe(k) .. "]", depth + 1, score + 12)
            end
        end
    end

    local protos = getProtos(fn)
    if protos then
        for i, p in pairs(protos) do
            if type(p) == "function" then
                inspectFunction(p, origin .. ".proto[" .. tostring(i) .. "]", depth + 1, score + 8)
            end
        end
    end
end

local function roots()
    local list = {}
    pcall(function()
        list[#list + 1] = game:GetService("CoreGui")
    end)
    pcall(function()
        local plr = game:GetService("Players").LocalPlayer
        if plr then
            local pg = plr:FindFirstChildOfClass("PlayerGui")
            if pg then list[#list + 1] = pg end
        end
    end)
    return list
end

local function findGate()
    for _, root in ipairs(roots()) do
        local ok, descendants = pcall(function() return root:GetDescendants() end)
        if ok and type(descendants) == "table" then
            local box, button, screen
            for _, obj in ipairs(descendants) do
                pcall(function()
                    if obj:IsA("TextBox") then
                        local ph = tostring(obj.PlaceholderText or "")
                        if ph:upper():find("ACCESS", 1, true) or ph:lower():find("key", 1, true) then
                            box = box or obj
                        end
                    elseif obj:IsA("TextButton") then
                        local text = tostring(obj.Text or "")
                        if text:upper() == "UNLOCK" or text:lower():find("confirm", 1, true) then
                            button = button or obj
                        end
                    elseif obj:IsA("ScreenGui") then
                        local n = tostring(obj.Name or "")
                        if n:lower():find("key", 1, true) or n:lower():find("loader", 1, true) then
                            screen = screen or obj
                        end
                    end
                end)
            end
            if box and button then return screen, box, button end
        end
    end
end

local function inspectSignal(signal, label)
    if type(getconnections) ~= "function" then return 0 end
    local ok, cons = pcall(getconnections, signal)
    if not ok or type(cons) ~= "table" then return 0 end

    local found = 0
    for i, c in ipairs(cons) do
        if stopRequested then break end
        local fn
        pcall(function() fn = c.Function end)
        if type(fn) == "function" and not selfFunctions[fn] then
            found = found + 1
            callbackCount = callbackCount + 1
            inspectFunction(fn, "UNLOCK." .. label .. ".connection[" .. tostring(i) .. "]", 0, 55)
        end
    end
    return found
end

local function phaseCallback()
    setStatus("Etapa 1/3: callback do UNLOCK")
    local screen, box, button = findGate()
    if not box or not button then
        log("Gate ACCESS-KEY/UNLOCK nao encontrado na interface.")
        return false
    end

    log("Gate encontrado: " .. safe(screen or button))
    log("Botao UNLOCK: " .. safe(button))

    local found = 0
    pcall(function() found = found + inspectSignal(button.MouseButton1Click, "MouseButton1Click") end)
    pcall(function() found = found + inspectSignal(button.Activated, "Activated") end)

    log("Callbacks acessiveis no UNLOCK: " .. tostring(found))
    return found > 0
end

local function phaseMarkedGC(gc)
    setStatus("Etapa 2/3: validator na memoria")
    for i, obj in ipairs(gc) do
        if stopRequested then return end
        if type(obj) == "function" and not selfFunctions[obj] then
            local c = getConstants(obj)
            if markerScoreFromConstants(c) > 0 then
                inspectFunction(obj, "gc-marker[" .. tostring(i) .. "]", 0, 45)
            end
        end
        if i % 700 == 0 then
            setStatus("Etapa 2/3: " .. tostring(i) .. "/" .. tostring(#gc))
            task.wait()
        end
    end
end

local function phaseFallback(gc)
    -- So entra se as fases focadas nao produziram candidatos fortes.
    setStatus("Etapa 3/3: fallback seguro")
    for i, obj in ipairs(gc) do
        if stopRequested then return end
        if type(obj) == "function" and not selfFunctions[obj] then
            local ups = getUpvalues(obj)
            if ups then
                for k, v in pairs(ups) do
                    if type(v) == "string" then
                        add(v, "fallback.gc[" .. tostring(i) .. "].upvalue[" .. safe(k) .. "]", 3)
                    elseif type(v) == "table" then
                        -- Profundidade menor no fallback para evitar varrer o jogo inteiro.
                        local oldSeen = seen[v]
                        if not oldSeen then
                            inspectValue(v, "fallback.gc[" .. tostring(i) .. "].upvalue[" .. safe(k) .. "]", 5, 1)
                        end
                    end
                end
            end
        end
        if i % 700 == 0 then
            setStatus("Etapa 3/3: " .. tostring(i) .. "/" .. tostring(#gc))
            task.wait()
        end
    end
end

local function buildResult()
    local best = {}
    for _, h in ipairs(hits) do
        local old = best[h.value]
        if not old or h.score > old.score then
            best[h.value] = h
        end
    end

    local list = {}
    for _, h in pairs(best) do list[#list + 1] = h end
    table.sort(list, function(a, b)
        if a.score == b.score then
            if #a.value == #b.value then return a.value < b.value end
            return #a.value < #b.value
        end
        return a.score > b.score
    end)
    return list
end

local function saveReport(stateText)
    local result = buildResult()
    local finalRows = {}
    finalRows[#finalRows + 1] = "Estado: " .. tostring(stateText)
    finalRows[#finalRows + 1] = "Objetos GC verificados: " .. tostring(scannedGC)
    finalRows[#finalRows + 1] = "Callbacks UNLOCK acessiveis: " .. tostring(callbackCount)
    finalRows[#finalRows + 1] = "Funcoes validator marcadas: " .. tostring(markerFunctionCount)
    finalRows[#finalRows + 1] = string.format("Tempo: %.2fs", startedAt > 0 and (os.clock() - startedAt) or 0)
    finalRows[#finalRows + 1] = ""
    finalRows[#finalRows + 1] = "========== CANDIDATOS =========="

    for i, h in ipairs(result) do
        if i > 180 then break end
        finalRows[#finalRows + 1] = string.format(
            "[%03d] score=%d | %q | %s",
            i,
            h.score,
            h.value,
            h.origin
        )
    end

    if #result == 0 then
        finalRows[#finalRows + 1] = "<nenhum candidato recuperado>"
    end

    local report = table.concat(finalRows, "\n")
    G.EXACT_KEY_MEMORY_RESULTS = result
    G.EXACT_KEY_MEMORY_REPORT = report

    local filename = "ExactKeyMemory_" .. tostring(os.time()) .. ".txt"
    if type(writefile) == "function" then
        local ok = pcall(writefile, filename, report)
        if ok then log("Relatorio salvo em: " .. filename) end
    end
    return report, result
end

local function runScan()
    if running or finished then return end
    running = true
    stopRequested = false
    startedAt = os.clock()
    rows = {}
    hits = {}
    seen = {}
    inspectedFunctions = {}
    callbackCount = 0
    markerFunctionCount = 0

    setStatus("Iniciando...")
    log("Scanner V3 iniciado em modo somente leitura.")

    if type(getgc) ~= "function" then
        log("ERRO: executor nao possui getgc().")
        setStatus("Erro: getgc indisponivel")
        running = false
        return
    end

    -- Etapa 1: callback real do botao, sem dispara-lo.
    phaseCallback()

    if stopRequested then
        saveReport("scan interrompido")
        setStatus("Interrompido")
        running = false
        finished = true
        return
    end

    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then
        log("ERRO: getgc(true) falhou.")
        setStatus("Erro em getgc")
        running = false
        return
    end
    scannedGC = #gc

    -- Etapa 2: somente funcoes contendo textos do validator.
    phaseMarkedGC(gc)

    local interim = buildResult()
    local strongest = interim[1] and interim[1].score or 0

    -- Etapa 3: fallback apenas se ainda nao recuperamos algo convincente.
    if not stopRequested and strongest < 35 then
        phaseFallback(gc)
    end

    local state = stopRequested and "scan interrompido" or "scan concluido"
    local _, result = saveReport(state)

    if stopRequested then
        setStatus("Interrompido - toque FINALIZAR")
    elseif #result == 0 then
        setStatus("Concluido: 0 candidatos")
    else
        setStatus("Concluido: " .. tostring(#result) .. " candidatos")
    end

    running = false
    finished = true
end

local function destroyUI()
    if ui then
        pcall(function() ui:Destroy() end)
        ui = nil
    end
end

G.EXACT_KEY_MEMORY_STOP = function(silent)
    stopRequested = true
    if running then
        setStatus("Finalizando...")
        local deadline = os.clock() + 2
        while running and os.clock() < deadline do task.wait(0.05) end
    elseif not finished and startedAt > 0 then
        saveReport("scan finalizado")
    end
    if not silent then destroyUI() end
end

local function buildUI()
    local parent
    pcall(function()
        if type(gethui) == "function" then parent = gethui() end
    end)
    if not parent then
        pcall(function() parent = game:GetService("CoreGui") end)
    end
    if not parent then
        local plr = game:GetService("Players").LocalPlayer
        parent = plr and plr:FindFirstChildOfClass("PlayerGui")
    end
    if not parent then return end

    ui = Instance.new("ScreenGui")
    ui.Name = "ExactKeyMemoryScannerV3"
    ui.ResetOnSpawn = false
    ui.IgnoreGuiInset = true
    ui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ui.Parent = parent

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.Size = UDim2.fromOffset(260, 112)
    frame.Position = UDim2.new(0.5, -130, 0.12, 0)
    frame.BackgroundColor3 = Color3.fromRGB(19, 23, 31)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = ui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -16, 0, 24)
    title.Position = UDim2.fromOffset(8, 6)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(240, 243, 250)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "KEY MEMORY SCAN V3"
    title.Parent = frame

    statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -16, 0, 26)
    statusLabel.Position = UDim2.fromOffset(8, 31)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 11
    statusLabel.TextColor3 = Color3.fromRGB(174, 184, 205)
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Text = "Pronto - toque INICIAR"
    statusLabel.Parent = frame

    startButton = Instance.new("TextButton")
    startButton.Size = UDim2.new(0.5, -12, 0, 36)
    startButton.Position = UDim2.fromOffset(8, 66)
    startButton.BackgroundColor3 = Color3.fromRGB(68, 126, 245)
    startButton.BorderSizePixel = 0
    startButton.Font = Enum.Font.GothamBold
    startButton.TextSize = 12
    startButton.TextColor3 = Color3.new(1, 1, 1)
    startButton.Text = "INICIAR"
    startButton.Parent = frame
    Instance.new("UICorner", startButton).CornerRadius = UDim.new(0, 8)

    stopButton = Instance.new("TextButton")
    stopButton.Size = UDim2.new(0.5, -12, 0, 36)
    stopButton.Position = UDim2.new(0.5, 4, 0, 66)
    stopButton.BackgroundColor3 = Color3.fromRGB(48, 55, 69)
    stopButton.BorderSizePixel = 0
    stopButton.Font = Enum.Font.GothamBold
    stopButton.TextSize = 12
    stopButton.TextColor3 = Color3.new(1, 1, 1)
    stopButton.Text = "FINALIZAR"
    stopButton.Parent = frame
    Instance.new("UICorner", stopButton).CornerRadius = UDim.new(0, 8)

    local startConn
    startConn = startButton.MouseButton1Click:Connect(function()
        if running or finished then return end
        startButton.Text = "RODANDO..."
        startButton.AutoButtonColor = false
        task.spawn(runScan)
    end)

    local stopConn
    stopConn = stopButton.MouseButton1Click:Connect(function()
        stopRequested = true
        setStatus("Finalizando...")
        task.spawn(function()
            local deadline = os.clock() + 2
            while running and os.clock() < deadline do task.wait(0.05) end
            if not running and not finished and startedAt > 0 then
                saveReport("scan finalizado")
            end
            destroyUI()
        end)
    end)

    selfFunctions[runScan] = true
    selfFunctions[phaseCallback] = true
    selfFunctions[phaseMarkedGC] = true
    selfFunctions[phaseFallback] = true
    selfFunctions[inspectFunction] = true
    selfFunctions[inspectValue] = true
    selfFunctions[buildResult] = true
    selfFunctions[saveReport] = true

    pcall(function()
        if type(getconnections) == "function" then
            for _, c in ipairs(getconnections(startButton.MouseButton1Click)) do
                local fn
                pcall(function() fn = c.Function end)
                if type(fn) == "function" then selfFunctions[fn] = true end
            end
            for _, c in ipairs(getconnections(stopButton.MouseButton1Click)) do
                local fn
                pcall(function() fn = c.Function end)
                if type(fn) == "function" then selfFunctions[fn] = true end
            end
        end
    end)
end

buildUI()
