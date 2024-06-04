--- STEAMODDED HEADER
--- MOD_NAME: Distro
--- MOD_ID: Distro
--- MOD_AUTHOR: [DVRP]
--- MOD_DESCRIPTION: Adds Discord Rich Presence support
--- VERSION: 1.0.0

----------------------------------------------
------------MOD CODE -------------------------

Distro = {}

if SMODS.Atlas then
    SMODS.Atlas({
        key = "modicon",
        path = "icon.png",
        px = 34,
        py = 34
    })
end

local main_menu_ref = Game.main_menu
function Game:main_menu(change_context)
    main_menu_ref(self, change_context)

    if not Distro.initialized then
        local path = SMODS.findModByID and SMODS.findModByID("Distro").path or SMODS.Mods["Distro"].path

        NFS.load(path.."discord-rpc.lua")()
        NFS.load(path.."util.lua")()
        Distro.initialized = true
    end

    if not DiscordIPC.connected and not DiscordIPC.connect() then
        print("Distro :: Failed to connect to Discord IPC")
        DiscordIPC.reconnect()
    end

    DiscordIPC.activity = {
        details = "Idling",
        timestamps = {
            start = os.time() * 1000
        },
        assets = {
            large_image = "default"
        }
    }
    DiscordIPC.send_activity()
end

local start_run_ref = Game.start_run
function Game:start_run(args)
    start_run_ref(self, args)

    local back_key = G.GAME.selected_back.effect.center.key
    local is_back_vanilla = get_index(Distro.decks, back_key)
    local stake_name = G.P_CENTER_POOLS.Stake[G.GAME.stake].name:gsub("Chip", "Stake")
    local is_stake_vanilla = Distro.stakes[G.GAME.stake]

    DiscordIPC.activity = {
        details = "Ante "..G.GAME.round_resets.ante,
        state = "Selecting Blind",
        timestamps = {
            start = os.time() * 1000
        },
        assets = {
            large_image = is_back_vanilla and back_key or "b_unknown",
            large_text = G.GAME.selected_back.name..(is_back_vanilla and "" or " (Modded)"),
            small_image = Distro.stakes[G.GAME.stake] or "stake_unknown",
            small_text = stake_name..(is_stake_vanilla and "" or " (Modded)")
        }
    }

    if G.GAME.challenge then
        for _, v in ipairs(G.CHALLENGES) do
            if v.id == G.GAME.challenge then
                DiscordIPC.activity.assets.small_text = "Challenge ("..v.name..")"

                break
            end
        end
    end

    DiscordIPC.send_activity()
end

local update_blind_select_ref = Game.update_blind_select
function Game:update_blind_select(dt)
    if not G.STATE_COMPLETE then
        DiscordIPC.activity.state = "Selecting Blind"
        DiscordIPC.send_activity()
    end

    update_blind_select_ref(self, dt)
end

local update_selecting_hand_ref = Game.update_selecting_hand
function Game:update_selecting_hand(dt)
    if not G.STATE_COMPLETE then
        DiscordIPC.activity.details = "Ante "..G.GAME.round_resets.ante.." | "..G.GAME.blind.name
        DiscordIPC.activity.state = G.GAME.current_round.hands_left.." Hands, "..G.GAME.current_round.discards_left.." Discards left"
        DiscordIPC.send_activity()
    end

    update_selecting_hand_ref(self, dt)
end

local update_shop_ref = Game.update_shop
function Game:update_shop(dt)
    if not G.STATE_COMPLETE then
        DiscordIPC.activity.details = "Ante "..G.GAME.round_resets.ante.." | Round "..G.GAME.round
        DiscordIPC.activity.state = "In Shop"
        DiscordIPC.send_activity()
    end

    update_shop_ref(self, dt)
end

local quit_ref = G.FUNCS.quit
function G.FUNCS.quit(e)
    DiscordIPC.close()
    quit_ref(e)
end