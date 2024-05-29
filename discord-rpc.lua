-- Heavily based on https://github.com/vionya/discord-rich-presence

local ffi = require("ffi")
ffi.cdef[[
    typedef unsigned int size_t;
    typedef unsigned short sa_family_t;
    typedef unsigned int socklen_t;
    typedef int ssize_t;

    struct sockaddr {
        sa_family_t sa_family;
        char sa_data[14];
    };

    struct sockaddr_un {
        sa_family_t sun_family;
        char sun_path[104];
    };

    int socket(int domain, int type, int protocol);
    int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
    ssize_t send(int sockfd, const void *buf, size_t len, int flags);
    ssize_t recv(int sockfd, void *buf, size_t len, int flags);
    int close(int fd);
]]

DiscordIPC = {
    id = "1244356034689237082",
    activity = {},
    is_windows = love.system.getOS() == "Windows",
    OPCODES = {
        HANDSHAKE = 0,
        FRAME = 1,
        CLOSE = 2,
        PING = 3,
        PONG = 4
    },
    PIPE_ENVS = {
        "XDG_RUNTIME_DIR",
        "TMPDIR",
        "TMP",
        "TEMP"
    },
    PIPE_PATHS = {
        "",
        "app/com.discordapp.Discord/",
        "snap.discord-canary/",
        "snap.discord/"
    }
}

function DiscordIPC.connect()
    if DiscordIPC.is_windows then
        for i = 0, 9 do
            local file, _ = io.open("\\\\.\\pipe\\discord-ipc-"..i, "r+")

            if file then
                print("Distro :: Connected to Discord IPC (pipe "..i..")")

                DiscordIPC.socket = file
                local result, _ = DiscordIPC.send_handshake()

                return result == DiscordIPC.OPCODES.FRAME
            end
        end
    else
        local socket = ffi.C.socket(1, 1, 0)
        if socket < 0 then
            print("Distro :: Failed to create Discord IPC socket")

            return false
        end

        local env = nil
        for _, v in ipairs(DiscordIPC.PIPE_ENVS) do
            env = os.getenv(v)

            if env then
                if env:sub(-1) == "/" then
                    env = env:sub(1, -2)
                end

                break
            end
        end

        if not env then
            env = "/tmp"
        end

        for i = 0, 9 do
            for _, v in ipairs(DiscordIPC.PIPE_PATHS) do
                local address = ffi.new("struct sockaddr_un")
                address.sun_family = 1
                ffi.copy(address.sun_path, env.."/"..v.."discord-ipc-"..i)

                if ffi.C.connect(
                    socket, ffi.cast("const struct sockaddr*", address), ffi.sizeof(address)
                ) < 0 then
                    print("Distro :: Failed to connect to Discord IPC (pipe "..i..")")

                    return false
                end

                print("Distro :: Connected to Discord IPC (pipe "..i..")")
                DiscordIPC.socket = socket
                local result, _ = DiscordIPC.send_handshake()

                return result == DiscordIPC.OPCODES.FRAME
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

    if DiscordIPC.is_windows then
        DiscordIPC.socket:close()
    else
        ffi.C.close(DiscordIPC.socket)
    end

    print("Distro :: Disconnected from Discord IPC")
end

function DiscordIPC.send(data, opcode)
    if DiscordIPC.is_windows then
        DiscordIPC.write(Distro.pack(opcode, #data)..data)
    else
        local message = Distro.pack(opcode, #data)..data
        ffi.C.send(DiscordIPC.socket, message, #message, 0)
    end
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
    local opcode, length, data = nil, nil, nil

    if DiscordIPC.is_windows then
        opcode, length = Distro.unpack(DiscordIPC.read(8))
        data = DiscordIPC.read(length)
    else
        local header_buffer = ffi.new("char[8]")
        local header_bytes = ffi.C.recv(DiscordIPC.socket, header_buffer, 8, 0)
        opcode, length = Distro.unpack(ffi.string(header_buffer, header_bytes))

        local data_buffer = ffi.new("char["..length.."]")
        local data_bytes = ffi.C.recv(DiscordIPC.socket, data_buffer, length, 0)
        data = ffi.string(data_buffer, data_bytes)
    end

    print("Distro :: Received "..opcode.." - "..data)

    return opcode, data
end