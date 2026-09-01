require "BanditCompatibility"
require "BanditFS"

EugenesBanditsCompatibility = EugenesBanditsCompatibility or {}

local M = EugenesBanditsCompatibility

local function serialize(value, indent)
    indent = indent or ""
    local valueType = type(value)

    if valueType == "number" or valueType == "boolean" then
        return tostring(value)
    elseif valueType == "string" then
        return string.format("%q", value)
    elseif valueType ~= "table" then
        error("Cannot serialize BanditFS type: " .. valueType)
    end

    local nextIndent = indent .. "  "
    local lines = { "{" }
    for key, entry in pairs(value) do
        local serializedKey
        if type(key) == "string" and key:match("^[_%a][_%w]*$") then
            serializedKey = key
        else
            serializedKey = "[" .. serialize(key, nextIndent) .. "]"
        end
        lines[#lines + 1] = nextIndent .. serializedKey .. " = "
            .. serialize(entry, nextIndent) .. ","
    end
    lines[#lines + 1] = indent .. "}"
    return table.concat(lines, "\n")
end

local function deserialize(source)
    local position = 1
    local length = #source

    local function fail(message)
        error("Invalid BanditFS data at byte " .. tostring(position) .. ": " .. message)
    end

    local function skipWhitespace()
        while position <= length and source:sub(position, position):match("%s") do
            position = position + 1
        end
    end

    local function consume(expected)
        skipWhitespace()
        if source:sub(position, position + #expected - 1) ~= expected then
            fail("expected " .. expected)
        end
        position = position + #expected
    end

    local parseValue

    local function parseString()
        local quote = source:sub(position, position)
        position = position + 1
        local output = {}

        while position <= length do
            local character = source:sub(position, position)
            position = position + 1
            if character == quote then return table.concat(output) end

            if character ~= "\\" then
                output[#output + 1] = character
            else
                if position > length then fail("unfinished string escape") end
                local escaped = source:sub(position, position)
                position = position + 1
                local replacements = {
                    a = "\a", b = "\b", f = "\f", n = "\n",
                    r = "\r", t = "\t", v = "\v",
                    ["\\"] = "\\", ['"'] = '"', ["'"] = "'",
                }
                if replacements[escaped] then
                    output[#output + 1] = replacements[escaped]
                elseif escaped:match("%d") then
                    local digits = escaped
                    for _ = 1, 2 do
                        local nextCharacter = source:sub(position, position)
                        if not nextCharacter:match("%d") then break end
                        digits = digits .. nextCharacter
                        position = position + 1
                    end
                    local byte = tonumber(digits)
                    if not byte or byte > 255 then fail("invalid decimal string escape") end
                    output[#output + 1] = string.char(byte)
                elseif escaped == "z" then
                    skipWhitespace()
                elseif escaped == "\n" then
                    output[#output + 1] = "\n"
                else
                    fail("unsupported string escape \\" .. escaped)
                end
            end
        end
        fail("unterminated string")
    end

    local function parseTable()
        consume("{")
        local result = {}
        while true do
            skipWhitespace()
            if source:sub(position, position) == "}" then
                position = position + 1
                return result
            end

            local key
            if source:sub(position, position) == "[" then
                position = position + 1
                key = parseValue()
                consume("]")
            else
                local identifier = source:sub(position):match("^([_%a][_%w]*)")
                if not identifier then fail("expected a table key") end
                key = identifier
                position = position + #identifier
            end
            consume("=")
            result[key] = parseValue()

            skipWhitespace()
            local separator = source:sub(position, position)
            if separator == "," or separator == ";" then
                position = position + 1
            elseif separator ~= "}" then
                fail("expected a table separator or closing brace")
            end
        end
    end

    parseValue = function()
        skipWhitespace()
        local character = source:sub(position, position)
        if character == "{" then return parseTable() end
        if character == '"' or character == "'" then return parseString() end

        local remaining = source:sub(position)
        if remaining:sub(1, 4) == "true"
            and not remaining:sub(5, 5):match("[_%w]") then
            position = position + 4
            return true
        end
        if remaining:sub(1, 5) == "false"
            and not remaining:sub(6, 6):match("[_%w]") then
            position = position + 5
            return false
        end

        local numberText = remaining:match("^([+-]?%d+%.?%d*[eE]?[+-]?%d*)")
        local number = numberText and tonumber(numberText) or nil
        if number then
            position = position + #numberText
            return number
        end
        fail("expected a value")
    end

    local result = parseValue()
    skipWhitespace()
    if position <= length then fail("unexpected trailing data") end
    return result
end

if not M.banditFSPatched then
    BanditFS.Write = function(resourceId, data)
        local fileName = tostring(resourceId) .. ".bfs"
        local fileFull = BanditCompatibility.GetConfigPath() .. fileName
        local writer = getFileWriter(fileFull, true, false)
        if not writer then
            return false, "could not open " .. fileFull .. " for writing"
        end
        writer:write(serialize(data))
        writer:close()
        return true
    end

    BanditFS.Read = function(resourceId)
        local fileName = tostring(resourceId) .. ".bfs"
        local fileFull = BanditCompatibility.GetConfigPath() .. fileName
        local reader = getFileReader(fileFull, false)
        if not reader then return nil end

        local lines = {}
        while true do
            local line = reader:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
        reader:close()
        if #lines == 0 then return nil end
        return deserialize(table.concat(lines, "\n"))
    end

    M.banditFSPatched = true
end
