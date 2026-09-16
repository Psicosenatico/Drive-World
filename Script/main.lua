-- PSICOSENATICO | Drive World Vehicle Menu V5.2.1
-- Loader fix: usa substituicao por funcao para preservar '%' no bloco inserido.
-- Pressao+ continua bloqueado em re/neutral e so auxilia quando frente esta confirmada.

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

    local reverseConfirmed = false
    local forwardConfirmed = false
    local neutralConfirmed = false

    -- 1) VehicleSeat: quando disponivel, a entrada negativa confirma re.
    if currentSeat and currentSeat:IsA("VehicleSeat") then
        local seatThrottle
        pcall(function() seatThrottle = currentSeat.ThrottleFloat end)
        if type(seatThrottle) == "number" then
            if seatThrottle < -0.04 then
                reverseConfirmed = true
            elseif seatThrottle > 0.04 then
                forwardConfirmed = true
            end
        end
    end

    -- 2) Indicador de marcha do proprio carro: usado para BLOQUEAR R/N.
    -- Marcha positiva nao libera impulso sozinha, porque pode estar atrasada.
    if type(controller) == "table" then
        local instrument = rawget(controller, "instrumentScreen")
        local label = type(instrument) == "table" and rawget(instrument, "currentGearLabel") or nil
        local text

        if typeof(label) == "Instance" then
            pcall(function()
                if label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox") then
                    text = label.Text
                end
            end)
        elseif type(label) == "string" then
            text = label
        end

        if type(text) == "string" then
            local normalized = string.lower(text):gsub("[%s%._%-]", "")
            if normalized == "r"
            or normalized == "re"
            or normalized == "ré"
            or normalized:find("reverse", 1, true) then
                reverseConfirmed = true
                forwardConfirmed = false
            elseif normalized == "n"
            or normalized:find("neutral", 1, true) then
                neutralConfirmed = true
            end
        end

        -- 3) Estado numerico interno: apenas -1/negativo e 0 sao usados para bloquear.
        local gear = tonumber(rawget(controller, "gear"))
        if gear then
            if gear < 0 then
                reverseConfirmed = true
                forwardConfirmed = false
            elseif gear == 0 then
                neutralConfirmed = true
            end
        end
    end

    -- 4) Direcao fisica do carro: confirmacao principal depois que ele comeca a andar.
    if forwardSpeed < -0.75 then
        reverseConfirmed = true
        forwardConfirmed = false
    elseif forwardSpeed > 0.75 and not reverseConfirmed then
        forwardConfirmed = true
    end

    -- Em re ou neutro, o impulso artificial do Pressao+ fica totalmente desligado.
    if reverseConfirmed or neutralConfirmed then return end

    -- Parado/ambiguo: espera a fisica original iniciar o movimento para frente.
    if not forwardConfirmed then return end
    if forwardSpeed < -0.25 then return end

    local baseTop = getBaseTopSpeed()
    local startTaper = baseTop * 0.68
    local factor = 1
    if forwardSpeed > startTaper then
        factor = math.clamp(
            (baseTop - forwardSpeed) / math.max(baseTop - startTaper, 1),
            0,
            1
        )
    end

    if factor > 0 then
        main.AssemblyLinearVelocity += cf.LookVector * (PRESSURE_ACCEL * factor * dt)
    end
end]]

-- IMPORTANTE: replacement por funcao evita que '%' do codigo novo seja
-- interpretado pelo string.gsub como referencia de captura.
local patched, replacements = source:gsub(oldBlock, function()
    return newBlock
end, 1)

if replacements ~= 1 then
    error("Drive World V5.2.1 hotfix: bloco Pressao+ nao encontrado")
end

patched = patched:gsub(
    "PSICOSENATICO • DRIVE WORLD V5",
    "PSICOSENATICO • DRIVE WORLD V5.2.1",
    1
)

local fn, err = loadstring(patched)
if not fn then
    error("Drive World V5.2.1 compile error: " .. tostring(err))
end

return fn()