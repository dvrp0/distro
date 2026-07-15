local ffi = require("ffi")

local AF_UNIX = 1
local SOCK_STREAM = 1
local SOL_SOCKET = 1
local SO_SNDTIMEO = 21
local SO_RCVTIMEO = 20
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048
local MSG_NOSIGNAL = 0x4000
local EAGAIN = 11
local EWOULDBLOCK = 11
local EINPROGRESS = 115
local WSAEWOULDBLOCK = 10035
local FIONBIO = 0x8004667E
local RETRY_INTERVAL = 5

pcall(function()
    ffi.cdef[[
        typedef unsigned int size_t;
        typedef unsigned short sa_family_t;
        typedef unsigned int socklen_t;
        typedef int ssize_t;
        typedef unsigned short WORD;

        struct sockaddr {
            sa_family_t sa_family;
            char sa_data[14];
        };

        struct sockaddr_un {
            sa_family_t sun_family;
            char sun_path[108];
        };

        struct timeval {
            long tv_sec;
            long tv_usec;
        };

        int socket(int domain, int type, int protocol);
        int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
        ssize_t send(int sockfd, const void *buf, size_t len, int flags);
        ssize_t recv(int sockfd, void *buf, size_t len, int flags);
        int close(int fd);
        int fcntl(int fd, int cmd, int arg);
        int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
        unsigned int getuid(void);
        const char *wine_get_version(void);
        int WSAStartup(WORD wVersionRequested, void *lpWSAData);
        int WSAGetLastError(void);
        int closesocket(int s);
        int ioctlsocket(int s, long cmd, unsigned long *argp);
    ]]
end)

local function detect_wine()
    if love.system.getOS() ~= "Windows" then
        return false
    end

    local ok, ntdll = pcall(ffi.load, "ntdll")
    if not ok or not ntdll then
        return false
    end

    local ok_ver, ver = pcall(function()
        return ntdll.wine_get_version()
    end)

    return ok_ver and ver ~= nil
end

DiscordIPC = {
    id = "1244356034689237082",
    activity = {},
    is_windows = love.system.getOS() == "Windows",
    is_wine = detect_wine(),
    connected = false,
    unix_mode = false,
    socket = nil,
    last_activity_payload = nil,
    retry_at = 0,
    wsa_ready = false,
    ws2 = nil,
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
        "app/com.discordapp.DiscordCanary/",
        "app/com.discordapp.DiscordPTB/",
        "app/com.discord.Discord/",
        "snap.discord/",
        "snap.discord-canary/",
        "snap.discord-ptb/",
        ".flatpak/com.discordapp.Discord/xdg-run/",
        ".flatpak/com.discordapp.DiscordCanary/xdg-run/",
        ".flatpak/com.discordapp.DiscordPTB/xdg-run/"
    }
}

function DiscordIPC.get_base_dirs()
    local dirs = {}
    local seen = {}

    local function add(dir)
        if not dir or dir == "" then
            return
        end

        if dir:sub(-1) == "/" then
            dir = dir:sub(1, -2)
        end

        if not seen[dir] then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end

    for _, name in ipairs(DiscordIPC.PIPE_ENVS) do
        add(os.getenv(name))
    end

    add("/tmp")

    local uid = os.getenv("UID") or os.getenv("SUDO_UID")
    local xdg = os.getenv("XDG_RUNTIME_DIR")

    if not uid and xdg then
        uid = xdg:match("/run/user/(%d+)")
    end

    if not uid then
        local ok, result = pcall(function()
            return ffi.C.getuid()
        end)

        if ok and result then
            uid = tostring(result)
        end
    end

    if uid then
        add("/run/user/"..tostring(uid))
    end

    return dirs
end

function DiscordIPC.ensure_wsa()
    if DiscordIPC.wsa_ready then
        return true
    end

    local ok, ws2 = pcall(ffi.load, "ws2_32")
    if not ok or not ws2 then
        return false
    end

    DiscordIPC.ws2 = ws2
    local data = ffi.new("char[512]")
    local result = ws2.WSAStartup(0x202, data)

    if result ~= 0 then
        return false
    end

    DiscordIPC.wsa_ready = true
    return true
end

