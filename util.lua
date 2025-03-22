local ffi = require("ffi")

Distro.decks = {
    "b_red",
    "b_blue",
    "b_yellow",
    "b_green",
    "b_black",
    "b_magic",
    "b_nebula",
    "b_ghost",
    "b_abandoned",
    "b_checkered",
    "b_zodiac",
    "b_painted",
    "b_anaglyph",
    "b_plasma",
    "b_erratic",
    "b_challenge"
}
Distro.stakes = {
    "stake_white",
    "stake_red",
    "stake_green",
    "stake_black",
    "stake_blue",
    "stake_purple",
    "stake_orange",
    "stake_gold"
}
Distro.blinds = {
    "bl_small",
    "bl_big",
    "bl_ox",
    "bl_hook",
    "bl_mouth",
    "bl_fish",
    "bl_club",
    "bl_manacle",
    "bl_tooth",
    "bl_wall",
    "bl_house",
    "bl_mark",
    "bl_final_bell",
    "bl_wheel",
    "bl_arm",
    "bl_psychic",
    "bl_goad",
    "bl_water",
    "bl_eye",
    "bl_plant",
    "bl_needle",
    "bl_head",
    "bl_final_leaf",
    "bl_final_vessel",
    "bl_window",
    "bl_serpent",
    "bl_pillar",
    "bl_flint",
    "bl_final_acorn",
    "bl_final_heart"
}
local success, lang = pcall(function()
    return assert(loadstring(love.filesystem.read("localization/en-us.lua")))()
end)
if success then
    Distro.lang = lang
else
    print("Error loading localization file: "..tostring(lang))
    Distro.lang = nil
end

-- https://gist.github.com/jrus/3197011
function Distro.get_uuid()
    local success, result = pcall(function()
        math.randomseed(os.time())

        local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        return string.gsub(template,
            "[xy]",
            function(c)
                local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
                return string.format("%x", v)
            end
        )
    end)

    if not success then
        print("Error generating UUID: "..tostring(result))
        return nil
    end

    return result
end

function Distro.get_pid()
    local success, pid = pcall(function()
        if DiscordIPC.is_windows then
            ffi.cdef[[
                unsigned long GetCurrentProcessId(void);
            ]]
            return ffi.C.GetCurrentProcessId()
        else
            ffi.cdef[[
                int getpid(void);
            ]]
            return ffi.C.getpid()
        end
    end)

    if not success then
        print("Error getting process ID: "..tostring(pid))
        return nil
    end

    return pid
end

function Distro.stringify(data)
    local success, result = pcall(function()
        local result = {}

        for k, v in pairs(data) do
            local formatted = type(v) == "table" and Distro.stringify(v) or tostring(v)

            if type(v) == "string" then
                formatted = '"'..formatted..'"'
            end

            table.insert(result, string.format("\"%s\":%s", k, formatted))
        end

        return "{"..table.concat(result, ",").."}"
    end)

    if not success then
        print("Error stringifying data: "..tostring(result))
        return nil
    end

    return result
end

function Distro.int_to_le_bytes(number)
    local success, result = pcall(function()
        local hex = string.format("%04x", number)
        local result = {}

        table.insert(result, tonumber(hex:sub(3, 4), 16))
        table.insert(result, tonumber(hex:sub(1, 2), 16))

        for _ = 1, 4 - #result do
            table.insert(result, 0)
        end

        return result
    end)

    if not success then
        print("Error converting integer to little-endian bytes: "..tostring(result))
        return nil
    end

    return result
end

function Distro.le_bytes_to_int(bytes)
    local success, result = pcall(function()
        local result = 0

        for i, v in ipairs(bytes) do
            result = result + v * (0x100 ^ (i - 1))
        end

        return math.floor(result)
    end)

    if not success then
        print("Error converting little-endian bytes to integer: "..tostring(result))
        return nil
    end

    return result
end

