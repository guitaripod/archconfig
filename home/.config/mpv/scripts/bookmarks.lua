local mp = require "mp"
local utils = require "mp.utils"

local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/mpv"
local STORE = STATE_DIR .. "/bookmarks.json"
local DUPLICATE_WINDOW = 1
local DELETE_WINDOW = 5

---Returns a stable key for the current media: absolute path or URL.
local function media_key()
    local path = mp.get_property("path")
    if not path then return nil end
    if path:find("^%a[%w+.-]*://") then return path end
    return utils.join_path(mp.get_property("working-directory"), path)
end

---Reads the whole bookmark store, or an empty table when missing or corrupt.
local function load_store()
    local file = io.open(STORE, "r")
    if not file then return {} end
    local raw = file:read("*a")
    file:close()
    return utils.parse_json(raw) or {}
end

---Writes the store through a temp file so a crash never truncates it.
local function save_store(store)
    utils.subprocess({args = {"mkdir", "-p", STATE_DIR}})
    local tmp = STORE .. ".tmp"
    local file = io.open(tmp, "w")
    if not file then
        mp.osd_message("Bookmarks: cannot write " .. STORE)
        return false
    end
    file:write(utils.format_json(store))
    file:close()
    return os.rename(tmp, STORE) ~= nil
end

---Formats seconds as H:MM:SS.
local function format_time(seconds)
    seconds = math.floor(seconds)
    return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
end

---Returns the chapter title at a position, or nil when the file has none.
local function chapter_title_at(time)
    local chapters = mp.get_property_native("chapter-list") or {}
    local title
    for _, chapter in ipairs(chapters) do
        if chapter.time > time then break end
        title = chapter.title
    end
    return title
end

---Human label for a bookmark: time plus its name or chapter.
local function label(bookmark)
    local name = bookmark.name
    if not name or name == "" then name = chapter_title_at(bookmark.t) end
    if name and name ~= "" then
        return string.format("%s  %s", format_time(bookmark.t), name)
    end
    return format_time(bookmark.t)
end

---Returns the current media's bookmarks sorted by time, and the store they live in.
local function current_bookmarks()
    local key = media_key()
    if not key then return nil end
    local store = load_store()
    local list = store[key] or {}
    table.sort(list, function(a, b) return a.t < b.t end)
    return list, store, key
end

---Persists a bookmark list for a key, dropping the key when the list is empty.
local function commit(store, key, list)
    store[key] = #list > 0 and list or nil
    return save_store(store)
end

---Adds a bookmark at the playback position, replacing any within a second.
local function add(name)
    local list, store, key = current_bookmarks()
    local position = mp.get_property_number("time-pos")
    if not list or not position then return end
    for i = #list, 1, -1 do
        if math.abs(list[i].t - position) < DUPLICATE_WINDOW then table.remove(list, i) end
    end
    local bookmark = {t = position, name = name}
    list[#list + 1] = bookmark
    table.sort(list, function(a, b) return a.t < b.t end)
    if commit(store, key, list) then
        mp.osd_message("Bookmarked " .. label(bookmark))
    end
end

---Prompts for a name, then adds the bookmark at the position it was invoked.
local function add_named()
    local position = mp.get_property_number("time-pos")
    if not position then return end
    mp.input.get({
        prompt = "Bookmark name:",
        submit = function(text)
            mp.input.terminate()
            mp.set_property_number("time-pos", position)
            add(text)
        end,
    })
end

---Seeks to a bookmark and shows it on the OSD.
local function jump(bookmark)
    mp.commandv("seek", bookmark.t, "absolute")
    mp.osd_message("Bookmark " .. label(bookmark))
end

---Opens a selector of the file's bookmarks, preselecting the nearest one before now.
local function browse()
    local list = current_bookmarks()
    if not list then return end
    if #list == 0 then
        mp.osd_message("No bookmarks")
        return
    end
    local position = mp.get_property_number("time-pos") or 0
    local items, default = {}, 1
    for i, bookmark in ipairs(list) do
        items[i] = label(bookmark)
        if bookmark.t <= position then default = i end
    end
    mp.input.select({
        prompt = "Bookmarks:",
        items = items,
        default_item = default,
        submit = function(index) jump(list[index]) end,
    })
end

---Seeks to the next (direction 1) or previous (-1) bookmark relative to now.
local function step(direction)
    local list = current_bookmarks()
    local position = mp.get_property_number("time-pos")
    if not list or not position then return end
    local target
    if direction > 0 then
        for _, bookmark in ipairs(list) do
            if bookmark.t > position + DUPLICATE_WINDOW then target = bookmark break end
        end
    else
        for i = #list, 1, -1 do
            if list[i].t < position - DUPLICATE_WINDOW then target = list[i] break end
        end
    end
    if target then jump(target) else mp.osd_message("No more bookmarks") end
end

---Deletes the bookmark closest to the playback position within a few seconds.
local function delete_nearest()
    local list, store, key = current_bookmarks()
    local position = mp.get_property_number("time-pos")
    if not list or not position then return end
    local best, distance
    for i, bookmark in ipairs(list) do
        local d = math.abs(bookmark.t - position)
        if d <= DELETE_WINDOW and (not distance or d < distance) then best, distance = i, d end
    end
    if not best then
        mp.osd_message("No bookmark within " .. DELETE_WINDOW .. "s")
        return
    end
    local removed = table.remove(list, best)
    if commit(store, key, list) then mp.osd_message("Deleted " .. label(removed)) end
end

mp.add_key_binding(nil, "bookmark-add", function() add("") end)
mp.add_key_binding(nil, "bookmark-add-named", add_named)
mp.add_key_binding(nil, "bookmark-browse", browse)
mp.add_key_binding(nil, "bookmark-next", function() step(1) end)
mp.add_key_binding(nil, "bookmark-prev", function() step(-1) end)
mp.add_key_binding(nil, "bookmark-delete", delete_nearest)
