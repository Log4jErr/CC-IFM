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
    self.tagProvider = opts.tagProvider
    -- A revision provider turns the containment memoisation into a cache that is
    -- dropped whenever the definitions (or the tag table) change. Without one the
    -- engine falls back to computing every answer, which is always correct.
    self.revisionProvider = opts.revisionProvider
    self.revisionKey = nil
    self.dnfCache = {}
    self.subsetCache = {}
    self.subsetActive = {}
    return self
end

function Filter.nbtEquals(expected, actual)
    expected = expected or ""
    actual = actual or ""
    return expected == actual
end

function Filter:tagsOf(name)
    if not name or not self.tagProvider then
        return nil
    end
    return self.tagProvider(name)
end

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

-- ---------------------------------------------------------------------------
-- Filter containment (subset) via disjunctive normal form.
--
-- A filter is a predicate over resources:
--     F(r) = (I_1 or ... or I_n) and not X_1 and ... and not X_m
-- with I the include rules and X the exclude rules (no include rule means
-- "include everything"). Distributing the conjunction over the disjunction gives
-- its DNF: one term per include rule, each carrying every exclude as a negative
-- literal. A term is { pos = {literal...}, neg = {literal...} }; a literal is one
-- minimal element - include/exclude of an item/fluid (by id) or of a tag.
-- Nested filter_include rules are expanded recursively while a filter_exclude
-- stays one opaque "not (that filter)" literal. Two filters are then compared
-- term by term: A is a subset of B when every term of A is covered by some term
-- of B.
-- ---------------------------------------------------------------------------

local function literalOfRule(rule)
    local kind, literalType
    if rule.type == "item_include" or rule.type == "item_exclude" then
        kind, literalType = "item", "item"
    elseif rule.type == "fluid_include" or rule.type == "fluid_exclude" then
        kind, literalType = "fluid", "item"
    elseif rule.type == "itemTag_include" or rule.type == "itemTag_exclude" then
        kind, literalType = "item", "tag"
    elseif rule.type == "fluidTag_include" or rule.type == "fluidTag_exclude" then
        kind, literalType = "fluid", "tag"
    elseif rule.type == "filter_include" or rule.type == "filter_exclude" then
        kind, literalType = "filter", "filter"
    else
        return nil
    end
    return {
        kind = kind,
        type = literalType,
        id = rule.id,
        nbt = rule.nbt,
        ignoreNbt = rule.ignoreNbt and true or false,
    }
end

