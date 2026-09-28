--[[
control_bundle.lua — Single-file Control.json manager.

The default configuration is EMBEDDED below, so this file works standalone.
Optionally loads/saves an external Control.json:
  - Roblox executor environments: uses readfile / writefile if available
  - Plain Lua: uses io.open

Usage (plain Lua CLI):
    lua control_bundle.lua              -- show embedded config summary
    lua control_bundle.lua path.json    -- load external file, show summary

Library usage:
    local control = require("control_bundle")
    control.load()                      -- external file, or embedded fallback
    control.ids_for_profile(rules, "Profile 1")
    control.save(rules, "Control.json") -- write rules back out as JSON
]]

local Control = {}

----------------------------------------------------------------------
-- Embedded default configuration (from Control.json)
----------------------------------------------------------------------

local DEFAULT_CONFIG = {
    ["replacement_rules"] = {
        {
            ["name"] = "Profile 1",
            ["replace_ids"] = {
                130002991386896
            },
            ["mode"] = "id",
            ["enabled"] = true
        },
        {
            ["name"] = "Profile 2",
            ["replace_ids"] = {
                135584181153647,
                108802825433341
            },
            ["mode"] = "id",
            ["enabled"] = true
        }
    }
}

----------------------------------------------------------------------
-- Minimal JSON encoder (for saving rules back to disk)
----------------------------------------------------------------------

