-- ExactKeyCandidateV6_3.lua
-- V6.3 - verifica uma chave candidata SOMENTE em estado clonado.
-- Nao escreve no TextBox real, nao clica UNLOCK real e nao consome tentativas.

local G=(getgenv and getgenv()) or _G
local CANDIDATE="ACCESS-KEY"
local TIMEOUT=3.0
local rows={}
local running=false
local ui,statusLabel,startButton,stopButton
local conns={}
local worker=nil
local cancelRequested=false

local function safe(v)
    local ok,s=pcall(tostring,v)
    return ok and s or "<tostring error>"
end
local function log(s)
    s=tostring(s); rows[#rows+1]=s; print("[KEY-CAND-V6.3] "..s)
end
local function setStatus(s)
    if statusLabel then pcall(function() statusLabel.Text=tostring(s) end) end
end
local function getUps(fn)
    for _,f in ipairs({rawget(G,"getupvalues"),debug and debug.getupvalues}) do
        if type(f)=="function" then local ok,r=pcall(f,fn); if ok and type(r)=="table" then return r end end
    end
end
local function setUp(fn,i,v)
    for _,f in ipairs({rawget(G,"setupvalue"),debug and debug.setupvalue}) do
        if type(f)=="function" then local ok=pcall(f,fn,i,v); if ok then return true end end
    end
    return false
end
local function roots()
    local r={}
    pcall(function() r[#r+1]=game:GetService("CoreGui") end)
    pcall(function()
        local p=game:GetService("Players").LocalPlayer
        if p then local pg=p:FindFirstChildOfClass("PlayerGui"); if pg then r[#r+1]=pg end end
    end)
    return r
end
local function findGate()
    for _,root in ipairs(roots()) do
        local ok,desc=pcall(function() return root:GetDescendants() end)
        if ok and type(desc)=="table" then
            local screen,frame,box,button,label
            for _,obj in ipairs(desc) do
                pcall(function()
                    if obj:IsA("TextBox") then
                        local ph=tostring(obj.PlaceholderText or "")
                        if ph:lower():find("key",1,true) or ph:upper():find("ACCESS",1,true) then
                            box=box or obj; frame=frame or obj.Parent; screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    elseif obj:IsA("TextButton") then
                        local tx=tostring(obj.Text or "")
                        if tx:upper()=="UNLOCK" or tx:lower():find("confirm",1,true) then
                            button=button or obj; screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    end
                end)
            end
            if frame then
                pcall(function()
                    for _,c in ipairs(frame:GetChildren()) do if c:IsA("TextLabel") then label=label or c end end
                end)
            end
            if box and button then return screen,frame,box,label,button end
        end
    end
end
local function getCallback(button)
    if type(getconnections)~="function" then return nil,"getconnections indisponivel" end
    for _,spec in ipairs({{button.MouseButton1Click,"MouseButton1Click"},{button.Activated,"Activated"}}) do
        local ok,cs=pcall(getconnections,spec[1])
        if ok and type(cs)=="table" then
            for i,c in ipairs(cs) do
                local fn; pcall(function() fn=c.Function end)
                if type(fn)=="function" then return fn,spec[2].."["..i.."]" end
            end
        end
    end
    return nil,"callback nao encontrado"
end
local function tableStats(t)
    local total,strings=0,0
    if type(t)~="table" then return 0,0 end
    for _,v in pairs(t) do total=total+1; if type(v)=="string" then strings=strings+1 end end
    return total,strings
end
local function tableHas(t,target)
    if type(t)~="table" then return false end
    for _,v in pairs(t) do if v==target then return true end end
    return false
end
local function locateStateOwner(dispatcher,box)
    local ups=getUps(dispatcher); if not ups then return end
    for i,v in pairs(ups) do if type(v)=="table" and tableHas(v,box) then return dispatcher,i,v end end
end
local function locatePoolOwner(fn,depth,seen)
    if type(fn)~="function" then return end
    depth=depth or 0; seen=seen or {}
    if depth>5 or seen[fn] then return end; seen[fn]=true
    local ups=getUps(fn); if not ups then return end
    for i,v in pairs(ups) do
        if type(v)=="table" then
            local total,strings=tableStats(v)
            if total>=190 and total<=230 and strings==total then return fn,i,v end
        elseif type(v)=="function" then
            local a,b,c=locatePoolOwner(v,depth+1,seen); if a then return a,b,c end
        end
    end
end
local function shallowCopy(t)
    local n={}; for k,v in pairs(t) do n[k]=v end; return n
end
local function fakeBox(input,onRead)
    return setmetatable({Name="TextBox",ClassName="TextBox"},{
        __index=function(_,k)
            if k=="Text" then onRead(); return input end
            if k=="PlaceholderText" then return "ACCESS-KEY" end
            if k=="ClearTextOnFocus" then return false end
            return nil
        end,
        __newindex=function(t,k,v) rawset(t,k,v) end
    })
end
local function fakeLabel(writes)
    return setmetatable({Name="TextLabel",ClassName="TextLabel"},{
        __index=function(t,k) return rawget(t,k) end,
        __newindex=function(t,k,v)
            if k=="Text" then writes[#writes+1]=tostring(v) end
            rawset(t,k,v)
        end
    })
end
local function fakeScreen(flag)
    local t={Name="KeySystemUI",ClassName="ScreenGui"}
    t.Destroy=function() flag.value=true end
    return t
end
local function fakeFrame() return {Name="Frame",ClassName="Frame"} end
local function saveReport()
    local report=table.concat(rows,"\n")
    G.EXACT_KEY_MEMORY_REPORT=report
    local name="ExactKeyCandidateV6_3_"..tostring(os.time())..".txt"
    if type(writefile)=="function" then pcall(writefile,name,report) end
    return name
end

local function verify()
    if running then setStatus("Ja esta executando") return end
    running=true; cancelRequested=false; rows={}
    setStatus("Localizando gate...")
    log("ExactKeyCandidate V6.3")
    log("Modo: verificacao isolada; sem clique real")
    log("CANDIDATO="..string.format("%q",CANDIDATE))

    local screen,frame,box,label,button=findGate()
    if not box or not button then log("ERRO: gate nao encontrado"); setStatus("Gate nao encontrado"); running=false; saveReport(); return end
    local cb,cbName=getCallback(button)
    if type(cb)~="function" then log("ERRO: "..safe(cbName)); setStatus("Callback inacessivel"); running=false; saveReport(); return end
    log("Callback="..cbName.." => "..safe(cb))

    local cbUps=getUps(cb)
    local dispatcher
    if cbUps then for _,v in pairs(cbUps) do if not dispatcher and type(v)=="function" then dispatcher=v end end end
    if not dispatcher then log("ERRO: dispatcher nao encontrado"); setStatus("Sem dispatcher"); running=false; saveReport(); return end

    local stateOwner,stateIndex,state=locateStateOwner(dispatcher,box)
    local poolOwner,poolIndex,pool=locatePoolOwner(dispatcher,0,{})
    if not state or not pool then log("ERRO: state/pool nao encontrados"); setStatus("State/pool ausentes"); running=false; saveReport(); return end

    local sawText=false
    local writes={}
    local destroyed={value=false}
    local poolReads={}
    local stateClone=shallowCopy(state)
    local fbox=fakeBox(CANDIDATE,function() sawText=true end)
    local flabel=fakeLabel(writes)
    local fscreen=fakeScreen(destroyed)
    local fframe=fakeFrame()
    for k,v in pairs(stateClone) do
        if v==box then stateClone[k]=fbox end
        if label and v==label then stateClone[k]=flabel end
        if screen and v==screen then stateClone[k]=fscreen end
        if frame and v==frame then stateClone[k]=fframe end
    end

    local poolProxy=setmetatable({}, {
        __index=function(_,k)
            local v=pool[k]
            if sawText and #poolReads<120 then poolReads[#poolReads+1]={k=k,v=v} end
            return v
        end,
        __newindex=function(t,k,v) rawset(t,k,v) end,
        __len=function() return #pool end,
        __pairs=function() return pairs(pool) end,
        __ipairs=function() return ipairs(pool) end,
    })

    local cbTableOriginals={}
    if cbUps then for i,v in pairs(cbUps) do if type(v)=="table" then cbTableOriginals[#cbTableOriginals+1]={idx=i,value=v} end end end
    local swapped={}
    local okState=setUp(stateOwner,stateIndex,stateClone)
    local okPool=setUp(poolOwner,poolIndex,poolProxy)
    for _,e in ipairs(cbTableOriginals) do
        local cp=shallowCopy(e.value)
        if setUp(cb,e.idx,cp) then swapped[#swapped+1]=e end
    end
    local function restore()
        pcall(setUp,stateOwner,stateIndex,state)
        pcall(setUp,poolOwner,poolIndex,pool)
        for _,e in ipairs(swapped) do pcall(setUp,cb,e.idx,e.value) end
    end
    if not okState or not okPool then log("ERRO: falha ao isolar"); restore(); setStatus("Falha ao isolar"); running=false; saveReport(); return end

    local done=false; local okRun=false; local errRun=nil
    worker=task.spawn(function()
        okRun,errRun=pcall(cb)
        done=true
    end)

    local t0=os.clock()
    while not done and not cancelRequested and os.clock()-t0<TIMEOUT do
        setStatus(string.format("Testando ACCESS-KEY %.1fs",os.clock()-t0))
        task.wait(0.05)
    end
    local timedOut=not done and not cancelRequested
    if (timedOut or cancelRequested) and worker then pcall(task.cancel,worker) end
    task.wait()
    restore()

    log("TextBox.Text lido="..tostring(sawText))
    log("Callback terminou="..tostring(done))
    log("Callback ok="..tostring(okRun))
    log("Erro/saida="..safe(errRun))
    log("Timeout="..tostring(timedOut))
    log("Cancelado="..tostring(cancelRequested))
    log("Fake GUI Destroy="..tostring(destroyed.value))
    log("Status writes="..tostring(#writes))
    for i,v in ipairs(writes) do log("STATUS["..i.."]="..string.format("%q",v)) end
    log("Pool reads="..tostring(#poolReads))
    for i,e in ipairs(poolReads) do
        local desc=type(e.v)=="string" and string.format("str(%d)=%q",#e.v,e.v) or safe(e.v)
        log(string.format("P[%03d] pool[%s] => %s",i,safe(e.k),desc))
    end

    if destroyed.value then
        log("RESULTADO: CANDIDATO ACEITO NO TRACE ISOLADO")
        setStatus("ACCESS-KEY ACEITA (isolado)")
    elseif #writes>0 then
        log("RESULTADO: houve escrita de status; revisar relatorio")
        setStatus("Concluido - revisar resultado")
    elseif timedOut then
        log("RESULTADO: timeout; inconclusivo")
        setStatus("Timeout - resultado inconclusivo")
    else
        log("RESULTADO: candidato nao acionou Destroy")
        setStatus("Concluido - candidato nao aceito")
    end
    local name=saveReport(); log("Relatorio="..name)
    running=false; worker=nil
end

local function close()
    if running then cancelRequested=true; setStatus("Cancelando..."); return end
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    if ui then pcall(function() ui:Destroy() end) end
end

local function buildUI()
    local parent
    pcall(function() parent=(gethui and gethui()) or game:GetService("CoreGui") end)
    if not parent then pcall(function() parent=game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end) end
    if not parent then return end
    ui=Instance.new("ScreenGui"); ui.Name="ExactKeyCandidateV63"; ui.ResetOnSpawn=false; ui.Parent=parent
    local f=Instance.new("Frame"); f.Size=UDim2.fromOffset(300,118); f.Position=UDim2.new(.5,-150,.12,0); f.BackgroundColor3=Color3.fromRGB(18,22,30); f.BorderSizePixel=0; f.Active=true; f.Draggable=true; f.Parent=ui
    local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,9); c.Parent=f
    local title=Instance.new("TextLabel"); title.Size=UDim2.new(1,-12,0,24); title.Position=UDim2.fromOffset(6,7); title.BackgroundTransparency=1; title.Text="KEY VERIFY V6.3"; title.TextColor3=Color3.fromRGB(240,240,240); title.TextSize=15; title.Font=Enum.Font.GothamBold; title.Parent=f
    statusLabel=Instance.new("TextLabel"); statusLabel.Size=UDim2.new(1,-12,0,28); statusLabel.Position=UDim2.fromOffset(6,36); statusLabel.BackgroundTransparency=1; statusLabel.Text="Pronto para verificar ACCESS-KEY"; statusLabel.TextColor3=Color3.fromRGB(185,198,218); statusLabel.TextSize=11; statusLabel.Font=Enum.Font.Gotham; statusLabel.Parent=f
    startButton=Instance.new("TextButton"); startButton.Size=UDim2.new(.52,-10,0,36); startButton.Position=UDim2.fromOffset(7,72); startButton.Text="VERIFICAR"; startButton.TextSize=12; startButton.Font=Enum.Font.GothamBold; startButton.BackgroundColor3=Color3.fromRGB(42,100,170); startButton.TextColor3=Color3.new(1,1,1); startButton.Parent=f
    local c1=Instance.new("UICorner"); c1.CornerRadius=UDim.new(0,7); c1.Parent=startButton
    stopButton=Instance.new("TextButton"); stopButton.Size=UDim2.new(.48,-5,0,36); stopButton.Position=UDim2.new(.52,0,0,72); stopButton.Text="FECHAR"; stopButton.TextSize=12; stopButton.Font=Enum.Font.GothamBold; stopButton.BackgroundColor3=Color3.fromRGB(105,47,58); stopButton.TextColor3=Color3.new(1,1,1); stopButton.Parent=f
    local c2=Instance.new("UICorner"); c2.CornerRadius=UDim.new(0,7); c2.Parent=stopButton
    conns[#conns+1]=startButton.MouseButton1Click:Connect(function() task.spawn(verify) end)
    conns[#conns+1]=stopButton.MouseButton1Click:Connect(close)
end

buildUI()
