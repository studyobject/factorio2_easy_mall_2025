--#region ▼
--#endregion ▲

-- script_basic_brain.lua

--#region ▼ Утилитарные функции

--#region ▼▼ ☆ Общие утилитарные функции

--- Определяет реальный тип прототипа по имени или возвращает первый допустимый.
--- @param name string --[[ Имя прототипа (сигнала, жидкости, предмета или рецепта). ]]
--- @param expected_type? string --[[ Если указано "recipe", сначала проверять только рецепты. ]]
--- @return "recipe"|"virtual"|"fluid"|"item"|nil --[[ Тип прототипа или nil, если не найден ]]
local function get_type(name, expected_type)
  if expected_type == "recipe" then
    if prototypes.recipe[name] then
      return "recipe"
    end
  end

  if prototypes.virtual_signal[name] then
    return "virtual"
  end

  if prototypes.fluid[name] then
    return "fluid"
  end

  if prototypes.item[name] then
    return "item"
  end

  game.print("Внимание, обнаружен неизвестный тип для объекта: " .. tostring(name))
  return nil
end

--- Устанавливает дефолтные параметры сигнала для decider combinator
--- @param params table --[[ Входная таблица с полями: name (обязательно), type (ожидаемый тип), quality (качество сигнала) ]]
--- @param fluid_quality boolean? --[[ Если false, то для fluid-сигналов выставляется минимальное качество ]]
--- @return table --[[ Исходная таблица params, дополненная полями type и quality ]]
local function sdp_signal_dc(params, fluid_quality)
  if not params.name then
    error("sdp_signal: параметр 'name' должен быть задан")
  end

  fluid_quality = fluid_quality == nil and true or fluid_quality

  params.type = get_type(params.name, params.type)

  if params.type == "fluid" and not fluid_quality then
    params.quality = qualities[1]
  else
    params.quality = params.quality or qualities[1]
  end

  return params
end

--- Ищет в области area сущности по имени метки.
--- @param label string --[[ Метка: ищется в combinator_description и group секций ]]
--- @param search_params table --[[ Параметры для surface.find_entities_filtered (можно без area) ]]
--- @return LuaEntity[] --[[ Список найденных сущностей (может быть пустым) ]]
local function findSpecialEntity(label, search_params)
  local surface = game.player.surface
  -- Используем глобальную переменную area, если она есть
  if area and not search_params.area then
    search_params.area = area
  end

  local entities = surface.find_entities_filtered(search_params)
  label = string.lower(label)

  local found_entities = {}

  for _, entity in ipairs(entities) do
    -- 📌 1. combinator_description (если есть)
    local success, desc = pcall(function()
      return entity.combinator_description
    end)
    if success and desc and string.lower(desc):find(label, 1, true) then
      table.insert(found_entities, entity)
    end

    -- 📌 2. get_logistic_sections с деактивированной секцией и подходящей group
    if entity.get_logistic_sections then
      local sections = entity.get_logistic_sections()
      if sections and sections.sections then
        for _, section in pairs(sections.sections) do
          if not section.active and section.group and type(section.group) == "string" then
            if string.lower(section.group) == label then
              table.insert(found_entities, entity)
            end
          end
        end
      end
    end
  end

  return found_entities
end

-- Функция, которая по таблице рецептов возвращает три группы объектов (items/fluids) и для каждого объекта
-- вычисляет «максимальное поглощение» (максимальное количество, требуемое в одном цикле крафта):
--   1) exclusively_ingredients: объекты, которые встречаются только в качестве ингредиента (ни разу не являются продуктом);
--   2) ingredients_and_products: объекты, которые одновременно встречаются как ингредиент и как продукт;
--   3) exclusively_products: объекты, которые встречаются только в качестве продукта (ни разу не используются как ингредиент).
-- Для объектов из группы «exclusively_products» значение «максимального поглощения» будет 0, так как они не потребляются.
--
-- @param recipes table Таблица всех рецептов в формате:
--                     {
--                       ["iron-plate"]    = <прототип рецепта iron-plate LuaPrototype>,
--                       ["copper-cable"]  = <прототип рецепта copper-cable LuaPrototype>,
--                       …
--                     }
--                     Где каждый <прототип рецепта> — это LuaPrototype с полем .ingredients
--                     (список таблиц { name=string, type="item"/"fluid", amount=number }) и
--                     полем .products / .results / .result.
-- @return table Таблица с полями:
--               exclusively_ingredients   = { [имя_объекта] = <макс. потребление>, … },
--               ingredients_and_products  = { [имя_объекта] = <макс. потребление>, … },
--               exclusively_products      = { [имя_объекта] = 0, … }
local function get_classify_ingredients(recipes)
  -- Результирующие подтаблицы
  local ingredient_groups  = {
    exclusively_ingredients  = {}, -- объекты, которые встречаются только в ingredients
    ingredients_and_products = {}, -- объекты, которые и там, и там
    exclusively_products     = {}, -- объекты, которые встречаются только в products
  }

  -- Шаг 0: вспомогательные структуры
  -- max_consumption[name] = максимальное количество этого объекта, требуемое в одном ремесле (из поля .ingredients)
  local max_consumption    = {}

  -- seen_as_ingredient[name] = true, если объект хотя бы раз встречался в ingredients
  local seen_as_ingredient = {}
  -- seen_as_product[name] = true, если объект хотя бы раз встречался в products
  local seen_as_product    = {}

  -- Вспомогательная функция: получить прототип item/fluid, если нужно.
  -- Здесь нам важны только имена, но проверка прототипа может пригодиться для валидации.
  local function get_object_prototype(name, maybe_type)
    if maybe_type == "fluid" then
      return prototypes.fluid[name]
    end
    if prototypes.item[name] then
      return prototypes.item[name]
    elseif prototypes.fluid[name] then
      return prototypes.fluid[name]
    else
      return nil
    end
  end

  -- Шаг 1: Собираем информацию о потреблении и продукции из каждого рецепта
  for _, recipe_proto in pairs(recipes) do
    -- 1.1 Обрабатываем ingredients
    if recipe_proto.ingredients then
      for _, ing in ipairs(recipe_proto.ingredients) do
        local obj_name = ing.name
        local obj_type = ing.type -- может быть "item" или "fluid"
        local amount = ing.amount or 0
        -- Обновляем максимальное потребление
        if not max_consumption[obj_name] or amount > max_consumption[obj_name] then
          max_consumption[obj_name] = amount
        end
        -- Отмечаем, что объект встречался как ингредиент
        seen_as_ingredient[obj_name] = true
      end
    end

    -- 1.2 Обрабатываем products / results / result
    if recipe_proto.products then
      for _, prod in ipairs(recipe_proto.products) do
        local obj_name = prod.name
        seen_as_product[obj_name] = true
        -- Обратите внимание: продукты не влияют на max_consumption,
        -- т.к. это метрика только для потребления.
        -- Но если вдруг в других рецептах этот объект будет ингредиентом,
        -- его max_consumption уже учтён выше.
      end
    elseif recipe_proto.results then
      for _, prod in ipairs(recipe_proto.results) do
        local obj_name = prod.name
        seen_as_product[obj_name] = true
      end
    elseif recipe_proto.result then
      local obj_name = recipe_proto.result
      seen_as_product[obj_name] = true
    end
  end

  -- Шаг 2: Определяем группы и заполняем итоговые таблицы
  -- 2.1 Те объекты, которые встречались в ingredients
  for name, _ in pairs(seen_as_ingredient) do
    if seen_as_product[name] then
      -- Если встречался и там, и там
      ingredient_groups.ingredients_and_products[name] = max_consumption[name] or 0
      -- Убираем из seen_as_product, чтобы потом не учитывать в exclusively_products
      seen_as_product[name] = nil
    else
      -- Только как ингредиент
      ingredient_groups.exclusively_ingredients[name] = max_consumption[name] or 0
    end
  end

  -- 2.2 Оставшиеся в seen_as_product — те, которые никогда не встречались в ingredients
  for name, _ in pairs(seen_as_product) do
    -- Для них максимальное потребление = 0
    ingredient_groups.exclusively_products[name] = 0
  end

  return ingredient_groups
end

--- Возвращает размер стака для item/fluid, с учётом фолбэка.
--- @param name string Имя ресурса
--- @param fluid_default number? Размер по умолчанию для жидкости
--- @param zero_fallback number? Значение, если stack_size == 0
--- @return number stack_size Размер стака или zero_fallback
local function get_stack_size(name, fluid_default, zero_fallback)
  local stack_size = 0

  if prototypes.item[name] then
    stack_size = prototypes.item[name].stack_size
  elseif prototypes.fluid[name] then
    stack_size = fluid_default or 1000
  else
    game.print("Сигнал не обладает значением стака: " .. tostring(name))
  end

  if stack_size == 0 and zero_fallback then
    return zero_fallback
  end

  return stack_size
end