local function encode_json(value)
    local t = type(value)
    if t == "nil" then return "null" end
    if t == "boolean" then return tostring(value) end
    if t == "number" then
        if value % 1 == 0 and math.abs(value) < 2^53 then
            return string.format("%d", value)
        end
        return tostring(value)
    end
    if t == "string" then
        return string.format("%q", value)
    end
    if t == "table" then
        -- decide array vs object
        local maxn, count = 0, 0
        for k in pairs(value) do
            count = count + 1
            if type(k) == "number" and k > maxn then maxn = k end
        end
        local parts = {}
        if maxn == count and count > 0 then
            for i = 1, maxn do
                parts[i] = encode_json(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(value) do
                if type(k) ~= "string" then
                    error("ControlFileError: object keys must be strings when saving", 0)
                end
                parts[#parts + 1] = string.format("%q", k) .. ":" .. encode_json(v)
            end
            table.sort(parts)
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    error("ControlFileError: cannot encode type " .. t, 0)
end

----------------------------------------------------------------------
-- Minimal JSON decoder (bundled fallback; prefers lunajson/dkjson)
----------------------------------------------------------------------

local function decode_json(src)
    local pos, len = 1, #src

    local parse_value
    local function error_at(msg)
        error(("ControlFileError: JSON parse error at byte %d: %s"):format(pos, msg), 0)
    end
    local function skip_ws()
        while pos <= len do
            local c = src:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
        end
    end

    local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                      b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

    local function parse_string()
        pos = pos + 1
        local start = pos
        while pos <= len do
            local c = src:sub(pos, pos)
            if c == '"' then
                local raw = src:sub(start, pos - 1)
                pos = pos + 1
                return (raw:gsub("\\(.)", function(e)
                    local v = escapes[e]
                    if not v then error_at("invalid escape \\" .. e) end
                    return v
                end))
            elseif c == "\\" then pos = pos + 2
            else pos = pos + 1 end
        end
        error_at("unterminated string")
    end

    local function parse_number()
        local start = pos
        while pos <= len and src:sub(pos, pos):match("[%d%+%-%.eE]") do pos = pos + 1 end
        local n = tonumber(src:sub(start, pos - 1))
        if not n then error_at("invalid number") end
        return n
    end

    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if src:sub(pos, pos) == "}" then pos = pos + 1 return obj end
        while true do
            skip_ws()
            if src:sub(pos, pos) ~= '"' then error_at("expected string key") end
            local key = parse_string()
            skip_ws()
            if src:sub(pos, pos) ~= ":" then error_at("expected ':'") end
            pos = pos + 1
            skip_ws()
            obj[key] = parse_value()
            skip_ws()
            local c = src:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "}" then pos = pos + 1 return obj
            else error_at("expected ',' or '}'") end
        end
    end

    local function parse_array()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if src:sub(pos, pos) == "]" then pos = pos + 1 return arr end
        while true do
            skip_ws()
            arr[#arr + 1] = parse_value()
            skip_ws()
            local c = src:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "]" then pos = pos + 1 return arr
            else error_at("expected ',' or ']'") end
        end
    end

    parse_value = function()
        skip_ws()
        local c = src:sub(pos, pos)
        if c == '"' then return parse_string() end
        if c == "{" then return parse_object() end
        if c == "[" then return parse_array() end
        if c == "-" or c:match("%d") then return parse_number() end
        if src:sub(pos, pos + 3) == "true" then pos = pos + 4 return true end
        if src:sub(pos, pos + 4) == "false" then pos = pos + 5 return false end
        if src:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil end
        error_at("unexpected character")
    end

    local result = parse_value()
    skip_ws()
    if pos <= len then error_at("trailing data") end
    return result
end

local function parse_json(src)
    local ok, json = pcall(require, "lunajson")
    if ok and json and json.decode then return json.decode(src) end
    ok, json = pcall(require, "json")
    if ok and json and json.decode then return json.decode(src) end
    return decode_json(src)
end

----------------------------------------------------------------------
-- Validation
----------------------------------------------------------------------

local function fail(fmt, ...)
    error("ControlFileError: " .. fmt:format(...), 0)
end

local function parse_rule(item, index)
    local where = ("replacement_rules[%d]"):format(index)
    if type(item) ~= "table" then fail("%s: must be an object", where) end

    local name = item.name
    if type(name) ~= "string" or name == "" then
        fail("%s.name: must be a non-empty string", where)
    end

    local ids_raw = item.replace_ids
    if type(ids_raw) ~= "table" or #ids_raw == 0 then
        fail("%s.replace_ids: must be a non-empty list", where)
    end
    local ids = {}
    for i, value in ipairs(ids_raw) do
        if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
            fail("%s.replace_ids[%d]: must be a non-negative integer", where, i)
        end
        ids[i] = value
    end

    local mode = item.mode
    if type(mode) ~= "string" or mode == "" then
        fail("%s.mode: must be a non-empty string", where)
    end

    local enabled = item.enabled
    if type(enabled) ~= "boolean" then
        fail("%s.enabled: must be a boolean", where)
    end

    return { name = name, replace_ids = ids, mode = mode, enabled = enabled }
end

local function validate(raw)
    if type(raw) ~= "table" then fail("Root element must be a JSON object") end
    local rules_raw = raw.replacement_rules or {}
    if type(rules_raw) ~= "table" then fail("'replacement_rules' must be a list") end
    local rules = {}
    for index, item in ipairs(rules_raw) do
        rules[index] = parse_rule(item, index)
    end
    return rules
end

----------------------------------------------------------------------
-- File IO (executor readfile/writefile, else plain io)
----------------------------------------------------------------------

local function read_file(path)
    if readfile then
        local ok, data = pcall(readfile, path)
        if ok and type(data) == "string" then return data end
    end
    local fh, err = io.open(path, "r")
    if not fh then fail("Cannot read %s: %s", path, err or "unknown error") end
    local text = fh:read("*a")
    fh:close()
    return text
end

local function write_file(path, text)
    if writefile then
        local ok, err = pcall(writefile, path, text)
        if ok then return end
        fail("Cannot write %s: %s", path, tostring(err))
    end
    local fh, err = io.open(path, "w")
    if not fh then fail("Cannot write %s: %s", path, err or "unknown error") end
    fh:write(text)
    fh:close()
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Load rules from an external JSON file; falls back to the embedded
--- configuration if the file is missing. @param path string|nil
function Control.load(path)
    path = path or "Control.json"
    local text
    if readfile then
        local ok, data = pcall(readfile, path)
        if ok and type(data) == "string" then text = data end
    end
    if not text then
        local fh = io.open(path, "r")
        if not fh then
            -- external file not found: embedded fallback
            return validate(DEFAULT_CONFIG)
        end
        text = fh:read("*a")
        fh:close()
    end

    local ok, raw = pcall(parse_json, text)
    if not ok then
        local msg = tostring(raw)
        if msg:match("^ControlFileError") then error(raw, 0) end
        fail("Invalid JSON in %s: %s", path, msg)
    end
    return validate(raw)
end

--- Write rules back out as JSON. @param rules table[] @param path string|nil
function Control.save(rules, path)
    path = path or "Control.json"
    local doc = { replacement_rules = rules }
    local ok, encoded = pcall(encode_json, doc)
    if not ok then error(encoded, 0) end
    write_file(path, encoded)
end

--- Rules whose `enabled` flag is true.
function Control.enabled_rules(rules)
    local out = {}
    for _, rule in ipairs(rules) do
        if rule.enabled then out[#out + 1] = rule end
    end
    return out
end

--- IDs replaced by the named profile (empty table if it is disabled).
function Control.ids_for_profile(rules, name)
    for _, rule in ipairs(rules) do
        if rule.name == name then
            return rule.enabled and rule.replace_ids or {}
        end
    end
    fail("No profile named '%s'", name)
end

--- Union of all enabled profiles' replace_ids, sorted, de-duplicated.
function Control.active_ids(rules)
    local seen, out = {}, {}
    for _, rule in ipairs(rules) do
        if rule.enabled then
            for _, id in ipairs(rule.replace_ids) do
                if not seen[id] then seen[id] = true out[#out + 1] = id end
            end
        end
    end
    table.sort(out)
    return out
end

----------------------------------------------------------------------
-- CLI
----------------------------------------------------------------------

local function show_summary(rules, source)
    print(("Loaded %d rule(s) from %s\n"):format(#rules, source))
    for _, rule in ipairs(rules) do
        local status = rule.enabled and "enabled " or "disabled"
        local ids = {}
        for i, id in ipairs(rule.replace_ids) do ids[i] = tostring(id) end
        print(("  [%s] %s (mode=%s): %s")
            :format(status, rule.name, rule.mode, table.concat(ids, ", ")))
    end
    local parts = {}
    for i, id in ipairs(Control.active_ids(rules)) do parts[i] = tostring(id) end
    print("\nActive replace IDs: " .. (#parts > 0 and table.concat(parts, ", ") or "(none)"))
end

local function main(args)
    local path = args[1] or "Control.json"
    local rules, source
    local ok, result = pcall(Control.load, path)
    if ok then
        rules, source = result, path
    else
        rules, source = validate(DEFAULT_CONFIG), "embedded config (file not found)"
    end
    show_summary(rules, source)
end

-- Auto-run when executed as a CLI script or inside Roblox via loadstring.
-- Set _G.CONTROL_BUNDLE_NO_AUTORUN = true before loading to suppress this.
if arg and arg[0] and arg[0]:match("control_bundle%.lua$") then
    main(arg)
elseif type(game) == "userdata" and not _G.CONTROL_BUNDLE_NO_AUTORUN then
    main({ "Control.json" })
end

return Control