function DiscordIPC.create_socket()
    if DiscordIPC.is_windows then
        if not DiscordIPC.ensure_wsa() then
            return nil
        end

        local sock = DiscordIPC.ws2.socket(AF_UNIX, SOCK_STREAM, 0)

        if sock < 0 then
            return nil
        end

        return sock
    end

    local sock = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)

    if sock < 0 then
        return nil
    end

    return sock
end

function DiscordIPC.close_fd(fd)
    if not fd or fd < 0 then
        return
    end

    if DiscordIPC.is_windows then
        if DiscordIPC.ws2 then
            DiscordIPC.ws2.closesocket(fd)
        end
    else
        ffi.C.close(fd)
    end
end

function DiscordIPC.set_socket_timeouts(fd)
    if DiscordIPC.is_windows then
        return
    end

    local tv = ffi.new("struct timeval")
    tv.tv_sec = 2
    tv.tv_usec = 0

    pcall(function()
        ffi.C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
        ffi.C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof(tv))
    end)
end

function DiscordIPC.set_nonblock(fd)
    if DiscordIPC.is_windows then
        local mode = ffi.new("unsigned long[1]", 1)
        pcall(function()
            DiscordIPC.ws2.ioctlsocket(fd, FIONBIO, mode)
        end)
        return
    end

    pcall(function()
        local flags = ffi.C.fcntl(fd, F_GETFL, 0)

        if flags >= 0 then
            local bor = bit and bit.bor or function(a, b)
                return a + b
            end
            ffi.C.fcntl(fd, F_SETFL, bor(flags, O_NONBLOCK))
        end
    end)
end

function DiscordIPC.unix_connect(fd, path)
    local address = ffi.new("struct sockaddr_un")
    address.sun_family = AF_UNIX

    if #path >= 108 then
        return false
    end

    ffi.fill(address.sun_path, 108)
    ffi.copy(address.sun_path, path)

    local addrlen = ffi.sizeof(address)

    if DiscordIPC.is_windows then
        return DiscordIPC.ws2.connect(
            fd,
            ffi.cast("const struct sockaddr*", address),
            addrlen
        ) == 0
    end

    DiscordIPC.set_socket_timeouts(fd)

    return ffi.C.connect(
        fd,
        ffi.cast("const struct sockaddr*", address),
        addrlen
    ) == 0
end

function DiscordIPC.would_block()
    if DiscordIPC.is_windows then
        if not DiscordIPC.ws2 then
            return false
        end

        return DiscordIPC.ws2.WSAGetLastError() == WSAEWOULDBLOCK
    end

    local err = ffi.errno()
    return err == EAGAIN or err == EWOULDBLOCK or err == EINPROGRESS
end

function DiscordIPC.sock_send(ptr, len, flags)
    if DiscordIPC.is_windows then
        return DiscordIPC.ws2.send(DiscordIPC.socket, ptr, len, flags or 0)
    end

    return ffi.C.send(DiscordIPC.socket, ptr, len, flags or MSG_NOSIGNAL)
end

function DiscordIPC.sock_recv(ptr, len, flags)
    if DiscordIPC.is_windows then
        return DiscordIPC.ws2.recv(DiscordIPC.socket, ptr, len, flags or 0)
    end

    return ffi.C.recv(DiscordIPC.socket, ptr, len, flags or 0)
end

function DiscordIPC.clear_socket_state()
    DiscordIPC.socket = nil
    DiscordIPC.connected = false
    DiscordIPC.unix_mode = false
end

function DiscordIPC.handle_disconnect(allow_immediate_retry)
    local sock = DiscordIPC.socket
    local unix_mode = DiscordIPC.unix_mode
    local win_pipe = DiscordIPC.is_windows and not unix_mode and sock

    DiscordIPC.clear_socket_state()

    if allow_immediate_retry then
        DiscordIPC.retry_at = 0
    end

    if not sock then
        return
    end

    if win_pipe then
        pcall(function()
            sock:close()
        end)
    else
        DiscordIPC.close_fd(sock)
    end
end