--- Вычисляет минимальный размер стака для запуска ракеты данным предметом (https://lua-api.factorio.com/latest/auxiliary/item-weight.html).
---@param item_name string Имя предмета.
---@return integer Минимальное количество предметов, либо 0 если имя принадлежит не предмету.
local function get_min_rocket_stack_size(item_name)
  if not prototypes.item or not prototypes.item[item_name] then
    game.print("[get_min_rocket_stack_size] '" .. item_name .. "' не является допустимым предметом.")
    return 0
  end

  local item_prototype = prototypes.item[item_name]
  local weight = item_prototype.weight
  local ROCKET_LIFT_WEIGHT = 1000000

  if not weight or weight <= 0 then
    game.print("[get_min_rocket_stack_size] У предмета '" .. item_name .. "' отсутствует корректный вес.")
    return 0
  end

  if weight > ROCKET_LIFT_WEIGHT then
    game.print("[get_min_rocket_stack_size] '" .. item_name .. "' слишком тяжёлый для ракеты (вес: " .. weight .. ").")
    return 0
  end

  return math.floor(ROCKET_LIFT_WEIGHT / weight + 0.5)
end

-- Функция для получения списка имён рецептов {"iron-chest", ...} и таблицы со точным значением рейтинга {"iron-chest" = 3, ...}
--- Вычисляет «рейтинг» рецептов и возвращает
-- 1) список имён, отсортированный по убыванию рейтинга (или, если flip, — в обратном порядке),
-- 2) таблицу рейтингов { [recipe_name] = rating, … }
-- @param recipes table — словарь { name → prototype }
-- @param flip?   boolean — если true, разворачивает список и зеркалирует значения рейтингов
local function get_recipe_rating(recipes, flip)
  -- 1) строим карту main_product → { recipe_name, … }
  local produces = {}
  for rname, recipe in pairs(recipes) do
    local prod = recipe.main_product.name
    produces[prod] = produces[prod] or {}
    table.insert(produces[prod], rname)
  end

  -- 2) DFS для сбора всех уникальных поставщиков
  local function dfs(rname, seen)
    if seen[rname] then return end
    seen[rname] = true
    local rec = recipes[rname]
    if not rec or not rec.ingredients then return end
    for _, ing in ipairs(rec.ingredients) do
      for _, provider in ipairs(produces[ing.name] or {}) do
        dfs(provider, seen)
      end
    end
  end

  -- 3) считаем рейтинги
  local names, ratings = {}, {}
  for rname in pairs(recipes) do
    local seen = {}
    dfs(rname, seen)
    -- рейтинг = число уникальных рецептов в seen
    local cnt = 0
    for _ in pairs(seen) do cnt = cnt + 1 end
    ratings[rname] = cnt
    table.insert(names, rname)
  end

  -- 4) сортируем по убыванию рейтинга
  table.sort(names, function(a, b)
    return ratings[a] > ratings[b]
  end)

  -- 5) если нужно «перевернуть»:
  if flip then
    -- а) найдём min и max по исходным ratings
    local minV, maxV
    for _, score in pairs(ratings) do
      if not minV or score < minV then minV = score end
      if not maxV or score > maxV then maxV = score end
    end
    -- б) зеркалируем каждый рейтинг
    for rname, score in pairs(ratings) do
      ratings[rname] = (minV + maxV) - score
    end
    -- в) разворачиваем список имён
    for i = 1, math.floor(#names / 2) do
      local j = #names - i + 1
      names[i], names[j] = names[j], names[i]
    end
  end

  return names, ratings
end

-- Функция получения связанных рецептов жидкостей типа наполнить/опустошить бочку
local function get_barrel_recipes_for_fluid(fluid_name)
  local result = {
    fluid_name = fluid_name,        -- Имя жидкости
    filled_barrel_name = nil,       -- Имя наполненной бочки
    fill_barrel_recipe = nil,       -- Рецепт наполнения бочки
    empty_barrel_recipe = nil,      -- Рецепт опустошения бочки
    assembler_activated_fluid = nil -- Жидкость, активирующая рецепт в ассемблере
  }

  -- Поиск рецепта опустошения бочки (subgroup "empty-barrel") для нахождения имени бочки
  for name, recipe in pairs(prototypes.recipe) do
    if recipe.subgroup and recipe.subgroup.name == "empty-barrel" and recipe.ingredients then
      for _, ingredient in pairs(recipe.ingredients) do
        -- Если продуктом рецепта является искомая жидкость, то ингредиент - это бочка
        if recipe.products then
          for _, product in pairs(recipe.products) do
            if product.name == fluid_name then
              result.empty_barrel_recipe = name
              result.filled_barrel_name = ingredient.name -- Имя наполненной бочки
              break
            end
          end
        end
      end
    end
  end

  -- Поиск рецепта наполнения бочки (subgroup "fill-barrel")
  for name, recipe in pairs(prototypes.recipe) do
    if recipe.subgroup and recipe.subgroup.name == "fill-barrel" and recipe.ingredients then
      for _, ingredient in pairs(recipe.ingredients) do
        if ingredient.name == fluid_name then
          result.fill_barrel_recipe = name
          break
        end
      end
    end
  end

  -- Проверка, активирует ли сигнал жидкости рецепт в ассемблере
  for name, recipe in pairs(prototypes.recipe) do
    if recipe.category and recipe.category == "crafting-with-fluid" and recipe.ingredients then
      for _, ingredient in pairs(recipe.ingredients) do
        if ingredient.name == fluid_name then
          result.assembler_activated_fluid = fluid_name -- Записываем имя жидкости
          break
        end
      end
    end
  end

  return result
end

--- Возвращает все комбинации ингредиентов, включая замену жидкостей на бочки.
--- @param recipe LuaRecipePrototype --[[ Оригинальный рецепт ]]
--- @return table[] --[[ Список таблиц ингредиентов (каждая — одна возможная комбинация) ]]
local function get_alternative_ingredient_variants(recipe)
  if not recipe or not recipe.ingredients then
    return {}
  end

  --- Локальный deepcopy (без сторонних библиотек)
  local function deepcopy(tbl)
    local res = {}
    for k, v in pairs(tbl) do
      if type(v) == "table" then
        res[k] = deepcopy(v)
      else
        res[k] = v
      end
    end
    return res
  end

  --- Все альтернативы для одного ингредиента
  local function expand_ingredient(ing)
    local list = { ing }
    if ing.type == "fluid" then
      local barrel = get_barrel_recipes_for_fluid(ing.name)
      if barrel and barrel.filled_barrel_name then
        table.insert(list, {
          name = barrel.filled_barrel_name,
          type = "item",
          amount = math.ceil((ing.amount or 1) / 50)
        })
      end
    end
    return list
  end

  --- Перебор всех комбинаций (декартово произведение)
  local function combine(options_by_slot)
    local result = { {} }
    for i = 1, #options_by_slot do
      local new_result = {}
      for _, partial in ipairs(result) do
        for _, variant in ipairs(options_by_slot[i]) do
          local next_combo = deepcopy(partial)
          table.insert(next_combo, variant)
          table.insert(new_result, next_combo)
        end
      end
      result = new_result
    end
    return result
  end

  --- Основная логика
  local options_by_slot = {}
  for _, ing in ipairs(recipe.ingredients) do
    table.insert(options_by_slot, expand_ingredient(ing))
  end

  return combine(options_by_slot)
end

--- Возвращает суммарное количество всех ингредиентов для данного рецепта.
--- @param recipe table --[[ Рецепт с полем .ingredients = { {name=string, type=string, amount=number}, … } или методом :get_ingredients(). Поддерживается и форма {name, amount}. ]]
--- @return number --[[ Общая сумма amount по всем ингредиентам ]]
local function get_total_ingredients_count(recipe)
  if not recipe then
    return 0
  end

  -- получаем список ингредиентов
  local ingredients = recipe.ingredients
  if not ingredients and type(recipe.get_ingredients) == "function" then
    ingredients = recipe:get_ingredients()
  end
  if not ingredients then
    return 0
  end

  -- суммируем
  local total = 0
  for _, ing in ipairs(ingredients) do
    -- поддерживаем поля .amount или короткую форму {name, amount}
    local amount = ing.amount or ing[2] or 0
    total = total + amount
  end

  return total
end

-- Пример использования:
-- local count = get_total_ingredients_count(prototypes.recipe["iron-gear-wheel"])
-- game.print("Всего ингредиентов: " .. count)


--- Возвращает максимальное значение amount для каждого ингредиента из набора рецептов.
--- @param recipes table — словарь рецептов { [name] = LuaRecipePrototype, … }
--- @return table<string, number> — таблица вида { [ingredient_name] = max_amount, … }
local function get_max_ingredient_amounts(recipes)
  local result = {}

  for _, recipe_proto in pairs(recipes) do
    local ingredients = recipe_proto.ingredients
    if ingredients then
      for _, ing in ipairs(ingredients) do
        local name = ing.name
        local amount = ing.amount or 0
        if not result[name] or amount > result[name] then
          result[name] = amount
        end
      end
    end
  end

  return result
end


--- Уникализация значений сигналов (только положительный сдвиг)
--- Принимает массив сигналов вида { { name=string, value=number }, … }
--- @param signals table[] список сигналов с исходными значениями, где каждый элемент имеет поля name и value
--- @return table[] unique_signals список сигналов с уникальными значениями поля value
--- @return table<string, number> shifts карта сдвигов: shifts[name] = сколько добавлено к оригинальному value
local function uniquify_signal_values(signals)
  local used   = {} -- set для уже занятых значений
  local unique = {} -- результирующий массив уникальных сигналов
  local shifts = {} -- результаты смещений

  for _, sig in ipairs(signals) do
    local name  = sig.name
    local orig  = sig.value
    local val   = orig
    local shift = 0

    -- если orig уже занят, ищем следующий свободный orig + i
    if used[val] then
      local i = 1
      while used[orig + i] do
        i = i + 1
      end
      val   = orig + i
      shift = i
    end

    -- отмечаем val как занятое и сохраняем результат
    used[val] = true
    table.insert(unique, { name = name, value = val })
    shifts[name] = shift
  end

  return unique, shifts
end

--- Вычисляет количество занятых слотов для всех item-ингредиентов рецепта.
--- @param recipe LuaRecipePrototype — рецепт
--- @param multiplier number? — множитель количества (по умолчанию 1)
--- @param add number? — слагаемое, прибавляемое к каждому количеству перед расчётом (по умолчанию 0)
--- @return integer — количество занятых слотов (fluid ингредиенты игнорируются)
function calculate_ingredient_slot_usage(recipe, multiplier, add)
  multiplier = multiplier or 1
  add = add or 0

  if not recipe or not recipe.ingredients then
    return 0
  end

  local slot_count = 0
  for _, ing in ipairs(recipe.ingredients) do
    if ing.type == "item" then
      local amount = (ing.amount or 0) * multiplier + add
      local stack_size = get_stack_size(ing.name)
      slot_count = slot_count + math.ceil(amount / stack_size)
    end
  end

  return slot_count
end

--#endregion ▲▲ Общие утилитарные функции

--#region ▼▼ Изичные функции

--- Преобразует ключи таблицы в массив строк.
---@param tbl table Любая таблица.
---@return string[] keys Массив ключей tbl.
local function get_keys(tbl)
  local keys = {}
  for key, _ in pairs(tbl) do
    table.insert(keys, key)
  end
  return keys
end
--#endregion ▲▲ Изичные функции

--#region ▼▼ ☆☆☆ Работа с множествами Lua

local Set = {}

function Set.U(a, b, ...) -- объединение (union ∪)
  local res = {}
  for k, v in pairs(a) do res[k] = v end
  for k, v in pairs(b or {}) do res[k] = v end
  if ... then return Set.U(res, ...) end
  return res
end

function Set.I(a, b, ...) -- пересечение (intersection ∩)
  local res = {}
  for k, v in pairs(a) do if b[k] then res[k] = v end end
  if ... then return Set.I(res, ...) end
  return res
end

function Set.D(a, b, ...) -- разность (difference -)
  local res = {}
  for k, v in pairs(a) do if not b[k] then res[k] = v end end
  if ... then return Set.D(res, ...) end
  return res
end

function Set.S(a, b, ...) -- симметричная разность (symmetric difference Δ)
  local res = {}
  for k, v in pairs(a) do if not b[k] then res[k] = v end end
  for k, v in pairs(b) do if not a[k] then res[k] = v end end
  if ... then return Set.S(res, ...) end
  return res
end

--#endregion ▲▲ Работа с множествами Lua

--#region ▼▼ Короткие функции-последовательности (для update_cc_storage)

local Upd = {}

--- Генератор «инкрементера»: прибавляет к old: start, затем start+step, start+2*step, ...
-- @param start number — первое приращение (по умолчанию 1)
-- @param step  number — размер шага (по умолчанию 1)
-- @return function(old)->new
function Upd.inc(start, step)
  start          = start or 1
  step           = step or 1
  local next_add = start
  return function(old)
    local add = next_add
    next_add = next_add + step
    return old + add
  end
end

--- Всегда прибавляет n  (аналог add)
-- @param n number
-- @return function(old)->new
function Upd.add(n)
  n = n or 0
  return function(old)
    return old + n
  end
end

--- Всегда умножает на n (аналог multiply)
-- @param n number
-- @return function(old)->new
function Upd.mul(n)
  n = n or 1
  return function(old)
    return old * n
  end
end

--- Генератор-счётчик: возвращает 1, 2, 3, ... при каждом вызове
-- @param start number — с какого значения начать (по умолчанию 1)
-- @param step  number — шаг увеличения (по умолчанию 1)
-- @return function(_)->number
function Upd.count(start, step)
  start         = start or 1
  step          = step or 1
  local current = start - step
  return function(_)
    current = current + step
    return current
  end
end

--#endregion ▲▲ Короткие функции-последовательности (для update_cc_storage)

--#region ▼ Функции направленные на формирование сигналов (формы сигнлов/условий)

-- Возвращает комбинации условий ингредиентов рецептов с учётом жидкостей и бочек
-- @param ingredient_list table список { { name, type, amount }, … }
-- @param offset number?     сколько вычесть из каждого порога (по умолчанию 0)
-- @param multiplier number? на какой множитель умножить ing.amount (по умолчанию 1)
local function build_ingredient_combinations(ingredient_list, offset, multiplier)
  offset                  = offset or 0
  multiplier              = multiplier or 1

  local groups            = {}
  local has_barrel_option = false

  for _, ing in ipairs(ingredient_list) do
    local amount = ing.amount * multiplier
    local opts = {}

    -- 1) Обычный вариант
    local base_signal = {
      name    = ing.name,
      quality = qualities[1],
      type    = ing.type,
    }

    local base_networks
    if ing.type == "fluid" then
      base_networks = { red = true, green = false }
    else
      base_networks = { red = false, green = true }
    end

    table.insert(opts, {
      first_signal          = base_signal,
      comparator            = "≥",
      constant              = offset + amount,
      first_signal_networks = base_networks,
    })

    -- 2) Вариант с бочкой
    if ing.type == "fluid" then
      local bar = get_barrel_recipes_for_fluid(ing.name)
      if bar.filled_barrel_name then
        has_barrel_option = true
        table.insert(opts, {
          first_signal          = { name = bar.filled_barrel_name, quality = qualities[1], type = ing.type },
          comparator            = "≥",
          constant              = offset + math.ceil(amount / 50),
          first_signal_networks = { red = false, green = true },
        })
      end
    end

    table.insert(groups, opts)
  end

  if not has_barrel_option then
    local and_group = { "and" }
    for _, opts in ipairs(groups) do
      table.insert(and_group, opts[1])
    end
    return { "or", and_group }
  end

  local combos = { {} }
  for _, opts in ipairs(groups) do
    local new_combos = {}
    for _, seq in ipairs(combos) do
      for _, entry in ipairs(opts) do
        local copy = { table.unpack(seq) }
        table.insert(copy, entry)
        table.insert(new_combos, copy)
      end
    end
    combos = new_combos
  end

  local result = { "or" }
  for _, seq in ipairs(combos) do
    local and_group = { "and" }
    for _, entry in ipairs(seq) do
      table.insert(and_group, entry)
    end
    table.insert(result, and_group)
  end

  return result
end


--- Извлекает из прототипа рецепта списки жидкостей-ингредиентов и жидкостей-продуктов
-- @param recipe LuaPrototype — прототип рецепта
-- @return table с полями:
--   ingredients = { "water", … } — уникальные имена всех жидкостей из recipe.ingredients
--   products    = { "crude-oil", … } — уникальные имена всех жидкостей из recipe.products/results/result
local function extract_fluid_data(recipe)
  local data = {
    ingredients = {},
    products    = {}
  }

  -- 1) Жидкости в ингредиентах
  if recipe.ingredients then
    for _, ing in ipairs(recipe.ingredients) do
      if ing.type == "fluid" then
        table.insert(data.ingredients, ing.name)
      end
    end
  end

  -- 2) Жидкости в продуктах
  if recipe.products then
    for _, prod in ipairs(recipe.products) do
      if prod.type == "fluid" then
        table.insert(data.products, prod.name)
      end
    end
  elseif recipe.results then
    for _, prod in ipairs(recipe.results) do
      if prod.type == "fluid" then
        table.insert(data.products, prod.name)
      end
    end
  elseif recipe.result and recipe.result_type == "fluid" then
    table.insert(data.products, recipe.result)
  end

  -- Удаляем дубликаты
  local function unique(list)
    local seen, out = {}, {}
    for _, v in ipairs(list) do
      if not seen[v] then
        seen[v] = true
        table.insert(out, v)
      end
    end
    return out
  end

  data.ingredients = unique(data.ingredients)
  data.products    = unique(data.products)

  return data
