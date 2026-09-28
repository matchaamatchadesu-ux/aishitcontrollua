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
-- Big Skin module (visual character mod, toggled from the GUI)
----------------------------------------------------------------------

local lp = game:GetService("Players").LocalPlayer

local bigSkinBugEnabled = false
local bigSkinBugOriginal = {}
local bigSkinBugConnections = {}

local function applyBigSkin(char)
    local data = bigSkinBugOriginal[char]
    if not data then return end
    for item in pairs(data.accessories) do
        item.Parent = nil
    end
    for part in pairs(data.parts) do
        part.Color = Color3.fromRGB(128, 128, 128)
        part.Material = Enum.Material.SmoothPlastic
        part.CanCollide = true
        if part:IsA("MeshPart") then part.TextureID = "" end
        local nameLower = part.Name:lower()
        if nameLower:match("torso") then
            part.Size = Vector3.new(5.6, 4.4, 3.4)
        elseif nameLower:match("leg") or nameLower:match("arm") then
            part.Size = Vector3.new(2.6, 4.8, 2.6)
        elseif nameLower == "head" then
            part.Size = Vector3.new(2.2, 2.2, 2.2)
            local mesh = part:FindFirstChildOfClass("SpecialMesh")
            if mesh then mesh.Parent = nil end
        end
    end
    for joint, saved in pairs(data.joints) do
        local jName = joint.Name:lower()
        local c0 = saved.C0
        if jName:match("rightshoulder") or jName:match("right shoulder") then
            joint.C0 = c0 * CFrame.new(2.4, 0.6, 0)
        elseif jName:match("leftshoulder") or jName:match("left shoulder") then
            joint.C0 = c0 * CFrame.new(-2.4, 0.6, 0)
        elseif jName:match("righthip") or jName:match("right hip") then
            joint.C0 = c0 * CFrame.new(0.9, -0.6, 0)
        elseif jName:match("lefthip") or jName:match("left hip") then
            joint.C0 = c0 * CFrame.new(-0.9, -0.6, 0)
        elseif jName:match("neck") then
            joint.C0 = c0 * CFrame.new(0, 0.8, 0)
        end
    end
end

local function saveBigSkinOriginal(char)
    local data = { parts = {}, accessories = {}, joints = {} }
    for _, item in pairs(char:GetDescendants()) do
        if item:IsA("Accessory") or item:IsA("Clothing") or item:IsA("ShirtGraphic") or item:IsA("Decal") then
            data.accessories[item] = { Parent = item.Parent }
        elseif item:IsA("BasePart") and item.Name ~= "HumanoidRootPart" then
            local saved = { Size = item.Size, Color = item.Color, Material = item.Material,
                            TextureID = item:IsA("MeshPart") and item.TextureID or nil }
            if item.Name == "Head" then
                local mesh = item:FindFirstChildOfClass("SpecialMesh")
                if mesh then saved.MeshParent = mesh.Parent end
            end
            data.parts[item] = saved
        elseif item:IsA("Motor6D") and item.Part0 and item.Part1 then
            data.joints[item] = { C0 = item.C0, C1 = item.C1 }
        end
    end
    bigSkinBugOriginal[char] = data
end

local function restoreBigSkin(char)
    local data = bigSkinBugOriginal[char]
    if not data then return end
    for item, saved in pairs(data.accessories) do
        if saved.Parent then item.Parent = saved.Parent end
    end
    for part, saved in pairs(data.parts) do
        part.Size = saved.Size
        part.Color = saved.Color
        part.Material = saved.Material
        if saved.TextureID and part:IsA("MeshPart") then part.TextureID = saved.TextureID end
        if saved.MeshParent and part.Name == "Head" then
            local mesh = part:FindFirstChildOfClass("SpecialMesh")
            if not mesh and saved.MeshParent ~= part then
                local oldMesh = saved.MeshParent:FindFirstChildOfClass("SpecialMesh")
                if oldMesh then oldMesh.Parent = part end
            end
        end
    end
    for joint, saved in pairs(data.joints) do
        joint.C0 = saved.C0
        joint.C1 = saved.C1
    end
    bigSkinBugOriginal[char] = nil
end

local function onCharAddedBigSkin(char)
    if not bigSkinBugEnabled then return end
    task.wait(0.4)
    saveBigSkinOriginal(char)
    applyBigSkin(char)
end

