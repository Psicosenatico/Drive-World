-- PostUnlockMonitor.lua
-- Monitor de diagnostico apos a confirmacao MANUAL da chave.
-- Nao preenche chave, nao clica UNLOCK, nao altera validacao e nao intercepta codigo/rede.

local G=(getgenv and getgenv()) or _G

if type(G.POST_UNLOCK_MONITOR_STOP)=="function" then
    pcall(G.POST_UNLOCK_MONITOR_STOP,true)
end

local rows={}
local conns={}
local ui,statusLabel,armButton,stopButton
local armed=false
local finished=false
local startClock=0
local reportName=nil
local gateScreen,gateBox,gateButton,gateStatus
local guiBefore={}
local genvBefore={}

local function safe(v)
    local ok,s=pcall(tostring,v)
    return ok and s or "<tostring error>"
end

local function log(s)
    local t=startClock>0 and (os.clock()-startClock) or 0
    local line=string.format("[%.3f] %s",t,tostring(s))
    rows[#rows+1]=line
    print("[POST-UNLOCK] "..tostring(s))
end

local function setStatus(s)
    if statusLabel then pcall(function() statusLabel.Text=tostring(s) end) end
end

local function addConn(c)
    conns[#conns+1]=c
    return c
end

local function disconnectAll()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns={}
end

local function saveReport(extra)
    if extra then log(extra) end
    local report=table.concat(rows,"\n")
    G.POST_UNLOCK_MONITOR_REPORT=report
    reportName=reportName or ("PostUnlockMonitor_"..tostring(os.time())..".txt")
    if type(writefile)=="function" then pcall(writefile,reportName,report) end
    return report
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
            local screen,box,button,status
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
                        if tx:upper()=="UNLOCK" or tx:lower():find("confirm",1,true) then
                            button=button or obj
                            screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    elseif obj:IsA("TextLabel") then
                        local tx=tostring(obj.Text or ""):lower()
                        if tx:find("valid",1,true) or tx:find("granted",1,true) or tx:find("copied",1,true) then
                            status=status or obj
                        end
                    end
                end)
            end
            if box and button then return screen,box,button,status end
        end
    end
end

local function snapshotGui()
    local out={}
    for _,root in ipairs(roots()) do
        local ok,desc=pcall(function() return root:GetDescendants() end)
        if ok and type(desc)=="table" then
            for _,obj in ipairs(desc) do
                local tp=nil
                pcall(function()
                    if obj:IsA("ScreenGui") or obj:IsA("Frame") or obj:IsA("TextButton") or obj:IsA("TextLabel") then
                        tp=obj.ClassName
                    end
                end)
                if tp then
                    local key=safe(obj)
                    local full=nil
                    pcall(function() full=obj:GetFullName() end)
                    out[obj]=tp.." | "..safe(full or key)
                end
            end
        end
    end
    return out
end

local function snapshotGenv()
    local out={}
    for k,v in pairs(G) do out[k]=v end
    return out
end

local function logGuiDiff(before,after)
    local added,removed={},{}
    for obj,desc in pairs(after) do if not before[obj] then added[#added+1]=desc end end
    for obj,desc in pairs(before) do if not after[obj] then removed[#removed+1]=desc end end
    table.sort(added); table.sort(removed)
    log("GUI adicionados="..#added.." removidos="..#removed)
    for i,v in ipairs(added) do if i>40 then break end log("  + "..v) end
    for i,v in ipairs(removed) do if i>40 then break end log("  - "..v) end
end

local function logGenvDiff(before,after)
    local added,changed={},{ }
    for k,v in pairs(after) do
        if before[k]==nil then
            added[#added+1]=safe(k).."="..safe(v)
        elseif before[k]~=v then
            changed[#changed+1]=safe(k)..": "..safe(before[k]).." -> "..safe(v)
        end
    end
    table.sort(added); table.sort(changed)
    log("GETGENV novos="..#added.." alterados="..#changed)
    for i,v in ipairs(added) do if i>30 then break end log("  + "..v) end
    for i,v in ipairs(changed) do if i>30 then break end log("  * "..v) end
end

local function snapshot(label)
    log("===== SNAPSHOT "..label.." =====")
    local guiNow=snapshotGui()
    local genvNow=snapshotGenv()
    logGuiDiff(guiBefore,guiNow)
    logGenvDiff(genvBefore,genvNow)
    local alive=false
    if gateScreen then pcall(function() alive=gateScreen.Parent~=nil end) end
    log("KeySystemUI ainda existe="..tostring(alive))
    saveReport()
end

local function finish(reason)
    if finished then return end
    finished=true
    armed=false
    snapshot("FINAL")
    log("FINALIZADO: "..safe(reason))
    saveReport("Relatorio salvo em: "..safe(reportName))
    setStatus("Concluido - envie o relatorio")
end

local function arm()
    if armed then setStatus("Ja esta armado - confirme a chave") return end
    if finished then setStatus("Reexecute para novo teste") return end

    startClock=os.clock()
    rows={}
    reportName="PostUnlockMonitor_"..tostring(os.time())..".txt"
    log("PostUnlockMonitor V1")
    log("Modo: observacao passiva apos UNLOCK manual")

    gateScreen,gateBox,gateButton,gateStatus=findGate()
    if not gateBox or not gateButton then
        log("ERRO: gate ACCESS-KEY/UNLOCK nao encontrado")
        setStatus("Gate nao encontrado")
        saveReport()
        return
    end

    guiBefore=snapshotGui()
    genvBefore=snapshotGenv()
    log("Baseline GUI="..tostring((function() local n=0 for _ in pairs(guiBefore) do n=n+1 end return n end)()))
    log("Baseline getgenv="..tostring((function() local n=0 for _ in pairs(genvBefore) do n=n+1 end return n end)()))

    pcall(function()
        local ls=game:GetService("LogService")
        addConn(ls.MessageOut:Connect(function(msg,typ)
            if armed then log("LOG ["..safe(typ).."] "..safe(msg)) end
        end))
    end)

    pcall(function()
        local sc=game:GetService("ScriptContext")
        addConn(sc.Error:Connect(function(msg,stack,scriptInst)
            if armed then
                log("SCRIPT ERROR: "..safe(msg))
                if stack then log("STACK: "..safe(stack)) end
                if scriptInst then log("SCRIPT: "..safe(scriptInst)) end
            end
        end))
    end)

    if gateStatus then
        pcall(function()
            addConn(gateStatus:GetPropertyChangedSignal("Text"):Connect(function()
                if armed then log("STATUS UI => "..safe(gateStatus.Text)) end
            end))
        end)
    end

    if gateScreen then
        pcall(function()
            addConn(gateScreen.AncestryChanged:Connect(function(_,parent)
                if armed and parent==nil then log("EVENTO: KeySystemUI removida") end
            end))
        end)
        pcall(function()
            if gateScreen.Destroying then
                addConn(gateScreen.Destroying:Connect(function()
                    if armed then log("EVENTO: KeySystemUI.Destroying") end
                end))
            end
        end)
    end

    local clickSeen=false
    addConn(gateButton.MouseButton1Click:Connect(function()
        if not armed or clickSeen then return end
        clickSeen=true
        log("EVENTO: clique real no UNLOCK detectado")
        setStatus("Observando 10 segundos...")
        task.spawn(function()
            task.wait(.25); if armed then snapshot("+0.25s") end
            task.wait(.75); if armed then snapshot("+1.00s") end
            task.wait(2.00); if armed then snapshot("+3.00s") end
            task.wait(7.00); if armed then finish("janela de observacao de 10s concluida") end
        end)
    end))

    armed=true
    setStatus("ARMADO - digite a chave e clique UNLOCK")
    log("ARMADO. Agora confirme a chave manualmente UMA vez.")
    saveReport()
end

local function stop()
    if armed and not finished then finish("finalizado manualmente") end
    disconnectAll()
    if ui then pcall(function() ui:Destroy() end) end
end

local function buildUI()
    local parent
    pcall(function() parent=(gethui and gethui()) or game:GetService("CoreGui") end)
    if not parent then pcall(function() parent=game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end) end
    if not parent then return end

    ui=Instance.new("ScreenGui")
    ui.Name="PostUnlockMonitorUI"
    ui.ResetOnSpawn=false
    ui.Parent=parent

    local f=Instance.new("Frame")
    f.Size=UDim2.fromOffset(330,126)
    f.Position=UDim2.new(.5,-165,.10,0)
    f.BackgroundColor3=Color3.fromRGB(18,22,30)
    f.BorderSizePixel=0
    f.Active=true
    f.Draggable=true
    f.Parent=ui
    local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,9); c.Parent=f

    local title=Instance.new("TextLabel")
    title.Size=UDim2.new(1,-12,0,26); title.Position=UDim2.fromOffset(6,6)
    title.BackgroundTransparency=1; title.Text="POST-UNLOCK MONITOR V1"
    title.TextColor3=Color3.fromRGB(240,240,240); title.TextSize=15; title.Font=Enum.Font.GothamBold; title.Parent=f

    statusLabel=Instance.new("TextLabel")
    statusLabel.Size=UDim2.new(1,-16,0,32); statusLabel.Position=UDim2.fromOffset(8,34)
    statusLabel.BackgroundTransparency=1; statusLabel.Text="Arme antes de confirmar a chave"
    statusLabel.TextWrapped=true; statusLabel.TextColor3=Color3.fromRGB(185,198,218); statusLabel.TextSize=11; statusLabel.Font=Enum.Font.Gotham; statusLabel.Parent=f

    armButton=Instance.new("TextButton")
    armButton.Size=UDim2.new(.56,-10,0,38); armButton.Position=UDim2.fromOffset(8,78)
    armButton.Text="ARMAR MONITOR"; armButton.TextSize=12; armButton.Font=Enum.Font.GothamBold
    armButton.BackgroundColor3=Color3.fromRGB(42,100,170); armButton.TextColor3=Color3.new(1,1,1); armButton.Parent=f
    local c1=Instance.new("UICorner"); c1.CornerRadius=UDim.new(0,7); c1.Parent=armButton

    stopButton=Instance.new("TextButton")
    stopButton.Size=UDim2.new(.44,-6,0,38); stopButton.Position=UDim2.new(.56,0,0,78)
    stopButton.Text="FINALIZAR"; stopButton.TextSize=12; stopButton.Font=Enum.Font.GothamBold
    stopButton.BackgroundColor3=Color3.fromRGB(105,47,58); stopButton.TextColor3=Color3.new(1,1,1); stopButton.Parent=f
    local c2=Instance.new("UICorner"); c2.CornerRadius=UDim.new(0,7); c2.Parent=stopButton

    addConn(armButton.MouseButton1Click:Connect(function() task.spawn(arm) end))
    addConn(stopButton.MouseButton1Click:Connect(stop))
end

G.POST_UNLOCK_MONITOR_STOP=function(silent)
    armed=false
    disconnectAll()
    if not silent then saveReport("STOP externo") end
    if ui then pcall(function() ui:Destroy() end) end
    return true
end

buildUI()