end

--#endregion ▲ Функции направленные на формирование сигналов (формы сигнлов/условий)

--#endregion ▲ Утилитарные функции

--#region ▼ Функции инициализации

-- Формирование базовых таблиц-множеств рецептов
local function global_recipe_filtered()
  -- ☆ Проверяет ингредиенты рецепта на наличие parameter
  local function has_parameter_item_ingredient(recipe)
    if not recipe.ingredients then return false end
    for _, ing in pairs(recipe.ingredients) do
      if ing.type == "item" then
        local proto = prototypes.item[ing.name]
        if proto and proto.parameter then
          return true
        end
      end
    end
    return false
  end

  -- ☆ Все рецепты разделенные по эффектам
  local function get_recipes_by_effects()
    local effect_names = { "productivity", "quality", "speed" }
    for _, effect in ipairs(effect_names) do
      if not prototypes.module_category[effect] then
        error("Отсутствует категория модуля: " .. effect)
      end
    end
    local result = {}
    for _, effect in ipairs(effect_names) do
      result[effect] = {}
    end
    for name, recipe in pairs(prototypes.recipe) do
      local effects = recipe.allowed_effects
      if effects then
        for _, effect in ipairs(effect_names) do
          if effects[effect] then
            result[effect][name] = recipe
          end
        end
      end
    end
    return result
  end

  -- ☆ Удаляет невалидные рецепты из таблицы
  local function filter_invalid_recipes(recipe_table, invalid_recipes)
    for key, value in pairs(recipe_table) do
      if type(value) == "table" then
        -- Рекурсивно применим к вложенным таблицам
        recipe_table[key] = filter_invalid_recipes(value, invalid_recipes)
      end
    end
    return Set.D(recipe_table, invalid_recipes)
  end

  -- Проверяет допустимость рецепта на выбранной поверхности
  local function is_allowed_on_surface(recipe, surface)
    if not recipe.surface_conditions then return true end
    for _, cond in ipairs(recipe.surface_conditions) do
      local prop = cond.property
      local minv = cond.min or -math.huge
      local maxv = cond.max or math.huge

      local success, value = pcall(function() return surface.get_property(prop) end)
      if not success or value == nil then
        return false
      end

      if value < minv or value > maxv then
        return false
      end
    end
    return true
  end

  -- Возвращает таблицу зацикленных рецептов. Все рецепты каждой "петли" связанных рецептов
  local function get_cyclic_recipes(recipes_table)
    ------------------------------------------------------------------
    -- 0. Источник рецептов
    ------------------------------------------------------------------
    local source = recipes_table or prototypes.recipe

    ------------------------------------------------------------------
    -- 1. Соберём единую «плоскую» коллекцию recipe-prototype-ов
    ------------------------------------------------------------------
    local recipe_list = {}   -- { <proto>, … } – для итераций массивом
    local name_to_proto = {} -- name → prototype

    for k, v in pairs(source) do
      local proto =
          (type(k) == "table" and k.name and k)             -- Set-множество
          or (type(v) == "table" and v.name and v)          -- обычный массив
          or (type(k) == "string" and prototypes.recipe[k]) -- set с именами
      if proto and not name_to_proto[proto.name] then
        name_to_proto[proto.name] = proto
        recipe_list[#recipe_list + 1] = proto
      end
    end

    ------------------------------------------------------------------
    -- 2. Карты produces / consumes
    --    produces[item]   → {recipe-name,…}
    --    consumes[recipe] → {item-name,…}
    ------------------------------------------------------------------
    local produces, consumes = {}, {}

    local function add_item(tbl, key, val)
      local t = tbl[key]
      if not t then
        t = {}; tbl[key] = t
      end
      t[#t + 1] = val
    end

    for _, recipe in ipairs(recipe_list) do
      local rname = recipe.name
      consumes[rname] = {}

      -- ✦ ингредиенты
      local ingredients = recipe.ingredients or (recipe.get_ingredients and recipe:get_ingredients()) or {}
      for _, ing in pairs(ingredients) do
        local iname = ing.name or ing[1] -- поддержка краткой формы
        if iname then add_item(consumes, rname, iname) end
      end

      -- ✦ продукты
      local products = recipe.products or recipe.results
          or (recipe.get_products and recipe:get_products()) or {}
      for _, prod in pairs(products) do
        local pname = prod.name or prod[1]
        if pname then add_item(produces, pname, rname) end
      end
    end

    ------------------------------------------------------------------
    -- 3. Граф зависимостей: adj[recipe] → {recipe,…}
    ------------------------------------------------------------------
    local adj = {}
    for rname, items in pairs(consumes) do
      local edges = {}
      adj[rname] = edges
      for _, item in ipairs(items) do
        local makers = produces[item]
        if makers then
          for _, maker in ipairs(makers) do
            edges[#edges + 1] = maker
          end
        end
      end
    end

    ------------------------------------------------------------------
    -- 4. Tarjan (SCC) – поиск циклов
    ------------------------------------------------------------------
    local index, stack               = 0, {}
    local indices, lowlink, on_stack = {}, {}, {}
    local cyclic                     = {} -- имя → prototype

    local function strongconnect(v)
      index = index + 1
      indices[v], lowlink[v] = index, index
      stack[#stack + 1] = v
      on_stack[v] = true

      local nbrs = adj[v]
      if nbrs then
        for _, w in ipairs(nbrs) do
          if not indices[w] then
            strongconnect(w)
            if lowlink[w] < lowlink[v] then lowlink[v] = lowlink[w] end
          elseif on_stack[w] and indices[w] < lowlink[v] then
            lowlink[v] = indices[w]
          end
        end
      end

      if lowlink[v] == indices[v] then -- корень SCC
        local comp = {}
        local w
        repeat
          w = stack[#stack]
          stack[#stack] = nil
          on_stack[w] = nil
          comp[#comp + 1] = w
        until w == v

        if #comp > 1 then -- цикл длиной >1
          for _, r in ipairs(comp) do
            cyclic[r] = name_to_proto[r]
          end
        else -- возможная самопетля
          local r = comp[1]
          local e = adj[r]
          if e then
            for _, dst in ipairs(e) do
              if dst == r then -- рецепт ест сам себя
                cyclic[r] = name_to_proto[r]
                break
              end
            end
          end
        end
      end
    end

    for v in pairs(adj) do
      if not indices[v] then strongconnect(v) end
    end

    return cyclic -- { name = proto, … }
  end

  local global_recipe_table = {}

  -- ☆ Все рецепты которые скрыты или являются параметром
  global_recipe_table.invalid_recipes = {}
  global_recipe_table.parameter_recipes = {}
  for name, recipe in pairs(prototypes.recipe) do
    local is_param = recipe.parameter or has_parameter_item_ingredient(recipe)
    if is_param then
      global_recipe_table.parameter_recipes[name] = recipe
    end
    if recipe.hidden or is_param then
      global_recipe_table.invalid_recipes[name] = recipe
    end
  end

  -- ☆☆ Все рецепты у которых ВСЕ ингредиенты имеют тип жидкости
  global_recipe_table.fluid_only_ingredient_recipes = prototypes.get_recipe_filtered {
    {
      filter = "has-ingredient-item",
      invert = true
    },
    {
      filter = "has-ingredient-fluid",
      mode = "and"
    }
  }

  -- ☆☆ Все рецепты у которых ВСЕ продукты имеют тип жидкости
  global_recipe_table.fluid_only_product_recipes = prototypes.get_recipe_filtered {
    {
      filter = "has-product-item",
      invert = true
    },
    {
      filter = "has-product-fluid",
      mode = "and"
    }
  }

  -- ☆ Все рецепты разделенные по эффектам productivity, quality, speed
  global_recipe_table.recipes_by_effect = get_recipes_by_effects()

  -- ☆ Все рецепты разрешенные на всех планетах
  global_recipe_table.all_surface_recipes = {}
  for name, recipe in pairs(prototypes.recipe) do
    if not recipe.surface_conditions then
      global_recipe_table.all_surface_recipes[name] = recipe
    end
  end

  -- -- ☆ Рецепты, разрешённые для каждой из открытой поверхности **** !?
  -- global_recipe_table.surface_recipes = {}
  -- for _, surface in pairs(game.surfaces) do
  --   local name = surface.name
  --   global_recipe_table.surface_recipes[name] = {}

  --   for recipe_name, recipe in pairs(prototypes.recipe) do
  --     if is_allowed_on_surface(recipe, surface) then
  --       global_recipe_table.surface_recipes[name][recipe_name] = recipe
  --     end
  --   end
  -- end

  -- Все рецепты с main_product
  global_recipe_table.recipes_with_main = {}
  for name, recipe in pairs(prototypes.recipe) do
    if recipe.main_product then
      global_recipe_table.recipes_with_main[name] = recipe
    end
  end

  -- ☆ Все машины и все рецепты для каждый из них
  global_recipe_table.machines = {}
  for name, entity in pairs(prototypes.entity) do
    if entity.crafting_categories then
      local recipes = {}
      for recipe_name, recipe in pairs(prototypes.recipe) do
        if entity.crafting_categories[recipe.category] then
          recipes[recipe_name] = recipe
        end
      end
      global_recipe_table.machines[name] = recipes
    end
  end

  -- ☆ Все машины в которые можно установить рецепт сигналом
  local machines_ass = {}
  for name, entity in pairs(prototypes.entity) do
    if entity.type == "assembling-machine" and not entity.fixed_recipe then
      machines_ass[name] = entity
    end
  end
  global_recipe_table.machines_ass = Set.I(global_recipe_table.machines, machines_ass)

  -- Все циклические рецепты. Если рецепт производит main_product который сам же потребляет или Если есть от двух рецептов, которые производят "по кругу"
  local recipes = Set.D(global_recipe_table.recipes_with_main, global_recipe_table.invalid_recipes)
  global_recipe_table.cyclic_recipes = get_cyclic_recipes(recipes)

  -- ☆ Все рецепты являющиеся опустошение бочки
  global_recipe_table.empty_barrel = prototypes.get_recipe_filtered {
    { filter = "subgroup", subgroup = "empty-barrel" }
  }

  -- ☆ Все рецепты являющиеся наполнения бочки
  global_recipe_table.fill_barrel = prototypes.get_recipe_filtered {
    { filter = "subgroup", subgroup = "fill-barrel" }
  }

  -- Глобальная таблица машин с рецептами типа assembling_machines
  global_recipe_table.assembling_machines = {}
  -- Общий список всех рецептов от всех машин (вперемешку)
  global_recipe_table.all_assembling_recipes = {}
  for name, entity in pairs(prototypes.entity) do
    if entity.type == "assembling-machine" and entity.crafting_categories and not entity.fixed_recipe then
      local machine_recipes = {}
      for recipe_name, recipe in pairs(prototypes.recipe) do
        if recipe.category and entity.crafting_categories[recipe.category] then
          machine_recipes[recipe_name] = recipe
          global_recipe_table.all_assembling_recipes[recipe_name] = recipe
        end
      end
      if next(machine_recipes) then
        global_recipe_table.assembling_machines[name] = machine_recipes
      end
    end
  end
  global_recipe_table.all_assembling_recipes = Set.I(prototypes.recipe, global_recipe_table.all_assembling_recipes)


  -- Все полезные рецепты:
  -- Могут быть установлены в машине по сигналу ✓
  -- Не пустые ингредиенты/продукты ...
  -- Не рецепты свапов ...
  -- Крафтиться не на платформе ...
  global_recipe_table.usefull_recipes = Set.D(global_recipe_table.all_assembling_recipes, Set.U(
    global_recipe_table.empty_barrel,
    global_recipe_table.fill_barrel))


  -- Все бесполезные рецепты качества 2+:
  -- Производит/Потребляет только жидкость ✓
  -- Не имеет полезных бонусов от качества ...
  global_recipe_table.quality_useless_recipes = Set.U(
    global_recipe_table.fluid_only_ingredient_recipes,
    global_recipe_table.fluid_only_product_recipes)

  -- ☆ Применяем фильтрацию ко всем таблицам, исключая invalid_recipes
  for key, value in pairs(global_recipe_table) do
    if key ~= "invalid_recipes" and key ~= "parameter_recipes" then
      global_recipe_table[key] = filter_invalid_recipes(value, global_recipe_table.invalid_recipes)
    end
  end

  return global_recipe_table
end

-- Формирование базовых таблиц-множеств предметов и жидкостей
local function global_item_or_fluid_filtered()
  -- Сбор всех невалидных имён item и fluid
  local function collect_invalid_resource_names()
    local invalid = {}
    for name, item in pairs(prototypes.item) do
      if item.parameter or item.hidden or item.subgroup.name == "spawnables" then
        invalid[name] = true
      end
    end
    for name, fluid in pairs(prototypes.fluid) do
      if fluid.parameter or fluid.hidden then
        invalid[name] = true
      end
    end
    return invalid
  end

  local global_resource_table = {}

  global_resource_table.invalid_names = collect_invalid_resource_names()

  -- Все предметы
  global_resource_table.all_items = {}
  for name, item in pairs(prototypes.item) do
    global_resource_table.all_items[name] = item
  end

  -- Все жидкости
  global_resource_table.all_fluids = {}
  for name, fluid in pairs(prototypes.fluid) do
    global_resource_table.all_fluids[name] = fluid
  end

  -- Все ресурсы, у которых есть main_product
  global_resource_table.resource_main_product = {}
  for _, recipe in pairs(global_recipe_table.recipes_with_main) do
    local main = recipe.main_product
    if main and main.name and main.type then
      if main.type == "item" then
        local item = prototypes.item[main.name]
        if item then
          global_resource_table.resource_main_product[main.name] = item
        end
      elseif main.type == "fluid" then
        local fluid = prototypes.fluid[main.name]
        if fluid then
          global_resource_table.resource_main_product[main.name] = fluid
        end
      end
    end
  end

  -- Ресурсы, которые встречаются как main_product в нескольких рецептах
  global_resource_table.resource_repeating_main_product = {}
  local product_to_recipes = {}

  for recipe_name, recipe in pairs(global_recipe_table.recipes_with_main) do
    local main = recipe.main_product
    if main and main.name then
      local key = main.name
      product_to_recipes[key] = product_to_recipes[key] or {}
      product_to_recipes[key][recipe_name] = recipe
    end
  end

  for product_name, recipe_map in pairs(product_to_recipes) do
    local count = 0
    for _ in pairs(recipe_map) do count = count + 1 end
    if count > 1 then
      global_resource_table.resource_repeating_main_product[product_name] = recipe_map
    end
  end

  -- Фильтрация: рекурсивно удаляет все невалидные имена, кроме поля invalid_names
  local function filter_invalid_except_invalid_names(tbl, invalid_names)
    local function recursive_filter(t)
      for k, v in pairs(t) do
        if type(v) == "table" then
          t[k] = recursive_filter(v)
        end
      end
      return Set.D(t, invalid_names)
    end

    for key, value in pairs(tbl) do
      if key ~= "invalid_names" and type(value) == "table" then
        tbl[key] = recursive_filter(value)
      end
    end
  end

  -- Вызов фильтрации
  filter_invalid_except_invalid_names(global_resource_table, global_resource_table.invalid_names)

  return global_resource_table
end

--#endregion ▲ Функции инициализации

--#region ▼ Класс DeciderC решающего комбинатора

-- Функции для объединения условий в "and" и "or"
local function AND(...)
  return { "and", ... }
end

local function OR(...)
  return { "or", ... }
end

-- Определяем класс Combinator (решающий комбинатор)
local DeciderC = {}
DeciderC.__index = DeciderC

-- Функция process_expr преобразует выражение в ДНФ и возвращает список нормализованных условий.
local function process_expr(expr)
  local function is_logic_node(x)
    return type(x) == "table" and (x[1] == "and" or x[1] == "or")
  end

  local function cross_product(lists)
    if #lists == 0 then return {} end
    local result = { {} }
    for _, list in ipairs(lists) do
      local new_result = {}
      for _, seq in ipairs(result) do
        for _, item in ipairs(list) do
          local new_seq = { table.unpack(seq) }
          table.insert(new_seq, item)
          table.insert(new_result, new_seq)
        end
      end
      result = new_result
    end
    return result
  end

  local function flatten(op, args)
    local result = {}
    for _, arg in ipairs(args) do
      if is_logic_node(arg) and arg[1] == op then
        for _, sub in ipairs(flatten(op, { table.unpack(arg, 2) })) do
          table.insert(result, sub)
        end
      else
        table.insert(result, arg)
      end
    end
    return result
  end

  local function to_dnf(expr)
    if not is_logic_node(expr) then
      return expr
    end

    local op = expr[1]
    local args = { table.unpack(expr, 2) }
    local dnf_args = {}
    for _, arg in ipairs(args) do
      table.insert(dnf_args, to_dnf(arg))
    end

    if op == "or" then
      return OR(table.unpack(flatten("or", dnf_args)))
    elseif op == "and" then
      local sets = {}
      for _, arg in ipairs(dnf_args) do
        if is_logic_node(arg) and arg[1] == "or" then
          table.insert(sets, { table.unpack(arg, 2) })
        else
          table.insert(sets, { arg })
        end
      end

      local combos = cross_product(sets)
      local result = {}
      for _, combo in ipairs(combos) do
        table.insert(result, AND(table.unpack(flatten("and", combo))))
      end

      return OR(table.unpack(result))
    end
  end

  local function normalize_condition(condition)
    local first = condition.first_signal
    local second = condition.second_signal

    if first then
      condition.first_signal = sdp_signal_dc(first)
    end
    if second then
      condition.second_signal = sdp_signal_dc(second)
    end

    local first_name = first and first.name
    local is_signal_each = first_name == "signal-each"

    if condition.compare_type == nil then
      condition.compare_type = is_signal_each and "or" or "and"
    end

    if condition.comparator == nil then
      condition.comparator = is_signal_each and "=" or ">"
    end

    if condition.constant == nil then
      condition.constant = is_signal_each and nil or 0
    end

    local default_or_nets = { red = true, green = false }
    local default_and_nets = { red = false, green = true }

    if is_signal_each then
      if condition.first_signal_networks == nil then
        condition.first_signal_networks = default_or_nets
      end
      if condition.second_signal and condition.second_signal_networks == nil then
        condition.second_signal_networks = default_or_nets
      end
    else
      if condition.first_signal_networks == nil then
        condition.first_signal_networks = default_and_nets
      end
      if condition.second_signal and condition.second_signal_networks == nil then
        condition.second_signal_networks = default_and_nets
      end
    end

    return condition
  end

  local function fix_or_redundancy(conditions)
    local or_streak = 0
    for _, cond in ipairs(conditions) do
      if cond.compare_type == "or" then
        or_streak = or_streak + 1
        if or_streak == 2 then
          cond.compare_type = "and"
        elseif or_streak >= 3 then
          log("⚠️ Обнаружено подряд условий 'or', это может быть ошибкой логики.")
        end
      else
        or_streak = 0
      end
    end
  end

  local function flatten_dnf_to_conditions(dnf)
    local conditions = {}
    assert(dnf[1] == "or", "Ожидался корень выражения 'or'")
    for _, group in ipairs({ table.unpack(dnf, 2) }) do
      assert(group[1] == "and", "Ожидалась группа 'and'")
      local found_or = nil
      local others = {}
      for _, cond in ipairs({ table.unpack(group, 2) }) do
        local norm = normalize_condition(cond)
        if norm.compare_type == "or" and norm.first_signal and norm.first_signal.name == "signal-each" then
          found_or = norm
        else
          table.insert(others, norm)
        end
      end
      assert(found_or ~= nil, "Не найдено условие 'or' с signal-each в группе")
      table.insert(conditions, found_or)
      for _, cond in ipairs(others) do
        table.insert(conditions, cond)
      end
    end
    fix_or_redundancy(conditions)
    return conditions
  end

  local dnf = to_dnf(expr)
  local conditions = flatten_dnf_to_conditions(dnf)
  return conditions
end

------------------------------------------------------------
-- Метод для установки параметров на объекте комбинатора.
-- Встроенная логика аналогична обновленной функции
-- set_decider_combinator_parameters.
------------------------------------------------------------
local function updated_set_decider_combinator_parameters(entity, settings)
  -- local behavior = entity.get_or_create_control_behavior()
  entity.parameters = {
    conditions = settings.conditions or {},
    outputs = settings.outputs or {
      {
        signal = { name = "signal-each", type = "virtual" },
        copy_count_from_input = true,
        networks = { red = true, green = false }
      }
    }
  }
end

--- Конструктор DeciderC
-- @param entity LuaEntity — игровой объект решающего комбинатора
function DeciderC:new(entity)
  if not entity or type(entity.get_or_create_control_behavior) ~= "function" then
    error("[DeciderC] invalid object")
  end
  local behavior = entity:get_or_create_control_behavior()
  if not behavior or not behavior.valid then
    error("[DeciderC] control behavior invalid")
  end
  local self = setmetatable({}, DeciderC)
  self._behavior = behavior
  self.conditions = {} -- условия решающего комбинатора
  return self
end

------------------------------------------------------------
-- Метод add_expr.
-- Принимает логическое выражение, преобразует его в список условий через process_expr,
-- и добавляет полученные условия к уже сохраненным.
------------------------------------------------------------
function DeciderC:add_expr(expr)
  local new_conditions = process_expr(expr)
  for _, cond in ipairs(new_conditions) do
    table.insert(self.conditions, cond)
  end
end

------------------------------------------------------------
-- Альтернативный метод для добавления условий,
-- если условия уже подготовлены.
------------------------------------------------------------
function DeciderC:add_conditions(conds)
  for _, cond in ipairs(conds) do
    table.insert(self.conditions, cond)
  end
end

------------------------------------------------------------
-- Метод apply_settings.
-- Применяет настройки (conditions и outputs) к Lua объекту комбинатора,
-- используя интегрированную функцию обновленной установки параметров.
------------------------------------------------------------
function DeciderC:apply_settings(outputs)
  local settings = { conditions = self.conditions, outputs = outputs }
  updated_set_decider_combinator_parameters(self._behavior, settings)
end

--#endregion ▲ Класс решающего комбинатора

--#region ▼ Класс SectionCC логической группы констант комбинатора

--- Добавляет сигнал в целевое хранилище
-- @param storage table — хранилище вида [name][quality][type] = min
-- @param norm {name=string, quality=string, type=string, min=number}
function add_signal_to_storage(storage, norm)
  local n, q, t, m = norm.name, norm.quality, norm.type, norm.min
  storage[n]       = storage[n] or {}
  storage[n][q]    = storage[n][q] or {}
  storage[n][q][t] = (storage[n][q][t] or 0) + m
end

SectionCC = {}
SectionCC.__index = function(self, key)
  if SectionCC[key] then return SectionCC[key] end
  local first = self._sections and self._sections[1]
  if first and first[key] then
    if type(first[key]) == "function" then
      return function(tbl, ...) return first[key](first, ...) end
    else
      return first[key]
    end
  end
  return nil
end

--- Конструктор «абстрактной» секции
-- @param control_behavior LuaConstantCombinatorControlBehavior
-- @param group_key string?
-- @param parent ConstantC?
function SectionCC:new(control_behavior, group_key, parent)
  local obj = {
    _control  = control_behavior,
    group_key = group_key or "",
    storage   = {},
    _parent   = parent,
    _sections = {} -- множество real-секций
  }
  setmetatable(obj, SectionCC)
  return obj
end

--- Нормализует одну запись
-- @param entry {name=string, min=number?, quality=string?, type=string?}
-- @return {name, quality, type, min} или nil
function SectionCC:normalize(entry)
  if not entry.name then error("[SectionCC] 'name' must be set") end
  local min = entry.min or 0
  if type(min) ~= "number" then error("[SectionCC] 'min' must be a number") end
  local quality = entry.quality or qualities[1]
  local typ = get_type(entry.name, entry.type)
  if not typ then
    game.print("[SectionCC] unknown signal name: " .. tostring(entry.name))
    return nil
  end
  return { name = entry.name, quality = quality, type = typ, min = min }
end

--- Добавляет массив записей в storage (аггрегирует по сумме min)
-- @param entries table[]
function SectionCC:add_signals(entries)
  for _, entry in ipairs(entries) do
    local norm = self:normalize(entry)
    if norm then
      add_signal_to_storage(self.storage, norm)
    end
  end
end

--- Создаёт real-секцию один раз и обновляет её фильтры
function SectionCC:set_signals()
  local control = self._control
  if not control.valid then
    game.print("[SectionCC] combinator not valid")
    return
  end

  -- Собираем flat_signals из storage
  local flat_signals = {}
  for name, quals in pairs(self.storage) do
    for quality, types in pairs(quals) do
      for typ, sum_min in pairs(types) do
        table.insert(flat_signals, {
          value = { name = name, type = typ, quality = quality },
          min   = sum_min
        })
      end
    end
  end

  if #flat_signals == 0 then
    -- Нет сигналов — ничего не делаем, существующая секция остаётся как есть
    return
  end

  local MAX_PER_SECTION = 1000
  local total = #flat_signals
  local i = 1

  -- ⬇ Используем уже привязанную секцию, если она есть и стоит на первой позиции ⬇
  if self._section then
    local count = math.min(total, MAX_PER_SECTION)
    local slice = {}
    for j = 1, count do
      slice[j] = flat_signals[j]
    end
    self._section.filters = slice
    i = count + 1
  end

  -- ⬇ Добавляем дополнительные секции только при переполнении ⬇
  while i <= total do
    local slice = {}
    for j = i, math.min(i + MAX_PER_SECTION - 1, total) do
      slice[#slice + 1] = flat_signals[j]
    end

    local section
    -- Для новых секций используем любой способ создания
    if self.group_key and #self._sections == 0 then
      section = control.add_section(self.group_key)
    else
      section = control.add_section()
    end

    section.filters = slice
    table.insert(self._sections, section)
    i = i + MAX_PER_SECTION
  end
end

--#endregion ▲ SectionCC

--#region ▼ Класс ConstantC констант-комбинатора

-- <НЕ РЕАЛИЗОВАНО!> Максимум секций 100 ед. в постоянном комбинаторе !!!

ConstantC = {}
ConstantC.__index = function(self, key)
  if ConstantC[key] then return ConstantC[key] end
  local beh = rawget(self, "_behavior")
  if beh and beh[key] then
    if type(beh[key]) == "function" then
      return function(tbl, ...) return beh[key](beh, ...) end
    else
      return beh[key]
    end
  end
  return nil
end

--- Конструктор ConstantC
-- @param obj LuaEntity
function ConstantC:new(obj)
  if not obj or type(obj.get_or_create_control_behavior) ~= "function" then
    error("[ConstantC] invalid object")
  end
  local behavior = obj:get_or_create_control_behavior()
  local self = {
    _behavior  = behavior,
    sections   = {},
    cc_storage = {}
  }
  setmetatable(self, ConstantC)
  return self
end

--- Добавляет массив записей в cc_storage (агрегирует по сумме min)
-- @param entries table[] — каждый элемент: {name=string, min=number?, quality=string?, type=string?}
function ConstantC:add_signals_to_cc_storage(entries)
  for _, entry in ipairs(entries) do
    if not entry.name then
      error("[ConstantC] 'name' must be set")
    end
    local min = entry.min or 0
    if type(min) ~= "number" then
      error("[ConstantC] 'min' must be a number")
    end
    local quality = entry.quality or qualities[1]
    local typ = get_type(entry.name, entry.type)
    if not typ then
      game.print("[ConstantC] unknown signal name: " .. tostring(entry.name))
    else
      add_signal_to_storage(self.cc_storage, {
        name = entry.name,
        quality = quality,
        type = typ,
        min = min
      })
    end
  end
end

--- Добавляет новую секцию сразу в игре и в sections[]
-- @param group_key string?
-- @return SectionCC
function ConstantC:add_section(group_key)
  if not self._behavior.valid then
    game.print("[ConstantC] combinator not valid")
    return
  end
  local real
  if group_key and group_key ~= "" then
    real = self._behavior.add_section(group_key)
  else
    real = self._behavior.add_section()
  end
  local sc = SectionCC:new(self._behavior, group_key, self) -- ← передаём self как parent
  rawset(sc, "_section", real)
  table.insert(self.sections, sc)
  return sc
end

--- Копирует сигналы из cc_storage по фильтрам и пользовательскому порядку в target
-- @param filters table, где каждый filters[field] может быть:
--    • nil — не фильтровать и без порядка
--    • множество {[value]=true} — фильтровать по ключам, без порядка
--    • массив {"v1","v2",…} — фильтровать по этому списку и именно в этом порядке
-- @param target SectionCC|string|string[] — куда класть сигналы
-- @return SectionCC[] — список получившихся секций
function ConstantC:copy_filtered_signals(filters, target)
  -- 1) Построить include-множества и order-списки
  local include = {}
  local order   = {}
  for _, field in ipairs { "name", "quality", "type" } do
    local f = filters[field]
    if type(f) == "table" then
      if #f > 0 then
        -- массив: фильтр + порядок
        include[field] = {}
        for _, v in ipairs(f) do include[field][v] = true end
        order[field] = f
      else
        -- множество: только фильтр
        include[field] = f
      end
    end
  end

  -- 2) Собрать «matched» в виде matched[name][quality][type] = sum
  local matched = {}
  for name, quals in pairs(self.cc_storage) do
    if not include.name or include.name[name] then
      for quality, types in pairs(quals) do
        if not include.quality or include.quality[quality] then
          for typ, sum_min in pairs(types) do
            if not include.type or include.type[typ] then
              matched[name]               = matched[name] or {}
              matched[name][quality]      = matched[name][quality] or {}
              matched[name][quality][typ] = sum_min
            end
          end
        end
      end
    end
  end
  if not next(matched) then return game.print("[ConstantC] copy_filtered_signals: nothing matched") and {} end
  -- if not next(matched) then error("copy_filtered_signals: nothing matched") end
  local result = {}

  -- 3a) Если target — SectionCC, просто заполняем его storage
  if type(target) == "table" and type(target.add_signals) == "function" then
    for name, quals in pairs(matched) do
      for quality, types in pairs(quals) do
        for typ, sum_min in pairs(types) do
          target.storage[name]               = target.storage[name] or {}
          target.storage[name][quality]      = target.storage[name][quality] or {}
          target.storage[name][quality][typ] = sum_min
        end
      end
    end
    table.insert(result, target)
    return result
  end

  -- 3b) Если target — string, создаём одну новую секцию с этим именем
  if type(target) == "string" then
    local sc = self:add_section(target)
    for name, quals in pairs(matched) do
      for quality, types in pairs(quals) do
        for typ, sum_min in pairs(types) do
          sc.storage[name]               = sc.storage[name] or {}
          sc.storage[name][quality]      = sc.storage[name][quality] or {}
          sc.storage[name][quality][typ] = sum_min
        end
      end
    end
    table.insert(result, sc)
    return result
  end

  -- 3c) Если target — array of strings, авто-распределение по комбинациям этих полей
  if type(target) == "table" then
    -- убедиться, что это именно массив полей
    local is_array = true
    for i = 1, #target do
      if type(target[i]) ~= "string" then
        is_array = false; break
      end
    end
    if is_array then
      -- 3c.1) собрать уникальные комбинации dims[field]=value
      local combos = {}
      local seen   = {}
      for name, quals in pairs(matched) do
        for quality, types in pairs(quals) do
          for typ, sum_min in pairs(types) do
            local dims = {}
            for _, field in ipairs(target) do
              if field == "name" then
                dims[field] = name
              elseif field == "quality" then
                dims[field] = quality
              else
                dims[field] = typ
              end
            end
            -- ключ для уникальности
            local parts = {}
            for _, field in ipairs(target) do parts[#parts + 1] = dims[field] end
            local key = table.concat(parts, "|")
            if not seen[key] then
              seen[key]           = true
              combos[#combos + 1] = dims
            end
          end
        end
      end

      -- 3c.2) отсортировать combos по user-order
      table.sort(combos, function(a, b)
        for _, field in ipairs(target) do
          local va, vb = a[field], b[field]
          local ord    = order[field]
          if ord then
            -- найти индексы в ord
            local ia, ib
            for idx, v in ipairs(ord) do
              if v == va then ia = idx end
              if v == vb then ib = idx end
            end
            if ia and ib and ia ~= ib then return ia < ib end
            if ia and not ib then return true end
            if ib and not ia then return false end
          end
          -- fallback: лексикографический
          if va ~= vb then return va < vb end
        end
        return false
      end)

      -- 3c.3) создать секцию на каждую комбинацию и скопировать туда свои записи
      for _, dims in ipairs(combos) do
        local sc = self:add_section("")
        result[#result + 1] = sc
        for name, quals in pairs(matched) do
          for quality, types in pairs(quals) do
            for typ, sum_min in pairs(types) do
              local ok = true
              for _, field in ipairs(target) do
                local val = (field == "name" and name)
                    or (field == "quality" and quality)
                    or typ
                if dims[field] ~= val then
                  ok = false; break
                end
              end
              if ok then
                sc.storage[name]               = sc.storage[name] or {}
                sc.storage[name][quality]      = sc.storage[name][quality] or {}
                sc.storage[name][quality][typ] = sum_min
              end
            end
          end
        end
      end

      return result
    end
  end

  error("copy_filtered_signals: invalid target")
end

--- Обновляет значения в cc_storage по фильтрам
-- @param filters { name=table?, quality=table?, type=table? }  — nil-поля не фильтруют
-- @param delta   number|function(old_value)->new_value
function ConstantC:update_cc_storage(filters, delta)
  for name, quals in pairs(self.cc_storage) do
    if not filters.name or filters.name[name] then
      for quality, types in pairs(quals) do
        if not filters.quality or filters.quality[quality] then
          for typ, old in pairs(types) do
            if not filters.type or filters.type[typ] then
              local new
              if type(delta) == "function" then
                new = delta(old)
              else
                new = old + delta
              end
              self.cc_storage[name][quality][typ] = new
            end
          end
        end
      end
    end
  end
end

--- Устанавливает накопленные фильтры во все секции
function ConstantC:set_all_signals()
  for _, section in ipairs(self.sections) do
    section:set_signals()
  end
end

--- Поочерёдно применяет fn к подмножествам cc_storage,
--- разбивая по каждому значению в фильтре в том порядке, как задано в literal.
--- Если filter пустой (`{}`), то fn применяется ко всем значениям в cc_storage.
-- @param filter table, где filter[field] может быть:
--    • массив {"v1","v2",…} — фильтрация + пользовательский порядок
--    • множество {[v1]=true, …} — фильтрация без гарантии порядка
-- @param fn     function(old)->new
function ConstantC:update_by_filter(filter, fn)
  -- Если фильтр пуст — обновить всё cc_storage
  if not next(filter) then
    self:update_cc_storage({}, fn)
    return
  end

  for field, values in pairs(filter) do
    local list = {}
    if type(values) == "table" and #values > 0 then
      for _, v in ipairs(values) do
        list[#list + 1] = v
      end
    elseif type(values) == "table" then
      for v in pairs(values) do
        list[#list + 1] = v
      end
    else
      error("update_by_filter: filter[" .. tostring(field) .. "] must be a table")
    end

    for _, val in ipairs(list) do
      self:update_cc_storage({ [field] = { [val] = true } }, fn)
    end
  end
end

--- Возвращает cc_storage в развёрнутом виде
-- @return table[] — массив { name=string, quality=string, type=string, min=number }
function ConstantC:get_cc_storage()
  local result = {}
  for name, qualities in pairs(self.cc_storage) do
    for quality, types in pairs(qualities) do
      for typ, min in pairs(types) do
        table.insert(result, {
          name    = name,
          quality = quality,
          type    = typ,
          min     = min
        })
      end
    end
  end
  return result
end

--#endregion ▲ ConstantC

--#region ▼ SectionRC: логическая абстракция секции сундука запроса

local SectionRC = {}
SectionRC.__index = SectionRC

--- Создаёт абстрактную секцию для логистического сундука
-- @param group_key string — имя секции (section.group)
-- @param opts table?
--    chest_mod boolean — спец. режим (заглушка), по умолчанию false
--    multiplier number — множитель секции, по умолчанию 1.0
--    active boolean — состояние секции (section.active), по умолчанию true
function SectionRC:new(group_key, opts)
  opts = opts or {}
  local obj = {
    group_key  = group_key or "",
    chest_mod  = opts.chest_mod or false,
    multiplier = opts.multiplier or 1.0,
    active     = opts.active == nil and true or opts.active,
    storage    = {} -- signals[name][type][comparator][quality] = { min, max, is_set_max }
  }
  setmetatable(obj, SectionRC)
  return obj
end

--- Нормализует входные параметры секции
-- @param entry table { name, type?, comparator?, quality?, min?, max?, set_max? }
-- @return table|nil нормализованный сигнал или nil при ошибке
function SectionRC:normalize(entry)
  if not entry.name then error("[SectionRC] 'name' должен быть задан") end
  local name = entry.name
  local typ  = get_type(name, entry.type)
  if not typ then
    game.print("[SectionRC] неизвестный тип для '" .. name .. "', пропускаем")
    return nil
  end
  if typ ~= "item" then
    game.print("[SectionRC] warning: тип '" .. typ .. "' не 'item' для сундука запроса")
  end
  local cmp = entry.comparator or "="
  local allowed = { ["="] = true, ["≠"] = true, [">"] = true, ["<"] = true, ["≥"] = true, ["≤"] = true, ["any"] = true }
  if not allowed[cmp] then cmp = "=" end
  local qual       = entry.quality or qualities[1]
  local mn         = entry.min or 0
  local is_set_max = entry.set_max ~= nil
  local mx
  if is_set_max then
    mx = entry.set_max
  else
    if entry.max == nil or entry.max == "inf" then
      mx = math.huge
    else
      mx = entry.max
    end
  end

  return {
    name       = name,
    type       = typ,
    comparator = cmp,
    quality    = qual,
    min        = mn,
    max        = mx,
    is_set_max = is_set_max
  }
end

--- Добавляет или объединяет сигнал в storage
-- @param entry table входной формат для normalize
function SectionRC:add_signal(entry)
  if self.chest_mod then
    game.print("[SectionRC] chest_mod режим не реализован, заглушка")
  end
  local norm = self:normalize(entry)
  if not norm then return end

  local n, t, c, q, mn, mx = norm.name, norm.type, norm.comparator, norm.quality, norm.min, norm.max
  self.storage[n]          = self.storage[n] or {}
  self.storage[n][t]       = self.storage[n][t] or {}
  self.storage[n][t][c]    = self.storage[n][t][c] or {}
  local qmap               = self.storage[n][t][c]

  local old                = qmap[q]
  if not old then
    qmap[q] = { min = mn, max = mx, is_set_max = norm.is_set_max }
  else
    old.min = old.min + mn
    if norm.is_set_max then
      old.max = mx
      old.is_set_max = true
    else
      if old.max == math.huge or mx == math.huge then
        old.max = math.huge
      else
        old.max = old.max + mx
      end
    end
  end
end

--- Формирует массив фильтров для LuaLogisticSection.filters
-- @return table[] список фильтров
function SectionRC:prepare_export()
  local out = {}
  for name, typmap in pairs(self.storage) do
    for typ, cmpmap in pairs(typmap) do
      for cmp, qmap in pairs(cmpmap) do
        for qual, data in pairs(qmap) do
          -- формируем базовый сигнал
          local value = { name = name, type = typ }

          -- добавляем качество и знак внутрь value, если не "any"
          if cmp ~= "any" then
            value.quality    = qual
            value.comparator = cmp
          end

          -- создаём фильтр с min/max
          local filter = {
            value = value,
            min   = data.min
          }
          if data.max and data.max < math.huge then
            filter.max = data.max
          end

          table.insert(out, filter)
        end
      end
    end
  end
  return out
end

--- Применяет эту абстрактную секцию к реальному логистическому пункту
-- @param point LuaLogisticPoint — результат entity:get_requester_point()
function SectionRC:apply_to_point(point)
  local real      = point.add_section(self.group_key or "")
  real.multiplier = self.multiplier or 1.0
  real.active     = (self.active == nil) and true or self.active
  real.filters    = self:prepare_export()
  return real
end

--#endregion ▲ SectionRC

--#region ▼ RequestC: управление requester logistic-container

local RequestC = {}
RequestC.__index = RequestC

--- Конструктор RequestC
-- @param entity LuaEntity — должен быть logistic-container mode="requester"
-- @param take boolean? — true = загрузить все секции; false = только помеченные <...>
function RequestC:new(entity, take)
  if not entity or not entity.valid then
    error("[RequestC] недопустимый entity")
  end
  if entity.prototype.logistic_mode ~= "requester" then
    error("[RequestC] entity не является requester logistic-container")
  end
  local point = entity.get_requester_point and entity:get_requester_point()
  if not point or not point.valid then
    error("[RequestC] не удалось получить logistic_point")
  end

  local obj = { entity = entity, point = point, sections = {} }
  setmetatable(obj, RequestC)

  -- загрузка существующих секций
  for _, sec in ipairs(point.sections) do
    if take or (sec.group and sec.group:match("^<.+>$")) then
      local sc = SectionRC:new(sec.group, {
        chest_mod  = false,
        multiplier = sec.multiplier or 1.0,
        active     = sec.active
      })
      for _, f in ipairs(sec.filters) do
        sc:add_signal {
          name       = f.value.name,
          type       = f.value.type,
          comparator = f.comparator,
          quality    = f.value.quality,
          min        = f.min,
          max        = f.max or "inf"
        }
      end
      table.insert(obj.sections, sc)
    end
  end

  return obj
end

--- Явное создание новой секции
-- @param group_key string — имя секции
-- @param opts table? — опции chest_mod, multiplier, active
function RequestC:add_section(group_key, opts)
  local sc = SectionRC:new(group_key, opts)
  table.insert(self.sections, sc)
  return sc
end

--- Применяет все накопленные секции и их фильтры в сундук
--  Удаляет старые реальные секции, затем создаёт новые по apply_to_point,
--  и сбрасывает список абстрактных секций.
function RequestC:apply()
  for i = #self.point.sections, 1, -1 do
    self.point.remove_section(i)
  end
  for _, sc in ipairs(self.sections) do
    sc:apply_to_point(self.point)
  end
  self.sections = {}
end

--#endregion ▲ RequestC


local function main()
  --#region ▼ Вызовы инициализации

  if area == nil then
    area = { { 0, 0 }, { 100, 100 } }
  end

  area = area

  qualities = {} -- ☆ Список всех имен существующих качеств в виде строки
  for _, proto in pairs(prototypes.quality) do
    if proto.hidden == false then
      table.insert(qualities, proto.name)
    end
  end

  global_recipe_table = global_recipe_filtered()
  global_resource_table = global_item_or_fluid_filtered()

  --#endregion ▲ Вызовы инициализации

  --#region ▼▼ Тест ? - ...
  --#endregion ▲▲ Тест ? - ...

  local usefull_recipes = Set.I(global_recipe_table.usefull_recipes, global_recipe_table.machines
    ["assembling-machine-3"], global_recipe_table.recipes_with_main)


  local offset_hight = 10 ^ 6     -- Верхняя точка отсчета

  local offset_low = 0            -- Нижняя точка отсчета

  local block_count = -5 * 10 ^ 6 -- Условно блокирующее значение константы

  -- Списки И, ИП, П
  local classify_ingredients = get_classify_ingredients(usefull_recipes)

  --#region ▼ DC управления авто-ассемблером

  --#region ▼▼ DeciderCombinator

  local function process_dc_multi_RS_trigger_max(dc_multi_RS_trigger_max)
    -- Пропускающее с. liquid если ни разу не была установлена жидкость как ингредиент
    local other_fluids_conditions = { "and" }
    table.insert(other_fluids_conditions, {
      first_signal = { name = "signal-each" },
      second_signal = { name = "signal-liquid", quality = qualities[#qualities], type = "virtual" }
    })
    for _, other_fluid in pairs(global_resource_table.all_fluids) do
      table.insert(other_fluids_conditions, {
        first_signal = { name = other_fluid.name, quality = qualities[#qualities], type = "fluid" },
        comparator = "=",
        constant = 0,
        first_signal_networks = { red = false, green = true }
      })
    end
    dc_multi_RS_trigger_max:add_expr(other_fluids_conditions)

    -- Пропускающее с. B если ни разу не был установлен рецепт опрожнения бочки
    local other_empty_barrel_recipes = { "and" }
    table.insert(other_empty_barrel_recipes, {
      first_signal = { name = "signal-each" },
      second_signal = { name = "signal-B", quality = qualities[#qualities], type = "virtual" }
    })
    for _, other_empty_barrel_recipe in pairs(global_recipe_table.empty_barrel) do
      table.insert(other_empty_barrel_recipes, {
        first_signal = { name = other_empty_barrel_recipe.name, quality = qualities[1], type = "recipe" },
        comparator = "=",
        constant = offset_low,
        first_signal_networks = { red = false, green = true }
      })
    end
    dc_multi_RS_trigger_max:add_expr(other_empty_barrel_recipes)

    -- -- Пропускающее с. констант -1 * offset01 с красного провода
    -- local all_signals_offset = AND({
    --   first_signal = { name = "signal-each" },
    --   constant = -1 * offset01
    -- })
    -- dc_multi_RS_trigger_max:add_expr(all_signals_offset)

    -- -- Пропускающее с. F для нейтрализации пропуска констант -1 * offset01 с красного провода
    -- local all_signals_F_count = AND({
    --   first_signal = { name = "signal-each" },
    --   second_signal = { name = "signal-F", type = "virtual" }
    -- })
    -- dc_multi_RS_trigger_max:add_expr(all_signals_F_count)

    for recipe_name, recipe in pairs(usefull_recipes) do
      local recipe_signal = { name = recipe_name, quality = qualities[1], type = "recipe" }
      local fluid_data = extract_fluid_data(recipe)

      local recipe_out = {
        first_signal  = { name = "signal-each" },
        second_signal = recipe_signal
      }

      local recipe_offset = {
        first_signal          = recipe_signal,
        comparator            = ">",
        constant              = offset_hight,
        first_signal_networks = { red = false, green = true }
      }

      local filter_max_recipe = {
        first_signal           = { name = "signal-everything", type = "virtual" },
        second_signal          = recipe_signal,
        comparator             = "≤",
        first_signal_networks  = { red = false, green = true },
        second_signal_networks = { red = true, green = false }
      }

      local lock_active_recipe = {
        first_signal          = { name = "signal-everything", type = "virtual" },
        constant              = offset_hight / 2 - 1,
        comparator            = "<",
        first_signal_networks = { red = false, green = true }
      }

      local ingredients = { "or" }
      for _, ing_variant in ipairs(get_alternative_ingredient_variants(recipe)) do
        local and_group = { "and" }
        for _, ing in ipairs(ing_variant) do
          local amount            = ing.amount or 1
          local signal            = { name = ing.name, quality = qualities[1], type = ing.type }
          local networks          = (ing.type == "fluid") and { red = true, green = true } or
              { red = false, green = true }

          local offset_multiplier = (ing.type == "fluid") and -2 or -1
          local constant          = offset_multiplier * offset_low + amount

          table.insert(and_group, {
            first_signal          = signal,
            comparator            = "≥",
            constant              = constant,
            first_signal_networks = networks
          })
        end
        table.insert(ingredients, and_group)
      end

      local check_F = {
        first_signal          = { name = "signal-F", type = "virtual" },
        constant              = 3,
        comparator            = "=",
        first_signal_networks = { red = false, green = true }
      }

      local fluids_d4 = { "or" }
      local fluids_d5 = { "or" }
      for _, fluid_name in ipairs(fluid_data.ingredients) do
        local fluid_signal = { name = fluid_name, quality = qualities[#qualities], type = "fluid" }

        table.insert(fluids_d4, AND(
          { first_signal = { name = "signal-each" }, second_signal = fluid_signal },
          check_F,
          recipe_offset
        ))

        local fluid_offset = {
          first_signal          = fluid_signal,
          comparator            = ">",
          constant              = 0,
          first_signal_networks = { red = false, green = true }
        }
        local other_fluids_conditions = { "and" }
        for _, other in pairs(global_resource_table.all_fluids) do
          if other.name ~= fluid_name then
            table.insert(other_fluids_conditions, {
              first_signal          = { name = other.name, quality = qualities[#qualities], type = "fluid" },
              comparator            = "=",
              constant              = 0,
              first_signal_networks = { red = false, green = true }
            })
          end
        end
        table.insert(fluids_d5, AND(
          { first_signal = { name = "signal-each" }, second_signal = fluid_signal },
          fluid_offset,
          other_fluids_conditions
        ))
      end

      local empty_barrel_d4 = { "or" }
      local empty_barrel_d5 = { "or" }
      for _, fluid_name in ipairs(fluid_data.ingredients) do
        local barrel = get_barrel_recipes_for_fluid(fluid_name)
        if barrel and barrel.empty_barrel_recipe then
          local barrel_signal = {
            name    = barrel.empty_barrel_recipe,
            quality = qualities[1],
            type    = "recipe"
          }

          table.insert(empty_barrel_d4, AND(
            { first_signal = { name = "signal-each" }, second_signal = barrel_signal },
            check_F,
            recipe_offset
          ))

          local barrel_offset = {
            first_signal          = barrel_signal,
            comparator            = ">",
            constant              = offset_low,
            first_signal_networks = { red = false, green = true }
          }
          local other_barrels = { "and" }
          for _, other in pairs(global_recipe_table.empty_barrel) do
            if other.name ~= barrel.empty_barrel_recipe then
              table.insert(other_barrels, {
                first_signal          = { name = other.name, quality = qualities[1], type = "recipe" },
                comparator            = "=",
                constant              = offset_low,
                first_signal_networks = { red = false, green = true }
              })
            end
          end
          table.insert(empty_barrel_d5, AND(
            { first_signal = { name = "signal-each" }, second_signal = barrel_signal },
            barrel_offset,
            other_barrels
          ))
        end
      end

      local d1 = AND(recipe_out, ingredients, lock_active_recipe)
      local d2 = AND(recipe_out, ingredients, recipe_offset, filter_max_recipe)
      -- local d3 = AND(recipe_out, ingredients, recipe_offset, check_F)
      local d3 = AND(recipe_out, ingredients, recipe_offset)

      -- local expr = OR(
      --   d1, d2, d3,
      --   fluids_d4, fluids_d5,
      --   empty_barrel_d4, empty_barrel_d5
      -- )

      local expr = OR(
        d1, d2, d3
      )

      dc_multi_RS_trigger_max:add_expr(expr)
    end

    local outputs = {
      {
        signal = { name = "signal-each", type = "virtual" },
        networks = { red = true, green = false }
      },
      {
        signal = { name = "signal-F", type = "virtual" },
        copy_count_from_input = false
      }
    }

    dc_multi_RS_trigger_max:apply_settings(outputs)
  end

  local found = findSpecialEntity("<dc_multi_RS_trigger_max>", { name = { "decider-combinator" } })
  if #found ~= 0 then
    local dc_multi_RS_trigger_max = DeciderC:new(found[1])
    process_dc_multi_RS_trigger_max(dc_multi_RS_trigger_max)
  end

  --#endregion ▲▲ DeciderCombinator

  --#region ▼▼ ConstantCombinator

  local function process_recipes_for_assembling_machine_2(cc)
    local index = Upd.count(1, 1)
    local index_section = cc:add_section("")
    local constant_section = cc:add_section("")
    for recipe_name, _ in pairs(usefull_recipes) do
      index_section:add_signals({ { name = recipe_name, quality = qualities[1], type = "recipe", min = index() } })
      constant_section:add_signals({ { name = recipe_name, quality = qualities[1], type = "recipe", min = offset_hight } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<recipes_for_assembling-machine-2>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_recipes_for_assembling_machine_2(ConstantC:new(found[1]))
  end

  local function process_all_resource_and_empty_barrel_recipes(cc)
    local all_items_section = cc:add_section("")
    for item_name, _ in pairs(global_resource_table.all_items) do
      all_items_section:add_signals({ { name = item_name, quality = qualities[1], min = block_count } })
    end
    local all_fluids_section = cc:add_section("")
    for fluid_name, _ in pairs(global_resource_table.all_fluids) do
      all_fluids_section:add_signals({ { name = fluid_name, quality = qualities[1], min = block_count } })
    end
    local recipes_empty_barrel_section = cc:add_section("")
    for recipe_empty_barrel_name, _ in pairs(global_recipe_table.empty_barrel) do
      recipes_empty_barrel_section:add_signals({ { name = recipe_empty_barrel_name, quality = qualities[1], type = "recipe", min = block_count } })
    end
    local recipes_section = cc:add_section("")
    local ban_recipes_am = Set.D(global_recipe_table.all_assembling_recipes,
      global_recipe_table.machines["assembling-machine-3"])
    for recipe_name, _ in pairs(ban_recipes_am) do
      recipes_section:add_signals({ { name = recipe_name, quality = qualities[1], type = "recipe", min = block_count } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<all_resource_and_empty_barrel_recipes>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_all_resource_and_empty_barrel_recipes(ConstantC:new(found[1]))
  end

  local function process_all_resource_limit(cc)
    local all_resource_am = Set.U(classify_ingredients.exclusively_ingredients,
      classify_ingredients.ingredients_and_products, classify_ingredients.exclusively_products)
    local section = cc:add_section("")
    for resource_name, _ in pairs(all_resource_am) do
      section:add_signals({ { name = resource_name, quality = qualities[1], min = -2 ^ 31 } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<all_resource_limit>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_all_resource_limit(ConstantC:new(found[1]))
  end

  local function process_pure_ingredients(cc)
    local section = cc:add_section("")
    for ingredient_name, _ in pairs(classify_ingredients.exclusively_ingredients) do
      section:add_signals({ { name = ingredient_name, quality = qualities[1], min = -1 * get_stack_size(ingredient_name) } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<pure_ingredients>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_pure_ingredients(ConstantC:new(found[1]))
  end

  local function process_ingredients_and_products(cc)
    local section = cc:add_section("")
    for ingorprod_name, _ in pairs(classify_ingredients.ingredients_and_products) do
      section:add_signals({ { name = ingorprod_name, quality = qualities[1], type = "item", min = -1 * get_stack_size(ingorprod_name) } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<ingredients_and_products>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_ingredients_and_products(ConstantC:new(found[1]))
  end

  local function process_request_for_am2(cc)
    local ingorprod_section = cc:add_section("")
    local product_section = cc:add_section("")
    for ingorprod_name, _ in pairs(classify_ingredients.ingredients_and_products) do
      ingorprod_section:add_signals({ { name = ingorprod_name, quality = qualities[1], type = "item", min = -1 * get_stack_size(ingorprod_name) } })
    end
    for product_name, _ in pairs(classify_ingredients.exclusively_products) do
      product_section:add_signals({ { name = product_name, quality = qualities[1], type = "item", min = -1 * get_stack_size(product_name) } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<request_for_am2>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_request_for_am2(ConstantC:new(found[1]))
  end

  --#region ▼▼▼ Баны сигналов (красный провод - ряды)

  -- Блок банов всего что не относится к допустимым рецептам основной рабочей машины
  local function process_all_ban_resource_and_empty_barrel_recipes(cc)
    local all_items_section = cc:add_section("")
    for item_name, _ in pairs(global_resource_table.all_items) do
      all_items_section:add_signals({ { name = item_name, quality = qualities[1], min = block_count } })
    end

    local all_fluids_section = cc:add_section("")
    for fluid_name, _ in pairs(global_resource_table.all_fluids) do
      all_fluids_section:add_signals({ { name = fluid_name, quality = qualities[1], min = block_count } })
    end

    local barrel_recipe_section = cc:add_section("")
    local barrel_recipes = Set.U(global_recipe_table.fill_barrel, global_recipe_table.empty_barrel)
    for barrel_recipe_name, _ in pairs(barrel_recipes) do
      barrel_recipe_section:add_signals({ { name = barrel_recipe_name, quality = qualities[1], type = "recipe", min = block_count } })
    end

    cc:set_all_signals()
  end

  local found = findSpecialEntity("<all_ban_resource_and_empty_barrel_recipes>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_all_ban_resource_and_empty_barrel_recipes(ConstantC:new(found[1]))
  end

  -- Блок банов всего что не относится к допустимым рецептам машины снабжения жидкостями
  local function process_all_ban_resource_and_recipes(cc)
    local all_items_section = cc:add_section("")
    for item_name, _ in pairs(global_resource_table.all_items) do
      all_items_section:add_signals({ { name = item_name, quality = qualities[1], min = block_count } })
    end

    local all_fluids_section = cc:add_section("")
    for fluid_name, _ in pairs(global_resource_table.all_fluids) do
      all_fluids_section:add_signals({ { name = fluid_name, quality = qualities[1], min = block_count } })
    end

    local ban_recipes_section = cc:add_section("")
    local non_barrel_am3_recipes = Set.D(global_recipe_table.machines["assembling-machine-3"],
      global_recipe_table.empty_barrel)
    for recipe_name, _ in pairs(non_barrel_am3_recipes) do
      ban_recipes_section:add_signals({ { name = recipe_name, quality = qualities[1], type = "recipe", min = block_count } })
    end

    cc:set_all_signals()
  end

  local found = findSpecialEntity("<all_ban_resource_and_recipes>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_all_ban_resource_and_recipes(ConstantC:new(found[1]))
  end

  --#endregion ▲▲▲ Баны сигналов (красный провод - ряды)

  --#region ▼▼▼ Постоянные сигналы

  -- Лимит постаки бочек с жидкостями по жидкости
  local function process_max_liquid_buffer(cc)
    local fluids_max_limit_section = cc:add_section("")
    for fluid_name, _ in pairs(global_resource_table.all_fluids) do
      fluids_max_limit_section:add_signals({ { name = fluid_name, quality = qualities[1], min = -1 * 40 } })
    end

    local all_fluids_section = cc:add_section("")
    for fluid_name, _ in pairs(global_resource_table.all_fluids) do
      all_fluids_section:add_signals({ { name = fluid_name, quality = qualities[1], min = 2 ^ 31 - 1 } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<max_liquid_buffer>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_max_liquid_buffer(ConstantC:new(found[1]))
  end

  -- Индексы жидкостей (легендарные) и рецептов опрожнения бочек
  local function process_all_index_fluid_recipes(cc)
    local index = Upd.count(10, 10)
    local index_fluid_recipes_section = cc:add_section("")
    index_fluid_recipes_section:add_signals({ { name = "signal-liquid", quality = qualities[#qualities], type = "virtual", min = index() } })
    local constant_fluid_recipes_section = cc:add_section("")
    constant_fluid_recipes_section:add_signals({ { name = "signal-liquid", quality = qualities[#qualities], type = "virtual", min = offset_hight / 10 } })
    for fluid_name, _ in pairs(global_resource_table.all_fluids) do
      index_fluid_recipes_section:add_signals({ { name = fluid_name, quality = qualities[#qualities], min = index() } })
      constant_fluid_recipes_section:add_signals({ { name = fluid_name, quality = qualities[#qualities], min = offset_hight / 10 } })
    end

    local index = Upd.count(10, 10)
    local index_empty_barrel_recipes_section = cc:add_section("")
    index_empty_barrel_recipes_section:add_signals({ { name = "signal-B", type = "virtual", quality = qualities[#qualities], min = index() } })
    local constant_empty_barrel_recipes_section = cc:add_section("")
    constant_empty_barrel_recipes_section:add_signals({ { name = "signal-B", type = "virtual", quality = qualities[#qualities], min = offset_hight / 5 } })
    for fluid_name, _ in pairs(global_recipe_table.empty_barrel) do
      index_empty_barrel_recipes_section:add_signals({ { name = fluid_name, type = "recipe", min = index() } })
      constant_empty_barrel_recipes_section:add_signals({ { name = fluid_name, type = "recipe", min = offset_hight / 5 } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<all_index_fluid_recipes>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_all_index_fluid_recipes(ConstantC:new(found[1]))
  end

  -- Постоянный сигнал минимальной вместимости ракеты со знаком минус
  local function process_request_min_rocket_capacity(cc)
    local section = cc:add_section("")
    for item_name, _ in pairs(global_resource_table.all_items) do
      section:add_signals({ { name = item_name, quality = qualities[1], min = -1 * get_min_rocket_stack_size(item_name) } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<request_min_rocket_capacity>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_request_min_rocket_capacity(ConstantC:new(found[1]))
  end
  --#endregion ▲▲▲ Постоянные сигналы

  --#endregion ▲▲ ConstantCombinator

  --#endregion ▲ DC управления авто-ассемблером

  --#region ▼ DeciderCombinator + ConstantCombinator разложение

  local function process_swap_item_recipe(dc)
    for recipe_name, recipe in pairs(usefull_recipes) do
      local recipe_signal = { name = recipe_name, quality = qualities[1], type = "recipe" }
      local main_product_signal = {
        name = recipe.main_product.name,
        quality = qualities[1],
        type = recipe.main_product.type
      }

      local recipe_out = { first_signal = { name = "signal-each" }, second_signal = recipe_signal }

      local main_product = {
        first_signal = main_product_signal,
        constant = 0,
        comparator = "<",
        first_signal_networks = { red = false, green = true },
      }

      local expr = AND(recipe_out, main_product)
      dc:add_expr(expr)
    end
    dc:apply_settings()
  end

  local found = findSpecialEntity("<swap_item_recipe>", { name = { "decider-combinator" } })
  if #found ~= 0 then
    process_swap_item_recipe(DeciderC:new(found[1]))
  end

  local function process_easy_distribution(dc)
    for recipe_name, recipe in pairs(usefull_recipes) do
      local recipe_signal = { name = recipe_name, quality = qualities[1], type = "recipe" }
      local main_product_signal = {
        name = recipe.main_product.name,
        quality = qualities[1],
        type = recipe.main_product.type
      }

      local ingredients = { "or" }
      for _, ingredient in ipairs(recipe.ingredients) do
        local ingredient_signal = { name = ingredient.name, quality = qualities[1], type = ingredient.type }
        local entry = { first_signal = { name = "signal-each" }, second_signal = ingredient_signal }
        table.insert(ingredients, entry)
      end

      local recipe_out = { first_signal = { name = "signal-each" }, second_signal = recipe_signal }

      local check_recipe = {
        first_signal = main_product_signal,
        constant = 0,
        comparator = ">",
        first_signal_networks = { red = false, green = true },
      }

      local expr1 = AND(ingredients, AND(check_recipe))
      dc:add_expr(expr1)

      local expr2 = AND(recipe_out, check_recipe)
      dc:add_expr(expr2)
    end
    dc:apply_settings()
  end

  local found = findSpecialEntity("<easy_distribution>", { name = { "decider-combinator" } })
  if #found ~= 0 then
    process_easy_distribution(DeciderC:new(found[1]))
  end

  local function process_index_list_of_ingredients(cc)
    local index = Upd.count(1, 1)
    local section1 = cc:add_section("")
    for ingredient_name, _ in pairs(classify_ingredients.exclusively_ingredients) do
      section1:add_signals({ { name = ingredient_name, quality = qualities[1], min = index() } })
    end
    local section2 = cc:add_section("")
    for ingorprod_name, _ in pairs(classify_ingredients.ingredients_and_products) do
      section2:add_signals({ { name = ingorprod_name, quality = qualities[1], min = index() } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<index_list_of_ingredients>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_index_list_of_ingredients(ConstantC:new(found[1]))
  end

  local function process_am2_priority_recipes(cc)
    local section1 = cc:add_section("")
    local index = Upd.count(100, 100)
    local section2 = cc:add_section("")
    local recipe_rating_list, recipe_rating_table = get_recipe_rating(usefull_recipes, true)
    for _, recipe_name in ipairs(recipe_rating_list) do
      local score = recipe_rating_table[recipe_name]
      section1:add_signals({ { name = recipe_name, quality = qualities[1], type = "recipe", min = score } })
      section2:add_signals({ { name = recipe_name, quality = qualities[1], type = "recipe", min = index() } })
    end
    cc:set_all_signals()
  end

  local found = findSpecialEntity("<am2_priority_recipes>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_am2_priority_recipes(ConstantC:new(found[1]))
  end

  -- Функция для приоритизации главных продуктов по рейтингу usefull_recipes
  local function process_am2_priority_main_product(cc)
    -- создаём две секции: для рейтинга и для шаговых индексов
    local section1                   = cc:add_section("")  -- секция рейтингов
    local index                      = Upd.count(100, 100) -- генератор 100, 200, 300, …
    local section2                   = cc:add_section("")  -- секция индексов

    -- получаем список рецептов в порядке рейтинга и саму таблицу рейтингов
    local recipe_list, recipe_scores = get_recipe_rating(usefull_recipes, true)

    -- чтобы не дублировать сигналы одинаковых продуктов
    local seen_products              = {}

    for _, recipe_name in ipairs(recipe_list) do
      local recipe = usefull_recipes[recipe_name]
      local prod   = recipe.main_product
      local pname  = prod.name
      local ptype  = prod.type

      if not seen_products[pname] then
        local score = recipe_scores[recipe_name]

        -- секция 1: сигнал главного продукта с min = рейтинг
        section1:add_signals({ {
          name    = pname,
          quality = qualities[1],
          type    = ptype,
          min     = score
        } })

        -- секция 2: сигнал главного продукта с min = шаговый индекс
        section2:add_signals({ {
          name    = pname,
          quality = qualities[1],
          type    = ptype,
          min     = index()
        } })

        seen_products[pname] = true
      end
    end

    -- применяем накопленные сигналы к констант-комбинатору
    cc:set_all_signals()
  end

  -- ищем констант-комбинатор с меткой <am2_priority_main_product> и запускаем обработку
  local found = findSpecialEntity("<am2_priority_main_product>", { name = { "constant-combinator" } })
  if #found ~= 0 then
    process_am2_priority_main_product(ConstantC:new(found[1]))
  end

  --- Обрабатывает три комбинатора:
  --- cc1 и cc2 — констант-комбинаторы, dc — решающий комбинатор
  --- @param cc1 any — первый констант-комбинатор
  --- @param dc  any — решающий комбинатор
  --- @param cc2 any — второй констант-комбинатор
  local function process_three_combinators(cc1, dc, cc2)
    -- 1) Уникализация максимальных количеств ингредиентов для cc1 и cc2
    local max_amounts = get_max_ingredient_amounts(usefull_recipes)

    -- for name, amount in pairs(max_amounts) do
    --   local new_amount_slots = math.ceil((amount * 2 + 20) / get_stack_size(name))
    --   max_amounts[name] = new_amount_slots
    -- end

    local signals = {}
    for name, amount in pairs(max_amounts) do
      table.insert(signals, { name = name, value = amount })
    end
    local unique_signals, shifts = uniquify_signal_values(signals)

    -- Секция 1: уникальные значения в cc1
    local section1 = cc1:add_section("")
    local entries1 = {}
    for _, sig in ipairs(unique_signals) do
      table.insert(entries1, {
        name    = sig.name,
        type    = get_type(sig.name),
        quality = qualities[1],
        min     = sig.value
      })
    end
    section1:add_signals(entries1)
    cc1:set_all_signals()

    -- 2) Заполнение dc условиями по рецептам и ингредиентам
    for recipe_name, recipe in pairs(global_recipe_table.usefull_recipes) do
      local cond_recipe = {
        first_signal = { name = recipe_name, type = "recipe" },
        comparator   = ">",
        constant     = 0
      }
      for _, ing in ipairs(recipe.ingredients or {}) do
        local cond_ing = {
          first_signal  = { name = "signal-each", type = "virtual" },
          second_signal = { name = ing.name, type = ing.type },
          comparator    = "="
        }
        dc:add_expr(AND(cond_ing, cond_recipe))
      end
    end
    dc:apply_settings()

    -- 3) Секция 2: сдвиги в cc2 (отрицательные, чтобы вернуть смещение)
    local section2 = cc2:add_section("")
    local entries2 = {}
    for name, shift in pairs(shifts) do
      table.insert(entries2, {
        name    = name,
        type    = get_type(name),
        quality = qualities[1],
        min     = -shift
      })
    end
    section2:add_signals(entries2)
    cc2:set_all_signals()
  end

  local cc1_found = findSpecialEntity("<combinator_1>", { name = { "constant-combinator" } })
  local dc_found  = findSpecialEntity("<combinator_2>", { name = { "decider-combinator" } })
  local cc2_found = findSpecialEntity("<combinator_3>", { name = { "constant-combinator" } })
  if #cc1_found > 0 and #dc_found > 0 and #cc2_found > 0 then
    local cc1 = ConstantC:new(cc1_found[1])
    local dc  = DeciderC:new(dc_found[1])
    local cc2 = ConstantC:new(cc2_found[1])
    process_three_combinators(cc1, dc, cc2)
  end

  -- Обрабатывает Decider Combinator <multi_energy>
  -- @param dc DeciderC — обёртка для LuaEntity
  local function process_multi_energy(dc)
    for recipe_name, recipe in pairs(usefull_recipes) do
      local cond_energy = {
        first_signal          = { name = "signal-each", type = "virtual", quality = qualities[1] },
        comparator            = "=",
        constant              = (get_total_ingredients_count(recipe) > 500) and 1 or math.ceil(1 / recipe.energy * 10),
        first_signal_networks = { red = true, green = false }
      }
      local cond_exist = {
        first_signal          = { name = recipe_name, type = "recipe", quality = qualities[1] },
        comparator            = ">",
        constant              = 0,
        first_signal_networks = { red = false, green = true }
      }
      dc:add_expr(AND(cond_energy, cond_exist))
    end

    dc:apply_settings({
      {
        signal   = { name = "signal-M", type = "virtual" },
        networks = { red = true, green = false }
      }
    })
  end

  -- Поиск и запуск обработки
  local found = findSpecialEntity("<multi_energy>", { name = { "decider-combinator" } })
  if #found > 0 then
    process_multi_energy(DeciderC:new(found[1]))
  end

  -- Заполняет Constant Combinator с рейтингом для каждого рецепта (создано по заказу Denisk)
  -- Рейтинг = слоты - кол-во уникальных item-ингредиентов, сортировка по возрастанию
  local function process_load_rating_for_each_recipe(cc)
    local rating_list = {} -- { { name = "recipe-name", rating = N }, ... }

    for recipe_name, recipe in pairs(usefull_recipes) do
      local slot_count = calculate_ingredient_slot_usage(recipe, 2, 20)

      -- Подсчёт уникальных item-ингредиентов
      local unique_items = {}
      if recipe.ingredients then
        for _, ing in ipairs(recipe.ingredients) do
          if ing.type == "item" then
            unique_items[ing.name] = true
          end
        end
      end
      local item_types_count = 0
      for _ in pairs(unique_items) do
        item_types_count = item_types_count + 1
      end

      -- Окончательный рейтинг
      local adjusted_rating = slot_count - item_types_count * 0
      table.insert(rating_list, { name = recipe_name, rating = adjusted_rating })
    end

    -- Сортируем по возрастанию рейтинга
    table.sort(rating_list, function(a, b)
      return a.rating < b.rating
    end)

    -- Создаём секцию и добавляем отсортированные сигналы
    local section = cc:add_section("")
    for _, entry in ipairs(rating_list) do
      section:add_signals({
        {
          name    = entry.name,
          quality = qualities[1],
          -- type    = "recipe",
          min     = entry.rating
        }
      })
    end

    cc:set_all_signals()
  end

  local found = findSpecialEntity("<load_rating_for_each_recipe>", { name = { "constant-combinator" } })
  if #found > 0 then
    process_load_rating_for_each_recipe(ConstantC:new(found[1]))
  end

  --#region ▼▼ Постоянный комбинатор: максимальные значения ингредиентов

  --- Обрабатывает постоянный комбинатор <max_ingredient_amounts> (создано по заказу Denisk)
  --- Добавляет сигналы с максимальными значениями всех ингредиентов из usefull_recipes
  local function process_max_ingredient_amounts(cc)
    local max_amounts = get_max_ingredient_amounts(usefull_recipes)

    -- for name, amount in pairs(max_amounts) do
    --   local new_amount_slots = math.ceil((amount * 2 + 20) / get_stack_size(name))
    --   max_amounts[name] = new_amount_slots
    -- end

    local section = cc:add_section("")

    for name, amount in pairs(max_amounts) do
      section:add_signals({
        {
          name    = name,
          type    = get_type(name),
          quality = qualities[1],
          min     = amount
        }
      })
    end

    cc:set_all_signals()
  end

  -- Поиск комбинатора по метке и применение функции
  local found = findSpecialEntity("<max_ingredient_amounts>", { name = { "constant-combinator" } })
  if #found > 0 then
    process_max_ingredient_amounts(ConstantC:new(found[1]))
  end

  --#endregion ▲▲ Постоянный комбинатор: максимальные значения ингредиентов

  --- Обрабатывает комбинатор с меткой <max_ingredient_slots> (создано по заказу Denisk)
  --- Добавляет в него количество слотов, которое бы заняли max-ингредиенты
  ---@param cc any
  local function process_max_ingredient_slots(cc)
    -- Получаем таблицу вида { [item_name] = max_amount }
    local max_amounts = get_max_ingredient_amounts(usefull_recipes)

    -- Подсчитываем слоты только для предметов (исключаем жидкости)
    local transformed = {} ---@type { name: string, slots: integer }[]
    for name, amount in pairs(max_amounts) do
      if get_type(name) == "item" then
        local stack_size = get_stack_size(name)
        local adjusted = amount * 2 + math.min(stack_size, 20)
        local slots = math.ceil(adjusted / stack_size)
        table.insert(transformed, { name = name, slots = slots })
      end
    end

    -- Сортировка по возрастанию количества слотов
    table.sort(transformed, function(a, b)
      return a.slots < b.slots
    end)

    -- Добавляем в комбинатор
    local section = cc:add_section("")
    for _, entry in ipairs(transformed) do
      section:add_signals({
        {
          name    = entry.name,
          quality = qualities[1],
          min     = entry.slots
        }
      })
    end

    cc:set_all_signals()
  end

  local found = findSpecialEntity("<max_ingredient_slots>", { name = { "constant-combinator" } })
  if #found > 0 then
    process_max_ingredient_slots(ConstantC:new(found[1]))
  end

  --#endregion ▲ DeciderCombinator + ConstantCombinator разложение


  --#region ▼ Тест 13 - упрощённый тест компаратора "any" (<test_any_comp_storage>)

  do
    local found = findSpecialEntity("<test_any_comp_storage>", { name = { "requester-chest" } })
    if #found > 0 then
      -- создаём новый RequestC без загрузки старых секций
      local request = RequestC:new(found[1])
      -- создаём секцию с меткой для проверки any
      local section = request:add_section("<test_any_comp_storage>")
      -- добавляем несколько сигналов с компаратором "any"
      section:add_signal { name = "iron-plate", type = "item", comparator = ">", quality = qualities[1], min = 0 }
      section:add_signal { name = "copper-plate", type = "item", comparator = "any", min = 0 }
      -- применяем в сундук
      request:apply()
    end
  end
  --#endregion ▲ Тест 13

  --#region ▼▼ Тест ? - Сценарий 4 с интеграцией Chest → SectionRC → RequestC

  -- do
  --   -- 1. Находим реальные сундуки по меткам
  --   local found1 = findSpecialEntity("<chest1>", { name = { "requester-chest" } })
  --   local found2 = findSpecialEntity("<chest2>", { name = { "requester-chest" } })
  --   if #found1 == 0 or #found2 == 0 then
  --     game.print("Не найдены оба сундука для сценария 4")
  --     return
  --   end

  --   -- 2. Создаём симуляторы вместимости
  --   local chest1 = Chest:new(found1[1])
  --   local chest2 = Chest:new(found2[1])

  --   -- 3. Циклически заполняем по 10 штук каждого предмета в оба симулятора
  --   local anySucceeded
  --   repeat
  --     anySucceeded = false
  --     for name in pairs(global_resource_table.all_items) do
  --       local rem1 = chest1:add(name, 10)
  --       local rem2 = chest2:add(name, 10)
  --       if rem1 < 10 or rem2 < 10 then
  --         anySucceeded = true
  --       end
  --     end
  --   until not anySucceeded

  --   -- 4. Переносим симулированные запросы в реальный сундук через RequestC/SectionRC

  --   -- 4.1 Первый сундук
  --   local req1     = RequestC:new(found1[1], false)
  --   local section1 = req1:add_section("<chest1_signals>")
  --   for name, _ in pairs(global_resource_table.all_items) do
  --     local full    = chest1.filled[name] or 0
  --     local partial = chest1.partial[name] or 0
  --     local S       = chest1.stack_size[name] or prototypes.item[name].stack_size
  --     local total   = full * S + partial
  --     section1:add_signal {
  --       name = name,
  --       type = "item",
  --       min  = total
  --     }
  --   end
  --   req1:apply()

  --   -- 4.2 Второй сундук
  --   local req2     = RequestC:new(found2[1], false)
  --   local section2 = req2:add_section("<chest2_signals>")
  --   for name, _ in pairs(global_resource_table.all_items) do
  --     local full    = chest2.filled[name] or 0
  --     local partial = chest2.partial[name] or 0
  --     local S       = chest2.stack_size[name] or prototypes.item[name].stack_size
  --     local total   = full * S + partial
  --     section2:add_signal {
  --       name = name,
  --       type = "item",
  --       min  = total
  --     }
  --   end
  --   req2:apply()

  --   game.print("Сценарий 4: сигналы из Chest перенесены в реальные сундуки")
  -- end

  --#endregion ▲▲ Тест ?

  game.print("Hi, i'm script!")
end

-- return main
main()
