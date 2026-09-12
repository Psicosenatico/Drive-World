-- ExactKeyMemoryScannerV6_2.lua
-- V6.2 - TRACE DIFERENCIAL ESTAVEL / CANCELAVEL
-- Nao clica no UNLOCK real, nao escreve no TextBox real e nao consome tentativas.
-- Volta ao isolamento raso que funcionou no V5 e executa cada callback em uma thread cancelavel.

local G = (getgenv and getgenv()) or _G

if type(G.EXACT_KEY_MEMORY_STOP) == "function" then
    pcall(G.EXACT_KEY_MEMORY_STOP, true)
end

local running = false
local finished = false
local cancelRequested = false
local currentWorker = nil
local currentStep = "Pronto"
local ui, statusLabel, startButton, stopButton
local conns = {}
local rows = {}
local reportName = "ExactKeyDiffV6_2_" .. tostring(os.time()) .. ".txt"

local function safe(v)
    local ok, s = pcall(tostring, v)
    return ok and s or "<tostring error>"
end

local function log(s)
    s = tostring(s)
    rows[#rows + 1] = s
    print("[KEY-TRACE-V6.2] " .. s)
end

local function setStatus(s)
    currentStep = tostring(s)
    if statusLabel then
        pcall(function() statusLabel.Text = currentStep end)
    end
end

local function saveReport()
    local report = table.concat(rows, "\n")
    G.EXACT_KEY_MEMORY_REPORT = report
    G.EXACT_KEY_MEMORY_REPORT_NAME = reportName
    if type(writefile) == "function" then
        pcall(writefile, reportName, report)
    end
    return report
end

local function getUps(fn)
    for _, f in ipairs({rawget(G, "getupvalues"), debug and debug.getupvalues}) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local function setUp(fn, idx, value)
    for _, f in ipairs({rawget(G, "setupvalue"), debug and debug.setupvalue}) do
        if type(f) == "function" then
            local ok = pcall(f, fn, idx, value)
            if ok then return true end
        end
    end
    return false
end

local function roots()
    local r = {}
    pcall(function() r[#r + 1] = game:GetService("CoreGui") end)
    pcall(function()
        local p = game:GetService("Players").LocalPlayer
        if p then
            local pg = p:FindFirstChildOfClass("PlayerGui")
            if pg then r[#r + 1] = pg end
        end
    end)
    return r
end

local function findGate()
    for _, root in ipairs(roots()) do
        local ok, desc = pcall(function() return root:GetDescendants() end)
        if ok and type(desc) == "table" then
            local box, button, screen, frame, label
            for _, obj in ipairs(desc) do
                pcall(function()
                    if obj:IsA("TextBox") then
                        local ph = tostring(obj.PlaceholderText or "")
                        if ph:lower():find("key", 1, true) or ph:upper():find("ACCESS", 1, true) then
                            box = box or obj
                            frame = frame or obj.Parent
                            screen = screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    elseif obj:IsA("TextButton") then
                        local tx = tostring(obj.Text or "")
                        if tx:upper() == "UNLOCK" or tx:lower():find("confirm", 1, true) then
                            button = button or obj
                            screen = screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    end
                end)
            end
            if frame then
                pcall(function()
                    for _, c in ipairs(frame:GetChildren()) do
                        if c:IsA("TextLabel") then label = label or c end
                    end
                end)
            end
            if box and button then return screen, frame, box, label, button end
        end
    end
end

local function getCallback(button)
    if type(getconnections) ~= "function" then return nil, "getconnections indisponivel" end
    for _, spec in ipairs({
        {signal = function() return button.MouseButton1Click end, name = "MouseButton1Click"},
        {signal = function() return button.Activated end, name = "Activated"},
    }) do
        local ok, sig = pcall(spec.signal)
        if ok then
            local ok2, cs = pcall(getconnections, sig)
            if ok2 and type(cs) == "table" then
                for i, c in ipairs(cs) do
                    local fn
                    pcall(function() fn = c.Function end)
                    if type(fn) == "function" then
                        return fn, spec.name .. "[" .. tostring(i) .. "]"
                    end
                end
            end
        end
    end
    return nil, "callback nao encontrado"
end

local function tableStats(t)
    local total, strings = 0, 0
    if type(t) ~= "table" then return 0, 0 end
    for _, v in pairs(t) do
        total = total + 1
        if type(v) == "string" then strings = strings + 1 end
    end
    return total, strings
end

local function tableHas(t, target)
    if type(t) ~= "table" then return false end
    for _, v in pairs(t) do if v == target then return true end end
    return false
end

local function locateStateOwner(dispatcher, box)
    local ups = getUps(dispatcher)
    if not ups then return end
    for i, v in pairs(ups) do
        if type(v) == "table" and tableHas(v, box) then
            return dispatcher, i, v
        end
    end
end

local function locatePoolOwner(fn, depth, seen)
    if type(fn) ~= "function" then return end
    depth = depth or 0
    seen = seen or {}
    if depth > 5 or seen[fn] then return end
    seen[fn] = true

    local ups = getUps(fn)
    if not ups then return end
    for i, v in pairs(ups) do
        if type(v) == "table" then
            local total, strings = tableStats(v)
            if total >= 190 and total <= 230 and strings == total then
                return fn, i, v
            end
        elseif type(v) == "function" then
            local a, b, c = locatePoolOwner(v, depth + 1, seen)
            if a then return a, b, c end
        end
    end
end

local function shallowCopy(t)
    local n = {}
    for k, v in pairs(t) do n[k] = v end
    return n
end

local function makeFakeBox(input, onRead)
    return setmetatable({Name = "TextBox", ClassName = "TextBox"}, {
        __index = function(_, k)
            if k == "Text" then onRead(); return input end
            if k == "PlaceholderText" then return "ACCESS-KEY" end
            if k == "ClearTextOnFocus" then return false end
            return nil
        end,
        __newindex = function(t, k, v) rawset(t, k, v) end,
    })
end

local function makeFakeLabel(writes)
    return setmetatable({Name = "TextLabel", ClassName = "TextLabel"}, {
        __index = function(t, k) return rawget(t, k) end,
        __newindex = function(t, k, v)
            if k == "Text" then writes[#writes + 1] = tostring(v) end
            rawset(t, k, v)
        end,
    })
end

local function makeFakeScreen(flag)
    local t = {Name = "KeySystemUI", ClassName = "ScreenGui"}
    t.Destroy = function() flag.value = true end
    return t
end

local function stopThread(th)
    if not th then return end
    if task and type(task.cancel) == "function" then
        pcall(task.cancel, th)
    end
    if coroutine and type(coroutine.close) == "function" then
        pcall(coroutine.close, th)
    end
end

local function describePoolValue(v)
    if type(v) ~= "string" then return type(v) .. "=" .. safe(v) end
    local printable = true
    for i = 1, #v do
        local b = string.byte(v, i)
        if b < 32 or b > 126 then printable = false break end
    end
    if printable then return string.format("str(%d)=%q", #v, v) end
    local h = {}
    for i = 1, math.min(#v, 48) do h[#h + 1] = string.format("%02X", string.byte(v, i)) end
    return string.format("str(%d) hex=%s%s", #v, table.concat(h), #v > 48 and "..." or "")
end

local function runOne(input, cb, cbUps, stateOwner, stateIndex, state, poolOwner, poolIndex, pool, screen, frame, box, label, testNo, totalTests)
    local r = {
        input = input,
        sawText = false,
        done = false,
        ok = false,
        err = nil,
        timedOut = false,
        cancelled = false,
        destroyed = {value = false},
        statusWrites = {},
        poolReads = {},
    }

    -- Mesmo modelo do V5 que concluiu: copias rasas.
    local stateClone = shallowCopy(state)
    local fbox = makeFakeBox(input, function() r.sawText = true end)
    local flabel = makeFakeLabel(r.statusWrites)
    local fscreen = makeFakeScreen(r.destroyed)
    local fframe = {Name = "Frame", ClassName = "Frame"}

    for k, v in pairs(stateClone) do
        if v == box then stateClone[k] = fbox end
        if label and v == label then stateClone[k] = flabel end
        if screen and v == screen then stateClone[k] = fscreen end
        if frame and v == frame then stateClone[k] = fframe end
    end

    local poolProxy = setmetatable({}, {
        __index = function(_, k)
            local v = pool[k]
            if r.sawText and #r.poolReads < 160 then
                r.poolReads[#r.poolReads + 1] = {k = k, v = v}
            end
            return v
        end,
        __newindex = function(t, k, v) rawset(t, k, v) end,
        __len = function() return #pool end,
        __pairs = function() return pairs(pool) end,
        __ipairs = function() return ipairs(pool) end,
    })

    local cbOriginals = {}
    for i, v in pairs(cbUps) do
        if type(v) == "table" then
            cbOriginals[#cbOriginals + 1] = {idx = i, value = v}
        end
    end

    local swappedState = setUp(stateOwner, stateIndex, stateClone)
    local swappedPool = setUp(poolOwner, poolIndex, poolProxy)
    local swappedCb = {}
    for _, e in ipairs(cbOriginals) do
        local cp = shallowCopy(e.value)
        if setUp(cb, e.idx, cp) then swappedCb[#swappedCb + 1] = e end
    end

    local function restore()
        pcall(setUp, stateOwner, stateIndex, state)
        pcall(setUp, poolOwner, poolIndex, pool)
        for _, e in ipairs(swappedCb) do pcall(setUp, cb, e.idx, e.value) end
    end

    if not swappedState or not swappedPool then
        r.err = "falha ao trocar state/pool"
        r.done = true
        restore()
        return r
    end

    local started = os.clock()
    local TIMEOUT = 1.75

    currentWorker = task.spawn(function()
        local ok, err = pcall(cb)
        r.ok = ok
        r.err = err
        r.done = true
    end)

    while not r.done do
        local elapsed = os.clock() - started
        setStatus(string.format("Teste %d/%d  %.1fs", testNo, totalTests, elapsed))

        if cancelRequested then
            r.cancelled = true
            stopThread(currentWorker)
            r.done = true
            r.err = "cancelado pelo usuario"
            break
        end

        if elapsed >= TIMEOUT then
            r.timedOut = true
            stopThread(currentWorker)
            r.done = true
            r.err = "timeout seguro de " .. tostring(TIMEOUT) .. "s"
            break
        end

        task.wait(0.05)
    end

    currentWorker = nil
    restore()
    return r
end

local function runTrace()
    if running then
        setStatus(currentStep)
        return
    end
    if finished then
        setStatus("Ja concluido - FINALIZAR fecha")
        return
    end

    running = true
    cancelRequested = false
    rows = {}
    if startButton then
        startButton.Text = "EM ANDAMENTO"
        startButton.AutoButtonColor = false
    end

    log("ExactKeyMemoryScanner V6.2")
    log("Modo: diferencial estavel / thread cancelavel / sem clique real")
    setStatus("Localizando callback...")

    local screen, frame, box, label, button = findGate()
    if not box or not button then
        log("ERRO: gate nao encontrado")
        setStatus("Gate nao encontrado")
        running = false
        saveReport()
        return
    end

    local cb, cbName = getCallback(button)
    if type(cb) ~= "function" then
        log("ERRO: " .. tostring(cbName))
        setStatus("Callback inacessivel")
        running = false
        saveReport()
        return
    end
    log("Callback: " .. cbName .. " => " .. safe(cb))

    local cbUps = getUps(cb)
    local dispatcher
    if cbUps then
        for _, v in pairs(cbUps) do
            if not dispatcher and type(v) == "function" then dispatcher = v end
        end
    end
    if not dispatcher then
        log("ERRO: dispatcher nao encontrado")
        setStatus("Dispatcher nao encontrado")
        running = false
        saveReport()
        return
    end

    local stateOwner, stateIndex, state = locateStateOwner(dispatcher, box)
    local poolOwner, poolIndex, pool = locatePoolOwner(dispatcher, 0, {})
    if not state or not pool then
        log("ERRO: state/pool nao encontrados")
        setStatus("State/pool nao encontrados")
        running = false
        saveReport()
        return
    end

    local base = "__KEY_TRACE_SENTINEL_V5__" -- 25 chars; ja concluiu no V5
    local n = #base
    local tests = {
        base,
        base:sub(1, n - 1) .. "X",
        "X" .. base:sub(2),
        base:sub(1, 12) .. "Z" .. base:sub(14),
    }

    log("Comprimento dos testes: " .. tostring(n))
    log("Total de testes: " .. tostring(#tests))
    saveReport()

    for ti, input in ipairs(tests) do
        if cancelRequested then break end
        setStatus("Preparando teste " .. ti .. "/" .. #tests)

        local r = runOne(input, cb, cbUps, stateOwner, stateIndex, state, poolOwner, poolIndex, pool, screen, frame, box, label, ti, #tests)

        log("")
        log("========== TESTE " .. ti .. " ==========")
        log("INPUT=" .. string.format("%q", input))
        log("TextBox.Text lido: " .. tostring(r.sawText))
        log("Callback ok: " .. tostring(r.ok))
        log("Erro/saida: " .. safe(r.err))
        log("Timeout: " .. tostring(r.timedOut))
        log("Cancelado: " .. tostring(r.cancelled))
        log("Fake GUI Destroy: " .. tostring(r.destroyed.value))
        log("Status writes: " .. tostring(#r.statusWrites))
        for i, v in ipairs(r.statusWrites) do
            log("  STATUS[" .. i .. "]=" .. string.format("%q", v))
        end

        log("POOL READS: " .. tostring(#r.poolReads))
        for i, e in ipairs(r.poolReads) do
            if i > 100 then log("  ... limite 100 ..."); break end
            log(string.format("  P[%03d] pool[%s] => %s", i, safe(e.k), describePoolValue(e.v)))
        end

        saveReport() -- salva apos CADA teste, inclusive timeout/cancelamento

        if r.cancelled then break end
        task.wait(0.08)
    end

    running = false
    finished = true

    if cancelRequested then
        log("")
        log("ESTADO FINAL: cancelado pelo usuario; relatorio parcial salvo")
        setStatus("CANCELADO - relatorio salvo")
    else
        log("")
        log("ESTADO FINAL: concluido; relatorio salvo")
        setStatus("CONCLUIDO - toque FINALIZAR")
    end

    if startButton then
        startButton.Text = "CONCLUIDO"
        startButton.AutoButtonColor = false
    end
    saveReport()
end

local function closeScanner()
    if running then
        cancelRequested = true
        setStatus("Cancelando teste atual...")
        stopThread(currentWorker)
        return
    end

    saveReport()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    if ui then pcall(function() ui:Destroy() end) end
    G.EXACT_KEY_MEMORY_STOP = nil
end

local function buildUI()
    local parent
    pcall(function() parent = (gethui and gethui()) or game:GetService("CoreGui") end)
    if not parent then
        pcall(function() parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end)
    end
    if not parent then return end

    ui = Instance.new("ScreenGui")
    ui.Name = "ExactKeyTraceV6_2"
    ui.ResetOnSpawn = false
    ui.Parent = parent

    local f = Instance.new("Frame")
    f.Size = UDim2.fromOffset(260, 108)
    f.Position = UDim2.new(0.5, -130, 0.12, 0)
    f.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
    f.BorderSizePixel = 0
    f.Active = true
    f.Draggable = true
    f.Parent = ui
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = f

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -12, 0, 24)
    title.Position = UDim2.fromOffset(6, 5)
    title.BackgroundTransparency = 1
    title.Text = "KEY TRACE V6.2"
    title.TextColor3 = Color3.fromRGB(235, 235, 235)
    title.TextSize = 13
    title.Font = Enum.Font.GothamBold
    title.Parent = f

    statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -12, 0, 26)
    statusLabel.Position = UDim2.fromOffset(6, 30)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Pronto - toque INICIAR"
    statusLabel.TextColor3 = Color3.fromRGB(180, 195, 215)
    statusLabel.TextSize = 10
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextWrapped = true
    statusLabel.Parent = f

    startButton = Instance.new("TextButton")
    startButton.Size = UDim2.new(0.48, -7, 0, 34)
    startButton.Position = UDim2.fromOffset(6, 65)
    startButton.Text = "INICIAR"
    startButton.TextSize = 12
    startButton.Font = Enum.Font.GothamBold
    startButton.BackgroundColor3 = Color3.fromRGB(36, 92, 155)
    startButton.TextColor3 = Color3.new(1, 1, 1)
    startButton.Parent = f
    local c1 = Instance.new("UICorner"); c1.CornerRadius = UDim.new(0, 6); c1.Parent = startButton

    stopButton = Instance.new("TextButton")
    stopButton.Size = UDim2.new(0.52, -7, 0, 34)
    stopButton.Position = UDim2.new(0.48, 1, 0, 65)
    stopButton.Text = "FINALIZAR"
    stopButton.TextSize = 12
    stopButton.Font = Enum.Font.GothamBold
    stopButton.BackgroundColor3 = Color3.fromRGB(110, 45, 55)
    stopButton.TextColor3 = Color3.new(1, 1, 1)
    stopButton.Parent = f
    local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0, 6); c2.Parent = stopButton

    conns[#conns + 1] = startButton.MouseButton1Click:Connect(function()
        if running then
            setStatus(currentStep .. "  (em andamento)")
            return
        end
        task.spawn(runTrace)
    end)

    conns[#conns + 1] = stopButton.MouseButton1Click:Connect(closeScanner)
end

G.EXACT_KEY_MEMORY_STOP = function(silent)
    cancelRequested = true
    stopThread(currentWorker)
    if not running then
        if not silent then saveReport() end
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        conns = {}
        if ui then pcall(function() ui:Destroy() end) end
        return true
    end
    return false
end

buildUI()
