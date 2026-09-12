-- PayloadLinkScannerV3.lua
-- Scanner read-only para localizar continuacoes/payloads ligados ao key system.
-- Nao digita chave, nao clica UNLOCK e nao altera a validacao.

local G=(getgenv and getgenv()) or _G
local rows={}
local ui,statusLabel,startButton,stopButton
local running=false
local conns={}

local KEY_MARKERS={
    "Key accepted!","Invalid key","ACCESS-KEY","KeySystemUI","Confirm Key","UNLOCK","GET KEY","work.ink"
}
local LOAD_MARKERS={
    "loadstring","load","HttpGet","HttpPost","request","http_request","syn.request","require","GetAsync","PostAsync"
}
local FLOW_MARKERS={
    "task","wait","Destroy","Text","TextColor3","fromRGB","Connect","MouseButton1Click","Activated"
}

local function safe(v)
    local ok,s=pcall(tostring,v)
    return ok and s or "<tostring error>"
end
local function log(s)
    rows[#rows+1]=tostring(s)
    print("[PAYLOAD-LINK-V3] "..tostring(s))
end
local function setStatus(s)
    if statusLabel then pcall(function() statusLabel.Text=tostring(s) end) end
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

local function containsAny(s,markers)
    if type(s)~="string" then return false,nil end
    local l=s:lower()
    for _,m in ipairs(markers) do
        if l:find(m:lower(),1,true) then return true,m end
    end
    return false,nil
end

local function addString(bucket,s,origin)
    if type(s)~="string" or #s==0 or #s>300 then return end
    local k=s.."\0"..origin
    if bucket._seen[k] then return end
    bucket._seen[k]=true
    bucket[#bucket+1]={value=s,origin=origin}
end

local function harvestFunction(fn,depth,seen,bucket)
    if type(fn)~="function" then return end
    depth=depth or 0
    if depth>5 or seen[fn] then return end
    seen[fn]=true

    local cs=getConstants(fn)
    if cs then
        for i,v in pairs(cs) do
            if type(v)=="string" then addString(bucket,v,"constant["..safe(i).."]") end
        end
    end

    local ups=getUps(fn)
    if ups then
        for i,v in pairs(ups) do
            if type(v)=="string" then
                addString(bucket,v,"upvalue["..safe(i).."]")
            elseif type(v)=="table" then
                local n=0
                for k,x in pairs(v) do
                    n=n+1; if n>350 then break end
                    if type(k)=="string" then addString(bucket,k,"upvalue["..safe(i).."].key") end
                    if type(x)=="string" then addString(bucket,x,"upvalue["..safe(i).."]["..safe(k).."]") end
                    if type(x)=="function" then harvestFunction(x,depth+1,seen,bucket) end
                end
            elseif type(v)=="function" then
                harvestFunction(v,depth+1,seen,bucket)
            end
        end
    end

    local ps=getProtos(fn)
    if ps then
        for _,p in pairs(ps) do if type(p)=="function" then harvestFunction(p,depth+1,seen,bucket) end end
    end
end

local function scoreBucket(bucket)
    local keyHits,loadHits,flowHits={},{},{}
    for _,e in ipairs(bucket) do
        local ok,m=containsAny(e.value,KEY_MARKERS); if ok then keyHits[#keyHits+1]={m=m,e=e} end
        local ok2,m2=containsAny(e.value,LOAD_MARKERS); if ok2 then loadHits[#loadHits+1]={m=m2,e=e} end
        local ok3,m3=containsAny(e.value,FLOW_MARKERS); if ok3 then flowHits[#flowHits+1]={m=m3,e=e} end
    end
    local score=#keyHits*7+#loadHits*12+#flowHits
    if #keyHits>0 and #loadHits>0 then score=score+30 end
    return score,keyHits,loadHits,flowHits
end

local function saveReport()
    local report=table.concat(rows,"\n")
    G.PAYLOAD_LINK_V3_REPORT=report
    local name="PayloadLinkScannerV3_"..tostring(os.time())..".txt"
    if type(writefile)=="function" then pcall(writefile,name,report) end
    return name
end

local function scan()
    if running then setStatus("Ja esta escaneando") return end
    running=true; rows={}
    setStatus("Escaneando funcoes GC...")
    log("PayloadLinkScanner V3")
    log("Modo: read-only; procura ligacoes entre key system e loaders")

    if type(getgc)~="function" then
        log("ERRO: getgc indisponivel")
        setStatus("getgc indisponivel")
        running=false; saveReport(); return
    end

    local ok,gc=pcall(getgc,true)
    if not ok or type(gc)~="table" then
        log("ERRO: falha em getgc")
        setStatus("Falha em getgc")
        running=false; saveReport(); return
    end

    local results={}
    local scanned=0
    for _,obj in ipairs(gc) do
        if type(obj)=="function" then
            scanned=scanned+1
            local bucket={_seen={}}
            harvestFunction(obj,0,{},bucket)
            bucket._seen=nil
            local score,keyHits,loadHits,flowHits=scoreBucket(bucket)
            if score>=8 then
                results[#results+1]={fn=obj,score=score,keyHits=keyHits,loadHits=loadHits,flowHits=flowHits,bucket=bucket}
            end
        end
        if scanned%500==0 then setStatus("Funcoes lidas: "..scanned); task.wait() end
    end

    table.sort(results,function(a,b) return a.score>b.score end)
    log("Funcoes GC escaneadas="..scanned)
    log("Candidatos relevantes="..#results)

    for ri,r in ipairs(results) do
        if ri>80 then log("... limite 80 candidatos ..."); break end
        log("")
        log(string.format("===== CANDIDATO %d score=%d fn=%s =====",ri,r.score,safe(r.fn)))
        log("KEY_HITS="..#r.keyHits.." LOAD_HITS="..#r.loadHits.." FLOW_HITS="..#r.flowHits)
        for _,h in ipairs(r.keyHits) do log("  KEY "..h.m.." <= "..string.format("%q",h.e.value).." @ "..h.e.origin) end
        for _,h in ipairs(r.loadHits) do log("  LOAD "..h.m.." <= "..string.format("%q",h.e.value).." @ "..h.e.origin) end
        local fc=0
        for _,h in ipairs(r.flowHits) do
            fc=fc+1; if fc>20 then break end
            log("  FLOW "..h.m.." <= "..string.format("%q",h.e.value).." @ "..h.e.origin)
        end
    end

    log("")
    local linked=0
    for _,r in ipairs(results) do if #r.keyHits>0 and #r.loadHits>0 then linked=linked+1 end end
    log("RESUMO key+loader na mesma arvore="..linked)
    if linked==0 then
        log("Nenhuma arvore de closure encontrada contendo simultaneamente marcadores de chave e de loader.")
    else
        log("Ha candidatos que ligam key system a funcoes de carregamento; revisar blocos LOAD acima.")
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

    ui=Instance.new("ScreenGui"); ui.Name="PayloadLinkScannerV3UI"; ui.ResetOnSpawn=false; ui.Parent=parent
    local f=Instance.new("Frame"); f.Size=UDim2.fromOffset(310,118); f.Position=UDim2.new(.5,-155,.1,0); f.BackgroundColor3=Color3.fromRGB(18,22,30); f.BorderSizePixel=0; f.Active=true; f.Draggable=true; f.Parent=ui
    local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,9); c.Parent=f
    local title=Instance.new("TextLabel"); title.Size=UDim2.new(1,-12,0,24); title.Position=UDim2.fromOffset(6,6); title.BackgroundTransparency=1; title.Text="PAYLOAD LINK SCAN V3"; title.TextColor3=Color3.fromRGB(240,240,240); title.TextSize=14; title.Font=Enum.Font.GothamBold; title.Parent=f
    statusLabel=Instance.new("TextLabel"); statusLabel.Size=UDim2.new(1,-14,0,30); statusLabel.Position=UDim2.fromOffset(7,34); statusLabel.BackgroundTransparency=1; statusLabel.Text="Pronto"; statusLabel.TextWrapped=true; statusLabel.TextColor3=Color3.fromRGB(185,198,218); statusLabel.TextSize=11; statusLabel.Font=Enum.Font.Gotham; statusLabel.Parent=f
    startButton=Instance.new("TextButton"); startButton.Size=UDim2.new(.58,-10,0,36); startButton.Position=UDim2.fromOffset(7,72); startButton.Text="ESCANEAR"; startButton.TextSize=12; startButton.Font=Enum.Font.GothamBold; startButton.BackgroundColor3=Color3.fromRGB(42,100,170); startButton.TextColor3=Color3.new(1,1,1); startButton.Parent=f
    local c1=Instance.new("UICorner"); c1.CornerRadius=UDim.new(0,7); c1.Parent=startButton
    stopButton=Instance.new("TextButton"); stopButton.Size=UDim2.new(.42,-5,0,36); stopButton.Position=UDim2.new(.58,0,0,72); stopButton.Text="FECHAR"; stopButton.TextSize=12; stopButton.Font=Enum.Font.GothamBold; stopButton.BackgroundColor3=Color3.fromRGB(105,47,58); stopButton.TextColor3=Color3.new(1,1,1); stopButton.Parent=f
    local c2=Instance.new("UICorner"); c2.CornerRadius=UDim.new(0,7); c2.Parent=stopButton
    conns[#conns+1]=startButton.MouseButton1Click:Connect(function() task.spawn(scan) end)
    conns[#conns+1]=stopButton.MouseButton1Click:Connect(close)
end

buildUI()
