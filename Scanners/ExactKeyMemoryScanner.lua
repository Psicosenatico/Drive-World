-- ExactKeyMemoryScanner.lua
-- Somente leitura de memoria: NAO clica, NAO preenche TextBox, NAO executa tentativas.
-- Execute com a tela SCRIPT ACCESS ja aberta.

local G = (getgenv and getgenv()) or _G
local rows = {}
local hits = {}
local seen = {}

local function log(s)
    s = tostring(s)
    rows[#rows+1] = s
    print("[KEY-MEM] " .. s)
end

local function add(value, origin, score)
    if type(value) ~= "string" then return end
    if #value < 3 or #value > 160 then return end
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
    }
    if noise[low] then return end
    if low:match("^https?://") then return end

    score = score or 0
    if value:match("^[%w%._%-]+$") then score = score + 2 end
    if value:match("%u") and value:match("%d") then score = score + 2 end
    if value:find("-",1,true) then score = score + 1 end
    if #value >= 6 and #value <= 64 then score = score + 1 end

    hits[#hits+1] = {value=value, origin=origin, score=score}
end

local function inspectTable(t, origin, depth)
    if type(t) ~= "table" or seen[t] or depth > 5 then return end
    seen[t] = true
    local n = 0
    for k,v in pairs(t) do
        n = n + 1
        if n > 500 then break end
        if type(k) == "string" then
            if v == true then add(k, origin.."[key=true]", 30) end
            local lk = k:lower()
            if type(v) == "string" and (lk:find("key",1,true) or lk:find("pass",1,true) or lk:find("access",1,true)) then
                add(v, origin.."["..k.."]", 25)
            else
                add(k, origin.."[table-key]", 1)
            end
        end
        if type(v) == "string" then
            add(v, origin.."[value]", 0)
        elseif type(v) == "table" then
            inspectTable(v, origin.."[table]", depth+1)
        end
    end
end

local function constants(fn)
    for _,f in ipairs({rawget(G,"getconstants"), debug and debug.getconstants}) do
        if type(f)=="function" then
            local ok,r=pcall(f,fn)
            if ok and type(r)=="table" then return r end
        end
    end
end

local function upvalues(fn)
    for _,f in ipairs({rawget(G,"getupvalues"), debug and debug.getupvalues}) do
        if type(f)=="function" then
            local ok,r=pcall(f,fn)
            if ok and type(r)=="table" then return r end
        end
    end
end

local function inspectFunction(fn, origin)
    if type(fn) ~= "function" or seen[fn] then return end
    seen[fn] = true

    local c = constants(fn)
    if c then
        local marker = false
        for _,v in pairs(c) do
            if type(v)=="string" then
                local l=v:lower()
                if l:find("that key is not valid",1,true) or l:find("access granted",1,true) or l=="unlock" or l=="access-key" then marker=true end
            end
        end
        for i,v in pairs(c) do
            if type(v)=="string" then add(v, origin..".const["..tostring(i).."]", marker and 10 or 0) end
        end
    end

    local u = upvalues(fn)
    if u then
        for k,v in pairs(u) do
            if type(v)=="string" then add(v, origin..".upvalue["..tostring(k).."]", 12)
            elseif type(v)=="table" then inspectTable(v, origin..".upvalue["..tostring(k).."]", 0) end
        end
    end
end

if type(getgc) ~= "function" then
    log("ERRO: executor nao possui getgc().")
    return
end

local ok,gc = pcall(getgc,true)
if not ok or type(gc) ~= "table" then
    log("ERRO: getgc(true) falhou.")
    return
end

log("Objetos GC: "..tostring(#gc))
for i,obj in ipairs(gc) do
    if type(obj)=="function" then
        inspectFunction(obj,"gc["..i.."]")
    elseif type(obj)=="table" then
        inspectTable(obj,"gc["..i.."]",0)
    end
end

local best = {}
for _,h in ipairs(hits) do
    local old = best[h.value]
    if not old or h.score > old.score then best[h.value]=h end
end

local list = {}
for _,h in pairs(best) do list[#list+1]=h end
table.sort(list,function(a,b)
    if a.score==b.score then return #a.value < #b.value end
    return a.score>b.score
end)

rows[#rows+1]=""
rows[#rows+1]="========== CANDIDATOS =========="
for i,h in ipairs(list) do
    if i>150 then break end
    local line=string.format("[%03d] score=%d | %q | %s",i,h.score,h.value,h.origin)
    rows[#rows+1]=line
    print("[KEY-MEM] "..line)
end

local report=table.concat(rows,"\n")
G.EXACT_KEY_MEMORY_RESULTS=list
G.EXACT_KEY_MEMORY_REPORT=report

local name="ExactKeyMemory_"..tostring(os.time())..".txt"
if type(writefile)=="function" then
    local okw=pcall(writefile,name,report)
    if okw then log("Relatorio salvo em: "..name) end
end

log("Concluido sem clicar no UNLOCK e sem consumir tentativa de chave.")
