-- PSICOSENATICO | Drive World Vehicle Menu V5.1
-- Hotfix: Pressao+ respeita a marcha de re em vez de empurrar sempre para frente.

local CORE_URL = "https://raw.githubusercontent.com/Psicosenatico/Drive-World/8a326ee9a89d7080667d5a4a40ddfc6506a1869b/Script/main.lua"
local source = game:HttpGet(CORE_URL)

local oldBlock = [[local function applyPressureAssist(dt, main, cf, forwardSpeed)
    if not flags.pressure then return end
    local throttle = getThrottleIntent()
    if throttle <= 0.04 or forwardSpeed < -1 then return end

    local baseTop = getBaseTopSpeed()
    local startTaper = baseTop * 0.68
    local factor = 1
    if forwardSpeed > startTaper then
        factor = math.clamp((baseTop - forwardSpeed) / math.max(baseTop - startTaper, 1), 0, 1)
    end
    if factor > 0 then
        main.AssemblyLinearVelocity += cf.LookVector * (PRESSURE_ACCEL * factor * dt)
    end
end]]

local newBlock = [[local function applyPressureAssist(dt, main, cf, forwardSpeed)
    if not flags.pressure then return end

    local throttle = getThrottleIntent()
    if math.abs(throttle) <= 0.04 then return end

    -- No Drive World o pedal pode continuar positivo mesmo em re.
    -- A marcha do controlador e a fonte mais confiavel para a direcao.
    local gear = type(controller) == "table" and tonumber(rawget(controller, "gear")) or nil
    local direction
    if gear and gear < 0 then
        direction = -1
    elseif gear and gear > 0 then
        direction = 1
    else
        direction = throttle < 0 and -1 or 1
    end

    -- Velocidade medida na direcao da marcha atual.
    local directionalSpeed = forwardSpeed * direction

    -- Se ainda estiver rolando forte na direcao oposta, deixa o carro frear/trocar
    -- de sentido naturalmente antes de aplicar o assistente.
    if directionalSpeed < -1 then return end

    local baseTop = getBaseTopSpeed()

    -- A re tem seu proprio limite no cachedGears (ex.: indice -1).
    if direction < 0 and type(controller) == "table" then
        local cached = rawget(controller, "cachedGears")
        local tops = type(cached) == "table" and rawget(cached, "topSpeeds") or nil
        local reverseTop = type(tops) == "table" and tonumber(rawget(tops, -1)) or nil
        if reverseTop and reverseTop ~= 0 then
            baseTop = math.abs(reverseTop)
        else
            baseTop = math.min(baseTop, 55)
        end
    end

    local startTaper = baseTop * 0.68
    local factor = 1
    if directionalSpeed > startTaper then
        factor = math.clamp(
            (baseTop - directionalSpeed) / math.max(baseTop - startTaper, 1),
            0,
            1
        )
    end

    if factor > 0 then
        main.AssemblyLinearVelocity += cf.LookVector * (direction * PRESSURE_ACCEL * factor * dt)
    end
end]]

local patched, replacements = source:gsub(oldBlock, newBlock, 1)
if replacements ~= 1 then
    error("Drive World V5.1 hotfix: bloco Pressao+ nao encontrado")
end

local fn, err = loadstring(patched)
if not fn then
    error("Drive World V5.1 compile error: " .. tostring(err))
end
return fn()