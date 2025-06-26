local socket = require("socket")
local http = require("socket.http")
local url = require("socket.url")
local ltn12 = require("ltn12")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
-- Apparently https://github.com/harningt/luajson
local rapidjson = require("rapidjson")
local logger = require("logger")

local _ = require("gettext")
local T = require("ffi/util").template

local NetworkMgr = require("ui/network/manager")
local LuaSettings = require("luasettings")

local ReadeckCache = require("readeckcache")

local defaults = require("defaultsettings")


local function log_return_error(err_msg)
    err_msg = "Readeck API error: " .. err_msg
    logger.warn(err_msg)
    return nil, err_msg
end

local Api = {
    -- Mandatory
    settings = LuaSettings,
    cache = ReadeckCache,
    -- Optional
    proxy = nil,
}

function Api:new(o)
    o = o or {}
    if not (o.settings and o.cache) then
        logger.warn("Api:new() : Missing constructor parameters")
        return nil, "Missing constructor parameters"
    end

    setmetatable(o, self)
    self.__index = self
    if o.init then o:init() end
    return o
end

function Api:getSetting(setting)
    return self.settings:readSetting(setting, defaults[setting])
end

-------======= API call utilities =======-------

function Api:buildUrl(path, query)
    local target_url = self:getSetting("server_url") .. "/api" .. path .. "?"
    for q, val in pairs(query or {}) do
        if val ~= rapidjson.null then
            if type(val) == "table" then
                -- If an array, add the query several times
                for i, elt in pairs(val) do
                    if elt ~= rapidjson.null then
                        target_url = target_url .. url.escape(q) .. "=" .. url.escape(tostring(elt)) .. "&"
                    end
                end
            else
                target_url = target_url .. url.escape(q) .. "=" .. url.escape(tostring(val)) .. "&"
            end
        end
    end
    return target_url
end

---
-- @param sink
-- @param method GET, POST, DELETE, PATCH, etc…
-- @param path URL endpoint on Readeck server, without "<hostname>/api"
-- @query[opt] query Query to include in the url, if needed
-- @param[opt] body Body to include in the request, if needed
-- @param[opt] headers Defaults to Authorization for API endpoints, none for external
-- @return header, or nil
-- @return nil, or error message
function Api:callApi(sink, method, path, query, body, headers, no_auth)
    local server_url = self:getSetting("server_url")
    if not server_url or server_url:len() == 0 then
        return log_return_error(
            _'Readeck server not defined. Please do so in "Readeck settings ▸ Readeck server and credentials"')
    end
    if not self:getSetting("server_url"):match("^https?://") then
        return log_return_error(
            _'Readeck server URL missing protocol "http://" or "https://".  Please adjust in "Readeck settings ▸ Readeck server and credentials"')
    end

    local api_token = self:getSetting("api_token")
    if not no_auth and (not api_token or api_token:len() == 0) then
        logger.dbg("BABEU")
        local username = self:getSetting("username")
        local password = self:getSetting("password")
        if username and username:len() ~= 0 and password and password:len() ~= 0 then
            logger.dbg("BABEU2")
            local result, err = self:authenticate(username, password)
            if err then
                return result, err
            end
        else
            logger.dbg("BABEU3")
            return log_return_error(
                _'Need authentication, but username and/or password not defined. Please do so in "Readeck settings ▸ Readeck server and credentials"')
        end
    end
    logger.dbg("BABEU4")

    local ret
    NetworkMgr:runWhenOnline(function()
        ret = { self:callApiWhenOnline(sink, method, path, query, body, headers, no_auth) }
    end)

    if ret then
        return table.unpack(ret)
    else
        return log_return_error("Couldn't connect to the internet.")
    end
end

