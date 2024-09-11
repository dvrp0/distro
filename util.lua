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
Distro.lang = assert(loadstring(love.filesystem.read("localization/en-us.lua")))()

-- https://gist.github.com/jrus/3197011
function Distro.get_uuid()
    math.randomseed(os.time())

    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    local result = string.gsub(template,
        "[xy]",
        function(c)
            local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
            return string.format("%x", v)
        end
    )

    return result
end

function Distro.get_pid()
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
end

function Distro.stringify(data)
    local result = {}

    for k, v in pairs(data) do
        local formatted = type(v) == "table" and Distro.stringify(v) or tostring(v)

        if type(v) == "string" then
            formatted = '"'..formatted..'"'
        end

        table.insert(result, string.format("\"%s\":%s", k, formatted))
    end

    return "{"..table.concat(result, ",").."}"
end

function Distro.int_to_le_bytes(number)
    local hex = string.format("%04x", number)
    local result = {}

    table.insert(result, tonumber(hex:sub(3, 4), 16))
    table.insert(result, tonumber(hex:sub(1, 2), 16))

    for _ = 1, 4 - #result do
        table.insert(result, 0)
    end

    return result
end

function Distro.le_bytes_to_int(bytes)
    local result = 0

    for i, v in ipairs(bytes) do
        result = result + v * (0x100 ^ (i - 1))
    end

    return math.floor(result)
end

function Distro.string_to_le_bytes(str)
    local result = {}

    for i = 1, #str do
        table.insert(result, str:byte(i))
    end

    return result
end

function Distro.le_bytes_to_string(bytes)
    local result = {}

    for _, v in ipairs(bytes) do
        local byte = v < 0 and (0xff + v + 1) or v
        table.insert(result, string.char(byte))
    end

    return table.concat(result)
end

function Distro.pack(opcode, length)
    return
        Distro.le_bytes_to_string(Distro.int_to_le_bytes(opcode))
        ..
        Distro.le_bytes_to_string(Distro.int_to_le_bytes(length))
end

function Distro.unpack(data)
    return
        Distro.le_bytes_to_int(Distro.string_to_le_bytes(data:sub(1, 4))),
        Distro.le_bytes_to_int(Distro.string_to_le_bytes(data:sub(5, 8)))
end

function Distro.get_back_name()
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
end

function Distro.get_stake_name()
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
end

function Distro.get_blind_name()
    local key = G.GAME.blind.config.blind.key
    local name = G.P_BLINDS[key].name
    local is_vanilla = Distro.blinds[key]

    if Distro.lang and Distro.lang.descriptions.Blind[key] then
        name = Distro.lang.descriptions.Blind[key].name
    elseif G.P_BLINDS[key] and G.P_BLINDS[key].loc_txt then -- Modded blinds
        name = G.P_BLINDS[key].loc_txt.name
    end

    if not is_vanilla then
        name = name.." (Modded)"
    end

    return name
end