local function enableBigSkin()
    if bigSkinBugEnabled then return end
    bigSkinBugEnabled = true
    if lp.Character then
        saveBigSkinOriginal(lp.Character)
        applyBigSkin(lp.Character)
    end
    bigSkinBugConnections.CharAdded = lp.CharacterAdded:Connect(onCharAddedBigSkin)
end

local function disableBigSkin()
    bigSkinBugEnabled = false
    if bigSkinBugConnections.CharAdded then
        bigSkinBugConnections.CharAdded:Disconnect()
        bigSkinBugConnections.CharAdded = nil
    end
    if lp.Character then
        restoreBigSkin(lp.Character)
    end
end

function Control.toggle_big_skin()
    if bigSkinBugEnabled then
        disableBigSkin()
    else
        local ok, err = pcall(enableBigSkin)
        if not ok then
            bigSkinBugEnabled = false
            error("ControlFileError: enableBigSkin failed: " .. tostring(err), 0)
        end
    end
    return bigSkinBugEnabled
end

function Control.is_big_skin_enabled()
    return bigSkinBugEnabled
end

----------------------------------------------------------------------
-- Roblox GUI (shown when loaded via loadstring in-game)
----------------------------------------------------------------------

local function refresh_active_label(label, rules)
    local parts = {}
    for i, id in ipairs(Control.active_ids(rules)) do parts[i] = tostring(id) end
    label.Text = "Active IDs: " .. (#parts > 0 and table.concat(parts, ", ") or "(none)")
end

function Control.build_gui(rules)
    local player = game:GetService("Players").LocalPlayer

    local screen = Instance.new("ScreenGui")
    screen.Name = "ControlBundleGui"
    screen.ResetOnSpawn = false
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    -- parent: executor UI container > CoreGui > PlayerGui
    local parent
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then
        parent = hui
    else
        local ok2, core = pcall(game.GetService, game, "CoreGui")
        if ok2 and core then parent = core end
    end
    screen.Parent = parent or player:WaitForChild("PlayerGui")

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.fromOffset(340, 90)
    main.Position = UDim2.new(0.5, -170, 0.15, 0)
    main.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
    main.BorderSizePixel = 0
    main.Parent = screen
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -70, 0, 32)
    title.BackgroundTransparency = 1
    title.Text = " Control Panel"
    title.TextColor3 = Color3.fromRGB(235, 235, 240)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.Parent = main

    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(28, 28)
    close.Position = UDim2.new(1, -34, 0, 2)
    close.BackgroundColor3 = Color3.fromRGB(60, 40, 45)
    close.TextColor3 = Color3.fromRGB(255, 120, 120)
    close.Text = "X"
    close.Font = Enum.Font.GothamBold
    close.TextSize = 14
    close.Parent = main
    Instance.new("UICorner", close).CornerRadius = UDim.new(0, 8)
    close.MouseButton1Click:Connect(function() screen:Destroy() end)

    local list = Instance.new("Frame")
    list.Size = UDim2.new(1, -16, 1, -92)
    list.Position = UDim2.fromOffset(8, 34)
    list.BackgroundTransparency = 1
    list.Parent = main
    local layout = Instance.new("UIListLayout", list)
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder

    local activeLabel = Instance.new("TextLabel")
    activeLabel.Size = UDim2.new(1, -16, 0, 30)
    activeLabel.Position = UDim2.new(0, 8, 1, -54)
    activeLabel.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
    activeLabel.TextColor3 = Color3.fromRGB(180, 220, 180)
    activeLabel.Font = Enum.Font.Code
    activeLabel.TextSize = 12
    activeLabel.TextWrapped = true
    activeLabel.Text = ""
    activeLabel.Parent = main
    Instance.new("UICorner", activeLabel).CornerRadius = UDim.new(0, 6)

    local saveBtn = Instance.new("TextButton")
    saveBtn.Size = UDim2.fromOffset(80, 24)
    saveBtn.Position = UDim2.new(1, -88, 1, -20)
    saveBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 60)
    saveBtn.TextColor3 = Color3.fromRGB(230, 255, 230)
    saveBtn.Text = "Save JSON"
    saveBtn.Font = Enum.Font.Gotham
    saveBtn.TextSize = 12
    saveBtn.Visible = writefile ~= nil
    saveBtn.Parent = main
    Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 6)
    saveBtn.MouseButton1Click:Connect(function()
        local ok, err = pcall(Control.save, rules, "Control.json")
        saveBtn.Text = ok and "Saved!" or "Failed"
        task.delay(1.5, function() saveBtn.Text = "Save JSON" end)
    end)

    local skinBtn = Instance.new("TextButton")
    skinBtn.Size = UDim2.fromOffset(110, 24)
    skinBtn.Position = UDim2.fromOffset(8, 8)
    skinBtn.BackgroundColor3 = Color3.fromRGB(70, 55, 40)
    skinBtn.TextColor3 = Color3.fromRGB(255, 230, 200)
    skinBtn.Text = "Big Skin: OFF"
    skinBtn.Font = Enum.Font.GothamBold
    skinBtn.TextSize = 12
    skinBtn.Parent = main
    Instance.new("UICorner", skinBtn).CornerRadius = UDim.new(0, 6)

    local function paintSkin()
        if Control.is_big_skin_enabled() then
            skinBtn.BackgroundColor3 = Color3.fromRGB(45, 120, 70)
            skinBtn.TextColor3 = Color3.fromRGB(220, 255, 220)
            skinBtn.Text = "Big Skin: ON"
        else
            skinBtn.BackgroundColor3 = Color3.fromRGB(70, 55, 40)
            skinBtn.TextColor3 = Color3.fromRGB(255, 230, 200)
            skinBtn.Text = "Big Skin: OFF"
        end
    end

    skinBtn.MouseButton1Click:Connect(function()
        local ok, err = pcall(Control.toggle_big_skin)
        if not ok then
            skinBtn.Text = "Error"
            warn(tostring(err))
        else
            paintSkin()
        end
    end)

    local rowHeight = 46
    for i, rule in ipairs(rules) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, rowHeight)
        row.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
        row.BorderSizePixel = 0
        row.LayoutOrder = i
        row.Parent = list
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

        local name = Instance.new("TextLabel")
        name.Size = UDim2.new(1, -90, 0, 20)
        name.Position = UDim2.fromOffset(8, 3)
        name.BackgroundTransparency = 1
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.Font = Enum.Font.GothamBold
        name.TextSize = 13
        name.Text = rule.name .. "  (mode=" .. rule.mode .. ")"
        name.Parent = row

        local idLabel = Instance.new("TextLabel")
        idLabel.Size = UDim2.new(1, -90, 0, 18)
        idLabel.Position = UDim2.fromOffset(8, 22)
        idLabel.BackgroundTransparency = 1
        idLabel.TextXAlignment = Enum.TextXAlignment.Left
        idLabel.Font = Enum.Font.Code
        idLabel.TextSize = 11
        idLabel.TextColor3 = Color3.fromRGB(170, 170, 180)
        local ids = {}
        for j, id in ipairs(rule.replace_ids) do ids[j] = tostring(id) end
        idLabel.Text = table.concat(ids, ", ")
        idLabel.Parent = row

        local toggle = Instance.new("TextButton")
        toggle.Size = UDim2.fromOffset(74, 26)
        toggle.Position = UDim2.new(1, -82, 0.5, -13)
        toggle.Font = Enum.Font.GothamBold
        toggle.TextSize = 12
        toggle.Parent = row
        Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 6)

        local function paint()
            if rule.enabled then
                toggle.BackgroundColor3 = Color3.fromRGB(45, 120, 70)
                toggle.TextColor3 = Color3.fromRGB(220, 255, 220)
                toggle.Text = "ON"
            else
                toggle.BackgroundColor3 = Color3.fromRGB(90, 50, 55)
                toggle.TextColor3 = Color3.fromRGB(255, 200, 200)
                toggle.Text = "OFF"
            end
        end
        paint()

        toggle.MouseButton1Click:Connect(function()
            rule.enabled = not rule.enabled
            paint()
            refresh_active_label(activeLabel, rules)
        end)
    end

    local total = #rules
    main.Size = UDim2.fromOffset(340, 90 + total * (rowHeight + 6) + 30)
    refresh_active_label(activeLabel, rules)

    -- make the window draggable
    local dragging, dragStart, startPos
    main.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    main.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                       startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    return screen
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
    local ok, result = pcall(Control.load, "Control.json")
    local rules = ok and result or validate(DEFAULT_CONFIG)
    print(("[control_bundle] loaded %d rule(s)"):format(#rules))
    Control.build_gui(rules)
end

return Control
