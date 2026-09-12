--[[
AUTO-UNLOCK FULL FLOW CAPTURE
Target: yumyum272/driving/script1.lua

Purpose:
  1) run the original obfuscated script under local monitoring;
  2) capture any Lua source received by HttpGet/request;
  3) capture every source passed to loadstring;
  4) detect the local "SCRIPT ACCESS" gate;
  5) prefill the locally embedded keys already recovered from script.lua;
  6) trigger UNLOCK when the executor exposes firesignal/getconnections;
  7) save a summary naming the last/largest likely final Lua payload.

All captures are local files in the executor. Nothing is uploaded by this scanner.
]]

local TARGET_URL = "https://raw.githubusercontent.com/yumyum272/driving/refs/heads/main/script1.lua"
local CANDIDATE_KEYS = {
    "DEMO-2026-LOADER",
    "TRIAL-7-DAYS",
}

local G = (getgenv and getgenv()) or _G
local unpack_ = table.unpack or unpack
local START = os.clock()
local SESSION = "AutoUnlockFlow_" .. tostring(os.time())
local LOG_FILE = SESSION .. "_log.txt"
local SUMMARY_FILE = SESSION .. "_summary.txt"
local LOGS = {}
local CAPTURES = {}
local COUNTER = 0
local STOPPED = false

local function elapsed()
    return string.format("%.3f", os.clock() - START)
end

local function safe(v)
    local ok, out = pcall(function()
        if typeof and typeof(v) == "Instance" then
            return v:GetFullName()
        end
        return tostring(v)
    end)
    return ok and out or "<tostring error>"
end

local function writeLocal(name, data)
    if type(writefile) ~= "function" then
        return false
    end
    return pcall(writefile, name, tostring(data or ""))
end

local function flush()
    writeLocal(LOG_FILE, table.concat(LOGS, "\n"))
end

