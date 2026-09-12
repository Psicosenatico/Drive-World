-- Trace the original Drive World local key gate under Lua 5.1.
-- No Roblox/executor payload is sent anywhere. The target is downloaded by the workflow.

local ALL = {}
local SIGNALS = {}
local LOG = {}

local function out(...)
  local t={}
  for i=1,select('#',...) do t[#t+1]=tostring(select(i,...)) end
  local s=table.concat(t,' ')
  LOG[#LOG+1]=s
  print(s)
end

local function simple(v)
  local t=type(v)
  if t=='string' then return string.format('%q',v) end
  if t=='number' or t=='boolean' or t=='nil' then return tostring(v) end
  if t=='function' then return '<function:'..tostring(v)..'>' end
  if t=='table' then
    if rawget(v,'__isInstance') then return '<'..tostring(rawget(v,'ClassName'))..':'..tostring(rawget(v,'Name'))..'>' end
    return '<table:'..tostring(v)..'>'
  end
  return '<'..t..':'..tostring(v)..'>'
end

local Signal={}
Signal.__index=Signal
function Signal.new(owner,name)
  local s=setmetatable({owner=owner,name=name,connections={}},Signal)
  SIGNALS[#SIGNALS+1]=s
  return s
end
function Signal:Connect(fn)
  self.connections[#self.connections+1]=fn
  out('[CONNECT]', simple(self.owner), self.name, 'callback='..tostring(fn))
  return {Disconnect=function() end, Connected=true}
end
function Signal:Fire(...)
  for _,fn in ipairs(self.connections) do
    local ok,err=pcall(fn,...)
    out('[CALLBACK]', self.name, ok and 'OK' or ('ERR '..tostring(err)))
  end
end

local ObjMethods={}
local ObjMT={}
function ObjMT.__index(self,k)
  local m=ObjMethods[k]
  if m then return m end
  local v=rawget(self,k)
  if v~=nil then return v end
  if k=='MouseButton1Click' or k=='Activated' or k=='FocusLost' or k=='Changed' then
    local s=Signal.new(self,k); rawset(self,k,s); return s
  end
  return nil
end
function ObjMT.__newindex(self,k,v)
  rawset(self,k,v)
  if k=='Text' or k=='PlaceholderText' or k=='Name' or k=='Parent' or k=='Enabled' or k=='Visible' or k=='Active' then
    out('[SET]', simple(self), tostring(k), simple(v))
  end
end

local function newObj(class,name)
  local o=setmetatable({__isInstance=true,ClassName=class,Name=name or class,Parent=nil,_children={}},ObjMT)
  ALL[#ALL+1]=o
  return o
end
function ObjMethods:IsA(cls) return self.ClassName==cls or (cls=='GuiObject' and self.ClassName~='ScreenGui') end
function ObjMethods:GetChildren() return self._children end
function ObjMethods:GetDescendants()
  local outt={}
  local function rec(x)
    for _,c in ipairs(x._children or {}) do outt[#outt+1]=c; rec(c) end
  end
  rec(self); return outt
end
function ObjMethods:FindFirstChild(name)
  for _,c in ipairs(self._children or {}) do if c.Name==name then return c end end
  return nil
end
function ObjMethods:WaitForChild(name)
  local x=self:FindFirstChild(name)
  if x then return x end
  x=newObj('Folder',name); x.Parent=self; self._children[#self._children+1]=x; return x
end
function ObjMethods:Destroy() out('[DESTROY]',simple(self)); self.Parent=nil; self.Destroyed=true end
function ObjMethods:GetFullName() return tostring(self.Name) end
function ObjMethods:GetPropertyChangedSignal(name) return Signal.new(self,'PropertyChanged:'..tostring(name)) end

local Players=newObj('Players','Players')
local LocalPlayer=newObj('Player','LocalPlayer')
local PlayerGui=newObj('PlayerGui','PlayerGui')
LocalPlayer.PlayerGui=PlayerGui
Players.LocalPlayer=LocalPlayer
LocalPlayer._children[#LocalPlayer._children+1]=PlayerGui
PlayerGui.Parent=LocalPlayer
local CoreGui=newObj('CoreGui','CoreGui')

local gameObj=newObj('DataModel','game')
function ObjMethods:GetService(name)
  out('[GETSERVICE]',name)
  if name=='Players' then return Players end
  if name=='CoreGui' then return CoreGui end
  local x=newObj(name,name); return x
end

game=gameObj
workspace=newObj('Workspace','Workspace')

Instance={}
function Instance.new(class,parent)
  local o=newObj(class,class)
  if parent then o.Parent=parent; if parent._children then parent._children[#parent._children+1]=o end end
  out('[INSTANCE]',class)
  return o
end

local function ctor(name)
  return setmetatable({new=function(...) return {__type=name,args={...}} end,fromRGB=function(...) return {__type=name,args={...}} end,fromOffset=function(...) return {__type=name,args={...}} end,fromScale=function(...) return {__type=name,args={...}} end},{__index=function(t,k) return function(...) return {__type=name..'.'..k,args={...}} end end})
end
Color3=ctor('Color3'); UDim=ctor('UDim'); UDim2=ctor('UDim2'); Vector2=ctor('Vector2'); Vector3=ctor('Vector3'); CFrame=ctor('CFrame')
Enum=setmetatable({}, {__index=function(_,a) return setmetatable({}, {__index=function(_,b) return 'Enum.'..tostring(a)..'.'..tostring(b) end}) end})

task={}
function task.wait(x) out('[TASK.WAIT]',x); return x or 0 end
function task.spawn(fn,...) out('[TASK.SPAWN]',tostring(fn)); return fn(...) end
function task.defer(fn,...) out('[TASK.DEFER]',tostring(fn)); return fn(...) end
wait=task.wait

function setclipboard(v) out('[SETCLIPBOARD]',simple(v)) end
function warn(...) out('[WARN]',...) end
function typeof(v) if type(v)=='table' and v.__isInstance then return 'Instance' end return type(v) end

-- Log key string helpers while preserving behavior.
local _upper=string.upper
string.upper=function(s) local r=_upper(s); out('[STRING.UPPER]',simple(s),'->',simple(r)); return r end
local _match=string.match
string.match=function(s,p,...) local r=_match(s,p,...); out('[STRING.MATCH]',simple(s),simple(p),'->',simple(r)); return r end
local _gsub=string.gsub
string.gsub=function(s,p,r,n) local a,b=_gsub(s,p,r,n); out('[STRING.GSUB]',simple(s),simple(p),'->',simple(a)); return a,b end
local _tonumber=tonumber
tonumber=function(v,...) local r=_tonumber(v,...); out('[TONUMBER]',simple(v),'->',simple(r)); return r end

-- Load target in the same global environment.
local target=assert(loadfile('script.lua'))
local ok,err=pcall(target)
out('[TARGET]',ok and 'OK' or ('ERR '..tostring(err)))

out('=== UI OBJECTS ===')
for i,o in ipairs(ALL) do
  if o.ClassName=='ScreenGui' or o.ClassName=='TextBox' or o.ClassName=='TextButton' or o.ClassName=='TextLabel' then
    out('[UI]',i,o.ClassName,'Name='..tostring(o.Name),'Text='..simple(rawget(o,'Text')),'Placeholder='..simple(rawget(o,'PlaceholderText')))
  end
end

local seen={}
local function dumpValue(v,depth,label)
  if depth>5 then return end
  local tv=type(v)
  if tv=='string' or tv=='number' or tv=='boolean' or tv=='nil' then
    out(string.rep(' ',depth*2)..'[UPVALUE]',label,simple(v)); return
  end
  if tv=='table' then
    if seen[v] then return end; seen[v]=true
    out(string.rep(' ',depth*2)..'[TABLE]',label,simple(v))
    local n=0
    for k,x in pairs(v) do
      n=n+1; if n>100 then break end
      local kl='['..simple(k)..']'
      if type(x)=='string' or type(x)=='number' or type(x)=='boolean' then
        out(string.rep(' ',(depth+1)*2)..kl,'=',simple(x))
      elseif type(x)=='table' and not x.__isInstance then
        dumpValue(x,depth+1,label..kl)
      elseif type(x)=='function' then
        dumpValue(x,depth+1,label..kl)
      end
    end
  elseif tv=='function' then
    if seen[v] then return end; seen[v]=true
    out(string.rep(' ',depth*2)..'[FUNCTION]',label,tostring(v))
    local i=1
    while true do
      local name,val=debug.getupvalue(v,i)
      if not name then break end
      if type(val)=='string' or type(val)=='number' or type(val)=='boolean' or type(val)=='table' or type(val)=='function' then
        dumpValue(val,depth+1,label..'.'..name)
      end
      i=i+1
    end
  end
end

out('=== CALLBACK UPVALUES ===')
for _,sig in ipairs(SIGNALS) do
  for idx,fn in ipairs(sig.connections) do
    local owner=sig.owner
    local txt=owner and rawget(owner,'Text') or nil
    out('[SIGNAL]',simple(owner),sig.name,'Text='..simple(txt),'#'..idx)
    seen={}; dumpValue(fn,0,'callback')
  end
end

-- Invoke only the visible UNLOCK callback with a sentinel to log runtime transforms.
local box=nil
local unlockSignal=nil
for _,o in ipairs(ALL) do
  if o.ClassName=='TextBox' and (rawget(o,'PlaceholderText')=='ACCESS-KEY' or tostring(rawget(o,'PlaceholderText')):find('KEY')) then box=o end
end
for _,sig in ipairs(SIGNALS) do
  local owner=sig.owner
  if owner and owner.ClassName=='TextButton' and tostring(rawget(owner,'Text')):upper()=='UNLOCK' then unlockSignal=sig break end
end
if box and unlockSignal then
  box.Text='__TRACE_SENTINEL_9F3A__'
  out('=== INVOKE UNLOCK WITH SENTINEL ===')
  unlockSignal:Fire()
else
  out('[WARN] unlock gate not found for invocation')
end

out('=== DONE ===')
