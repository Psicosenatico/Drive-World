-- Drive World local key gate tracer for the Luau CLI.
-- The workflow injects the original script.lua source at __TARGET_EXEC__.

local ALL = {}
local SIGNALS = {}
local LOG = {}
local BASE_PAIRS = pairs
local BASE_IPAIRS = ipairs
local BASE_STRING = string

local function out(...)
    local t = {}
    for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end
    local s = table.concat(t, ' ')
    LOG[#LOG + 1] = s
    print(s)
end

local function simple(v)
    local tv = type(v)
    if tv == 'string' then return BASE_STRING.format('%q', v) end
    if tv == 'number' or tv == 'boolean' or tv == 'nil' then return tostring(v) end
    if tv == 'function' then return '<function:' .. tostring(v) .. '>' end
    if tv == 'table' then
        if rawget(v, '__isInstance') then
            return '<' .. tostring(rawget(v, 'ClassName')) .. ':' .. tostring(rawget(v, 'Name')) .. '>'
        end
        return '<table:' .. tostring(v) .. '>'
    end
    return '<' .. tv .. ':' .. tostring(v) .. '>'
end

local Signal = {}
Signal.__index = Signal
function Signal.new(owner, name)
    local s = setmetatable({owner = owner, name = name, connections = {}}, Signal)
    SIGNALS[#SIGNALS + 1] = s
    return s
end
function Signal:Connect(fn)
    self.connections[#self.connections + 1] = fn
    out('[CONNECT]', simple(self.owner), self.name, 'callback=' .. tostring(fn))
    return {Disconnect = function() end, Connected = true}
end
function Signal:Fire(...)
    for _, fn in BASE_IPAIRS(self.connections) do
        local ok, err = pcall(fn, ...)
        out('[CALLBACK]', self.name, ok and 'OK' or ('ERR ' .. tostring(err)))
    end
end

local ObjMethods = {}
local ObjMT = {}
function ObjMT.__index(self, k)
    local m = ObjMethods[k]
    if m then return m end
    local v = rawget(self, k)
    if v ~= nil then return v end
    if k == 'MouseButton1Click' or k == 'Activated' or k == 'FocusLost' or k == 'Changed' then
        local s = Signal.new(self, k)
        rawset(self, k, s)
        return s
    end
    return nil
end
function ObjMT.__newindex(self, k, v)
    rawset(self, k, v)
    if k == 'Parent' and type(v) == 'table' and rawget(v, '_children') then
        v._children[#v._children + 1] = self
    end
    if k == 'Text' or k == 'PlaceholderText' or k == 'Name' or k == 'Parent' or k == 'Enabled' or k == 'Visible' or k == 'Active' then
        out('[SET]', simple(self), tostring(k), simple(v))
    end
end

local function newObj(class, name)
    local o = setmetatable({__isInstance = true, ClassName = class, Name = name or class, Parent = nil, _children = {}}, ObjMT)
    ALL[#ALL + 1] = o
    return o
end
function ObjMethods:IsA(cls)
    return self.ClassName == cls or (cls == 'GuiObject' and self.ClassName ~= 'ScreenGui')
end
function ObjMethods:GetChildren() return self._children end
function ObjMethods:GetDescendants()
    local outt = {}
    local function rec(x)
        for _, c in BASE_IPAIRS(x._children or {}) do outt[#outt + 1] = c; rec(c) end
    end
    rec(self)
    return outt
end
function ObjMethods:FindFirstChild(name)
    for _, c in BASE_IPAIRS(self._children or {}) do if c.Name == name then return c end end
    return nil
end
function ObjMethods:WaitForChild(name)
    local x = self:FindFirstChild(name)
    if x then return x end
    x = newObj('Folder', name)
    x.Parent = self
    return x
end
function ObjMethods:Destroy()
    out('[DESTROY]', simple(self))
    rawset(self, 'Parent', nil)
    rawset(self, 'Destroyed', true)
end
function ObjMethods:GetFullName() return tostring(self.Name) end
function ObjMethods:GetPropertyChangedSignal(name) return Signal.new(self, 'PropertyChanged:' .. tostring(name)) end

local Players = newObj('Players', 'Players')
local LocalPlayer = newObj('Player', 'LocalPlayer')
local PlayerGui = newObj('PlayerGui', 'PlayerGui')
LocalPlayer.PlayerGui = PlayerGui
Players.LocalPlayer = LocalPlayer
PlayerGui.Parent = LocalPlayer
local CoreGui = newObj('CoreGui', 'CoreGui')

local gameObj = newObj('DataModel', 'game')
function ObjMethods:GetService(name)
    out('[GETSERVICE]', name)
    if name == 'Players' then return Players end
    if name == 'CoreGui' then return CoreGui end
    return newObj(name, name)
end

game = gameObj
workspace = newObj('Workspace', 'Workspace')

Instance = {}
function Instance.new(class, parent)
    local o = newObj(class, class)
    if parent then o.Parent = parent end
    out('[INSTANCE]', class)
    return o
end

local function ctor(name)
    return setmetatable({
        new = function(...) return {__type = name, args = {...}} end,
        fromRGB = function(...) return {__type = name, args = {...}} end,
        fromOffset = function(...) return {__type = name, args = {...}} end,
        fromScale = function(...) return {__type = name, args = {...}} end,
    }, {__index = function(_, k) return function(...) return {__type = name .. '.' .. k, args = {...}} end end})
end
Color3 = ctor('Color3')
UDim = ctor('UDim')
UDim2 = ctor('UDim2')
Vector2 = ctor('Vector2')
Vector3 = ctor('Vector3')
CFrame = ctor('CFrame')
Enum = setmetatable({}, {__index = function(_, a)
    return setmetatable({}, {__index = function(_, b) return 'Enum.' .. tostring(a) .. '.' .. tostring(b) end})
end})

task = {}
function task.wait(x) out('[TASK.WAIT]', x); return x or 0 end
function task.spawn(fn, ...) out('[TASK.SPAWN]', tostring(fn)); return fn(...) end
function task.defer(fn, ...) out('[TASK.DEFER]', tostring(fn)); return fn(...) end
wait = task.wait

function setclipboard(v) out('[SETCLIPBOARD]', simple(v)) end
function warn(...) out('[WARN]', ...) end
function typeof(v)
    if type(v) == 'table' and rawget(v, '__isInstance') then return 'Instance' end
    return type(v)
end

-- Keep built-ins untouched while the obfuscator bootstraps (anti-tamper sensitive).
local ok, err
__TARGET_EXEC__
out('[TARGET]', ok and 'OK' or ('ERR ' .. tostring(err)))

out('=== UI OBJECTS ===')
for i, o in BASE_IPAIRS(ALL) do
    if o.ClassName == 'ScreenGui' or o.ClassName == 'TextBox' or o.ClassName == 'TextButton' or o.ClassName == 'TextLabel' then
        out('[UI]', i, o.ClassName, 'Name=' .. tostring(o.Name), 'Text=' .. simple(rawget(o, 'Text')), 'Placeholder=' .. simple(rawget(o, 'PlaceholderText')))
    end
end

-- Find visible access gate.
local box = nil
local unlockSignals = {}
for _, o in BASE_IPAIRS(ALL) do
    if o.ClassName == 'TextBox' then
        local ph = tostring(rawget(o, 'PlaceholderText') or '')
        if ph == 'ACCESS-KEY' or BASE_STRING.upper(ph):find('KEY', 1, true) then box = o end
    end
end
for _, sig in BASE_IPAIRS(SIGNALS) do
    local owner = sig.owner
    if owner and owner.ClassName == 'TextButton' and BASE_STRING.upper(tostring(rawget(owner, 'Text') or '')) == 'UNLOCK' then
        unlockSignals[#unlockSignals + 1] = sig
    end
end

-- Runtime wrappers are installed only AFTER initialization, so the anti-tamper bootstrap
-- sees the original standard-library functions. They log any key table/normalization used
-- while the UNLOCK callback executes.
local function dumpSmallTable(t, tag)
    if type(t) ~= 'table' then return end
    local parts = {}
    local n = 0
    for k, v in BASE_PAIRS(t) do
        n += 1
        if n > 40 then break end
        if type(k) == 'string' or type(k) == 'number' then
            if type(v) == 'string' or type(v) == 'number' or type(v) == 'boolean' then
                parts[#parts + 1] = '[' .. simple(k) .. ']=' .. simple(v)
            end
        end
    end
    if #parts > 0 then out(tag, table.concat(parts, ' | ')) end
end

pairs = function(t)
    dumpSmallTable(t, '[PAIRS-TABLE]')
    return BASE_PAIRS(t)
end
ipairs = function(t)
    dumpSmallTable(t, '[IPAIRS-TABLE]')
    return BASE_IPAIRS(t)
end

local TRACE_STRING = {}
for k, v in BASE_PAIRS(BASE_STRING) do TRACE_STRING[k] = v end
TRACE_STRING.upper = function(s)
    local r = BASE_STRING.upper(s)
    out('[STRING.UPPER]', simple(s), '->', simple(r))
    return r
end
TRACE_STRING.match = function(s, p, ...)
    local r = BASE_STRING.match(s, p, ...)
    out('[STRING.MATCH]', simple(s), simple(p), '->', simple(r))
    return r
end
TRACE_STRING.gsub = function(s, p, r, n)
    local a, b = BASE_STRING.gsub(s, p, r, n)
    out('[STRING.GSUB]', simple(s), simple(p), '->', simple(a))
    return a, b
end
string = TRACE_STRING

local BASE_TONUMBER = tonumber
tonumber = function(v, ...)
    local r = BASE_TONUMBER(v, ...)
    out('[TONUMBER]', simple(v), '->', simple(r))
    return r
end

if box and #unlockSignals > 0 then
    box.Text = '__TRACE_SENTINEL_9F3A__'
    out('=== INVOKE UNLOCK WITH SENTINEL ===')
    for _, sig in BASE_IPAIRS(unlockSignals) do sig:Fire() end
else
    out('[WARN] unlock gate not found for invocation', 'box=' .. tostring(box), 'signals=' .. tostring(#unlockSignals))
end

out('=== POST-CALL UI ===')
for i, o in BASE_IPAIRS(ALL) do
    if o.ClassName == 'TextLabel' or o.ClassName == 'TextButton' or o.ClassName == 'TextBox' or o.ClassName == 'ScreenGui' then
        out('[UI-AFTER]', i, o.ClassName, 'Name=' .. tostring(o.Name), 'Text=' .. simple(rawget(o, 'Text')), 'Destroyed=' .. tostring(rawget(o, 'Destroyed')))
    end
end
out('=== DONE ===')