function DiscordIPC.recv_exact(nbytes)
    if not DiscordIPC.socket or nbytes <= 0 then
        return nil
    end

    local buf = ffi.new("char[?]", nbytes)
    local got = 0
    local deadline = os.clock() + 2.0

    while got < nbytes do
        local n = DiscordIPC.sock_recv(buf + got, nbytes - got, 0)

        if n > 0 then
            got = got + tonumber(n)
        elseif n == 0 then
            DiscordIPC.handle_disconnect(true)
            return nil
        else
            if DiscordIPC.would_block() then
                if os.clock() > deadline then
                    DiscordIPC.handle_disconnect(true)
                    return nil
                end
            else
                DiscordIPC.handle_disconnect(true)
                return nil
            end
        end
    end

    return ffi.string(buf, nbytes)
end

function DiscordIPC.try_unix_path(path)
    local sock = DiscordIPC.create_socket()

    if not sock then
        return false
    end

    if not DiscordIPC.unix_connect(sock, path) then
        DiscordIPC.close_fd(sock)
        return false
    end

    DiscordIPC.set_nonblock(sock)
    DiscordIPC.socket = sock
    DiscordIPC.unix_mode = true
    DiscordIPC.connected = true

    local opcode = select(1, DiscordIPC.send_handshake())

    if opcode == DiscordIPC.OPCODES.FRAME then
        return true
    end

    DiscordIPC.handle_disconnect()
    return false
end

function DiscordIPC.connect_unix()
    local bases = DiscordIPC.get_base_dirs()

    for i = 0, 9 do
        for _, base in ipairs(bases) do
            for _, sub in ipairs(DiscordIPC.PIPE_PATHS) do
                local path = base.."/"..sub.."discord-ipc-"..i

                if DiscordIPC.try_unix_path(path) then
                    print("Distro :: Connected to Discord IPC (pipe "..i..")")
                    return true
                end
            end
        end
    end

    return false
end

function DiscordIPC.connect_windows_pipes()
    for i = 0, 9 do
        local file, _ = io.open("\\\\.\\pipe\\discord-ipc-"..i, "r+")

        if file then
            print("Distro :: Connected to Discord IPC (pipe "..i..")")
            DiscordIPC.socket = file
        end
    end

    if DiscordIPC.socket then
        DiscordIPC.unix_mode = false
        DiscordIPC.connected = true
        local result, _ = DiscordIPC.send_handshake()

        if result == DiscordIPC.OPCODES.FRAME then
            return true
        end

        DiscordIPC.handle_disconnect()
    end

    return false
end

function DiscordIPC.connect()
    if DiscordIPC.connected and DiscordIPC.socket then
        return true
    end

    DiscordIPC.clear_socket_state()

    if DiscordIPC.is_windows and not DiscordIPC.is_wine then
        for i = 0, 9 do
            local file, _ = io.open("\\\\.\\pipe\\discord-ipc-"..i, "r+")

            if file then
                print("Distro :: Connected to Discord IPC (pipe "..i..")")
                DiscordIPC.socket = file
            end
        end

        if DiscordIPC.socket then
            DiscordIPC.connected = true
            local result, _ = DiscordIPC.send_handshake()

            return result == DiscordIPC.OPCODES.FRAME
        end

        DiscordIPC.retry_at = os.time() + RETRY_INTERVAL
        return false
    end

    local ok, connected = pcall(DiscordIPC.connect_unix)

    if ok and connected then
        return true
    end

    if DiscordIPC.socket then
        DiscordIPC.handle_disconnect()
    end

    if DiscordIPC.is_wine then
        local pipe_ok, pipe_connected = pcall(DiscordIPC.connect_windows_pipes)

        if pipe_ok and pipe_connected then
            return true
        end

        if DiscordIPC.socket then
            DiscordIPC.handle_disconnect()
        end
    end

    DiscordIPC.clear_socket_state()
    DiscordIPC.retry_at = os.time() + RETRY_INTERVAL
    return false
end

function DiscordIPC.reconnect()
    DiscordIPC.close()
    DiscordIPC.last_activity_payload = nil
    return DiscordIPC.connect()
end

function DiscordIPC.try_reconnect()
    local now = os.time()

    if now < (DiscordIPC.retry_at or 0) then
        return false
    end

    DiscordIPC.retry_at = now + RETRY_INTERVAL

    if DiscordIPC.socket then
        DiscordIPC.handle_disconnect()
    end

    DiscordIPC.last_activity_payload = nil
    local ok = DiscordIPC.connect()

    if not ok then
        DiscordIPC.retry_at = now + RETRY_INTERVAL
    end

    return ok
