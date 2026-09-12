-- ExactKeyMemoryScanner.lua
-- V5 - TRACE ISOLADO DO COMPARADOR DA KEY
-- Objetivo: observar quais constantes/tabelas a VM le logo depois de TextBox.Text.
-- Nao clica no botao real, nao preenche o TextBox real e tenta executar o callback
-- usando uma COPIA do estado da VM + objetos falsos.

local G = (getgenv and getgenv()) or _G

if type(G.EXACT_KEY_MEMORY_STOP) == "function" then
    pcall(G.EXACT_KEY_MEMORY_STOP, true)
end

local rows = {}
local ui, statusLabel, startButton, stopButton
local running = false
local finished = false
local stopRequested = false
local connections = {}

local function log(s)
    s = tostring(s)
    rows[#rows + 1] = s
    print("[KEY-TRACE-V5] " .. s)
end

local function safe(v)
    local ok, s = pcall(tostring, v)
    return ok and s or "<tostring error>"
end

local function setStatus(s)
    if statusLabel then
        pcall(function() statusLabel.Text = tostring(s) end)
    end
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

local function hex(s, max)
    if type(s) ~= "string" then return "" end
    max = max or 96
    local t = {}
    for i = 1, math.min(#s, max) do
        t[#t + 1] = string.format("%02X", string.byte(s, i))
    end
    local out = table.concat(t)
    if #s > max then out = out .. "..." end
    return out
end

local function printable(s)
    if type(s) ~= "string" then return false end
    if #s == 0 then return true end
    local good = 0
    for i = 1, #s do
        local b = string.byte(s, i)
        if b >= 32 and b <= 126 then good = good + 1 end
    end
    return (good / #s) >= 0.8
end

local function describe(v)
    local tv = typeof and typeof(v) or type(v)
    if type(v) == "string" then
        if printable(v) then
            return string.format("string len=%d ascii=%q hex=%s", #v, v, hex(v))
        else
            return string.format("string len=%d hex=%s", #v, hex(v))
        end
    elseif tv == "Instance" then
        local cn, nm = "?", "?"
        pcall(function() cn = v.ClassName end)
        pcall(function() nm = v.Name end)
        return "Instance " .. tostring(cn) .. " " .. tostring(nm)
    else
        return tostring(tv) .. "=" .. safe(v)
    end
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
            if box and button then
                if frame then
                    pcall(function()
                        for _, c in ipairs(frame:GetChildren()) do
                            if c:IsA("TextLabel") then label = label or c end
                        end
                    end)
                end
                return screen, frame, box, label, button
            end
        end
    end
end

local function getCallback(button)
    if type(getconnections) ~= "function" then return nil, "getconnections indisponivel" end
    local ok, cons = pcall(getconnections, button.MouseButton1Click)
    if not ok or type(cons) ~= "table" then return nil, "falha em getconnections" end
    for i, c in ipairs(cons) do
        local fn
        pcall(function() fn = c.Function end)
        if type(fn) == "function" then return fn, "MouseButton1Click[" .. i .. "]" end
    end
    local ok2, cons2 = pcall(getconnections, button.Activated)
    if ok2 and type(cons2) == "table" then
        for i, c in ipairs(cons2) do
            local fn
            pcall(function() fn = c.Function end)
            if type(fn) == "function" then return fn, "Activated[" .. i .. "]" end
        end
    end
    return nil, "nenhum callback acessivel"
end

local function tableStats(t)
    if type(t) ~= "table" then return 0,0,0 end
    local total, strings, instances = 0,0,0
    for _,v in pairs(t) do
        total = total + 1
        if type(v)=="string" then strings = strings + 1 end
        if typeof and typeof(v)=="Instance" then instances = instances + 1 end
    end
    return total, strings, instances
end

local function tableHasInstance(t, target)
    if type(t) ~= "table" then return false end
    for _,v in pairs(t) do
        if v == target then return true end
    end
    return false
end

local function locateStateOwner(dispatcher, box)
    local ups = getUps(dispatcher)
    if not ups then return end
    for i,v in pairs(ups) do
        if type(v)=="table" and tableHasInstance(v, box) then
            return dispatcher, i, v
        end
    end
end

local function locatePoolOwner(fn, depth, seen)
    if type(fn) ~= "function" then return end
    depth = depth or 0
    seen = seen or {}
    if depth > 4 or seen[fn] then return end
    seen[fn] = true

    local ups = getUps(fn)
    if not ups then return end
    for i,v in pairs(ups) do
        if type(v)=="table" then
            local total, strings = tableStats(v)
            if total >= 190 and total <= 230 and strings == total then
                return fn, i, v
            end
        elseif type(v)=="function" then
            local a,b,c = locatePoolOwner(v, depth+1, seen)
            if a then return a,b,c end
        end
    end
end

local function shallowCopy(t)
    local n = {}
    for k,v in pairs(t) do n[k]=v end
    return n
end

local function makeFakeTextBox(sentinel, onRead)
    return setmetatable({Name="TextBox", ClassName="TextBox"}, {
        __index = function(_, k)
            if k == "Text" then
                onRead()
                return sentinel
            end
            if k == "PlaceholderText" then return "ACCESS-KEY" end
            if k == "ClearTextOnFocus" then return false end
            return nil
        end,
        __newindex = function(t,k,v)
            rawset(t,k,v)
        end,
    })
end

local function makeFakeLabel(onWrite)
    local store = {Name="TextLabel", ClassName="TextLabel"}
    return setmetatable(store, {
        __index=function(t,k) return rawget(t,k) end,
        __newindex=function(t,k,v)
            if k=="Text" then onWrite(v) end
            rawset(t,k,v)
        end,
    })
end

local function makeFakeScreen(onDestroy)
    local t = {Name="KeySystemUI", ClassName="ScreenGui"}
    t.Destroy = function()
        onDestroy()
    end
    return t
end

local function makeFakeFrame()
    return {Name="Frame", ClassName="Frame"}
end

local function saveReport()
    local report = table.concat(rows, "\n")
    G.EXACT_KEY_MEMORY_REPORT = report
    local name = "ExactKeyComparatorV5_" .. tostring(os.time()) .. ".txt"
    if type(writefile)=="function" then
        local ok = pcall(writefile, name, report)
        if ok then log("Relatorio salvo em: " .. name) end
    end
    return report
end

local function runTrace()
    if running or finished then return end
    running = true
    stopRequested = false
    setStatus("Localizando callback...")

    rows = {}
    log("ExactKeyMemoryScanner V5")
    log("Modo: TRACE ISOLADO / sem clique real")

    local screen, frame, box, label, button = findGate()
    if not box or not button then
        log("ERRO: gate ACCESS-KEY/UNLOCK nao encontrado.")
        setStatus("Gate nao encontrado")
        running=false
        return
    end

    log("Screen: " .. safe(screen))
    log("TextBox: " .. safe(box))
    log("Button: " .. safe(button))
    if label then log("Label: " .. safe(label)) end

    local cb, cbName = getCallback(button)
    if type(cb) ~= "function" then
        log("ERRO: " .. tostring(cbName))
        setStatus("Callback inacessivel")
        running=false
        return
    end
    log("Callback: " .. tostring(cbName) .. " => " .. safe(cb))

    local cbUps = getUps(cb)
    if not cbUps then
        log("ERRO: nao foi possivel ler upvalues do callback")
        setStatus("Sem upvalues")
        running=false
        return
    end

    log("UPVALUES CALLBACK:")
    local dispatcher
    for i,v in pairs(cbUps) do
        log("  ["..tostring(i).."] "..describe(v))
        if not dispatcher and type(v)=="function" then dispatcher=v end
    end

    if type(dispatcher) ~= "function" then
        log("ERRO: dispatcher nao localizado")
        setStatus("Dispatcher nao encontrado")
        running=false
        return
    end

    local stateOwner, stateIndex, state = locateStateOwner(dispatcher, box)
    if not state then
        log("ERRO: tabela de estado com TextBox nao encontrada nos upvalues diretos do dispatcher")
        setStatus("Estado nao encontrado")
        running=false
        return
    end

    local stTotal, stStrings, stInstances = tableStats(state)
    log(string.format("STATE: owner=%s upvalue=%s total=%d strings=%d instances=%d", safe(stateOwner), tostring(stateIndex), stTotal, stStrings, stInstances))

    local poolOwner, poolIndex, pool = locatePoolOwner(dispatcher, 0, {})
    if not pool then
        log("ERRO: pool ~207 strings nao encontrada")
        setStatus("Pool nao encontrada")
        running=false
        return
    end

    local pTotal,pStrings = tableStats(pool)
    log(string.format("POOL: owner=%s upvalue=%s total=%d strings=%d", safe(poolOwner), tostring(poolIndex), pTotal, pStrings))

    local hasSetup = false
    for _,f in ipairs({rawget(G,"setupvalue"), debug and debug.setupvalue}) do
        if type(f)=="function" then hasSetup=true break end
    end
    if not hasSetup then
        log("ERRO: executor nao possui setupvalue/debug.setupvalue; trace isolado nao pode ser feito.")
        setStatus("setupvalue indisponivel")
        running=false
        saveReport()
        return
    end

    setStatus("Preparando estado isolado...")

    local beforeBoxText = ""
    local beforeLabelText = nil
    pcall(function() beforeBoxText = box.Text end)
    if label then pcall(function() beforeLabelText = label.Text end) end

    local sawText = false
    local poolReads = {}
    local statusWrites = {}
    local destroyed = false
    local sentinel = "__KEY_TRACE_SENTINEL_V5__"

    local function recordPool(k,v)
        if not sawText then return end
        if #poolReads >= 80 then return end
        poolReads[#poolReads+1] = {k=k, v=v}
    end

    local poolProxy = setmetatable({}, {
        __index=function(_,k)
            local v = pool[k]
            recordPool(k,v)
            return v
        end,
        __newindex=function(_,k,v)
            -- Isolado: nunca escreve na pool original.
            rawset(_,k,v)
        end,
        __len=function() return #pool end,
        __pairs=function() return pairs(pool) end,
        __ipairs=function() return ipairs(pool) end,
    })

    local stateClone = shallowCopy(state)
    local fakeBox = makeFakeTextBox(sentinel, function()
        if not sawText then
            sawText = true
            log("TRACE EVENT: TextBox.Text lido")
        end
    end)
    local fakeLabel = makeFakeLabel(function(v)
        statusWrites[#statusWrites+1] = v
    end)
    local fakeScreen = makeFakeScreen(function()
        destroyed = true
    end)
    local fakeFrame = makeFakeFrame()

    for k,v in pairs(stateClone) do
        if v == box then stateClone[k] = fakeBox end
        if label and v == label then stateClone[k] = fakeLabel end
        if screen and v == screen then stateClone[k] = fakeScreen end
        if frame and v == frame then stateClone[k] = fakeFrame end
    end

    -- Clona tabelas diretas do callback (ex.: upvalue[3]) para nao alterar estado auxiliar.
    local cbTableOriginals = {}
    for i,v in pairs(cbUps) do
        if type(v)=="table" then
            cbTableOriginals[#cbTableOriginals+1] = {idx=i, value=v}
        end
    end

    local replacedState = setUp(stateOwner, stateIndex, stateClone)
    local replacedPool = setUp(poolOwner, poolIndex, poolProxy)
    local replacedTables = {}
    for _,entry in ipairs(cbTableOriginals) do
        local copy = shallowCopy(entry.value)
        if setUp(cb, entry.idx, copy) then
            replacedTables[#replacedTables+1] = entry
        end
    end

    if not replacedState or not replacedPool then
        log("ERRO: nao foi possivel trocar state/pool por copias isoladas")
        pcall(setUp, stateOwner, stateIndex, state)
        pcall(setUp, poolOwner, poolIndex, pool)
        for _,e in ipairs(replacedTables) do pcall(setUp,cb,e.idx,e.value) end
        setStatus("Falha ao isolar")
        running=false
        saveReport()
        return
    end

    setStatus("Executando trace isolado...")
    local okRun, errRun = pcall(cb)

    -- RESTAURA PRIMEIRO, antes de qualquer analise/print.
    pcall(setUp, stateOwner, stateIndex, state)
    pcall(setUp, poolOwner, poolIndex, pool)
    for _,e in ipairs(replacedTables) do pcall(setUp,cb,e.idx,e.value) end

    log("TRACE RESULT: ok=" .. tostring(okRun) .. " err=" .. safe(errRun))
    log("TextBox fake lido: " .. tostring(sawText))
    log("Fake Screen Destroy chamado: " .. tostring(destroyed))

    log("")
    log("========== LEITURAS DA POOL APOS TextBox.Text ==========")
    if #poolReads == 0 then
        log("<nenhuma leitura registrada>")
    else
        for i,e in ipairs(poolReads) do
            log(string.format("[%02d] pool[%s] => %s", i, tostring(e.k), describe(e.v)))
        end
    end

    log("")
    log("========== ESCRITAS NO STATUS FAKE ==========")
    if #statusWrites==0 then
        log("<nenhuma escrita>")
    else
        for i,v in ipairs(statusWrites) do
            log(string.format("[%02d] %s",i,describe(v)))
        end
    end

    log("")
    log("========== ALTERACOES NO STATE CLONADO ==========")
    local changed = 0
    for k,v in pairs(stateClone) do
        local original = state[k]
        local isUiReplacement = (original==box or original==label or original==screen or original==frame)
        if not isUiReplacement and v ~= original then
            changed = changed + 1
            if changed <= 120 then
                log("state["..safe(k).."] original="..describe(original).." clone="..describe(v))
            end
        end
    end
    if changed==0 then log("<nenhuma alteracao detectada>") end
    log("Total state alterado: " .. tostring(changed))

    -- Verificacao de seguranca: GUI real deve estar identica.
    local afterBoxText = beforeBoxText
    local afterLabelText = beforeLabelText
    pcall(function() afterBoxText = box.Text end)
    if label then pcall(function() afterLabelText = label.Text end) end

    local leaked = (afterBoxText ~= beforeBoxText) or (label and afterLabelText ~= beforeLabelText)
    log("")
    log("========== VERIFICACAO DE SEGURANCA ==========")
    log("GUI real alterada: " .. tostring(leaked))
    if leaked then
        log("AVISO: houve alteracao visivel na GUI real; nao repetir este trace nesta sessao.")
        pcall(function() box.Text = beforeBoxText end)
        if label and beforeLabelText ~= nil then pcall(function() label.Text = beforeLabelText end) end
    else
        log("OK: TextBox/status reais permaneceram intactos.")
    end

    finished = true
    running = false
    setStatus(leaked and "Concluido com AVISO" or "Concluido - sem tentativa real")
    saveReport()
end

local function stopScanner(silent)
    stopRequested = true
    running = false
    for _,c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    connections = {}
    if ui then pcall(function() ui:Destroy() end) end
    ui=nil
    if not silent then
        saveReport()
    end
end

G.EXACT_KEY_MEMORY_STOP = stopScanner

local function buildUI()
    local parent
    pcall(function() parent = game:GetService("CoreGui") end)
    if not parent then
        local p = game:GetService("Players").LocalPlayer
        parent = p and p:FindFirstChildOfClass("PlayerGui")
    end
    if not parent then return end

    ui = Instance.new("ScreenGui")
    ui.Name = "ExactKeyTraceV5UI"
    ui.ResetOnSpawn = false
    ui.IgnoreGuiInset = true
    ui.Parent = parent

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(250, 104)
    frame.Position = UDim2.new(0.5,-125,0.14,0)
    frame.BackgroundColor3 = Color3.fromRGB(24,27,35)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = ui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0,10)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1,-16,0,22)
    title.Position = UDim2.fromOffset(8,6)
    title.BackgroundTransparency = 1
    title.Text = "KEY TRACE V5"
    title.TextColor3 = Color3.fromRGB(240,240,245)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = frame

    statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1,-16,0,20)
    statusLabel.Position = UDim2.fromOffset(8,30)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Pronto - trace isolado"
    statusLabel.TextColor3 = Color3.fromRGB(175,185,205)
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 11
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = frame

    startButton = Instance.new("TextButton")
    startButton.Size = UDim2.new(0.5,-12,0,34)
    startButton.Position = UDim2.new(0,8,1,-42)
    startButton.BackgroundColor3 = Color3.fromRGB(65,125,245)
    startButton.TextColor3 = Color3.new(1,1,1)
    startButton.Font = Enum.Font.GothamBold
    startButton.TextSize = 12
    startButton.Text = "INICIAR"
    startButton.Parent = frame
    local c1=Instance.new("UICorner"); c1.CornerRadius=UDim.new(0,8); c1.Parent=startButton

    stopButton = Instance.new("TextButton")
    stopButton.Size = UDim2.new(0.5,-12,0,34)
    stopButton.Position = UDim2.new(0.5,4,1,-42)
    stopButton.BackgroundColor3 = Color3.fromRGB(55,60,72)
    stopButton.TextColor3 = Color3.new(1,1,1)
    stopButton.Font = Enum.Font.GothamBold
    stopButton.TextSize = 12
    stopButton.Text = "FINALIZAR"
    stopButton.Parent = frame
    local c2=Instance.new("UICorner"); c2.CornerRadius=UDim.new(0,8); c2.Parent=stopButton

    connections[#connections+1]=startButton.MouseButton1Click:Connect(function()
        if not running and not finished then
            task.spawn(runTrace)
        end
    end)
    connections[#connections+1]=stopButton.MouseButton1Click:Connect(function()
        stopScanner(false)
    end)
end

buildUI()
