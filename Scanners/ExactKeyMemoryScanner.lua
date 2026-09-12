-- ExactKeyMemoryScanner.lua
-- Scanner de memoria em modo SOMENTE LEITURA.
-- Nao preenche TextBox, nao clica UNLOCK e nao consome tentativa de chave.
-- V2: interface compacta + inicio/finalizacao manual + scan focado no callback de validacao.

local G = (getgenv and getgenv()) or _G

-- Evita duas copias concorrentes do scanner.
if type(G.EXACT_KEY_MEMORY_STOP) == "function" then
    pcall(G.EXACT_KEY_MEMORY_STOP, true)
end

local rows = {}
local hits = {}
local seen = {}
local selfFns = {}
local stopRequested = false
local running = false
local finished = false
local scanStartedAt = 0
local scanCount = 0
local ui

local function now()
    return os.clock()
end

local function safe(v)
    local ok, s = pcall(tostring, v)
    return ok and s or "<tostring error>"
end

local function log(s)
    s = tostring(s)
    rows[#rows + 1] = s
    print("[KEY-MEM] " .. s)
end

local function isNoise(value)
    local low = value:lower()
    local noise = {
        ["script access"] = true,
        ["enter your access key to continue"] = true,
        ["access-key"] = true,
        ["get key"] = true,
        ["unlock"] = true,
        ["unlocked"] = true,
        ["that key is not valid."] = true,
        ["access granted."] = true,
        ["candidatos"] = true,
        ["exact-key"] = true,
    }
    if noise[low] then return true end
    if low:match("^https?://") then return true end
    if low:find("rbxasset", 1, true) then return true end
    return false
end

local function add(value, origin, score)
    if type(value) ~= "string" then return end
    if #value < 3 or #value > 160 then return end
    if isNoise(value) then return end

    score = score or 0
    if value:match("^[%w%._%-]+$") then score = score + 2 end
    if value:match("%u") and value:match("%d") then score = score + 2 end
    if value:find("-", 1, true) then score = score + 1 end
    if #value >= 6 and #value <= 64 then score = score + 1 end

    hits[#hits + 1] = {
        value = value,
        origin = origin,
        score = score,
    }
end

local function constants(fn)
    local candidates = {
        rawget(G, "getconstants"),
        debug and debug.getconstants,
    }
    for _, f in ipairs(candidates) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local function upvalues(fn)
    local candidates = {
        rawget(G, "getupvalues"),
        debug and debug.getupvalues,
    }
    for _, f in ipairs(candidates) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local function protos(fn)
    local candidates = {
        rawget(G, "getprotos"),
        debug and debug.getprotos,
    }
    for _, f in ipairs(candidates) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local inspectFunction
local inspectTable

inspectTable = function(t, origin, depth, inheritedScore)
    if stopRequested then return end
    if type(t) ~= "table" or seen[t] or depth > 7 then return end
    seen[t] = true

    local n = 0
    for k, v in pairs(t) do
        if stopRequested then return end
        n = n + 1
        if n > 700 then break end

        if type(k) == "string" then
            if v == true then
                -- Forte evidencia de VALID_KEYS["senha"] = true.
                add(k, origin .. "[key=true]", 35 + (inheritedScore or 0))
            end

            local lk = k:lower()
            if type(v) == "string" and (
                lk:find("key", 1, true)
                or lk:find("pass", 1, true)
                or lk:find("access", 1, true)
                or lk:find("secret", 1, true)
            ) then
                add(v, origin .. "[" .. k .. "]", 30 + (inheritedScore or 0))
            end
        end

        if type(v) == "string" then
            add(v, origin .. "[value]", inheritedScore or 0)
        elseif type(v) == "table" then
            inspectTable(v, origin .. "[table]", depth + 1, inheritedScore)
        elseif type(v) == "function" and not selfFns[v] then
            inspectFunction(v, origin .. "[function]", depth + 1, inheritedScore)
        end
    end
end

local function functionMarkerScore(fn)
    local c = constants(fn)
    if not c then return 0, nil end

    local score = 0
    for _, v in pairs(c) do
        if type(v) == "string" then
            local l = v:lower()
            if l:find("that key is not valid", 1, true) then score = score + 25 end
            if l:find("access granted", 1, true) then score = score + 25 end
            if l == "unlock" then score = score + 8 end
            if l == "access-key" then score = score + 8 end
            if l:find("1/3", 1, true) or l:find("2/3", 1, true) or l:find("3/3", 1, true) then score = score + 6 end
            if l:find("key", 1, true) and l:find("valid", 1, true) then score = score + 10 end
        end
    end

    return score, c
end

inspectFunction = function(fn, origin, depth, inheritedScore)
    if stopRequested then return end
    if type(fn) ~= "function" or selfFns[fn] or seen[fn] or depth > 7 then return end
    seen[fn] = true

    local markerScore, c = functionMarkerScore(fn)
    local totalScore = math.max(markerScore, inheritedScore or 0)

    if c then
        for i, v in pairs(c) do
            if type(v) == "string" then
                add(v, origin .. ".const[" .. tostring(i) .. "]", totalScore)
            end
        end
    end

    local u = upvalues(fn)
    if u then
        for k, v in pairs(u) do
            if stopRequested then return end
            local p = origin .. ".upvalue[" .. tostring(k) .. "]"
            if type(v) == "string" then
                add(v, p, totalScore + 8)
            elseif type(v) == "table" then
                inspectTable(v, p, depth + 1, totalScore + 5)
            elseif type(v) == "function" and not selfFns[v] then
                inspectFunction(v, p, depth + 1, totalScore + 3)
            end
        end
    end

    local ps = protos(fn)
    if ps then
        for i, p in pairs(ps) do
            if type(p) == "function" and not selfFns[p] then
                inspectFunction(p, origin .. ".proto[" .. tostring(i) .. "]", depth + 1, totalScore)
            end
        end
    end
end

local function buildList()
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
            return #a.value < #b.value
        end
        return a.score > b.score
    end)
    return list
