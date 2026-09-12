-- PayloadLinkScannerV4.lua
-- Auditoria READ-ONLY ancorada no callback real do botao UNLOCK/Confirm.
-- Evita os falsos positivos do V3: nao faz varredura global de getgc e nao usa substring generica "unlock/load".

local G=(getgenv and getgenv()) or _G
local rows={}
local ui,statusLabel,startButton,closeButton
local running=false
local conns={}

local function safe(v)
    local ok,s=pcall(tostring,v)
    return ok and s or "<tostring error>"
end
local function log(s)
    rows[#rows+1]=tostring(s)
    print("[PAYLOAD-LINK-V4] "..tostring(s))
end
local function setStatus(s)
    if statusLabel then pcall(function() statusLabel.Text=tostring(s) end) end
end
local function saveReport()
    local report=table.concat(rows,"\n")
    G.PAYLOAD_LINK_V4_REPORT=report
    local name="PayloadLinkScannerV4_"..tostring(os.time())..".txt"
    if type(writefile)=="function" then pcall(writefile,name,report) end
    return name
end

local function getConstants(fn)
    for _,f in ipairs({rawget(G,"getconstants"),debug and debug.getconstants}) do
        if type(f)=="function" then
            local ok,r=pcall(f,fn)
            if ok and type(r)=="table" then return r end
        end
    end
end
local function getUps(fn)
    for _,f in ipairs({rawget(G,"getupvalues"),debug and debug.getupvalues}) do
        if type(f)=="function" then
            local ok,r=pcall(f,fn)
            if ok and type(r)=="table" then return r end
        end
    end
end
local function getProtos(fn)
    for _,f in ipairs({rawget(G,"getprotos"),debug and debug.getprotos}) do
        if type(f)=="function" then
            local ok,r=pcall(f,fn)
            if ok and type(r)=="table" then return r end
        end
    end
end
local function fnInfo(fn)
    if debug and type(debug.info)=="function" then
        local ok,a,b,c=pcall(debug.info,fn,"sln")
        if ok then return string.format("src=%s line=%s name=%s",safe(a),safe(b),safe(c)) end
    end
    if debug and type(debug.getinfo)=="function" then
        local ok,r=pcall(debug.getinfo,fn)
        if ok and type(r)=="table" then
            return string.format("src=%s line=%s name=%s",safe(r.short_src or r.source),safe(r.linedefined),safe(r.name))
        end
    end
    return "info indisponivel"
end

local function roots()
    local r={}
    pcall(function() r[#r+1]=game:GetService("CoreGui") end)
    pcall(function()
        local p=game:GetService("Players").LocalPlayer
        if p then
            local pg=p:FindFirstChildOfClass("PlayerGui")
            if pg then r[#r+1]=pg end
        end
    end)
    return r
end
local function findGate()
    for _,root in ipairs(roots()) do
        local ok,desc=pcall(function() return root:GetDescendants() end)
        if ok and type(desc)=="table" then
            local screen,box,button
            for _,obj in ipairs(desc) do
                pcall(function()
                    if obj:IsA("TextBox") then
                        local ph=tostring(obj.PlaceholderText or "")
                        if ph:lower():find("key",1,true) or ph:upper():find("ACCESS",1,true) then
                            box=box or obj
                            screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    elseif obj:IsA("TextButton") then
                        local tx=tostring(obj.Text or "")
                        local u=tx:upper()
                        if u=="UNLOCK" or u=="CONFIRM KEY" or tx:lower():find("confirm",1,true) then
                            button=button or obj
                            screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    end
                end)
            end
            if box and button then return screen,box,button end
        end
    end
end
local function getCallback(button)
    if type(getconnections)~="function" then return nil,"getconnections indisponivel" end
    local specs={{button.MouseButton1Click,"MouseButton1Click"},{button.Activated,"Activated"}}
    for _,spec in ipairs(specs) do
        local ok,cs=pcall(getconnections,spec[1])
        if ok and type(cs)=="table" then
            for i,c in ipairs(cs) do
                local fn
                pcall(function() fn=c.Function end)
                if type(fn)=="function" then return fn,spec[2].."["..i.."]" end
            end
        end
    end
    return nil,"callback nao encontrado"
end

local STRONG_LOAD={
    loadstring=true,httpget=true,httppost=true,request=true,http_request=true,
    ["syn.request"]=true,getasync=true,postasync=true
}
local WEAK_LOAD={load=true,require=true}
local KEY_EXACT={
    ["key accepted!"]=true,["invalid key. try again."]=true,["access-key"]=true,
    ["keysystemui"]=true,["confirm key"]=true,["get key"]=true,["unlock"]=true,
    ["script access"]=true
}

local strongHits,weakHits,urlHits,keyHits,knownFnHits={},{},{},{},{}
local allStrings={}
local seenString={}
local seenFn={}
local seenTable={}
local fnCount,tableCount=0,0
local MAX_FUNCTIONS=180
local MAX_TABLES=260
local MAX_STRINGS=2200

local knownFns={}
local function addKnown(name,v)
    if type(v)=="function" then knownFns[v]=name end
end
addKnown("loadstring",rawget(G,"loadstring") or loadstring)
addKnown("load",rawget(G,"load") or load)
addKnown("require",require)
addKnown("request",rawget(G,"request"))
addKnown("http_request",rawget(G,"http_request"))
pcall(function() if syn then addKnown("syn.request",syn.request) end end)

local function recordString(s,origin)
    if type(s)~="string" or #s==0 or #s>500 then return end
    local low=s:lower()
    local id=s.."\0"..origin
    if not seenString[id] and #allStrings<MAX_STRINGS then
        seenString[id]=true
        allStrings[#allStrings+1]={v=s,o=origin}
    end
    if STRONG_LOAD[low] then strongHits[#strongHits+1]={v=s,o=origin} end
    if WEAK_LOAD[low] then weakHits[#weakHits+1]={v=s,o=origin} end
    if low:find("https://",1,true)==1 or low:find("http://",1,true)==1 then
        urlHits[#urlHits+1]={v=s,o=origin}
    end
    if KEY_EXACT[low] or low:find("that key is not valid",1,true)==1 or low:find("key accepted",1,true)==1 then
        keyHits[#keyHits+1]={v=s,o=origin}
    end
end

local walkValue,walkFunction
local function recordKnownFn(v,origin)
    local name=knownFns[v]
    if name then knownFnHits[#knownFnHits+1]={name=name,o=origin,fn=v} end
end

walkValue=function(v,path,depth)
    local tv=type(v)
    if tv=="string" then
        recordString(v,path)
    elseif tv=="function" then
        recordKnownFn(v,path)
        walkFunction(v,path,depth)
    elseif tv=="table" then
        if depth>6 or seenTable[v] or tableCount>=MAX_TABLES then return end
        seenTable[v]=true; tableCount=tableCount+1
        local n=0
        for k,x in pairs(v) do
            n=n+1; if n>500 then break end
            if type(k)=="string" then recordString(k,path..".key") end
            local child=path.."["..safe(k).."]"
            if type(x)=="string" then recordString(x,child)
            elseif type(x)=="function" then recordKnownFn(x,child); walkFunction(x,child,depth+1)
            elseif type(x)=="table" then walkValue(x,child,depth+1) end
        end
    end
end

walkFunction=function(fn,path,depth)
    if type(fn)~="function" or depth>7 or seenFn[fn] or fnCount>=MAX_FUNCTIONS then return end
    seenFn[fn]=true; fnCount=fnCount+1
    local cs=getConstants(fn)
    if cs then
        for i,v in pairs(cs) do
            if type(v)=="string" then recordString(v,path..".constant["..safe(i).."]")
            elseif type(v)=="function" then recordKnownFn(v,path..".constant["..safe(i).."]") end
        end
    end
    local ups=getUps(fn)
    if ups then
        for i,v in pairs(ups) do
            walkValue(v,path..".upvalue["..safe(i).."]",depth+1)
        end
    end
    local ps=getProtos(fn)
    if ps then
        for i,p in pairs(ps) do if type(p)=="function" then walkFunction(p,path..".proto["..safe(i).."]",depth+1) end end
    end
end

local function printable(s)
    if type(s)~="string" then return false end
    if #s<2 or #s>160 then return false end
    for i=1,#s do
        local b=string.byte(s,i)
        if b<32 or b>126 then return false end
    end
    return true
end

local function scan()
    if running then setStatus("Ja esta escaneando") return end
    running=true; rows={}
    strongHits,weakHits,urlHits,keyHits,knownFnHits={},{},{},{},{}
    allStrings={}; seenString={}; seenFn={}; seenTable={}; fnCount=0; tableCount=0
    setStatus("Localizando callback real...")
    log("PayloadLinkScanner V4")
    log("Modo: callback-anchored / read-only / matching exato")

    local screen,box,button=findGate()
    if not box or not button then
        log("ERRO: gate ACCESS-KEY/UNLOCK nao encontrado")
        setStatus("Gate nao encontrado")
        running=false; saveReport(); return
    end
    log("Gate="..safe(screen))
    log("TextBox="..safe(box))
    log("Button="..safe(button).." text="..safe(button.Text))

    local cb,cbName=getCallback(button)
    if type(cb)~="function" then
        log("ERRO: "..safe(cbName)); setStatus("Callback inacessivel"); running=false; saveReport(); return
    end
    log("Callback="..cbName.." => "..safe(cb))
    log("Callback info: "..fnInfo(cb))

    setStatus("Lendo somente a arvore do callback...")
    walkFunction(cb,"UNLOCK_CALLBACK",0)

    log("Funcoes na arvore="..fnCount)
    log("Tabelas na arvore="..tableCount)
    log("Strings coletadas="..#allStrings)
    log("")
    log("===== MARCADORES REAIS DE KEY =====")
    log("KEY fortes="..#keyHits)
    for i,h in ipairs(keyHits) do if i>80 then break end log(string.format("KEY %q @ %s",h.v,h.o)) end
    log("")
    log("===== LOADERS FORTES (match exato) =====")
    log("LOAD fortes="..#strongHits)
    for i,h in ipairs(strongHits) do if i>80 then break end log(string.format("LOAD %q @ %s",h.v,h.o)) end
    log("URLs="..#urlHits)
    for i,h in ipairs(urlHits) do if i>80 then break end log(string.format("URL %q @ %s",h.v,h.o)) end
    log("Referencias diretas a funcoes conhecidas="..#knownFnHits)
    for i,h in ipairs(knownFnHits) do if i>80 then break end log(string.format("FNREF %s => %s @ %s",h.name,safe(h.fn),h.o)) end
    log("")
    log("===== LOADERS FRACOS (apenas load/require exatos) =====")
    log("LOAD fracos="..#weakHits)
    for i,h in ipairs(weakHits) do if i>80 then break end log(string.format("WEAK %q @ %s",h.v,h.o)) end
    log("")
    log("===== STRINGS PRINTABLES DA ARVORE =====")
    local pc=0
    local printed={}
    for _,e in ipairs(allStrings) do
        if printable(e.v) and not printed[e.v] then
            printed[e.v]=true; pc=pc+1
            if pc>300 then log("... limite 300 strings ..."); break end
            log(string.format("S[%03d] %q @ %s",pc,e.v,e.o))
        end
    end

    log("")
    if #strongHits==0 and #urlHits==0 and #knownFnHits==0 then
        log("RESUMO: nenhum loader forte/URL/referencia direta foi encontrado na arvore real do callback.")
    else
        log("RESUMO: existe pelo menos um indicador forte; revisar LOAD/URL/FNREF acima.")
    end
    local name=saveReport()
    log("Relatorio="..name)
    setStatus("Concluido - envie o relatorio")
    running=false
end

local function close()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    if ui then pcall(function() ui:Destroy() end) end
end

local function buildUI()
    local parent
    pcall(function() parent=(gethui and gethui()) or game:GetService("CoreGui") end)
    if not parent then pcall(function() parent=game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end) end
    if not parent then return end
    ui=Instance.new("ScreenGui"); ui.Name="PayloadLinkScannerV4UI"; ui.ResetOnSpawn=false; ui.Parent=parent
    local f=Instance.new("Frame"); f.Size=UDim2.fromOffset(330,120); f.Position=UDim2.new(.5,-165,.1,0); f.BackgroundColor3=Color3.fromRGB(18,22,30); f.BorderSizePixel=0; f.Active=true; f.Draggable=true; f.Parent=ui
    local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,9); c.Parent=f
    local title=Instance.new("TextLabel"); title.Size=UDim2.new(1,-12,0,24); title.Position=UDim2.fromOffset(6,6); title.BackgroundTransparency=1; title.Text="PAYLOAD LINK AUDIT V4"; title.TextColor3=Color3.fromRGB(240,240,240); title.TextSize=14; title.Font=Enum.Font.GothamBold; title.Parent=f
    statusLabel=Instance.new("TextLabel"); statusLabel.Size=UDim2.new(1,-14,0,30); statusLabel.Position=UDim2.fromOffset(7,34); statusLabel.BackgroundTransparency=1; statusLabel.Text="Abra SCRIPT ACCESS antes de escanear"; statusLabel.TextWrapped=true; statusLabel.TextColor3=Color3.fromRGB(185,198,218); statusLabel.TextSize=11; statusLabel.Font=Enum.Font.Gotham; statusLabel.Parent=f
    startButton=Instance.new("TextButton"); startButton.Size=UDim2.new(.62,-10,0,36); startButton.Position=UDim2.fromOffset(7,74); startButton.Text="ESCANEAR CALLBACK"; startButton.TextSize=12; startButton.Font=Enum.Font.GothamBold; startButton.BackgroundColor3=Color3.fromRGB(42,100,170); startButton.TextColor3=Color3.new(1,1,1); startButton.Parent=f
    local c1=Instance.new("UICorner"); c1.CornerRadius=UDim.new(0,7); c1.Parent=startButton
    closeButton=Instance.new("TextButton"); closeButton.Size=UDim2.new(.38,-5,0,36); closeButton.Position=UDim2.new(.62,0,0,74); closeButton.Text="FECHAR"; closeButton.TextSize=12; closeButton.Font=Enum.Font.GothamBold; closeButton.BackgroundColor3=Color3.fromRGB(105,47,58); closeButton.TextColor3=Color3.new(1,1,1); closeButton.Parent=f
    local c2=Instance.new("UICorner"); c2.CornerRadius=UDim.new(0,7); c2.Parent=closeButton
    conns[#conns+1]=startButton.MouseButton1Click:Connect(function() task.spawn(scan) end)
    conns[#conns+1]=closeButton.MouseButton1Click:Connect(close)
end

buildUI()
