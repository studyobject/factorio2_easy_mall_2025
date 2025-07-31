-- base_control.lua
-- control.lua

local DEBUG = true
local function debugLog(message)
    if DEBUG then
        log("[DEBUG] " .. message)
    end
end

local function safe_call(fn)
    return function(...)
        local success, result_or_error = pcall(fn, ...)
        if not success then
            game.print("Ошибка выполнения функции: " .. result_or_error)
            debugLog("Error: " .. result_or_error)
            return nil
        end
        return result_or_error
    end
end

local function timed_call(fn, fn_name)
    return function(...)
        local start_time = game.tick
        local result = fn(...)
        local execution_time = game.tick - start_time
        debugLog("Функция [" .. fn_name .. "] выполнена за " .. execution_time .. " ticks.")
        return result
    end
end

-- Подключаем main.lua на верхнем уровне
local main = require("main")

-- Регистрируем команду для выполнения функции из main.lua
commands.add_command("run_basic_config", "Запустить настройку решающих комбинаторов", function()
    safe_call(timed_call(main, "main_logic"))()
end)
