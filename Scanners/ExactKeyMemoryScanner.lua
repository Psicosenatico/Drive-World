-- ExactKeyMemoryScanner.lua
-- V6 - TRACE DIFERENCIAL DE OPERACOES DO COMPARADOR
-- Nao clica no UNLOCK real, nao escreve no TextBox real e nao consome tentativas.
-- Executa o callback em estado clonado com entradas artificiais e registra:
-- pool reads, string.len/byte/char, table.remove/concat e deltas do estado.

local G = (getgenv and getgenv()) or _G
local unpack_ = table.unpack or unpack

if type(G.EXACT_KEY_MEMORY_STOP) == "function" then
    pcall(G.EXACT_KEY_MEMORY_STOP, true)
end

local rows = {}
local running, finished = false, false
local ui, statusLabel, startButton, stopButton
local conns = {}

local function safe(v)
    local ok,s = pcall(tostring,v)
    return ok and s or "<tostring error>"
end

local function log(s)
    s=tostring(s)
    rows[#rows+1]=s
    print("[KEY-TRACE-V6] "..s)
end

local function setStatus(s)
    if statusLabel then pcall(function() statusLabel.Text=tostring(s) end) end
end

local function getUps(fn)
    for _,f in ipairs({rawget(G,"getupvalues"), debug and debug.getupvalues}) do
        if type(f)=="function" then
            local ok,r=pcall(f,fn)
            if ok and type(r)=="table" then return r end
        end
    end
end

local function setUp(fn,idx,value)
    for _,f in ipairs({rawget(G,"setupvalue"), debug and debug.setupvalue}) do
        if type(f)=="function" then
            local ok=pcall(f,fn,idx,value)
            if ok then return true end
        end
    end
    return false
end

local function hexWith(s, bytefn, max)
    if type(s)~="string" then return "" end
    max=max or 80
    local out={}
    for i=1,math.min(#s,max) do
        out[#out+1]=string.format("%02X",bytefn(s,i))
    end
    local x=table.concat(out)
    if #s>max then x=x.."..." end
    return x
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
            local box,button,screen,frame,label
            for _,obj in ipairs(desc) do
                pcall(function()
                    if obj:IsA("TextBox") then
                        local ph=tostring(obj.PlaceholderText or "")
                        if ph:lower():find("key",1,true) or ph:upper():find("ACCESS",1,true) then
                            box=box or obj
                            frame=frame or obj.Parent
                            screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    elseif obj:IsA("TextButton") then
                        local tx=tostring(obj.Text or "")
                        if tx:upper()=="UNLOCK" or tx:lower():find("confirm",1,true) then
                            button=button or obj
                            screen=screen or obj:FindFirstAncestorOfClass("ScreenGui")
                        end
                    end
                end)
            end
            if frame then
                pcall(function()
                    for _,c in ipairs(frame:GetChildren()) do
                        if c:IsA("TextLabel") then
                            local tx=tostring(c.Text or ""):lower()
                            if tx:find("valid",1,true) or tx:find("granted",1,true) or tx:find("continue",1,true) then
                                label=label or c
                            end
                        end
                    end
                end)
            end
            if box and button then return screen,frame,box,label,button end
        end
    end
end

local function getCallback(button)
    if type(getconnections)~="function" then return nil,"getconnections indisponivel" end
    for _,spec in ipairs({
        {signal=function() return button.MouseButton1Click end,name="MouseButton1Click"},
        {signal=function() return button.Activated end,name="Activated"},
    }) do
        local ok,sig=pcall(spec.signal)
        if ok then
            local ok2,cs=pcall(getconnections,sig)
            if ok2 and type(cs)=="table" then
                for i,c in ipairs(cs) do
                    local fn
                    pcall(function() fn=c.Function end)
                    if type(fn)=="function" then return fn,spec.name.."["..i.."]" end
                end
            end
        end
    end
    return nil,"callback nao encontrado"
end

local function tableStats(t)
    local total,strings,instances=0,0,0
    if type(t)~="table" then return 0,0,0 end
    for _,v in pairs(t) do
        total=total+1
        if type(v)=="string" then strings=strings+1 end
        if typeof and typeof(v)=="Instance" then instances=instances+1 end
    end
    return total,strings,instances
end

local function tableHas(t,target)
    if type(t)~="table" then return false end
    for _,v in pairs(t) do if v==target then return true end end
    return false
end

local function locateStateOwner(dispatcher,box)
    local ups=getUps(dispatcher)
    if not ups then return end
    for i,v in pairs(ups) do
        if type(v)=="table" and tableHas(v,box) then return dispatcher,i,v end
    end
end

local function locatePoolOwner(fn,depth,seen)
    if type(fn)~="function" then return end
    depth=depth or 0
    seen=seen or {}
    if depth>5 or seen[fn] then return end
    seen[fn]=true
    local ups=getUps(fn)
    if not ups then return end
    for i,v in pairs(ups) do
        if type(v)=="table" then
            local total,strings=tableStats(v)
            if total>=190 and total<=230 and strings==total then
                return fn,i,v
            end
        elseif type(v)=="function" then
            local a,b,c=locatePoolOwner(v,depth+1,seen)
            if a then return a,b,c end
        end
    end
end

local function cloneDeep(v,map,depth)
    if type(v)~="table" then return v end
    map=map or {}
    depth=depth or 0
    if map[v] then return map[v] end
    if depth>6 then return v end
    local n={}
    map[v]=n
    for k,val in pairs(v) do
        local nk=type(k)=="table" and cloneDeep(k,map,depth+1) or k
        n[nk]=cloneDeep(val,map,depth+1)
    end
    local mt=getmetatable(v)
    if type(mt)=="table" then pcall(setmetatable,n,mt) end
    return n
end

local function replaceRefs(t,refmap,seen,depth)
    if type(t)~="table" then return end
    seen=seen or {}
    depth=depth or 0
    if seen[t] or depth>7 then return end
    seen[t]=true
    for k,v in pairs(t) do
        if refmap[v] then
            t[k]=refmap[v]
        elseif type(v)=="table" then
            replaceRefs(v,refmap,seen,depth+1)
        end
    end
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

local function fakeFrame()
    return {Name="Frame",ClassName="Frame"}
end

local function summarizeValue(v,bytefn)
    if type(v)=="string" then
        local printable=true
        for i=1,#v do
            local b=bytefn(v,i)
            if b<32 or b>126 then printable=false break end
        end
        if printable then return string.format("str(%d)=%q",#v,v) end
        return string.format("str(%d) hex=%s",#v,hexWith(v,bytefn,40))
    elseif type(v)=="number" or type(v)=="boolean" or type(v)=="nil" then
        return type(v).."="..safe(v)
    elseif type(v)=="table" then
        return "table(len="..tostring(#v)..")"
    end
    return type(v).."="..safe(v)
end

local function diffTop(original,clone,bytefn)
    local out={}
    local keys={}
    for k in pairs(original) do keys[k]=true end
    for k in pairs(clone) do keys[k]=true end
    for k in pairs(keys) do
        local a,b=original[k],clone[k]
        if a~=b then
            local sameTable=false
            if type(a)=="table" and type(b)=="table" then
                sameTable=(#a==#b)
            end
            if not sameTable then
                out[#out+1]={k=k,a=summarizeValue(a,bytefn),b=summarizeValue(b,bytefn)}
            end
        end
    end
    table.sort(out,function(x,y) return tostring(x.k)<tostring(y.k) end)
    return out
end

local function runOne(input, cb, cbUps, dispatcher, stateOwner,stateIndex,state,poolOwner,poolIndex,pool,
                      screen,frame,box,label, originals)
    local result={input=input,poolReads={},ops={},statusWrites={},destroyed={value=false},sawText=false,ok=false,err=nil,deltas={}}

    local byte0=originals.byte
    local len0=originals.len
    local char0=originals.char
    local remove0=originals.remove
    local concat0=originals.concat

    local stateClone=cloneDeep(state,{},0)
    local fbox=fakeBox(input,function() result.sawText=true end)
    local flabel=fakeLabel(result.statusWrites)
    local fscreen=fakeScreen(result.destroyed)
    local fframe=fakeFrame()
    replaceRefs(stateClone,{[box]=fbox,[label]=flabel,[screen]=fscreen,[frame]=fframe},{},0)

    local poolProxy=setmetatable({}, {
        __index=function(_,k)
            local v=pool[k]
            if result.sawText and #result.poolReads<180 then result.poolReads[#result.poolReads+1]={k=k,v=v} end
            return v
        end,
        __newindex=function(t,k,v) rawset(t,k,v) end,
        __len=function() return #pool end,
        __pairs=function() return pairs(pool) end,
        __ipairs=function() return ipairs(pool) end,
    })

    local cbTableOriginals={}
    for i,v in pairs(cbUps) do if type(v)=="table" then cbTableOriginals[#cbTableOriginals+1]={idx=i,value=v} end end

    local swappedState=setUp(stateOwner,stateIndex,stateClone)
    local swappedPool=setUp(poolOwner,poolIndex,poolProxy)
    local swappedCb={}
    for _,e in ipairs(cbTableOriginals) do
        local cp=cloneDeep(e.value,{},0)
        if setUp(cb,e.idx,cp) then swappedCb[#swappedCb+1]=e end
    end

    if not swappedState or not swappedPool then
        result.err="falha ao isolar state/pool"
    else
        local active=true
        local function rec(op,data)
            if active and result.sawText and #result.ops<500 then
                data.op=op
                result.ops[#result.ops+1]=data
            end
        end

        string.len=function(s)
            local r=len0(s)
            rec("string.len",{s=s,r=r})
            return r
        end
        string.byte=function(s,i,j)
            local rs={byte0(s,i,j)}
            rec("string.byte",{s=s,i=i,j=j,rs=rs})
            return unpack_(rs)
        end
        string.char=function(...)
            local args={...}
            local r=char0(...)
            rec("string.char",{args=args,r=r})
            return r
        end
        table.remove=function(t,pos)
            local before=#t
            local r=remove0(t,pos)
            rec("table.remove",{before=before,pos=pos,r=r,after=#t})
            return r
        end
        table.concat=function(t,sep,i,j)
            local r=concat0(t,sep,i,j)
            rec("table.concat",{n=#t,sep=sep,i=i,j=j,r=r})
            return r
        end

        local ok,err=pcall(cb)
        active=false
        result.ok=ok
        result.err=err

        string.len=len0
        string.byte=byte0
        string.char=char0
        table.remove=remove0
        table.concat=concat0
    end

    pcall(setUp,stateOwner,stateIndex,state)
    pcall(setUp,poolOwner,poolIndex,pool)
    for _,e in ipairs(swappedCb) do pcall(setUp,cb,e.idx,e.value) end

    string.len=len0
    string.byte=byte0
    string.char=char0
    table.remove=remove0
    table.concat=concat0

    result.deltas=diffTop(state,stateClone,byte0)
    return result
end

local function formatOp(op,byte0)
    if op.op=="string.len" then
        return "string.len("..summarizeValue(op.s,byte0)..") => "..safe(op.r)
    elseif op.op=="string.byte" then
        local rr={}
        for _,v in ipairs(op.rs or {}) do rr[#rr+1]=tostring(v) end
        return "string.byte("..summarizeValue(op.s,byte0)..", "..safe(op.i)..", "..safe(op.j)..") => ["..table.concat(rr,",").."]"
    elseif op.op=="string.char" then
        local aa={}
        for _,v in ipairs(op.args or {}) do aa[#aa+1]=tostring(v) end
        return "string.char("..table.concat(aa,",")..") => "..summarizeValue(op.r,byte0)
    elseif op.op=="table.remove" then
        return string.format("table.remove(len=%s,pos=%s) => %s ; after=%s",safe(op.before),safe(op.pos),summarizeValue(op.r,byte0),safe(op.after))
    elseif op.op=="table.concat" then
        return "table.concat(n="..safe(op.n)..", sep="..safe(op.sep)..") => "..summarizeValue(op.r,byte0)
    end
    return op.op
end

local function saveReport()
    local report=table.concat(rows,"\n")
    G.EXACT_KEY_MEMORY_REPORT=report
    local name="ExactKeyOpsV6_"..tostring(os.time())..".txt"
    if type(writefile)=="function" then
        local ok=pcall(writefile,name,report)
        if ok then log("Relatorio salvo em: "..name) end
    end
    return report
end

local function runTrace()
    if running or finished then return end
    running=true
    rows={}
    setStatus("Localizando callback...")

    log("ExactKeyMemoryScanner V6")
    log("Modo: TRACE DIFERENCIAL / sem clique real")

    local screen,frame,box,label,button=findGate()
    if not box or not button then log("ERRO: gate nao encontrado"); setStatus("Gate nao encontrado"); running=false; return end

    local cb,cbName=getCallback(button)
    if type(cb)~="function" then log("ERRO: "..tostring(cbName)); setStatus("Callback inacessivel"); running=false; return end
    log("Callback: "..cbName.." => "..safe(cb))

    local cbUps=getUps(cb)
    local dispatcher
    if cbUps then for _,v in pairs(cbUps) do if not dispatcher and type(v)=="function" then dispatcher=v end end end
    if not dispatcher then log("ERRO: dispatcher nao encontrado"); setStatus("Sem dispatcher"); running=false; return end

    local stateOwner,stateIndex,state=locateStateOwner(dispatcher,box)
    local poolOwner,poolIndex,pool=locatePoolOwner(dispatcher,0,{})
    if not state or not pool then log("ERRO: state/pool nao encontrados"); setStatus("State/pool ausentes"); running=false; return end

    local originals={byte=string.byte,len=string.len,char=string.char,remove=table.remove,concat=table.concat}
    local tests={"","A","AAAA","AAAAAAAAAAAA","ABCDEFGHIJKLMNOPQRSTUVW","__KEY_TRACE_SENTINEL_V6__"}

    for ti,input in ipairs(tests) do
        setStatus("Teste isolado "..ti.."/"..#tests)
        local r=runOne(input,cb,cbUps,dispatcher,stateOwner,stateIndex,state,poolOwner,poolIndex,pool,screen,frame,box,label,originals)
        log("")
        log("========== TESTE "..ti.." ==========")
        log("INPUT len="..#input.." value="..string.format("%q",input))
        log("TextBox.Text lido: "..tostring(r.sawText))
        log("Callback ok="..tostring(r.ok).." err="..safe(r.err))
        log("Fake GUI Destroy: "..tostring(r.destroyed.value))
        log("Status fake writes: "..tostring(#r.statusWrites))
        for i,v in ipairs(r.statusWrites) do log("  STATUS["..i.."]="..string.format("%q",v)) end

        log("POOL READS apos TextBox.Text: "..tostring(#r.poolReads))
        for i,e in ipairs(r.poolReads) do
            if i>120 then log("  ... limite 120 ..."); break end
            log(string.format("  P[%03d] pool[%s] => %s",i,safe(e.k),summarizeValue(e.v,originals.byte)))
        end

        log("OPERACOES: "..tostring(#r.ops))
        for i,op in ipairs(r.ops) do
            if i>220 then log("  ... limite 220 ..."); break end
            log(string.format("  O[%03d] %s",i,formatOp(op,originals.byte)))
        end

        log("DELTAS STATE: "..tostring(#r.deltas))
        for i,d in ipairs(r.deltas) do
            if i>40 then break end
            log("  state["..safe(d.k).."] "..d.a.." -> "..d.b)
        end
        task.wait()
    end

    log("")
    log("========== SEGURANCA ==========")
    log("Nenhum clique real foi disparado pelo scanner.")

    finished=true
    running=false
    setStatus("Concluido - toque FINALIZAR")
    saveReport()
end

local function closeScanner()
    if running then setStatus("Aguarde o teste atual terminar"); return end
    saveReport()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns={}
    if ui then pcall(function() ui:Destroy() end) end
    G.EXACT_KEY_MEMORY_STOP=nil
end

local function buildUI()
    local parent
    pcall(function() parent=(gethui and gethui()) or game:GetService("CoreGui") end)
    if not parent then pcall(function() parent=game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end) end
    if not parent then return end

    ui=Instance.new("ScreenGui")
    ui.Name="ExactKeyTraceV6"
    ui.ResetOnSpawn=false
    ui.Parent=parent

    local f=Instance.new("Frame")
    f.Size=UDim2.fromOffset(245,100)
    f.Position=UDim2.new(0.5,-122,0.12,0)
    f.BackgroundColor3=Color3.fromRGB(18,22,30)
    f.BorderSizePixel=0
    f.Active=true
    f.Draggable=true
    f.Parent=ui
    local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,8); c.Parent=f

    local title=Instance.new("TextLabel")
    title.Size=UDim2.new(1,-12,0,22); title.Position=UDim2.fromOffset(6,5)
    title.BackgroundTransparency=1; title.Text="KEY TRACE V6"
    title.TextColor3=Color3.fromRGB(235,235,235); title.TextSize=13; title.Font=Enum.Font.GothamBold; title.Parent=f

    statusLabel=Instance.new("TextLabel")
    statusLabel.Size=UDim2.new(1,-12,0,22); statusLabel.Position=UDim2.fromOffset(6,28)
    statusLabel.BackgroundTransparency=1; statusLabel.Text="Pronto"
    statusLabel.TextColor3=Color3.fromRGB(180,195,215); statusLabel.TextSize=11; statusLabel.Font=Enum.Font.Gotham; statusLabel.Parent=f

    startButton=Instance.new("TextButton")
    startButton.Size=UDim2.new(0.48,-7,0,32); startButton.Position=UDim2.fromOffset(6,59)
    startButton.Text="INICIAR"; startButton.TextSize=12; startButton.Font=Enum.Font.GothamBold
    startButton.BackgroundColor3=Color3.fromRGB(36,92,155); startButton.TextColor3=Color3.new(1,1,1); startButton.Parent=f
    local c1=Instance.new("UICorner"); c1.CornerRadius=UDim.new(0,6); c1.Parent=startButton

    stopButton=Instance.new("TextButton")
    stopButton.Size=UDim2.new(0.52,-7,0,32); stopButton.Position=UDim2.new(0.48,1,0,59)
    stopButton.Text="FINALIZAR"; stopButton.TextSize=12; stopButton.Font=Enum.Font.GothamBold
    stopButton.BackgroundColor3=Color3.fromRGB(110,45,55); stopButton.TextColor3=Color3.new(1,1,1); stopButton.Parent=f
    local c2=Instance.new("UICorner"); c2.CornerRadius=UDim.new(0,6); c2.Parent=stopButton

    conns[#conns+1]=startButton.MouseButton1Click:Connect(function() task.spawn(runTrace) end)
    conns[#conns+1]=stopButton.MouseButton1Click:Connect(closeScanner)
end

G.EXACT_KEY_MEMORY_STOP=function(silent)
    if running then return false end
    if not silent then saveReport() end
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns={}
    if ui then pcall(function() ui:Destroy() end) end
    return true
end

buildUI()
