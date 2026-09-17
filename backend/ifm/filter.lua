-- IFM :: ifm/filter.lua
-- 过滤器求值模块。
--
-- 规则类型（对应 task 第 8 条）：
--   item_include / item_exclude      {id = "mod:item",  ignoreNbt = bool}
--   fluid_include / fluid_exclude    {id = "mod:fluid", ignoreNbt = bool}
--   itemTag_include / itemTag_exclude   {id = "c:ores/gold"}
--   fluidTag_include / fluidTag_exclude {id = "c:water"}
--   filter_include / filter_exclude  {id = "<其它过滤器名称>"}
--
-- 语义：
--   * 只要过滤器内存在任意一条“包含”规则，则资源必须命中至少一条包含规则；
--   * 若过滤器内没有任何“包含”规则，则视为“默认包含一切”；
--   * 任何一条“排除”规则命中，则最终不匹配；
--   * 引用其它过滤器时递归求值，带访问栈保护，最大深度超限视为不匹配。

local Filter = {}
Filter.__index = Filter

local INCLUDE_TYPES = {
    item_include = true,
    fluid_include = true,
    itemTag_include = true,
    fluidTag_include = true,
    filter_include = true,
}

function Filter.isIncludeRule(ruleType)
    return INCLUDE_TYPES[ruleType] == true
end

function Filter.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Filter)
    self.Util = opts.Util
    self.Store = opts.Store
    self.maxDepth = opts.maxDepth or 16
    -- 标签提供者：返回 { [tag] = true } 或 { tag, ... }；缺省时标签规则不命中
    self.tagProvider = opts.tagProvider
    return self
end

--- NBT 相等语义：忽略 NBT 时由调用方直接返回 true；
--- 否则要求两边“同时没有 NBT”或“NBT 哈希相等”
function Filter.nbtEquals(expected, actual)
    expected = expected or ""
    actual = actual or ""
    return expected == actual
end

--- 取某个资源的标签集合（来自按需扫描并持久化的缓存）
function Filter:tagsOf(name)
    if not name or not self.tagProvider then
        return nil
    end
    return self.tagProvider(name)
end

--- 标签集合既可能是 {tag = true} 也可能是 {tag, ...}
local function hasTag(tags, tag)
    if type(tags) ~= "table" then
        return false
    end
    if tags[tag] == true then
        return true
    end
    for _, v in pairs(tags) do
        if v == tag then
            return true
        end
    end
    return false
end

--- 单条规则是否命中资源
function Filter:ruleMatches(rule, resource, seen, depth)
    if type(rule) ~= "table" then
        return false
    end
    local ruleType = rule.type
    local kind = resource.kind
    if ruleType == "item_include" or ruleType == "item_exclude" then
        if kind ~= "item" or resource.name ~= rule.id then
            return false
        end
        if rule.ignoreNbt then
            return true
        end
        return Filter.nbtEquals(rule.nbt, resource.nbt)
    elseif ruleType == "fluid_include" or ruleType == "fluid_exclude" then
        if kind ~= "fluid" or resource.name ~= rule.id then
            return false
        end
        if rule.ignoreNbt then
            return true
        end
        return Filter.nbtEquals(rule.nbt, resource.nbt)
    elseif ruleType == "itemTag_include" or ruleType == "itemTag_exclude" then
        if kind ~= "item" then
            return false
        end
        return hasTag(resource.tags or self:tagsOf(resource.name), rule.id)
    elseif ruleType == "fluidTag_include" or ruleType == "fluidTag_exclude" then
        if kind ~= "fluid" then
            return false
        end
        return hasTag(resource.tags or self:tagsOf(resource.name), rule.id)
    elseif ruleType == "filter_include" or ruleType == "filter_exclude" then
        return self:matches(rule.id, resource, seen, depth + 1)
    end
    return false
end

--- 资源是否符合指定名称的过滤器
-- resource = {kind = "item"|"fluid", name = string, nbt = string|nil, tags = table|nil}
function Filter:matches(filterName, resource, seen, depth)
    if type(resource) ~= "table" or not resource.kind or not resource.name then
        return false
    end
    local filter = self.Store:get("filters", filterName)
    if not filter then
        return false
    end
    seen = seen or {}
    depth = depth or 0
    if depth > self.maxDepth then
        return false
    end
    if seen[filterName] then
        return false
    end
    seen[filterName] = true
    local hasInclude, matched, excluded = false, false, false
    for _, rule in ipairs(filter.rules or {}) do
        local isInclude = Filter.isIncludeRule(rule.type)
        if isInclude then
            hasInclude = true
        end
        if self:ruleMatches(rule, resource, seen, depth) then
            if isInclude then
                matched = true
            else
                excluded = true
            end
        end
    end
    seen[filterName] = nil
    if not hasInclude then
        matched = true
    end
    return matched and not excluded
end

--- 资源是否符合“物品名/流体名/过滤器名”的输入描述
-- spec = {kind = "item"|"fluid"|"filter", id = string, nbt = string|nil, ignoreNbt = boolean|nil}
-- ignoreNbt 缺省（nil）视为忽略 NBT；显式 false 时要求 NBT 相等
function Filter:specMatches(spec, resource)
    if type(spec) ~= "table" then
        return false
    end
    if spec.kind == "filter" then
        return self:matches(spec.id, resource)
    end
    if spec.kind ~= resource.kind or spec.id ~= resource.name then
        return false
    end
    if spec.ignoreNbt == false then
        return Filter.nbtEquals(spec.nbt, resource.nbt)
    end
    return true
end

return Filter
