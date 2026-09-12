-- ExactKeyMemoryScanner.lua
-- V4 - scanner somente leitura do callback real do UNLOCK.
-- NAO preenche a chave, NAO clica UNLOCK e NAO consome tentativas.
-- Objetivo: reconstruir a estrutura da closure/VM e exportar strings BINARIAS com HEX exato.

local G = (getgenv and getgenv()) or _G

if type(G.EXACT_KEY_MEMORY_STOP) == "function" then
    pcall(G.EXACT_KEY_MEMORY_STOP, true)
end

local running = false
local stopped = false
local finished = false
local startedAt = 0
local ui, statusLabel, startButton, stopButton
local connections = {}

local function safe(v)
    local ok, r = pcall(tostring, v)
    return ok and r or "<tostring error>"
end

local function typeofSafe(v)
    local ok, r = pcall(function()
        if typeof then return typeof(v) end
        return type(v)
    end)
    return ok and r or type(v)
end

local function setStatus(text)
    if statusLabel then
        pcall(function() statusLabel.Text = tostring(text) end)
    end
    print("[KEY-MEM-V4] " .. tostring(text))
end

local function addConn(c)
    connections[#connections + 1] = c
    return c
end

local function disconnectAll()
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    connections = {}
end

local function getConstants(fn)
    for _, f in ipairs({rawget(G, "getconstants"), debug and debug.getconstants}) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local function getUpvalues(fn)
    for _, f in ipairs({rawget(G, "getupvalues"), debug and debug.getupvalues}) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local function getProtos(fn)
    for _, f in ipairs({rawget(G, "getprotos"), debug and debug.getprotos}) do
        if type(f) == "function" then
            local ok, r = pcall(f, fn)
            if ok and type(r) == "table" then return r end
        end
    end
end

local function byteHex(s)
    if type(s) ~= "string" then return "" end
    local t = table.create and table.create(#s) or {}
    for i = 1, #s do
        t[i] = string.format("%02X", string.byte(s, i))
    end
    return table.concat(t)
end

local function escapedAscii(s)
    if type(s) ~= "string" then return safe(s) end
    local out = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        if b == 92 then
            out[#out + 1] = "\\\\"
        elseif b == 34 then
            out[#out + 1] = "\\\""
        elseif b >= 32 and b <= 126 then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = string.format("\\x%02X", b)
        end
    end
    return table.concat(out)
end

local function printableRatio(s)
    if type(s) ~= "string" or #s == 0 then return 0 end
    local n = 0
    for i = 1, #s do
        local b = string.byte(s, i)
        if b >= 32 and b <= 126 then n = n + 1 end
    end
    return n / #s
end

local function roots()
    local out = {}
    pcall(function() out[#out + 1] = game:GetService("CoreGui") end)
    pcall(function()
        local plr = game:GetService("Players").LocalPlayer
        if plr then
            local pg = plr:FindFirstChildOfClass("PlayerGui")
            if pg then out[#out + 1] = pg end
        end
    end)
    return out
end

local function findGate()
    for _, root in ipairs(roots()) do
        local ok, desc = pcall(function() return root:GetDescendants() end)
        if ok and type(desc) == "table" then
            local screen, box, button, status
            for _, obj in ipairs(desc) do
                pcall(function()
                    if obj:IsA("TextBox") then
                        local ph = tostring(obj.PlaceholderText or "")
                        if ph:upper():find("ACCESS", 1, true) or ph:lower():find("key", 1, true) then
                            box = box or obj
                        end
                    elseif obj:IsA("TextButton") then
                        local tx = tostring(obj.Text or "")
                        if tx:upper() == "UNLOCK" or tx:lower():find("confirm", 1, true) then
                            button = button or obj
                        end
                    elseif obj:IsA("TextLabel") then
                        local tx = tostring(obj.Text or ""):lower()
                        if tx:find("key is not valid", 1, true)
                        or tx:find("access granted", 1, true)
                        or tx:find("copied to clipboard", 1, true) then
                            status = status or obj
                        end
                    elseif obj:IsA("ScreenGui") then
                        local n = tostring(obj.Name or ""):lower()
                        if n:find("key", 1, true) or n:find("loader", 1, true) then
                            screen = screen or obj
                        end
                    end
                end)
            end
            if box and button then return screen, box, button, status end
        end
    end
end

local function getUnlockCallbacks(button)
    local list = {}
    if type(getconnections) ~= "function" then return list end

    local function collect(signal, label)
        local ok, cons = pcall(getconnections, signal)
        if not ok or type(cons) ~= "table" then return end
        for i, c in ipairs(cons) do
            local fn
            pcall(function() fn = c.Function end)
            if type(fn) == "function" then
                list[#list + 1] = {
                    fn = fn,
                    path = "UNLOCK." .. label .. ".connection[" .. tostring(i) .. "]"
                }
            end
        end
    end

    pcall(function() collect(button.MouseButton1Click, "MouseButton1Click") end)
    pcall(function() collect(button.Activated, "Activated") end)
    return list
end

local function tableStats(t)
    local total, strings, funcs, tables, instances = 0, 0, 0, 0, 0
    for _, v in pairs(t) do
        total = total + 1
        local tp = typeofSafe(v)
        if type(v) == "string" then strings = strings + 1
        elseif type(v) == "function" then funcs = funcs + 1
        elseif type(v) == "table" then tables = tables + 1
        elseif tp == "Instance" then instances = instances + 1 end
        if total >= 5000 then break end
    end
    return total, strings, funcs, tables, instances
end

local function keyLabel(k)
    if type(k) == "number" then return "[" .. tostring(k) .. "]" end
    if type(k) == "string" then return "[\"" .. escapedAscii(k) .. "\"]" end
    return "[" .. safe(k) .. "]"
end

local function valueSummary(v)
    local tp = typeofSafe(v)
    if type(v) == "string" then
        return string.format("string len=%d ascii=\"%s\" hex=%s", #v, escapedAscii(v), byteHex(v))
    elseif tp == "Instance" then
        local class, name, full = "?", "?", "?"
        pcall(function() class = v.ClassName end)
        pcall(function() name = v.Name end)
        pcall(function() full = v:GetFullName() end)
        return string.format("Instance class=%s name=%s path=%s", safe(class), safe(name), safe(full))
    elseif type(v) == "number" or type(v) == "boolean" or type(v) == "nil" then
        return type(v) .. "=" .. safe(v)
    elseif type(v) == "function" then
        return "function=" .. safe(v)
    elseif type(v) == "table" then
        local a,b,c,d,e = tableStats(v)
        return string.format("table=%s total=%d strings=%d functions=%d tables=%d instances=%d", safe(v), a,b,c,d,e)
    end
    return tp .. "=" .. safe(v)
end

local function runScan()
    if running or finished then return end
    running = true
    stopped = false
    startedAt = os.clock()

    setStatus("Procurando gate...")
    local screen, box, button, status = findGate()
    if not box or not button then
        setStatus("Gate ACCESS-KEY / UNLOCK não encontrado")
        running = false
        return
    end

    setStatus("Lendo callback do UNLOCK...")
    local callbacks = getUnlockCallbacks(button)
    if #callbacks == 0 then
        setStatus("Nenhum callback acessível")
        running = false
        return
    end

    local report = {}
    local function push(s) report[#report + 1] = tostring(s) end

    push("ExactKeyMemoryScanner V4")
    push("Modo: SOMENTE LEITURA")
    push("Tempo inicial: " .. tostring(os.time()))
    push("Callbacks UNLOCK acessíveis: " .. tostring(#callbacks))
    push("TextBox: " .. safe(box))
    push("UNLOCK: " .. safe(button))
    push("Status: " .. safe(status))
    push("")

    local seenF, seenT = {}, {}
    local largeTables = {}
    local uiTables = {}
    local functionPaths = {}

    local function registerLargeTable(t, path)
        local total, strings, funcs, tables, instances = tableStats(t)
        if strings >= 12 then
            largeTables[#largeTables + 1] = {
                t=t, path=path, total=total, strings=strings, funcs=funcs, tables=tables, instances=instances
            }
        end
    end

    local function tableHasUI(t)
        local found = false
        local names = {}
        for k,v in pairs(t) do
            if v == box then found = true; names[#names+1] = keyLabel(k) .. "=TEXTBOX" end
            if v == button then found = true; names[#names+1] = keyLabel(k) .. "=UNLOCK" end
            if screen and v == screen then found = true; names[#names+1] = keyLabel(k) .. "=SCREEN" end
            if status and v == status then found = true; names[#names+1] = keyLabel(k) .. "=STATUS" end
        end
        return found, table.concat(names, ", ")
    end

    local inspectFunction, inspectValue

    inspectValue = function(v, path, depth)
        if stopped or depth > 9 then return end
        if type(v) == "function" then
            inspectFunction(v, path, depth + 1)
            return
        end
        if type(v) ~= "table" then return end
        if seenT[v] then return end
        seenT[v] = true

        registerLargeTable(v, path)
        local hasUI, which = tableHasUI(v)
        if hasUI then
            uiTables[#uiTables + 1] = {t=v, path=path, which=which}
        end

        local n = 0
        for k,val in pairs(v) do
            if stopped then return end
            n = n + 1
            if n > 1500 then break end
            if type(val) == "function" or type(val) == "table" then
                inspectValue(val, path .. keyLabel(k), depth + 1)
            end
        end
    end

    inspectFunction = function(fn, path, depth)
        if stopped or depth > 9 then return end
        if type(fn) ~= "function" or seenF[fn] then return end
        seenF[fn] = true
        functionPaths[#functionPaths + 1] = path

        local ups = getUpvalues(fn)
        if ups then
            for k,v in pairs(ups) do
                if type(v) == "function" or type(v) == "table" then
                    inspectValue(v, path .. ".upvalue[" .. safe(k) .. "]", depth + 1)
                end
            end
        end

        local protos = getProtos(fn)
        if protos then
            for i,p in pairs(protos) do
                if type(p) == "function" then
                    inspectFunction(p, path .. ".proto[" .. tostring(i) .. "]", depth + 1)
                end
            end
        end
    end

    for i, item in ipairs(callbacks) do
        if stopped then break end
        setStatus("Mapeando callback " .. tostring(i) .. "/" .. tostring(#callbacks))
        inspectFunction(item.fn, item.path, 0)
        task.wait()
    end

    push("========== ESTRUTURA ==========")
    push("Funções alcançadas: " .. tostring(#functionPaths))
    push("Tabelas grandes de strings: " .. tostring(#largeTables))
    push("Tabelas contendo referências da UI: " .. tostring(#uiTables))
    push("")

    push("========== UPVALUES DIRETOS DOS CALLBACKS ==========")
    for _, item in ipairs(callbacks) do
        push("CALLBACK " .. item.path)
        local ups = getUpvalues(item.fn)
        if ups then
            local keys = {}
            for k in pairs(ups) do keys[#keys+1] = k end
            table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
            for _,k in ipairs(keys) do
                push("  upvalue[" .. safe(k) .. "] => " .. valueSummary(ups[k]))
            end
        else
            push("  <upvalues indisponíveis>")
        end
    end
    push("")

    push("========== TABELAS COM REFERÊNCIAS DA UI ==========")
    if #uiTables == 0 then
        push("<nenhuma tabela contendo TextBox/UNLOCK/Status foi encontrada>")
    else
        for idx, item in ipairs(uiTables) do
            push(string.format("UI_TABLE #%d path=%s refs=%s", idx, item.path, item.which))
            local entries = {}
            for k,v in pairs(item.t) do entries[#entries+1] = {k=k,v=v} end
            table.sort(entries, function(a,b) return tostring(a.k) < tostring(b.k) end)
            for i,e in ipairs(entries) do
                if i > 300 then push("  ... limite 300 ..."); break end
                push("  " .. keyLabel(e.k) .. " => " .. valueSummary(e.v))
            end
            push("")
        end
    end

    table.sort(largeTables, function(a,b)
        if a.strings == b.strings then return a.total > b.total end
        return a.strings > b.strings
    end)

    push("========== GRANDES TABELAS DE STRINGS ==========")
    local maxTables = math.min(#largeTables, 6)
    for ti = 1, maxTables do
        local item = largeTables[ti]
        push(string.format(
            "STRING_TABLE #%d path=%s total=%d strings=%d functions=%d tables=%d instances=%d",
            ti, item.path, item.total, item.strings, item.funcs, item.tables, item.instances
        ))

        local entries = {}
        for k,v in pairs(item.t) do
            if type(v) == "string" then entries[#entries+1] = {k=k,v=v} end
        end
        table.sort(entries, function(a,b)
            if type(a.k) == "number" and type(b.k) == "number" then return a.k < b.k end
            if type(a.k) == "number" then return true end
            if type(b.k) == "number" then return false end
            return tostring(a.k) < tostring(b.k)
        end)

        for _,e in ipairs(entries) do
            local ratio = printableRatio(e.v)
            push(string.format(
                "  %s len=%d printable=%.2f ascii=\"%s\" hex=%s",
                keyLabel(e.k), #e.v, ratio, escapedAscii(e.v), byteHex(e.v)
            ))
        end
        push("")
    end

    push("========== CONSTANTES ASCII DOS CALLBACKS/PROTOS ==========")
    local asciiSeen = {}
    local function dumpFunctionAscii(fn, path, depth, visited)
        if stopped or depth > 9 or visited[fn] then return end
        visited[fn] = true
        local c = getConstants(fn)
        if c then
            for k,v in pairs(c) do
                if type(v) == "string" and printableRatio(v) == 1 and not asciiSeen[v] then
                    asciiSeen[v] = true
                    push(string.format("  %s.const[%s] len=%d value=\"%s\"", path, safe(k), #v, escapedAscii(v)))
                end
            end
        end
        local u = getUpvalues(fn)
        if u then
            for k,v in pairs(u) do
                if type(v) == "function" then
                    dumpFunctionAscii(v, path .. ".upvalue[" .. safe(k) .. "]", depth+1, visited)
                end
            end
        end
        local p = getProtos(fn)
        if p then
            for k,v in pairs(p) do
                if type(v)=="function" then dumpFunctionAscii(v, path .. ".proto[" .. safe(k) .. "]", depth+1, visited) end
            end
        end
    end

    local visitedAscii = {}
    for _,item in ipairs(callbacks) do
        dumpFunctionAscii(item.fn, item.path, 0, visitedAscii)
    end

    push("")
    push("Estado: " .. (stopped and "interrompido" or "scan concluído"))
    push(string.format("Tempo: %.2fs", os.clock() - startedAt))
    push("OBS: nenhuma tentativa de chave foi executada.")

    local text = table.concat(report, "\n")
    local filename = "ExactKeyClosureV4_" .. tostring(os.time()) .. ".txt"
    G.EXACT_KEY_MEMORY_REPORT = text
    G.EXACT_KEY_MEMORY_FILENAME = filename

    if type(writefile) == "function" then
        local ok, err = pcall(writefile, filename, text)
        if ok then
            setStatus("Concluído: " .. filename)
        else
            setStatus("Scan concluído; writefile falhou")
            warn(err)
        end
    else
        setStatus("Scan concluído; writefile indisponível")
    end

    running = false
    finished = true
end

local function stopScanner(silent)
    stopped = true
    running = false
    disconnectAll()
    if ui then pcall(function() ui:Destroy() end) end
    ui = nil
    G.EXACT_KEY_MEMORY_STOP = nil
    if not silent then print("[KEY-MEM-V4] Scanner finalizado") end
end

G.EXACT_KEY_MEMORY_STOP = stopScanner

local function buildUI()
    local parent
    pcall(function()
        if type(gethui) == "function" then parent = gethui() end
    end)
    if not parent then
        pcall(function() parent = game:GetService("CoreGui") end)
    end
    if not parent then
        pcall(function() parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end)
    end
    if not parent then
        warn("[KEY-MEM-V4] sem parent para UI")
        return
    end

    ui = Instance.new("ScreenGui")
    ui.Name = "ExactKeyMemoryScannerV4"
    ui.ResetOnSpawn = false
    ui.IgnoreGuiInset = false
    ui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ui.Parent = parent

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.Size = UDim2.fromOffset(250, 96)
    frame.Position = UDim2.new(0, 12, 0.5, -48)
    frame.BackgroundColor3 = Color3.fromRGB(20, 23, 31)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = ui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(10, 5)
    title.Size = UDim2.new(1, -20, 0, 19)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(245,245,245)
    title.Text = "KEY SCAN V4"
    title.Parent = frame

    statusLabel = Instance.new("TextLabel")
    statusLabel.BackgroundTransparency = 1
    statusLabel.Position = UDim2.fromOffset(10, 25)
    statusLabel.Size = UDim2.new(1, -20, 0, 25)
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 11
    statusLabel.TextWrapped = true
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.TextColor3 = Color3.fromRGB(190,198,214)
    statusLabel.Text = "Pronto — não consome tentativa"
    statusLabel.Parent = frame

    startButton = Instance.new("TextButton")
    startButton.Position = UDim2.fromOffset(10, 56)
    startButton.Size = UDim2.new(0.5, -15, 0, 30)
    startButton.BackgroundColor3 = Color3.fromRGB(68, 126, 246)
    startButton.BorderSizePixel = 0
    startButton.Font = Enum.Font.GothamBold
    startButton.TextSize = 12
    startButton.TextColor3 = Color3.new(1,1,1)
    startButton.Text = "INICIAR"
    startButton.Parent = frame
    local c1 = Instance.new("UICorner"); c1.CornerRadius = UDim.new(0,8); c1.Parent = startButton

    stopButton = Instance.new("TextButton")
    stopButton.Position = UDim2.new(0.5, 5, 0, 56)
    stopButton.Size = UDim2.new(0.5, -15, 0, 30)
    stopButton.BackgroundColor3 = Color3.fromRGB(56, 62, 76)
    stopButton.BorderSizePixel = 0
    stopButton.Font = Enum.Font.GothamBold
    stopButton.TextSize = 12
    stopButton.TextColor3 = Color3.new(1,1,1)
    stopButton.Text = "FINALIZAR"
    stopButton.Parent = frame
    local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0,8); c2.Parent = stopButton

    addConn(startButton.MouseButton1Click:Connect(function()
        if running or finished then return end
        startButton.Text = "RODANDO..."
        startButton.AutoButtonColor = false
        task.spawn(runScan)
    end))

    addConn(stopButton.MouseButton1Click:Connect(function()
        stopScanner(false)
    end))
end

buildUI()
