local A = {}

A.TRACEBACK = false

local function messageOf(first, ...)
    if select("#", ...) == 0 then
        return tostring(first)
    end
    return string.format(first, ...)
end

function A.is(cond, first, ...)
    if cond then
        return cond
    end
    local msg = messageOf(first, ...)
    if A.TRACEBACK then
        msg = msg .. "\n" .. debug.traceback("", 2)
    end
    error(msg, 2)
end

function A.field(t, name, kind)
    A.is(type(t) == "table", "expected a table when reading field '%s'", tostring(name))
    local value = t[name]
    A.is(value ~= nil, "missing field '%s'", tostring(name))
    if kind ~= nil then
        A.is(type(value) == kind, "field '%s' must be a %s, got %s", tostring(name), tostring(kind),
            type(value))
    end
    return value
end

function A.number(value, name)
    A.is(value ~= nil, "missing number '%s'", tostring(name))
    A.is(type(value) == "number", "'%s' must be a number, got %s", tostring(name), type(value))
    return value
end

function A.integer(value, name)
    A.number(value, name)
    A.is(value == math.floor(value), "'%s' must be an integer, got %s", tostring(name), tostring(value))
    return value
end

function A.count(value, name)
    A.integer(value, name)
    A.is(value >= 0, "'%s' must not be negative, got %s", tostring(name), tostring(value))
    return value
end

function A.positive(value, name)
    A.integer(value, name)
    A.is(value > 0, "'%s' must be > 0, got %s", tostring(name), tostring(value))
    return value
end

function A.string(value, name)
    A.is(value ~= nil, "missing string '%s'", tostring(name))
    A.is(type(value) == "string", "'%s' must be a string, got %s", tostring(name), type(value))
    A.is(value ~= "", "'%s' must not be empty", tostring(name))
    return value
end

function A.boolean(value, name)
    A.is(type(value) == "boolean", "'%s' must be a boolean, got %s", tostring(name), type(value))
    return value
end

function A.list(value, name)
    A.is(type(value) == "table", "'%s' must be a table, got %s", tostring(name), type(value))
    A.is(#value > 0, "'%s' must not be empty", tostring(name))
    return value
end

function A.protocol(message, op)
    A.is(type(message) == "table", "protocol message must be a table, got %s", type(message))
    A.is(message.op == op, "protocol message op must be '%s', got %s", tostring(op),
        tostring(message.op))
    return message
end

function A.optNumber(value, name)
    if value ~= nil then
        return A.number(value, name)
    end
    return nil
end

function A.optString(value, name)
    if value ~= nil then
        return A.string(value, name)
    end
    return nil
end

return A
