local mp = require 'mp'
local msg = require 'mp.msg'

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
    msg.verbose("display-names is empty, using fallback output " .. opts.fallback_output)
    return opts.fallback_output
end

local function content_is_hdr()
    local gamma = mp.get_property("video-params/gamma")
    if gamma == "pq" or gamma == "hlg" then return true end
    return mp.get_property("video-params/primaries") == "bt.2020"
end

local restore

local function enable()
    if not content_is_hdr() then
        restore()
        return
    end
    if state.output then return end
    if opts.require_fullscreen and mp.get_property_native("fullscreen") ~= true then return end
    local name = target_output()
    if not name then
        msg.warn("could not determine which output mpv is on")
        return
    end
    local before = read_output_states(name)
    if not before then
        msg.warn("could not read the HDR state of " .. name)
        return
    end
    state.output = name
    state.changed_hdr = not before.hdr
    state.changed_wcg = not before.wcg
    if not state.changed_hdr and not state.changed_wcg then
        msg.info(name .. " is already in HDR mode")
        return
    end
    if not apply_state(name, true, true) then state.output = nil end
end

function restore()
    if not state.output then return end
    local name = state.output
    apply_state(name, not state.changed_hdr, not state.changed_wcg)
    state.output = nil
    state.changed_hdr = false
    state.changed_wcg = false
end

local function has_next_entry()
    local pos = mp.get_property_number("playlist-pos")
    local count = mp.get_property_number("playlist-count")
    return pos ~= nil and count ~= nil and pos + 1 < count
end

local function on_file_loaded()
    mp.add_timeout(0.5, enable)
end

local function on_end_file(event)
    if event.reason == "eof" and has_next_entry() then
        mp.add_timeout(0.5, enable)
        return
    end
    restore()
end

local function on_fullscreen_change(_, value)
    if value == true then enable() end
end

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", on_end_file)
mp.register_event("shutdown", restore)
mp.observe_property("fullscreen", "bool", on_fullscreen_change)
