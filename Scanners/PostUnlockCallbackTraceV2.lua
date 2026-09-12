-- PostUnlockCallbackTraceV2.lua
-- Diagnostico SOMENTE LEITURA do callback real do UNLOCK.
-- Nao preenche chave, nao clica UNLOCK e nao altera a validacao.
-- Captura a estrutura/estado da closure antes e depois da confirmacao MANUAL.

local G=(getgenv and getgenv()) or _G
local rows,conns={},{ }
local ui,statusLabel,armButton,stopButton
local armed=false
local startClock=0
local gateScreen,gateButton,gateBox
local callback,callbackName
local beforeSnapshot=nil
local reportName=nil

local function safe(v)
    local ok,s=pcall(tostring,v)
    return ok and s or "<tostring error>"
end

local function log(s)
    local t=startClock>0 and (os.clock()-startClock) or 0
    local line=string.format("[%.3f] %s",t,tostring(s))
    rows[#rows+1]=line
    print("[POST-CALLBACK-V2] "..tostring(s))
end

local function setStatus(s)
    if statusLabel then pcall(function() statusLabel.Text=tostring(s) end) end
end

local function addConn(c) conns[#conns+1]=c return c end
local function disconnectAll()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns={}
end

local function getUps(fn)
    for _,f in ipairs({rawget(G,"getupvalues"),debug and debug.getupvalues}) do
        if type(f)=="function" then
            local ok,r=pcall(f,fn)
            if ok and type(r)=="table" then return r end
        end
    end
end

local function getConsts(fn)
    for _,f in ipairs({rawget(G,"getconstants"),debug and debug.getconstants}) do
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
            local screen,box,button
            for _,obj in ipairs(desc) do
                pcall(function()
                    if obj:IsA("TextBox") then
                        local ph=tostring(obj.PlaceholderText or "")
                        if ph:lower():find("key",1,true) or ph:upper():find("ACCESS",1,true) then
                            box=box or obj; screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    elseif obj:IsA("TextButton") then
                        local tx=tostring(obj.Text or "")
                        if tx:upper()=="UNLOCK" or tx:lower():find("confirm",1,true) then
                            button=button or obj; screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
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

local function primitive(v)
    local t=type(v)
    if t=="nil" or t=="boolean" or t=="number" or t=="string" then
        local s=safe(v)
        if #s>180 then s=s:sub(1,180).."..." end
        return t..":"..s
    end
    if typeof and typeof(v)=="Instance" then
        local full="?"; pcall(function() full=v:GetFullName() end)
        return "Instance:"..safe(full)
    end
    return t..":"..safe(v)
end

local function snapshotClosure(rootFn)
    local snap={functions={},tables={}}
    local seenF,seenT={},{}

    local walkF,walkT
    walkT=function(t,path,depth)
        if type(t)~="table" or seenT[t] or depth>5 then return end
        seenT[t]=true
        local entry={path=path,values={}}
        snap.tables[t]=entry
        local n=0
        for k,v in pairs(t) do
            n=n+1; if n>500 then break end
            local kp=safe(k)
            if type(v)=="function" then
                entry.values[kp]="function:"..safe(v)
                walkF(v,path.."["..kp.."]",depth+1)
            elseif type(v)=="table" then
                entry.values[kp]="table:"..safe(v)
                walkT(v,path.."["..kp.."]",depth+1)
            else
                entry.values[kp]=primitive(v)
            end
        end
    end

    walkF=function(fn,path,depth)
        if type(fn)~="function" or seenF[fn] or depth>5 then return end
        seenF[fn]=true
        local fe={path=path,upvalues={},constants={}}
        snap.functions[fn]=fe
        local ups=getUps(fn)
        if ups then
            for k,v in pairs(ups) do
                local kp=safe(k)
                if type(v)=="function" then
                    fe.upvalues[kp]="function:"..safe(v)
                    walkF(v,path..".up["..kp.."]",depth+1)
                elseif type(v)=="table" then
                    fe.upvalues[kp]="table:"..safe(v)
                    walkT(v,path..".up["..kp.."]",depth+1)
                else
                    fe.upvalues[kp]=primitive(v)
                end
            end
        end
        local cs=getConsts(fn)
        if cs then
            for i,v in pairs(cs) do
                if type(v)=="string" or type(v)=="number" or type(v)=="boolean" then
                    local s=primitive(v)
                    if #s>220 then s=s:sub(1,220).."..." end
                    fe.constants[#fe.constants+1]=safe(i).."="..s
                end
            end
        end
        local ps=getProtos(fn)
        if ps then for i,p in pairs(ps) do if type(p)=="function" then walkF(p,path..".proto["..safe(i).."]",depth+1) end end end
    end

    walkF(rootFn,"UNLOCK_CALLBACK",0)
    return snap
end

local function countMap(t) local n=0 for _ in pairs(t or {}) do n=n+1 end return n end

local function compare(before,after,label)
    log("===== DIFF "..label.." =====")
    log("functions before="..countMap(before.functions).." after="..countMap(after.functions))
    log("tables before="..countMap(before.tables).." after="..countMap(after.tables))
    local changes=0

    for ref,b in pairs(before.tables) do
        local a=after.tables[ref]
        if not a then
            changes=changes+1; log("TABLE LOST: "..b.path)
        else
            local keys={}
            for k in pairs(b.values) do keys[k]=true end
            for k in pairs(a.values) do keys[k]=true end
            for k in pairs(keys) do
                if b.values[k]~=a.values[k] then
                    changes=changes+1
                    log("TABLE CHANGE "..b.path.." ["..k.."] "..safe(b.values[k]).." -> "..safe(a.values[k]))
                    if changes>=120 then break end
                end
            end
        end
        if changes>=120 then break end
    end

    if changes<120 then
        for ref,a in pairs(after.tables) do
            if not before.tables[ref] then changes=changes+1; log("TABLE NEW: "..a.path); if changes>=120 then break end end
        end
    end

    if changes<120 then
        for ref,b in pairs(before.functions) do
            local a=after.functions[ref]
            if a then
                local keys={}
                for k in pairs(b.upvalues) do keys[k]=true end
                for k in pairs(a.upvalues) do keys[k]=true end
                for k in pairs(keys) do
                    if b.upvalues[k]~=a.upvalues[k] then
                        changes=changes+1
                        log("UPVALUE CHANGE "..b.path.." ["..k.."] "..safe(b.upvalues[k]).." -> "..safe(a.upvalues[k]))
                        if changes>=120 then break end
                    end
                end
            end
            if changes>=120 then break end
        end
    end
    log("total changes logged="..changes)
end

local function saveReport()
    local report=table.concat(rows,"\n")
    G.POST_UNLOCK_CALLBACK_REPORT=report
    reportName=reportName or ("PostUnlockCallbackV2_"..tostring(os.time())..".txt")
    if type(writefile)=="function" then pcall(writefile,reportName,report) end
end

local function arm()
    if armed then setStatus("Ja esta armado") return end
    startClock=os.clock(); rows={}; reportName="PostUnlockCallbackV2_"..tostring(os.time())..".txt"
    log("PostUnlockCallbackTrace V2")
    log("Modo: snapshot read-only da closure do UNLOCK")

    gateScreen,gateBox,gateButton=findGate()
    if not gateButton then log("ERRO: gate nao encontrado"); setStatus("Gate nao encontrado"); saveReport(); return end
    callback,callbackName=getCallback(gateButton)
    if type(callback)~="function" then log("ERRO: "..safe(callbackName)); setStatus("Callback inacessivel"); saveReport(); return end
    log("Callback="..callbackName.." => "..safe(callback))

    setStatus("Capturando estado inicial...")
    beforeSnapshot=snapshotClosure(callback)
    log("BASE functions="..countMap(beforeSnapshot.functions).." tables="..countMap(beforeSnapshot.tables))
    saveReport()

    armed=true
    addConn(gateButton.MouseButton1Click:Connect(function()
        if not armed then return end
        log("EVENTO: clique real no UNLOCK")
        setStatus("Observando callback...")
        task.spawn(function()
            task.wait(.65)
            if not armed then return end
            local s1=snapshotClosure(callback)
            compare(beforeSnapshot,s1,"+0.65s")
            saveReport()

            task.wait(1.35)
            if not armed then return end
            local s2=snapshotClosure(callback)
            compare(beforeSnapshot,s2,"+2.00s")
            saveReport()

            task.wait(3.0)
            if not armed then return end
            local s3=snapshotClosure(callback)
            compare(beforeSnapshot,s3,"+5.00s")
            local alive=false
            if gateScreen then pcall(function() alive=gateScreen.Parent~=nil end) end
            log("KeySystemUI ainda existe="..tostring(alive))
            log("FINALIZADO")
            armed=false
            saveReport()
            setStatus("Concluido - envie o relatorio")
        end)
    end))

    setStatus("ARMADO - confirme a chave manualmente")
    log("ARMADO. Digite a chave valida e clique UNLOCK uma vez.")
end

local function stop()
    armed=false; saveReport(); disconnectAll(); if ui then pcall(function() ui:Destroy() end) end
end

local function buildUI()
    local parent
    pcall(function() parent=(gethui and gethui()) or game:GetService("CoreGui") end)
    if not parent then pcall(function() parent=game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end) end
    if not parent then return end
    ui=Instance.new("ScreenGui"); ui.Name="PostUnlockCallbackV2UI"; ui.ResetOnSpawn=false; ui.Parent=parent
    local f=Instance.new("Frame"); f.Size=UDim2.fromOffset(340,128); f.Position=UDim2.new(.5,-170,.10,0); f.BackgroundColor3=Color3.fromRGB(18,22,30); f.BorderSizePixel=0; f.Active=true; f.Draggable=true; f.Parent=ui
    local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,9); c.Parent=f
    local title=Instance.new("TextLabel"); title.Size=UDim2.new(1,-12,0,26); title.Position=UDim2.fromOffset(6,6); title.BackgroundTransparency=1; title.Text="POST-UNLOCK CALLBACK V2"; title.TextColor3=Color3.fromRGB(240,240,240); title.TextSize=14; title.Font=Enum.Font.GothamBold; title.Parent=f
    statusLabel=Instance.new("TextLabel"); statusLabel.Size=UDim2.new(1,-16,0,34); statusLabel.Position=UDim2.fromOffset(8,34); statusLabel.BackgroundTransparency=1; statusLabel.Text="Arme antes de confirmar a chave"; statusLabel.TextWrapped=true; statusLabel.TextColor3=Color3.fromRGB(185,198,218); statusLabel.TextSize=11; statusLabel.Font=Enum.Font.Gotham; statusLabel.Parent=f
    armButton=Instance.new("TextButton"); armButton.Size=UDim2.new(.56,-10,0,38); armButton.Position=UDim2.fromOffset(8,80); armButton.Text="ARMAR SCAN"; armButton.TextSize=12; armButton.Font=Enum.Font.GothamBold; armButton.BackgroundColor3=Color3.fromRGB(42,100,170); armButton.TextColor3=Color3.new(1,1,1); armButton.Parent=f
    local c1=Instance.new("UICorner"); c1.CornerRadius=UDim.new(0,7); c1.Parent=armButton
    stopButton=Instance.new("TextButton"); stopButton.Size=UDim2.new(.44,-6,0,38); stopButton.Position=UDim2.new(.56,0,0,80); stopButton.Text="FINALIZAR"; stopButton.TextSize=12; stopButton.Font=Enum.Font.GothamBold; stopButton.BackgroundColor3=Color3.fromRGB(105,47,58); stopButton.TextColor3=Color3.new(1,1,1); stopButton.Parent=f
    local c2=Instance.new("UICorner"); c2.CornerRadius=UDim.new(0,7); c2.Parent=stopButton
    addConn(armButton.MouseButton1Click:Connect(function() task.spawn(arm) end))
    addConn(stopButton.MouseButton1Click:Connect(stop))
end

buildUI()