end

local function makeReport(stateText)
    local list = buildList()
    local reportRows = {}

    reportRows[#reportRows + 1] = "Estado: " .. tostring(stateText or "finalizado")
    reportRows[#reportRows + 1] = "Objetos GC verificados: " .. tostring(scanCount)
    reportRows[#reportRows + 1] = "Tempo: " .. string.format("%.2fs", scanStartedAt > 0 and (now() - scanStartedAt) or 0)
    reportRows[#reportRows + 1] = ""
    reportRows[#reportRows + 1] = "========== CANDIDATOS =========="

    for i, h in ipairs(list) do
        if i > 150 then break end
        reportRows[#reportRows + 1] = string.format(
            "[%03d] score=%d | %q | %s",
            i,
            h.score,
            h.value,
            h.origin
        )
    end

    local report = table.concat(reportRows, "\n")
    G.EXACT_KEY_MEMORY_RESULTS = list
    G.EXACT_KEY_MEMORY_REPORT = report
    return report, list
end

local function saveReport(stateText)
    local report, list = makeReport(stateText)
    local name = "ExactKeyMemory_" .. tostring(os.time()) .. ".txt"
    if type(writefile) == "function" then
        local ok = pcall(writefile, name, report)
        if ok then
            log("Relatorio salvo em: " .. name)
        end
    end
    return report, list, name
end

-- =========================
-- Interface compacta
-- =========================
local function parentForGui()
    local ok, result
    if type(gethui) == "function" then
        ok, result = pcall(gethui)
        if ok and result then return result end
    end
    ok, result = pcall(function() return game:GetService("CoreGui") end)
    if ok and result then return result end
    local plr = game:GetService("Players").LocalPlayer
    return plr and plr:FindFirstChildOfClass("PlayerGui")
end

local function makeGui()
    local old
    pcall(function()
        old = parentForGui():FindFirstChild("ExactKeyMemoryScannerUI")
    end)
    if old then pcall(function() old:Destroy() end) end

    local sg = Instance.new("ScreenGui")
    sg.Name = "ExactKeyMemoryScannerUI"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.Size = UDim2.fromOffset(250, 112)
    frame.Position = UDim2.new(0.5, -125, 0.12, 0)
    frame.BackgroundColor3 = Color3.fromRGB(19, 23, 31)
    frame.BorderSizePixel = 0
    frame.Parent = sg

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.4
    stroke.Color = Color3.fromRGB(96, 110, 140)
    stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(10, 7)
    title.Size = UDim2.new(1, -20, 0, 20)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(245, 247, 250)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "KEY MEMORY SCAN"
    title.Parent = frame

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.BackgroundTransparency = 1
    status.Position = UDim2.fromOffset(10, 29)
    status.Size = UDim2.new(1, -20, 0, 24)
    status.Font = Enum.Font.Gotham
    status.TextSize = 11
    status.TextColor3 = Color3.fromRGB(170, 180, 198)
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Text = "Pronto para iniciar"
    status.Parent = frame

    local start = Instance.new("TextButton")
    start.Name = "Start"
    start.Position = UDim2.fromOffset(10, 63)
    start.Size = UDim2.fromOffset(108, 36)
    start.BackgroundColor3 = Color3.fromRGB(60, 126, 255)
    start.BorderSizePixel = 0
    start.Font = Enum.Font.GothamBold
    start.TextSize = 12
    start.TextColor3 = Color3.new(1, 1, 1)
    start.Text = "INICIAR"
    start.Parent = frame
    Instance.new("UICorner", start).CornerRadius = UDim.new(0, 8)

    local finish = Instance.new("TextButton")
    finish.Name = "Finish"
    finish.Position = UDim2.fromOffset(132, 63)
    finish.Size = UDim2.fromOffset(108, 36)
    finish.BackgroundColor3 = Color3.fromRGB(54, 63, 80)
    finish.BorderSizePixel = 0
    finish.Font = Enum.Font.GothamBold
    finish.TextSize = 12
    finish.TextColor3 = Color3.new(1, 1, 1)
    finish.Text = "FINALIZAR"
    finish.Parent = frame
    Instance.new("UICorner", finish).CornerRadius = UDim.new(0, 8)

    -- Drag simples para celular/PC.
    local dragging = false
    local dragStart, startPos
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end)
    frame.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    sg.Parent = parentForGui()
    return sg, frame, status, start, finish
end

local statusLabel, startButton, finishButton
ui, _, statusLabel, startButton, finishButton = makeGui()

local function setStatus(text, color)
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = text
        if color then statusLabel.TextColor3 = color end
    end
end

local function finishScanner(closeUi)
    if finished then
        if closeUi and ui then pcall(function() ui:Destroy() end) end
        return
    end

    if running then
        stopRequested = true
        setStatus("Finalizando...", Color3.fromRGB(255, 202, 92))
        return
    end

    finished = true
    local _, list = saveReport("finalizado")
    setStatus("Salvo: " .. tostring(#list) .. " candidatos", Color3.fromRGB(102, 220, 145))

    if closeUi then
        task.delay(0.8, function()
            if ui then pcall(function() ui:Destroy() end) end
        end)
    end
end

G.EXACT_KEY_MEMORY_STOP = function(closeUi)
    stopRequested = true
    if not running then finishScanner(closeUi ~= false) end
end

local function runScan()
    if running or finished then return end
    if type(getgc) ~= "function" then
        setStatus("ERRO: getgc indisponivel", Color3.fromRGB(255, 110, 110))
        log("ERRO: executor nao possui getgc().")
        return
    end

    running = true
    stopRequested = false
    scanStartedAt = now()
    scanCount = 0
    hits = {}
    seen = {}

    startButton.Text = "LENDO..."
    startButton.AutoButtonColor = false
    setStatus("Escaneando memoria...", Color3.fromRGB(105, 170, 255))

    task.spawn(function()
        local ok, gc = pcall(getgc, true)
        if not ok or type(gc) ~= "table" then
            running = false
            startButton.Text = "INICIAR"
            startButton.AutoButtonColor = true
            setStatus("ERRO: getgc(true) falhou", Color3.fromRGB(255, 110, 110))
            return
        end

        log("Objetos GC: " .. tostring(#gc))

        -- PASSO 1: localiza apenas funcoes com marcas do gate.
        local marked = {}
        for i, obj in ipairs(gc) do
            if stopRequested then break end
            scanCount = i
            if (i % 350) == 0 then
                setStatus("Procurando validator... " .. tostring(i) .. "/" .. tostring(#gc), Color3.fromRGB(105, 170, 255))
                task.wait()
            end

            if type(obj) == "function" and not selfFns[obj] then
                local score = functionMarkerScore(obj)
                if score >= 10 then
                    marked[#marked + 1] = {fn = obj, index = i, score = score}
                end
            end
        end

        log("Callbacks candidatos do gate: " .. tostring(#marked))

        -- PASSO 2: segue constants/upvalues/protos somente desses callbacks.
        for n, item in ipairs(marked) do
            if stopRequested then break end
            setStatus("Lendo callback " .. n .. "/" .. #marked, Color3.fromRGB(105, 170, 255))
            inspectFunction(item.fn, "gc[" .. tostring(item.index) .. "]", 0, item.score)
            task.wait()
        end

        -- Fallback leve: se nenhum callback marcado apareceu, examina funcoes,
        -- mas NAO percorre todas as tabelas globais do jogo.
        if #marked == 0 and not stopRequested then
            log("Nenhum callback marcado; iniciando fallback leve.")
            for i, obj in ipairs(gc) do
                if stopRequested then break end
                scanCount = i
                if (i % 500) == 0 then
                    setStatus("Fallback... " .. tostring(i) .. "/" .. tostring(#gc), Color3.fromRGB(255, 202, 92))
                    task.wait()
                end
                if type(obj) == "function" and not selfFns[obj] then
                    local u = upvalues(obj)
                    if u then
                        for k, v in pairs(u) do
                            if type(v) == "table" then
                                -- Somente tabelas pequenas/relevantes acabarao produzindo scores uteis.
                                inspectTable(v, "gc[" .. i .. "].upvalue[" .. safe(k) .. "]", 0, 0)
                            end
                        end
                    end
                end
            end
        end

        running = false
        local state = stopRequested and "interrompido pelo usuario" or "scan concluido"
        local _, list = saveReport(state)

        if stopRequested then
            setStatus("Interrompido: " .. tostring(#list) .. " candidatos", Color3.fromRGB(255, 202, 92))
        else
            setStatus("Concluido: " .. tostring(#list) .. " candidatos", Color3.fromRGB(102, 220, 145))
        end

        startButton.Text = "CONCLUIDO"
        startButton.AutoButtonColor = false
        finished = true
    end)
end

-- Marca todas as funcoes internas do proprio scanner para nao auto-contaminar o resultado.
for _, fn in ipairs({
    now, safe, log, isNoise, add, constants, upvalues, protos,
    inspectTable, functionMarkerScore, inspectFunction, buildList,
    makeReport, saveReport, parentForGui, makeGui, setStatus,
    finishScanner, runScan,
}) do
    if type(fn) == "function" then selfFns[fn] = true end
end

startButton.MouseButton1Click:Connect(runScan)
finishButton.MouseButton1Click:Connect(function()
    if running then
        stopRequested = true
        setStatus("Finalizando...", Color3.fromRGB(255, 202, 92))
    else
        finishScanner(true)
    end
end)

setStatus("Pronto — toque INICIAR", Color3.fromRGB(170, 180, 198))
log("Interface pronta. O scan so comeca quando voce tocar INICIAR.")