function Api:callApiWhenOnline(sink, method, path, query, body, headers, no_auth)
    local target_url = self:buildUrl(path, query)
    logger.dbg("Readeck API: Sending " .. method .. " " .. target_url)

    headers = headers or {}
    if not headers.Authorization and not no_auth then
        headers.Authorization = "Bearer " .. self:getSetting("api_token")
    end

    local source = body
    if type(body) == "table" then
        -- Convert body to JSON
        -- TODO check if this is still compatible with rapidjson (was maed for "luajson")
        local bodyJson = rapidjson.encode(body)
        logger.dbg("JSON: ", bodyJson)
        source = ltn12.source.string(bodyJson)

        headers["Content-type"] = "application/json"
        headers["Content-Length"] = tostring(#bodyJson)
    end

    local code, header = socket.skip(1, http.request {
        url = target_url,
        method = method,
        headers = headers,
        proxy = self.proxy,
        sink = sink,
        source = source,
    })

    if type(code) ~= "number" then
        return log_return_error(code or _ "Unknown error")
    elseif code >= 400 then
        return log_return_error("Status code " .. code)
    else
        return header
    end
end

function Api:callDownloadApi(file, method, path, query, body, headers, no_auth)
    local sink = ltn12.sink.file(io.open(file, "wb"))
    return self:callApi(sink, method, path, query, body, headers, no_auth)
end

---
-- @return Lua table parsed from response JSON, or nil
-- @return The response headers, or error message
function Api:callJsonApi(method, path, query, body, headers, no_auth)
    headers = headers or {}
    headers["Accept"] = "application/json"

    local response_data = {}
    local sink = ltn12.sink.table(response_data)

    local resp_headers, err = self:callApi(sink, method, path, query, body, headers, no_auth)

    local content = table.concat(response_data, "")
    logger.dbg("Readeck API response: " .. content)

    -- TODO check if this is still compatible with rapidjson (was made for "luajson")
    local json_ok, json_result = pcall(rapidjson.decode, content)

    -- Even if the API call fails (returns > 400), we might still want the response JSON
    if not resp_headers then
        return nil,
            err .. (json_result and json_result.message and T(" (%1)", json_result.message) or ""),
            json_result
    end

    if json_ok then
        -- Empty JSON responses return nil, but we'd want an empty table
        return json_result or {}, resp_headers
    else
        return log_return_error("Failed to parse JSON in response: " .. tostring(json_result))
    end
end

-------======= Concrete API functions =======-------

-- -- User Profile

--- See https://your.readeck/docs/api#post-/auth
function Api:authenticate(username, password)
    if not username or not password or username == "" or password == "" then
        return nil, "Please provide both username and password."
    end

    -- Get my hostname for more informative API token name
    local hostname
    local cmd_out, err, err_code = io.popen("hostname")
    if cmd_out then
        hostname = cmd_out:read("*l")
        cmd_out:close()
    else
        logger.dbg("Readeck: 'hostname' command failed: " .. err .. " (" .. tostring(err_code) .. ")")
    end

    -- Request API token creation
    local body = {
        application = "readeck.koplugin" .. (hostname and (" @ " .. hostname) or ""),
        username = username,
        password = password,
        roles = { "scoped_bookmarks_r", "scoped_bookmarks_w" }
    }
    local result, err, err_json = self:callJsonApi("POST", "/auth", nil, body, nil, true)
    if not result then
        return result, err_json and err_json.message or err
    end

    if result.token then
        self.settings:saveSetting("api_token", result.token)
    end
    return result.token
end

--- See https://your.readeck/docs/api#get-/profile
function Api:userProfile()
    return self:callJsonApi("GET", "/profile")
end

-- -- Bookmarks

--- See https://your.readeck/docs/api#get-/bookmarks
function Api:bookmarkList(query, cache_entry)
    -- TODO define limits and pagination?
    local result, err = self:callJsonApi("GET", "/bookmarks", query)
    if result and cache_entry then
        self.cache:cacheBookmarkList(cache_entry, result)
    elseif cache_entry then
        logger.dbg("ReadeckApi:bookmarkList() : Couldn't fetch bookmark list. Loading from cache entry:", cache_entry)
        result = self.cache:getCachedBookmarksFromList(cache_entry)
    end
    return result, err
end

--- See https://your.readeck/docs/api#post-/bookmarks
-- @return The new bookmark's id, or nil
-- @return nil, or error message
function Api:bookmarkCreate(bookmark_url, title, labels)
    local response, headers = self:callJsonApi("POST", "/bookmarks", {}, {
        url = bookmark_url,
        title = #title ~= 0 and title or nil,
        labels = #labels ~= 0 and labels or nil,
    })
    if not response or not headers then
        return response, headers
    end

    logger.dbg("Readeck: Bookmark created:", tostring(headers["bookmark-id"]))
    return headers["bookmark-id"]
end

--- See http://your.readeck/docs/api#get-/bookmarks/-id-
-- @return A table with the bookmark's details
function Api:bookmarkDetails(id)
    return self:callJsonApi("GET", "/bookmarks/" .. id)
end

-- TODO bookmarkDelete
-- TODO bookmarkUpdate

-- TODO bookmarkArticle?

--- See https://your.readeck/docs/api#get-/bookmarks/-id-/article.-format-
-- @return Response header, or nil
-- @return nil, or error message
function Api:bookmarkExport(file, id)
    return self:callDownloadApi(file, "GET", "/bookmarks/" .. id .. "/article.epub", nil, nil,
        { ["Accept"] = "application/epub+zip" })
end

-- -- Labels

--- See https://your.readeck/docs/api#get-/bookmarks/labels
function Api:labelList()
    local result, err = self:callJsonApi("GET", "/bookmarks/labels")
    if result then
        self.cache:cacheLabelList(result)
    else
        logger.dbg("ReadeckApi:labelList() : Couldn't fetch label list. Loading cache entry.")
        result = self.cache:getCachedLabelList()
    end
    return result, err
end

-- TODO labelInfo
-- TODO labelDelete
-- TODO labelUpdate


-- -- Highlights
-- TODO highlightList
-- TODO bookmarkHighlights
-- TODO highlightCreate
-- TODO highlightDelete
-- TODO highlightUpdate


-- -- Collections

--- See https://your.readeck/docs/api#get-/bookmarks/collections
function Api:collectionList()
    -- TODO define limits and pagination?
    local result, err = self:callJsonApi("GET", "/bookmarks/collections")
    if result then
        self.cache:cacheCollectionList(result)
    else
        logger.dbg("ReadeckApi:collectionList() : Couldn't fetch collection list. Loading cache entry.")
        result = self.cache:getCachedCollectionList()
    end
    return result, err
end

-- TODO collectionCreate

--- See https://your.readeck/docs/api#get-/bookmarks/collections/-id-
function Api:collectionDetails(id)
    return self:callJsonApi("GET", "/bookmarks/collections/" .. id)
end

-- TODO collectionDelete
-- TODO collectionUpdate


-------======= Other functions =======-------

function Api:getDownloadDir()
    local ret = self:getSetting("download_dir")
    if not ret or ret == "" then
        ret = self:getSetting("data_dir") .. "/downloaded"
    end
    
    return ret
end

function Api:getBookmarkFilename(bookmark)
    return self:getDownloadDir() .. "/" .. util.getSafeFilename(bookmark.id .. ".epub")
end

function Api:bookmarkDownloaded(bookmark)
    return util.fileExists(self:getBookmarkFilename(bookmark))
end

-- From https://forums.solar2d.com/t/convert-string-to-date/309743/2
local function makeTimeStamp(dateString)
    -- 2025-04-20T11:19:34.431815474Z
    local year, month, day, hour, minute, seconds, offset, offsethour, offsetmin =
        dateString:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+).%d+([%+%-])(%d+)%:(%d+)")
    local offsetTimestamp
    if year then
        offsetTimestamp = offsethour * 60 + offsetmin
        if offset == "-" then offsetTimestamp = offsetTimestamp * -1 end
    else
        year, month, day, hour, minute, seconds =
            dateString:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+).%d+Z")
        offsetTimestamp = 0
    end
    local convertedTimestamp = os.time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = minute,
        sec = seconds
    })
    return convertedTimestamp + offsetTimestamp
