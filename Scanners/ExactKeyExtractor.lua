-- ExactKeyExtractor.lua
-- Extrai constantes/upvalues do callback do botao UNLOCK sem tentar chaves aleatorias.
-- Foco: descobrir a chave EXATA embutida localmente no gate SCRIPT ACCESS.

local TARGET_URL = "https://raw.githubusercontent.com/yumyum272/driving/refs/heads/main/script.lua"
local AUTO_LOAD_TARGET = true
local WAIT_SECONDS = 12

local G = (getgenv and getgenv()) or _G
local seen = {}
local rows = {}
local candidates = {}
local candidateSeen = {}

local function out(s)
    s = tostring(s)
    rows[#rows + 1] = s
    print("[EXACT-KEY] " .. s)
end

local function safe(v)
    local ok, r = pcall(tostring, v)
    return ok and r or "<tostring error>"
end

local function isKnownNoise(s)
    local l = s:lower()
    local exact = {
        ["script access"] = true,
        ["enter your access key to continue"] = true,
        ["access-key"] = true,
        ["get key"] = true,
        ["unlock"] = true,
        ["unlocked"] = true,
        ["copied to clipboard."] = true,
        ["access granted."] = true,
        ["invalid key"] = true,
        ["invalid key."] = true,
        ["screenGui"] = true,
    }
    if exact[l] then return true end
    if l:match("^https?://") then return true end
    if l:find("rbxasset", 1, true) then return true end
    if l:find("enum.", 1, true) then return true end
    if l:find("mousebutton", 1, true) then return true end
    if l:find("textbutton", 1, true) then return true end
    if l:find("textbox", 1, true) then return true end
    if l:find("screen", 1, true) and #s < 30 then return true end
    return false
end

local function addCandidate(s, origin, score)
    if type(s) ~= "string" then return end
    if #s < 3 or #s > 120 then return end
    if isKnownNoise(s) then return end

    local key = s .. "\0" .. tostring(origin)
    if candidateSeen[key] then return end
    candidateSeen[key] = true

    score = score or 0
    if s:find("%-", 1, true) then score = score + 2 end
    if s:match("%u") and s:match("%d") then score = score + 2 end
    if s:match("^[%w%._%-]+$") then score = score + 1 end
    if #s >= 6 and #s <= 48 then score = score + 1 end

    candidates[#candidates + 1] = {
        value = s,
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
    return nil
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
    return nil
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
    return nil
end

local inspectValue

inspectValue = function(v, path, depth)
    depth = depth or 0
    if depth > 7 then return end

    local tv = typeof and typeof(v) or type(v)

    if type(v) == "string" then
        addCandidate(v, path, 0)
        return
    end

    if type(v) == "table" then
        if seen[v] then return end
        seen[v] = true

        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 400 then break end

            if type(k) == "string" then
                -- Uma tabela do tipo VALID_KEYS[key] = true e evidencia muito forte.
                if val == true then
                    addCandidate(k, path .. "[table-key=true]", 20)
                else
                    addCandidate(k, path .. "[table-key]", 2)
                end
            end

            if type(val) == "string" then
                local bonus = 0
                if type(k) == "string" then
                    local lk = k:lower()
                    if lk:find("key", 1, true) or lk:find("pass", 1, true) or lk:find("access", 1, true) then
                        bonus = 15
                    end
                end
                addCandidate(val, path .. "[" .. safe(k) .. "]", bonus)
            elseif type(val) == "table" or type(val) == "function" then
                inspectValue(val, path .. "[" .. safe(k) .. "]", depth + 1)
            end
        end
        return
    end

    if type(v) == "function" then
        if seen[v] then return end
        seen[v] = true

        local consts = getConstants(v)
        if consts then
            for i, c in pairs(consts) do
                if type(c) == "string" then
                    addCandidate(c, path .. ".constant[" .. tostring(i) .. "]", 4)
                elseif type(c) == "table" then
                    inspectValue(c, path .. ".constant[" .. tostring(i) .. "]", depth + 1)
                end
            end
        end

        local ups = getUpvalues(v)
        if ups then
            for k, u in pairs(ups) do
                if type(u) == "string" then
                    addCandidate(u, path .. ".upvalue[" .. safe(k) .. "]", 7)
                elseif type(u) == "table" or type(u) == "function" then
                    inspectValue(u, path .. ".upvalue[" .. safe(k) .. "]", depth + 1)
                end
            end
        end

        local protos = getProtos(v)
        if protos then
            for i, p in pairs(protos) do
                if type(p) == "function" then
                    inspectValue(p, path .. ".proto[" .. tostring(i) .. "]", depth + 1)
                end
            end
        end
    end
end

local function roots()
    local r = {}
    pcall(function()
        local cg = game:GetService("CoreGui")
        r[#r + 1] = cg
    end)
    pcall(function()
        local plr = game:GetService("Players").LocalPlayer
        if plr then
            local pg = plr:FindFirstChildOfClass("PlayerGui")
            if pg then r[#r + 1] = pg end
        end
    end)
    return r
end

local function findGate()
    for _, root in ipairs(roots()) do
        local ok, desc = pcall(function() return root:GetDescendants() end)
        if ok then
            local box, button, gui
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
                    elseif obj:IsA("ScreenGui") then
                        gui = gui or obj
                    end
                end)
            end
            if box and button then return gui, box, button end
        end
    end
end

local function ensureGate()
    local gui, box, button = findGate()
    if box and button then return gui, box, button end

    if AUTO_LOAD_TARGET then
        out("Gate nao encontrado. Carregando o alvo original para abrir a interface...")
        local ok, err = pcall(function()
            local src = game:HttpGet(TARGET_URL)
            local fn, ce = loadstring(src, "@ExactKeyTarget")
            if not fn then error(ce) end
            fn()
        end)
        if not ok then out("Erro ao carregar alvo: " .. safe(err)) end
    end

    local deadline = os.clock() + WAIT_SECONDS
    repeat
        gui, box, button = findGate()
        if box and button then return gui, box, button end
        task.wait(0.15)
    until os.clock() >= deadline

    return nil
end

local function collectFromSignal(signal, name)
    if type(getconnections) ~= "function" then
        out("getconnections indisponivel; nao consigo ler o callback diretamente neste executor.")
        return 0
    end

    local ok, cons = pcall(getconnections, signal)
    if not ok or type(cons) ~= "table" then
        out("Falha ao ler connections de " .. name)
        return 0
    end

    out(name .. ": " .. tostring(#cons) .. " connection(s)")
    local count = 0
    for i, c in ipairs(cons) do
        local fn = nil
        pcall(function() fn = c.Function end)
        if type(fn) == "function" then
            count = count + 1
            inspectValue(fn, name .. ".connection[" .. tostring(i) .. "]", 0)
        end
    end
    return count
end

local gui, box, button = ensureGate()
if not box or not button then
    out("ERRO: nao encontrei o campo ACCESS-KEY + botao UNLOCK.")
    return
end

out("Gate encontrado: " .. safe(gui or button))
out("Botao encontrado: " .. safe(button))
out("O valor digitado no TextBox NAO sera registrado.")

local total = 0
pcall(function() total = total + collectFromSignal(button.MouseButton1Click, "MouseButton1Click") end)
pcall(function() total = total + collectFromSignal(button.Activated, "Activated") end)

if total == 0 then
    out("Nenhuma funcao de callback acessivel foi encontrada.")
end

table.sort(candidates, function(a, b)
    if a.score == b.score then
        if #a.value == #b.value then return a.value < b.value end
        return #a.value < #b.value
    end
    return a.score > b.score
end)

rows[#rows + 1] = ""
rows[#rows + 1] = "========== CANDIDATOS ORDENADOS =========="

local uniqueValue = {}
local ranked = {}
for _, c in ipairs(candidates) do
    if not uniqueValue[c.value] then
        uniqueValue[c.value] = true
        ranked[#ranked + 1] = c
    end
end

for i, c in ipairs(ranked) do
    if i > 120 then break end
    local line = string.format("[%03d] score=%d | %q | %s", i, c.score, c.value, c.origin)
    rows[#rows + 1] = line
    print("[EXACT-KEY] " .. line)
end

rows[#rows + 1] = ""
rows[#rows + 1] = "ALTA CONFIANCA: entradas com score >= 20 normalmente vieram de tabela no formato key=true."
rows[#rows + 1] = "Nao foram feitas tentativas automaticas para evitar consumir o limite de tentativas do menu."

local report = table.concat(rows, "\n")
local name = "ExactKeyDump_" .. tostring(os.time()) .. ".txt"
if type(writefile) == "function" then
    local ok = pcall(writefile, name, report)
    if ok then out("Relatorio salvo em: " .. name) end
end

G.EXACT_KEY_RESULTS = ranked
G.EXACT_KEY_REPORT = report
out("Pronto. Veja os primeiros candidatos no console ou no arquivo de relatorio.")