local function appendLiterals(dst, src)
    for _, literal in ipairs(src or {}) do
        dst[#dst + 1] = literal
    end
end

-- The revision key drops both caches when the store or the tag table changed, so
-- editing a filter invalidates every memoised answer at once.
function Filter:cacheKey()
    if type(self.revisionProvider) ~= "function" then
        return nil
    end
    local key = self.revisionProvider()
    if key ~= self.revisionKey then
        self.revisionKey = key
        self.dnfCache = {}
        self.subsetCache = {}
    end
    return key
end

function Filter:invalidate()
    self.revisionKey = nil
    self.dnfCache = {}
    self.subsetCache = {}
    self.subsetActive = {}
end

-- region(l2) is contained in region(l1) for two *positive* literals: every
-- resource matching l2 also matches l1.
function Filter:literalImplies(l2, l1)
    if type(l2) ~= "table" or type(l1) ~= "table" then
        return false
    end
    if l2.type == "filter" or l1.type == "filter" then
        if l2.type == "filter" and l1.type == "filter" then
            return l2.id == l1.id or self:isSubsetOf(l2.id, l1.id)
        end
        return false
    end
    if l2.kind ~= l1.kind then
        return false
    end
    if l1.type == "item" then
        if l2.type ~= "item" or l2.id ~= l1.id then
            return false
        end
        if l1.ignoreNbt then
            return true
        end
        if l2.ignoreNbt then
            return false
        end
        return (l2.nbt or "") == (l1.nbt or "")
    end
    if l1.type == "tag" then
        if l2.type == "item" then
            return hasTag(self:tagsOf(l2.id), l1.id)
        end
        if l2.type == "tag" then
            return l2.id == l1.id
        end
    end
    return false
end

-- region(l2) and region(l1) cannot both match one resource. Unknown tag pairs
-- answer "false" on purpose: two tags may share members.
function Filter:literalDisjoint(l2, l1)
    if type(l2) ~= "table" or type(l1) ~= "table" then
        return false
    end
    if l2.type == "filter" or l1.type == "filter" then
        return false
    end
    if l2.kind ~= l1.kind then
        return true
    end
    if l2.type == "item" and l1.type == "item" then
        if l2.id ~= l1.id then
            return true
        end
        if l2.ignoreNbt or l1.ignoreNbt then
            return false
        end
        return (l2.nbt or "") ~= (l1.nbt or "")
    end
    local item, tag
    if l2.type == "item" and l1.type == "tag" then
        item, tag = l2, l1
    elseif l2.type == "tag" and l1.type == "item" then
        item, tag = l1, l2
    end
    if item then
        return not hasTag(self:tagsOf(item.id), tag.id)
    end
    return false
end

-- Negative literals: "neg1 (not P) is at least as strong as neg2 (not Q)" when
-- every resource matching Q also matches P.
function Filter:negativeImplies(neg1, neg2)
    return self:literalImplies(neg2, neg1)
end

-- region(term) is contained in region(other).
function Filter:termSubset(term, other)
    for _, positive in ipairs(other.pos or {}) do
        local ok = false
        for _, mine in ipairs(term.pos or {}) do
            if self:literalImplies(mine, positive) then
                ok = true
                break
            end
        end
        if not ok then
            return false
        end
    end
    for _, negative in ipairs(other.neg or {}) do
        local covered = false
        for _, mine in ipairs(term.neg or {}) do
            if self:negativeImplies(mine, negative) then
                covered = true
                break
            end
        end
        if not covered then
            local pos = term.pos or {}
            if #pos == 0 then
                return false
            end
            for _, mine in ipairs(pos) do
                if not self:literalDisjoint(negative, mine) then
                    return false
                end
            end
        end
    end
    return true
end

-- A term contained in another term of the same disjunction adds nothing.
function Filter:absorbTerms(terms)
    if #terms <= 1 then
        return terms
    end
    local drop = {}
    for i = 1, #terms do
        for j = 1, #terms do
            if i ~= j and not drop[j] and self:termSubset(terms[i], terms[j]) then
                if not self:termSubset(terms[j], terms[i]) or j < i then
                    drop[i] = true
                    break
                end
            end
        end
    end
    local kept = {}
    for i = 1, #terms do
        if not drop[i] then
            kept[#kept + 1] = terms[i]
        end
    end
    if #kept == 0 then
        return { terms[1] }
    end
    return kept
end

-- The DNF terms of a filter. nil when the filter does not exist; a cycle stops
-- expanding and contributes nothing, matching Filter:matches (which refuses to
-- revisit a filter name).
function Filter:dnfTerms(name, seen, depth)
    local filter = self.Store:get("filters", name)
    if not filter then
        return nil
    end
    seen = seen or {}
    depth = depth or 0
    if depth > self.maxDepth or seen[name] then
        return {}
    end
    seen[name] = true
    local includes, excludes = {}, {}
    for _, rule in ipairs(filter.rules or {}) do
        if Filter.isIncludeRule(rule.type) then
            includes[#includes + 1] = rule
        else
            local literal = literalOfRule(rule)
            if literal then
                excludes[#excludes + 1] = literal
            end
        end
    end
    local terms = {}
    if #includes == 0 then
        local term = { pos = {}, neg = {} }
        appendLiterals(term.neg, excludes)
        terms[1] = term
    else
        for _, rule in ipairs(includes) do
            if rule.type == "filter_include" then
                local nested = self:dnfTerms(rule.id, seen, depth + 1)
                for _, nestedTerm in ipairs(nested or {}) do
                    local term = { pos = {}, neg = {} }
                    appendLiterals(term.pos, nestedTerm.pos)
                    appendLiterals(term.neg, nestedTerm.neg)
                    appendLiterals(term.neg, excludes)
                    terms[#terms + 1] = term
                end
            else
                local literal = literalOfRule(rule)
                if literal then
                    local term = { pos = { literal }, neg = {} }
                    appendLiterals(term.neg, excludes)
                    terms[#terms + 1] = term
                end
            end
        end
    end
    seen[name] = nil
    return self:absorbTerms(terms)
end

function Filter:dnf(name)
    local key = self:cacheKey()
    if key then
        local cached = self.dnfCache[name]
        if cached ~= nil then
            return cached
        end
    end
    local terms = self:dnfTerms(name)
    if key and terms ~= nil then
        self.dnfCache[name] = terms
    end
    return terms
end

function Filter:computeSubset(subName, superName)
    local subTerms = self:dnf(subName)
    local superTerms = self:dnf(superName)
    if not subTerms or not superTerms then
        return false
    end
    for _, subTerm in ipairs(subTerms) do
        local covered = false
        for _, superTerm in ipairs(superTerms) do
            if self:termSubset(subTerm, superTerm) then
                covered = true
                break
            end
        end
        if not covered then
            return false
        end
    end
    return true
end

-- "Every resource matching subName also matches superName." The answer is
-- memoised per (store revision, tag revision); editing either filter drops the
-- cache. The re-entrancy guard keeps a self-referential pair from looping.
function Filter:isSubsetOf(subName, superName)
    if type(subName) ~= "string" or type(superName) ~= "string"
        or subName == "" or superName == "" then
        return false
    end
    if subName == superName then
        return true
    end
    local key = self:cacheKey()
    local pair = subName .. "\1" .. superName
    if key then
        local cached = self.subsetCache[pair]
        if cached ~= nil then
            return cached
        end
    end
    if self.subsetActive[pair] then
        return false
    end
    self.subsetActive[pair] = true
    local result = self:computeSubset(subName, superName)
    self.subsetActive[pair] = nil
    if key then
        self.subsetCache[pair] = result
    end
    return result
end

return Filter