end

function Api:applyBookmarkDetails(bookmark)
    if not self:bookmarkDownloaded(bookmark) then
        return nil, "Bookmark not downloaded"
    end

    -- TODO apply reading progress and title
end

function Api:uploadBookmarkDetails(bookmark)
    if not self:bookmarkDownloaded(bookmark) then
        return nil, "Bookmark not downloaded"
    end

    -- TODO upload reading progress and title
end

-- TODO function not tested
function Api:syncBookmarkDetails(bookmark)
    if not self:bookmarkDownloaded(bookmark) then
        return nil, "Bookmark not downloaded"
    end

    local file = self:getBookmarkFilename(bookmark)
    local localtime, err = lfs.attributes(file, 'modification')
    if err then
        logger.dbg("LFS: " .. err)
        return nil, err
    end

    local ok, result = pcall(makeTimeStamp, bookmark.updated)
    if not ok then
        logger.dbg("Error making timestamp: " .. result)
        return nil, result
    end
    local remotetime = result

    if localtime > remotetime then
        return self:uploadBookmarkDetails(bookmark)
    else
        return self:applyBookmarkDetails(bookmark)
    end
end

--- Shortcut for bookmarkExport with a properly named file
-- @return the filepath, or nil
-- @return true if already downloaded, or error message
function Api:downloadBookmark(bookmark)
    local file = self:getBookmarkFilename(bookmark)
    if util.fileExists(file) then
        return file, true
    end

    util.makePath(self:getDownloadDir())

    local result, err = self:callDownloadApi(file, "GET", "/bookmarks/" .. bookmark.id .. "/article.epub",
        nil, nil, { ["Accept"] = "application/epub+zip" })
    if result then
        self:applyBookmarkDetails(bookmark)
        return file, false
    else
        util.removeFile(file)
        return result, err
    end
end

return Api
