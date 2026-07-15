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

    int WSAStartup(unsigned short wVersionRequested, void *lpWSAData);
    int closesocket(int s);
]]

DiscordIPC = {
    id = "1244356034689237082",
    activity = {},
    is_windows = love.system.getOS() == "Windows",
    connected = false,
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

function DiscordIPC.get_socket_api()
    if not DiscordIPC.is_windows then
        return ffi.C
    end

    if DiscordIPC.socket_api then
        return DiscordIPC.socket_api
    end

    local ok, api = pcall(ffi.load, "ws2_32")
    if not ok then
        return nil
    end

    -- Winsock must be initialized before opening a Unix-domain socket. This
    -- path is used by Wine/Proton when native Linux Discord is running.
    local wsa_data = ffi.new("uint8_t[512]")
    if api.WSAStartup(0x0202, wsa_data) ~= 0 then
        return nil
    end

    DiscordIPC.socket_api = api
    return api
end

function DiscordIPC.connect_unix_socket()
    local api = DiscordIPC.get_socket_api()
    if not api then
        return false
    end

    local env = nil

    for _, variable in ipairs(DiscordIPC.PIPE_ENVS) do
        env = os.getenv(variable)

        if env and env ~= "" then
            if env:sub(-1) == "/" then
                env = env:sub(1, -2)
            end

            break
        end
    end

    env = env or "/tmp"

    for i = 0, 9 do
        for _, subpath in ipairs(DiscordIPC.PIPE_PATHS) do
            local socket = api.socket(1, 1, 0)

            if socket >= 0 then
                local address = ffi.new("struct sockaddr_un")
                address.sun_family = 1

                local socket_path =
                    env .. "/" .. subpath .. "discord-ipc-" .. i

                ffi.copy(address.sun_path, socket_path)

                local result = api.connect(
                    socket,
                    ffi.cast("const struct sockaddr*", address),
                    ffi.sizeof(address)
                )

                if result == 0 then
                    print("Distro :: Connected to Discord IPC (pipe " .. i .. ")")
                    DiscordIPC.socket = socket
                    DiscordIPC.socket_is_file = false
                    return true
                end

                if DiscordIPC.is_windows then
                    api.closesocket(socket)
                else
                    api.close(socket)
                end
            end
        end
    end

    return false
end

function DiscordIPC.connect()
    if DiscordIPC.is_windows then
        for i = 0, 9 do
            local file = io.open("\\\\.\\pipe\\discord-ipc-" .. i, "r+")

            if file then
                print("Distro :: Connected to Discord IPC (pipe " .. i .. ")")
                DiscordIPC.socket = file
                DiscordIPC.socket_is_file = true
                break
            end
        end

        -- When Balatro runs through Wine/Proton, Windows named pipes cannot
        -- reach a native Linux Discord process. Wine's AF_UNIX support can.
        if not DiscordIPC.socket then
            DiscordIPC.connect_unix_socket()
        end
    else
        DiscordIPC.connect_unix_socket()
    end

    if DiscordIPC.socket then
        DiscordIPC.connected = true

        local result = DiscordIPC.send_handshake()
        return result == DiscordIPC.OPCODES.FRAME
    end

    return false
end

function DiscordIPC.reconnect()
    DiscordIPC.close()
    DiscordIPC.connect()
end

function DiscordIPC.write(message)
    if not DiscordIPC.socket then
        return
    end

    if DiscordIPC.socket_is_file then
        DiscordIPC.socket:seek("end")
        local _, err = DiscordIPC.socket:write(message)
        DiscordIPC.socket:flush()

        if err then
            print("Distro :: Failed to write to Discord IPC - "..err)
        end
    else
        local sent = DiscordIPC.socket_api and DiscordIPC.socket_api.send(
            DiscordIPC.socket, message, #message, 0
        ) or ffi.C.send(DiscordIPC.socket, message, #message, 0)

        if sent < 0 then
            print("Distro :: Failed to write to Discord IPC")
        end
    end
end

function DiscordIPC.read(buffer)
    if not DiscordIPC.socket then
        return
    end

    return DiscordIPC.socket:read(buffer)
end

function DiscordIPC.close()
    if not DiscordIPC.socket then
        return
    end

    DiscordIPC.send("{}", DiscordIPC.OPCODES.CLOSE)

    if DiscordIPC.socket_is_file then
        DiscordIPC.socket:close()
    else
        if DiscordIPC.is_windows then
            DiscordIPC.socket_api.closesocket(DiscordIPC.socket)
        else
            ffi.C.close(DiscordIPC.socket)
        end
    end

    DiscordIPC.socket = nil
    DiscordIPC.socket_is_file = nil
    DiscordIPC.connected = false
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
    local opcode, length, data = nil, nil, nil

    if DiscordIPC.socket_is_file then
        opcode, length = Distro.unpack(DiscordIPC.read(8))
        data = DiscordIPC.read(length)
    else
        local header_buffer = ffi.new("char[8]")
        local api = DiscordIPC.socket_api or ffi.C
        local header_bytes = api.recv(DiscordIPC.socket, header_buffer, 8, 0)
        opcode, length = Distro.unpack(ffi.string(header_buffer, header_bytes))

        local data_buffer = ffi.new("char["..length.."]")
        local data_bytes = api.recv(DiscordIPC.socket, data_buffer, length, 0)
        data = ffi.string(data_buffer, data_bytes)
    end

    print("Distro :: Received "..opcode.." - "..data)

    return opcode, data
end
