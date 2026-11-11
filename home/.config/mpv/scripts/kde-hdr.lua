local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local opts = {
    output = mp.get_opt("kde-hdr-output") or "",
    fallback_output = mp.get_opt("kde-hdr-fallback-output") or "DP-1",
    require_fullscreen = (mp.get_opt("kde-hdr-require-fullscreen") or "yes") ~= "no",
    dry_run = (mp.get_opt("kde-hdr-dry-run") or "no") == "yes",
}

local state = {
    output = nil,
    changed_hdr = false,
    changed_wcg = false,
}

local restore
local sync
local sync_timer

local cache_dir = (os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/mpv"
local state_path = cache_dir .. "/kde-hdr.state"

local function run(argv)
    local res = mp.command_native({
        name = "subprocess",
        args = argv,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    })
    if not res or res.status ~= 0 then
        msg.warn("command failed: " .. table.concat(argv, " "))
        return nil
    end
    return res.stdout
end

local function read_output_states(name)
    local text = run({ "kscreen-doctor", "-o" })
    if not text then return nil end
    text = text:gsub("\27%[[%d;]*m", "")
    local block, inside = nil, false
    for line in text:gmatch("[^\n]+") do
        if line:match("Output:") then
            inside = line:find(" " .. name .. " ", 1, true) ~= nil
        elseif inside then
            block = (block or "") .. line .. "\n"
        end
    end
    if not block then return nil end
    local hdr = block:match("HDR:%s*(%a+)")
    local wcg = block:match("Wide Color Gamut:%s*(%a+)")
    if not hdr then return nil end
    return { hdr = hdr == "enabled", wcg = wcg == "enabled" }
end

local function apply_state(name, hdr, wcg)
    local args = {
        "kscreen-doctor",
        "output." .. name .. ".hdr." .. (hdr and "enable" or "disable"),
        "output." .. name .. ".wcg." .. (wcg and "enable" or "disable"),
    }
    if opts.dry_run then
        msg.info("would run: " .. table.concat(args, " "))
        return true
    end
    return run(args) ~= nil
end

local function target_output()
    if opts.output ~= "" then return opts.output end
    local names = mp.get_property_native("display-names")
    if names and #names > 0 then return names[1] end
    if mp.get_property_native("fullscreen") == true then
        return opts.fallback_output
    end
    return nil
end

local function content_is_hdr()
    local gamma = mp.get_property("video-params/gamma")
    if gamma == "pq" or gamma == "hlg" then return true end
    return mp.get_property("video-params/primaries") == "bt.2020"
end

local function wants_hdr()
    if not content_is_hdr() then return false end
    return not opts.require_fullscreen or mp.get_property_native("fullscreen") == true
end

local function remember()
    os.execute('mkdir -p "' .. cache_dir .. '"')
    local file = io.open(state_path, "w")
    if not file then return end
    file:write(string.format("%d\t%s\t%s\t%s\n", utils.getpid(), state.output,
        tostring(state.changed_hdr), tostring(state.changed_wcg)))
    file:close()
end

local function forget()
    os.remove(state_path)
end

local function recover_stale_state()
    local file = io.open(state_path, "r")
    if not file then return end
    local line = file:read("*l")
    file:close()
    local pid, name, changed_hdr, changed_wcg = (line or ""):match("^(%d+)\t([^\t]+)\t(%a+)\t(%a+)$")
    if not pid then
        forget()
        return
    end
    if tonumber(pid) ~= utils.getpid() and utils.file_info("/proc/" .. pid) then return end
    msg.verbose("recovering HDR state left behind by pid " .. pid)
    apply_state(name, changed_hdr ~= "true", changed_wcg ~= "true")
    forget()
end

local function enable_on(name)
    local before = read_output_states(name)
    if not before then
        msg.warn("could not read the HDR state of " .. name)
        return false
    end
    state.output = name
    state.changed_hdr = not before.hdr
    state.changed_wcg = not before.wcg
    if not state.changed_hdr and not state.changed_wcg then
        msg.verbose(name .. " is already in HDR mode")
        return true
    end
    if not apply_state(name, true, true) then
        state.output = nil
        return false
    end
    remember()
    msg.verbose("enabled HDR on " .. name)
    return true
end

restore = function()
    if not state.output then return end
    local name = state.output
    msg.verbose("restoring " .. name)
    apply_state(name, not state.changed_hdr, not state.changed_wcg)
    state.output = nil
    state.changed_hdr = false
    state.changed_wcg = false
    forget()
end

sync = function()
    if not wants_hdr() then
        restore()
        return
    end
    local name = target_output()
    if not name then
        restore()
        return
    end
    if name == state.output then return end
    restore()
    enable_on(name)
end

local function schedule_sync()
    if sync_timer then sync_timer:kill() end
    sync_timer = mp.add_timeout(0.6, function()
        sync_timer = nil
        sync()
    end)
end

local function has_next_entry()
    local pos = mp.get_property_number("playlist-pos")
    local count = mp.get_property_number("playlist-count")
    return pos ~= nil and count ~= nil and pos + 1 < count
end

local function on_end_file(event)
    if event.reason == "eof" and has_next_entry() then
        schedule_sync()
        return
    end
    restore()
end

mp.register_event("file-loaded", schedule_sync)
mp.register_event("end-file", on_end_file)
mp.register_event("shutdown", restore)
mp.observe_property("fullscreen", "bool", schedule_sync)
mp.observe_property("display-names", "native", schedule_sync)