end

function DiscordIPC.tick()
    if DiscordIPC.connected and DiscordIPC.socket then
        return
    end

    if DiscordIPC.try_reconnect() then
        if DiscordIPC.activity and next(DiscordIPC.activity) ~= nil then
            DiscordIPC.send_activity()
        end
    end
end

function DiscordIPC.write(message)
    if not DiscordIPC.socket then
        return false
    end

    if DiscordIPC.is_windows and not DiscordIPC.unix_mode then
        DiscordIPC.socket:seek("end")
        local _, err = DiscordIPC.socket:write(message)
        DiscordIPC.socket:flush()

        if err then
            print("Distro :: Failed to write to Discord IPC - "..err)
            DiscordIPC.handle_disconnect(true)
            return false
        end

        return true
    end

    local len = #message
    local buf = ffi.new("char[?]", len)
    ffi.copy(buf, message, len)

    local offset = 0
    local deadline = os.clock() + 2.0

    while offset < len do
        local sent = DiscordIPC.sock_send(buf + offset, len - offset, DiscordIPC.is_windows and 0 or MSG_NOSIGNAL)

        if sent > 0 then
            offset = offset + tonumber(sent)
        elseif sent == 0 then
            print("Distro :: Failed to write to Discord IPC")
            DiscordIPC.handle_disconnect(true)
            return false
        else
            if DiscordIPC.would_block() then
                if os.clock() > deadline then
                    print("Distro :: Failed to write to Discord IPC")
                    DiscordIPC.handle_disconnect(true)
                    return false
                end
            else
                print("Distro :: Failed to write to Discord IPC")
                DiscordIPC.handle_disconnect(true)
                return false
            end
        end
    end

    return true
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

    local sock = DiscordIPC.socket
    local unix_mode = DiscordIPC.unix_mode
    local win_pipe = DiscordIPC.is_windows and not unix_mode

    pcall(function()
        DiscordIPC.write(Distro.pack(DiscordIPC.OPCODES.CLOSE, 2).."{}")
    end)

    if DiscordIPC.socket == sock then
        if win_pipe then
            pcall(function()
                sock:close()
            end)
        else
            DiscordIPC.close_fd(sock)
        end
    end

    DiscordIPC.clear_socket_state()
    DiscordIPC.last_activity_payload = nil
    print("Distro :: Disconnected from Discord IPC")
end

function DiscordIPC.send(data, opcode)
    return DiscordIPC.write(Distro.pack(opcode, #data)..data)
end

function DiscordIPC.send_handshake()
    if not DiscordIPC.send('{"v": 1, "client_id": "'..DiscordIPC.id..'"}', DiscordIPC.OPCODES.HANDSHAKE) then
        return nil, nil
    end

    return DiscordIPC.receive()
end

function DiscordIPC.send_activity()
    local activity_key = Distro.stringify(DiscordIPC.activity or {})

    if DiscordIPC.connected and DiscordIPC.socket and activity_key == DiscordIPC.last_activity_payload then
        return
    end

    if not DiscordIPC.connected or not DiscordIPC.socket then
        return
    end

    local data = {
        cmd = "SET_ACTIVITY",
        args = {
            pid = Distro.get_pid() or 9999,
            activity = DiscordIPC.activity
        },
        nonce = Distro.get_uuid()
    }

    if DiscordIPC.send(Distro.stringify(data), DiscordIPC.OPCODES.FRAME) then
        DiscordIPC.last_activity_payload = activity_key
    end
end

function DiscordIPC.clear_activity()
    DiscordIPC.last_activity_payload = nil

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

    if DiscordIPC.is_windows and not DiscordIPC.unix_mode then
        opcode, length = Distro.unpack(DiscordIPC.read(8))
        data = DiscordIPC.read(length)
    else
        local header = DiscordIPC.recv_exact(8)

        if not header then
            return nil, nil
        end

        opcode, length = Distro.unpack(header)

        if not length or length < 0 or length > 1048576 then
            DiscordIPC.handle_disconnect(true)
            return nil, nil
        end

        data = DiscordIPC.recv_exact(length)

        if not data then
            return nil, nil
        end
    end

    print("Distro :: Received "..tostring(opcode).." - "..tostring(data))

    return opcode, data
end
