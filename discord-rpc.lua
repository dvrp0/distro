-- Heavily based on https://github.com/vionya/discord-rich-presence

DiscordIPC = {
    id = "1244356034689237082",
    activity = {},
    OPCODES = {
        HANDSHAKE = 0,
        FRAME = 1,
        CLOSE = 2,
        PING = 3,
        PONG = 4
    }
}

function DiscordIPC.connect()
    local envs = {
        "XDG_RUNTIME_DIR",
        "TMPDIR",
        "TMP",
        "TEMP"
    }
    local paths = {
        "",
        "app/com.discordapp.Discord/",
        "snap.discord-canary/",
        "snap.discord/"
    }

    for i = 0, 9 do
        if love.system.getOS() == "Windows" then
            local file, _ = io.open("\\\\.\\pipe\\discord-ipc-"..i, "r+")

            if file then
                print("Distro :: Connected to Discord IPC (pipe "..i..")")

                DiscordIPC.socket = file
                local result, _ = DiscordIPC.send_handshake()

                return result == DiscordIPC.OPCODES.FRAME
            end
        else
            local env = nil
            for _, v in ipairs(envs) do
                if os.getenv(v) then
                    env = v

                    break
                end
            end

            if not env then
                print("Distro :: Failed to find Discord IPC environment variable")

                return false
            end

            for _, v in ipairs(paths) do
                local file, _ = io.open(env.."/"..v.."discord-ipc-"..i, "r+")

                if file then
                    print("Distro :: Connected to Discord IPC (pipe "..i..")")

                    DiscordIPC.socket = file
                    local result, _ = DiscordIPC.send_handshake()

                    return result == DiscordIPC.OPCODES.FRAME
                end
            end
        end
    end
end

function DiscordIPC.reconnect()
    DiscordIPC.close()
    DiscordIPC.connect()
end

function DiscordIPC.write(message)
    if not DiscordIPC.socket then
        return
    end

    DiscordIPC.socket:seek("end")
    local _, err = DiscordIPC.socket:write(message)
    DiscordIPC.socket:flush()

    if err then
        print("Distro :: Failed to write to Discord IPC - "..err)
    end
end

function DiscordIPC.read(buffer)
    if not DiscordIPC.socket then
        return
    end

    return DiscordIPC.socket:read(buffer)
end

function DiscordIPC.close()
    DiscordIPC.send("{}", DiscordIPC.OPCODES.CLOSE)
    DiscordIPC.socket:close()

    print("Distro :: Disconnected from Discord IPC")
end

function DiscordIPC.send(data, opcode)
    DiscordIPC.write(Distro.pack(opcode, #data)..data)
end

function DiscordIPC.send_handshake()
    DiscordIPC.send('{"v": 1, "client_id": "'..DiscordIPC.id..'"}', DiscordIPC.OPCODES.HANDSHAKE)

    return DiscordIPC.receive()
end

function DiscordIPC.send_activity()
    local data = {
        cmd = "SET_ACTIVITY",
        args = {
            pid = Distro.get_pid() or 9999,
            activity = DiscordIPC.activity
        },
        nonce = Distro.get_uuid()
    }

    DiscordIPC.send(Distro.stringify(data), DiscordIPC.OPCODES.FRAME)
end

function DiscordIPC.clear_activity()
    local activity = {
        cmd = "SET_ACTIVITY",
        args = {
            pid = Distro.get_pid() or 9999,
            activity = {}
        },
        nonce = Distro.get_uuid()
    }

    DiscordIPC.send(Distro.stringify(activity), DiscordIPC.OPCODES.FRAME)
end

function DiscordIPC.receive()
    local opcode, length = Distro.unpack(DiscordIPC.read(8))
    local data = DiscordIPC.read(length)

    print("Distro :: Received "..opcode.." - "..data)

    return opcode, data
end