local function log(tag, msg)
    local line = string.format("[%s] [%s] %s", elapsed(), tostring(tag), tostring(msg))
    LOGS[#LOGS + 1] = line
    print("[AUTO-UNLOCK-FLOW] " .. line)
    if (#LOGS % 10) == 0 then
        flush()
    end
end

local function looksLikeLua(s)
    if type(s) ~= "string" or #s < 30 then
        return false
    end
    local score = 0
    if s:find("local ", 1, true) then score = score + 1 end
    if s:find("function", 1, true) then score = score + 1 end
    if s:find("return", 1, true) then score = score + 1 end
    if s:find("game", 1, true) then score = score + 1 end
    if s:find("GetService", 1, true) then score = score + 1 end
    if s:find("Instance.new", 1, true) then score = score + 1 end
    if s:find("loadstring", 1, true) then score = score + 1 end
    if s:find("--[[", 1, true) then score = score + 1 end
    return score >= 2
end

local function saveCapture(kind, source, meta)
    if type(source) ~= "string" or #source == 0 then
        return nil
    end
    COUNTER = COUNTER + 1
    local filename = string.format(
        "%s_%03d_%s.txt",
        SESSION,
        COUNTER,
        tostring(kind):gsub("[^%w_%-]", "_")
    )
    local item = {
        index = COUNTER,
        kind = tostring(kind),
        file = filename,
        bytes = #source,
        luaLike = looksLikeLua(source),
        meta = tostring(meta or ""),
        time = elapsed(),
    }
    CAPTURES[#CAPTURES + 1] = item
    writeLocal(filename, source)
    log("CAPTURE", string.format(
        "#%03d | %s | %d bytes | lua=%s | %s",
        item.index,
        item.kind,
        item.bytes,
        tostring(item.luaLike),
        item.meta
    ))
    return filename
end

local function captureBody(kind, url, body)
    if type(body) ~= "string" then
        return
    end
    if looksLikeLua(body) then
        saveCapture(kind, body, tostring(url or "?"))
    else
        log(kind, tostring(url or "?") .. " -> " .. tostring(#body) .. " bytes")
    end
end

local originalLoadstring = rawget(G, "loadstring") or loadstring

if type(originalLoadstring) == "function" then
    local wrappedLoadstring = function(source, chunkName, ...)
        if type(source) == "string" then
            local file = saveCapture("loadstring", source, "chunk=" .. tostring(chunkName or "?"))
            log("LOADSTRING", tostring(file) .. " | " .. tostring(#source) .. " bytes")
        else
            log("LOADSTRING", "non-string input: " .. safe(source))
        end
        return originalLoadstring(source, chunkName, ...)
    end

    if type(hookfunction) == "function" then
        local ok = pcall(function()
            hookfunction(originalLoadstring, wrappedLoadstring)
        end)
        log("HOOK", "loadstring=" .. tostring(ok))
    else
        pcall(function()
            G.loadstring = wrappedLoadstring
        end)
        log("HOOK", "loadstring global replacement attempted")
    end
else
    log("WARN", "loadstring unavailable")
end

local function hookRequest(name, original)
    if type(original) ~= "function" then
        return
    end

    local wrapped = function(options, ...)
        local url = "?"
        if type(options) == "table" then
            url = options.Url or options.URL or options.url or "?"
        else
            url = tostring(options)
        end
        log("REQUEST", tostring(name) .. " -> " .. tostring(url))
        local results = {original(options, ...)}
        local response = results[1]
        if type(response) == "table" then
            local body = response.Body or response.body
            captureBody("request_response", url, body)
        elseif type(response) == "string" then
            captureBody("request_response", url, response)
        end
        return unpack_(results)
    end

    if type(hookfunction) == "function" then
        local ok = pcall(function()
            hookfunction(original, wrapped)
        end)
        log("HOOK", tostring(name) .. "=" .. tostring(ok))
    else
        pcall(function()
            G[name] = wrapped
        end)
    end
end

for _, name in ipairs({"request", "http_request", "httprequest"}) do
    hookRequest(name, rawget(G, name))
end

if type(rawget(G, "syn")) == "table" and type(G.syn.request) == "function" then
    local synOriginal = G.syn.request
    local wrapped = function(options, ...)
        local url = type(options) == "table" and (options.Url or options.URL or options.url) or tostring(options)
        log("REQUEST", "syn.request -> " .. tostring(url))
        local results = {synOriginal(options, ...)}
        local response = results[1]
        if type(response) == "table" then
            captureBody("request_response", url, response.Body or response.body)
        elseif type(response) == "string" then
            captureBody("request_response", url, response)
        end
        return unpack_(results)
    end
    if type(hookfunction) == "function" then
        local ok = pcall(function()
            hookfunction(synOriginal, wrapped)
        end)
        log("HOOK", "syn.request=" .. tostring(ok))
    else
        pcall(function() G.syn.request = wrapped end)
    end
end

local function hookHttpMethod(label, fn)
    if type(fn) ~= "function" or type(hookfunction) ~= "function" then
        return
    end
    local old
    local ok = pcall(function()
        old = hookfunction(fn, function(self, url, ...)
            log(label, tostring(url))
            local results = {old(self, url, ...)}
            if type(results[1]) == "string" then
                captureBody(label .. "_response", url, results[1])
            end
            return unpack_(results)
        end)
    end)
    log("HOOK", label .. "=" .. tostring(ok))
end

pcall(function() hookHttpMethod("HttpGet", game.HttpGet) end)
pcall(function() hookHttpMethod("HttpGetAsync", game.HttpGetAsync) end)

pcall(function()
    if type(hookmetamethod) ~= "function"
    or type(newcclosure) ~= "function"
    or type(getnamecallmethod) ~= "function" then
        return
    end

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        local args = {...}

        if method == "HttpGet" or method == "HttpGetAsync" then
            local url = tostring(args[1])
            log("NAMECALL-" .. method, url)
            local results = {oldNamecall(self, ...)}
            if type(results[1]) == "string" then
                captureBody(method .. "_response", url, results[1])
            end
            return unpack_(results)
        end

        return oldNamecall(self, ...)
    end))

    log("HOOK", "__namecall=true")
end)

local function findGate()
    local roots = {}
    pcall(function()
        local players = game:GetService("Players")
        local lp = players.LocalPlayer
        if lp then
            local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
            if pg then roots[#roots + 1] = pg end
        end
    end)
    pcall(function()
        local cg = game:GetService("CoreGui")
        if cg then roots[#roots + 1] = cg end
    end)
    pcall(function()
        if type(gethui) == "function" then
            local hui = gethui()
            if hui then roots[#roots + 1] = hui end
        end
    end)

    for _, root in ipairs(roots) do
        local ok, descendants = pcall(function() return root:GetDescendants() end)
        if ok and type(descendants) == "table" then
            local box = nil
            local unlock = nil
            local status = nil
            local screen = nil
            for _, obj in ipairs(descendants) do
                pcall(function()
                    if obj:IsA("ScreenGui") then
                        local n = tostring(obj.Name)
                        if n == "LoaderKeySystem" or n:lower():find("key", 1, true) then
                            screen = screen or obj
                        end
                    elseif obj:IsA("TextBox") then
                        local ph = tostring(obj.PlaceholderText or "")
                        if ph == "ACCESS-KEY" or ph:lower():find("key", 1, true) then
                            box = obj
                        end
                    elseif obj:IsA("TextButton") then
                        local txt = tostring(obj.Text or "")
                        if txt:upper() == "UNLOCK" or txt:lower():find("confirm", 1, true) then
                            unlock = obj
                        end
                    elseif obj:IsA("TextLabel") then
                        local txt = tostring(obj.Text or "")
                        if txt:lower():find("waiting for key", 1, true)
                        or txt:lower():find("access", 1, true) then
                            status = status or obj
                        end
                    end
                end)
            end
            if box and unlock then
                return screen, box, unlock, status
            end
        end
    end
    return nil
end

local function fireButton(button)
    local fired = false

    if type(firesignal) == "function" then
        pcall(function() firesignal(button.MouseButton1Click) fired = true end)
        pcall(function() firesignal(button.Activated) fired = true end)
    end

    if type(getconnections) == "function" then
        local function fireConnections(signal)
            local ok, list = pcall(getconnections, signal)
            if not ok or type(list) ~= "table" then return end
            for _, c in ipairs(list) do
                local okFire = pcall(function()
                    if type(c.Fire) == "function" then
                        c:Fire()
                    elseif type(c.Function) == "function" then
                        c.Function()
                    elseif type(c.Enable) == "function" and type(c.Function) == "function" then
                        c:Enable()
                        c.Function()
                    end
                end)
                if okFire then fired = true end
            end
        end
        pcall(function() fireConnections(button.MouseButton1Click) end)
        pcall(function() fireConnections(button.Activated) end)
    end

    if not fired then
        pcall(function()
            button:Activate()
            fired = true
        end)
    end

    return fired
end

local function tryAutoUnlock()
    local deadline = os.clock() + 12
    local screen, box, button, status
    while os.clock() < deadline and not STOPPED do
        screen, box, button, status = findGate()
        if box and button then break end
        task.wait(0.15)
    end

    if not box or not button then
        log("AUTO-UNLOCK", "key gate not found; interact manually if a UI is visible")
        return false
    end

    log("AUTO-UNLOCK", "gate found: " .. safe(screen or button))

    for _, key in ipairs(CANDIDATE_KEYS) do
        if STOPPED then return false end
        pcall(function() box.Text = key end)
        log("AUTO-UNLOCK", "trying recovered local key: " .. key)
        local fired = fireButton(button)
        log("AUTO-UNLOCK", "button trigger attempted=" .. tostring(fired))
        task.wait(0.8)

        local screenGone = false
        pcall(function()
            screenGone = screen and screen.Parent == nil
        end)

        local text = ""
        pcall(function() text = tostring(status and status.Text or "") end)
        local lower = text:lower()
        if screenGone
        or lower:find("granted", 1, true)
        or lower:find("accepted", 1, true)
        or lower:find("success", 1, true)
        or tostring(button.Text):upper() == "UNLOCKED" then
            log("AUTO-UNLOCK", "local key accepted: " .. key)
            return true
        end
    end

    log("AUTO-UNLOCK", "automatic attempts did not confirm success")
    return false
end

local function makeSummary()
    local lines = {}
    lines[#lines + 1] = "AUTO-UNLOCK FULL FLOW SUMMARY"
    lines[#lines + 1] = "Session: " .. SESSION
    lines[#lines + 1] = "Target: " .. TARGET_URL
    lines[#lines + 1] = "Captures: " .. tostring(#CAPTURES)
    lines[#lines + 1] = ""

    local largestLua = nil
    local lastLua = nil
    for _, c in ipairs(CAPTURES) do
        lines[#lines + 1] = string.format(
            "#%03d | %s | %d bytes | lua=%s | %s | %s",
            c.index,
            c.kind,
            c.bytes,
            tostring(c.luaLike),
            c.file,
            c.meta
        )
        if c.luaLike then
            lastLua = c
            if not largestLua or c.bytes > largestLua.bytes then
                largestLua = c
            end
        end
    end

    lines[#lines + 1] = ""
    if lastLua then
        lines[#lines + 1] = "LAST LUA-LIKE CAPTURE: " .. lastLua.file
        lines[#lines + 1] = tostring(lastLua.bytes) .. " bytes"
    else
        lines[#lines + 1] = "LAST LUA-LIKE CAPTURE: none"
    end

    if largestLua then
        lines[#lines + 1] = "LARGEST LUA-LIKE CAPTURE: " .. largestLua.file
        lines[#lines + 1] = tostring(largestLua.bytes) .. " bytes"
    else
        lines[#lines + 1] = "LARGEST LUA-LIKE CAPTURE: none"
    end

    return table.concat(lines, "\n")
end

G.AUTO_UNLOCK_FLOW_STOP = function()
    STOPPED = true
    flush()
    local summary = makeSummary()
    writeLocal(SUMMARY_FILE, summary)
    print("\n========== AUTO-UNLOCK FLOW SUMMARY ==========\n" .. summary .. "\n================================================\n")
    return summary
end

local function runTarget()
    if type(originalLoadstring) ~= "function" then
        error("loadstring unavailable")
    end

    log("RUN", "downloading original target")
    local source = game:HttpGet(TARGET_URL)
    log("RUN", "initial target bytes=" .. tostring(#source))
    saveCapture("initial_target", source, TARGET_URL)

    local chunk, compileErr = originalLoadstring(source, "@AUTO_UNLOCK_FLOW_TARGET")
    if not chunk then
        error("target compile failed: " .. tostring(compileErr))
    end

    log("RUN", "executing original target")
    local ok, err = pcall(chunk)
    if not ok then
        log("TARGET-ERROR", safe(err))
    else
        log("RUN", "initial target returned; hooks remain active")
    end
end

local ok, err = pcall(runTarget)
if not ok then
    log("SCANNER-ERROR", safe(err))
end

task.spawn(function()
    local unlocked = tryAutoUnlock()
    log("AUTO-UNLOCK", "result=" .. tostring(unlocked))

    task.wait(4)
    local summary = makeSummary()
    writeLocal(SUMMARY_FILE, summary)
    flush()
    print("\n========== AUTO-UNLOCK FLOW SUMMARY ==========\n" .. summary .. "\n================================================\n")
    log("INFO", "To stop later: getgenv().AUTO_UNLOCK_FLOW_STOP()")
end)