function Distro.string_to_le_bytes(str)
    local success, result = pcall(function()
        local result = {}

        for i = 1, #str do
            table.insert(result, str:byte(i))
        end

        return result
    end)

    if not success then
        print("Error converting string to little-endian bytes: "..tostring(result))
        return nil
    end

    return result
end

function Distro.le_bytes_to_string(bytes)
    local success, result = pcall(function()
        local result = {}

        for _, v in ipairs(bytes) do
            local byte = v < 0 and (0xff + v + 1) or v
            table.insert(result, string.char(byte))
        end

        return table.concat(result)
    end)

    if not success then
        print("Error converting little-endian bytes to string: "..tostring(result))
        return nil
    end

    return result
end

function Distro.pack(opcode, length)
    local success, result = pcall(function()
        return
            Distro.le_bytes_to_string(Distro.int_to_le_bytes(opcode))
            ..
            Distro.le_bytes_to_string(Distro.int_to_le_bytes(length))
    end)

    if not success then
        print("Error packing data: "..tostring(result))
        return nil
    end

    return result
end

function Distro.unpack(data)
    local success, opcode, length = pcall(function()
        return
            Distro.le_bytes_to_int(Distro.string_to_le_bytes(data:sub(1, 4))),
            Distro.le_bytes_to_int(Distro.string_to_le_bytes(data:sub(5, 8)))
    end)

    if not success then
        print("Error unpacking data: "..tostring(opcode))
        return nil, nil
    end

    return opcode, length
end

function get_index(tbl, value)
    for i, v in ipairs(tbl) do
        if v == value then
            return i
        end
    end
    return nil
end

function Distro.get_back_name()
    local success, key, name = pcall(function()
        local key = G.GAME.selected_back.effect.center.key
        local name = G.GAME.selected_back.name
        local is_vanilla = get_index(Distro.decks, key)

        if Distro.lang and Distro.lang.descriptions.Back[key] then
            name = Distro.lang.descriptions.Back[key].name
        elseif G.P_CENTERS[key] and G.P_CENTERS[key].loc_txt then -- Modded decks
            name = G.P_CENTERS[key].loc_txt.name
        end

        if not is_vanilla then
            key = "b_unknown"
            name = name.." (Modded)"
        end

        return key, name
    end)
    if not success then
        print("Error getting back name: "..tostring(key))
        return nil, nil
    end

    return key, name
end

function Distro.get_stake_name()
    local success, key, name = pcall(function()
        local key = G.P_CENTER_POOLS.Stake[G.GAME.stake].key
        local name = G.P_CENTER_POOLS.Stake[G.GAME.stake].name:gsub("Chip", "Stake") 
        local is_vanilla = Distro.stakes[G.GAME.stake]

        if Distro.lang and Distro.lang.descriptions.Stake[key] then
            name = Distro.lang.descriptions.Stake[key].name
        elseif G.P_STAKES[key] and G.P_STAKES[key].loc_txt then -- Modded stakes
            name = G.P_STAKES[key].loc_txt.name
        end

        if not is_vanilla then
            key = "stake_unknown"
            name = name.." (Modded)"
        end
        return key, name
    end)

    if not success then
        print("Error getting stake name: "..tostring(key))
        return "stake_white" , "stake_white"
    end

    return key, name
end

function Distro.get_blind_name()
    local success, name = pcall(function()
        local key = G.GAME.blind.config.blind.key
        local name = G.P_BLINDS[key].name
        local is_vanilla = get_index(Distro.blinds, key)

        if Distro.lang and Distro.lang.descriptions.Blind[key] then
            name = Distro.lang.descriptions.Blind[key].name
        elseif G.P_BLINDS[key] and G.P_BLINDS[key].loc_txt then -- Modded blinds
            name = G.P_BLINDS[key].loc_txt.name 
        end

        if not is_vanilla then
            name = name.." (Modded)"
        end

        return name
    end)

    if not success then
        print("Error getting blind name: "..tostring(name))
        return "b_challenge"
    end

    return name
end