-- PSICOSENATICO | Drive World Vehicle Menu V5.2
-- Hotfix revisado: Pressao+ nunca injeta impulso para frente durante re/neutral.
-- Usa o indicador de marcha do proprio carro + gear + direcao fisica antes de aplicar assistencia.

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

    -- O scan do Vulture mostrou uma relacao de re dedicada em gears[-1]
    -- e cachedGears[-1]. Nao usamos apenas controller.gear porque o scan
    -- anterior nao mediu uma manobra de re e esse campo pode atualizar tarde.
    local reverseConfirmed = false
    local forwardConfirmed = false
    local neutralConfirmed = false

    -- 1) Entrada nativa do assento, quando o jogo usa VehicleSeat.
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

    -- 2) Indicador de marcha que o proprio controlador fornece ao painel.
    -- Ele so e usado para bloquear R/N; uma indicacao positiva NAO libera
    -- o impulso sozinha, evitando usar uma marcha antiga durante a transicao.
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

        -- 3) Estado numerico interno: somente R/N bloqueiam.
        -- gear positivo nao confirma frente porque pode estar atrasado.
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

    -- 4) A direcao fisica e a confirmacao principal quando o carro se move.
    if forwardSpeed < -0.75 then
        reverseConfirmed = true
        forwardConfirmed = false
    elseif forwardSpeed > 0.75 and not reverseConfirmed then
        forwardConfirmed = true
    end

    -- Pressao+ deixa re e neutro inteiramente para a fisica original do jogo.
    -- O aumento de TorqueCurve continua sendo tratado pelo controlador normal;
    -- apenas o impulso artificial para frente e bloqueado aqui.
    if reverseConfirmed or neutralConfirmed then return end

    -- Parado/ambíguo: nao aplica impulso. Em frente, o carro anda alguns
    -- centimetros pela fisica original e entao o assistente entra.
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

local patched, replacements = source:gsub(oldBlock, newBlock, 1)
if replacements ~= 1 then
    error("Drive World V5.2 hotfix: bloco Pressao+ nao encontrado")
end

-- Marcacao visual clara para confirmar que a revisao nova foi carregada.
patched = patched:gsub(
    "PSICOSENATICO • DRIVE WORLD V5",
    "PSICOSENATICO • DRIVE WORLD V5.2",
    1
)

local fn, err = loadstring(patched)
if not fn then
    error("Drive World V5.2 compile error: " .. tostring(err))
end
return fn()