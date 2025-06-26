--[[--
@module koplugin.readeck
]]

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local Event = require("ui/event")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = FFIUtil.template
local N_ = _.ngettext

local ReadeckApi = require("readeckapi")
local ReadeckBrowser = require("readeckbrowser")
local ReadeckCache = require("readeckcache")

local defaults = require("defaultsettings")

---------====== UTILITY FUNCTIONS ========------

local function parseLabels(labels_str)
    local labels = {}
    for label in labels_str:gmatch("[^,]+") do
        label = label:match("^%s*(.-)%s*$")
        if #label > 0 then -- ignore only whitespace sections
            table.insert(labels, label)
        end
    end

    return labels
end

local function labelsToString(labels)
    return table.concat(labels or {}, ", ")
end


---------====== MODULE ========------

local Readeck = WidgetContainer:extend {
    name = "readeck",
    -- Set by init()
    settings = LuaSettings,
    cache = ReadeckCache,
}

function Readeck:onDispatcherRegisterActions()
    -- TODO do I need actions for anything?
    Dispatcher:registerAction("helloworld_action", {
        category="none",
        event="HelloWorld",
        title=_"Hello World",
        general=true,
    })
end

function Readeck:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/readeck.lua")
    util.makePath(self:getSetting("data_dir"))

    self.cache = ReadeckCache:new{
        settings = self.settings,
    }

    self.api = ReadeckApi:new{
        settings = self.settings,
        cache = self.cache,
    }

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.link then
        self.ui.link:addToExternalLinkDialog("22_readeck", function(this, link_url)
            return {
                text = _"Add to Readeck",
                callback = function()
                    UIManager:close(this.external_link_dialog)
                    this.ui:handleEvent(Event:new("AddArticleToReadeck", link_url))
                end,
            }
        end)
    end
end

function Readeck:onAddArticleToReadeck(article_url)
    if not NetworkMgr:isOnline() then
        -- TODO store article link to upload on next sync
        UIManager:show(InfoMessage:new{
            text = T(_"Not connected to the internet. Couldn't add article:\n%1", BD.url(article_url)),
            timeout = 3,
        })
        return nil, "Not connected"
    end

    -- TODO option to add as favorite, mark as read, or archive immediately
    local labels_text = labelsToString(self:getSetting("default_labels"))
    if #labels_text > 0 then
        labels_text = labels_text .. ", "
    end

    local bookmark_id, err
    local dialog
    dialog = MultiInputDialog:new {
        title = T(_"Create bookmark for %1", BD.url(article_url)),
        fields = {
            {
                description = _"Bookmark title",
                text = "",
                hint = _"Custom title (optional)",
            },
            {
                description = _"Labels",
                text = labels_text,
                hint = _"E.g.: label 1, label 2, ... (optional)",
            },
        },
        buttons = {
            {
                {
                    text = _"Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end
                },
                {
                    text = _"OK",
                    id = "ok",
                    callback = function()
                        local fields = dialog:getFields()
                        local title = fields[1]
                        local labels = parseLabels(fields[2])

                        bookmark_id, err = self.api:bookmarkCreate(article_url, title, labels)

                        UIManager:close(dialog)

                        -- TODO ask if the user wants to open the bookmark now, or favorite it, or archive it
                        UIManager:show(InfoMessage:new {
                            text =
                                bookmark_id
                                and T(_"Bookmark for\n%1\nsuccessfully created.", BD.url(article_url))
                                or T(_"Failed to create bookmark:\n%1", err),
                            timeout = 3,
                        })
                        return  bookmark_id, err
                    end
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()

    return bookmark_id, err
end

function Readeck:addToMainMenu(menu_items)

    menu_items.readeck_bookmarks = {
        text = _"Readeck bookmarks",
        sorting_hint = "search",
        callback = function()
            self.browser = ReadeckBrowser:new{ api = self.api, settings = self.settings }
            UIManager:show(self.browser)
        end,
    }
    menu_items.readeck_settings = {
        text = _"Readeck settings",
        sorting_hint = "search_settings",
        sub_item_table = {
            {
                text = _"Readeck server and credentials",
                keep_menu_open = true,
                callback = function()
                    return self:severConfigDialog()
                end,
            }, {
                text = _"New bookmarks settings",
                keep_menu_open = true,
                callback = function()
                    return self:newBookmarksConfigDialog()
                end,
            }, {
                text = _"Select download directory",
                keep_menu_open = true,
                callback = function()
                    require("ui/downloadmgr"):new{
                        onConfirm = function(path)
                            self.settings:saveSetting("download_dir", path)
                        end,
                    }:chooseDir(self.api:getDownloadDir())
                end,
            },
        },
    }
end

function Readeck:getSetting(setting)
    return self.settings:readSetting(setting, defaults[setting])
end

function Readeck:severConfigDialog()
    local text_info = T(_[[
If you don't want your password being stored in plaintext, you can erase the password field and save the settings after logging in and getting your API token.

You can also edit the configuration file directly in your settings folder:
%1
and then restart KOReader.]], self.settings.file)

    local function saveSettings(fields)
        self.settings:saveSetting("server_url", fields[1]:gsub("/*$", "")) -- remove all trailing slashes
            :saveSetting("username", fields[2])
            :saveSetting("password", fields[3])
            :saveSetting("api_token", fields[4])
            :flush()
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = _"Readeck server settings",
        fields = {
            {
                text = self:getSetting("server_url"),
                hint = _"Server URL"
            }, {
                text = self:getSetting("username"),
                hint = _"Username (if no API Token is given)"
            }, {
                text = self:getSetting("password"),
                text_type = "password",
                hint = _"Password (if no API Token is given)"
            }, {
                text = self:getSetting("api_token"),
                description = _"API Token",
                text_type = "password",
                hint = _"Will be acquired automatically if Username and Password are given."
            },
        },
        buttons = {
            {
                {
                    text = _"Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end
                }, {
                    text = _"Info",
                    callback = function()
                        UIManager:show(InfoMessage:new{ text = text_info })
                    end
                }, {
                    text = _"Save",
                    callback = function()
                        saveSettings(dialog:getFields())
                        UIManager:close(dialog)
                    end
                },
            }, {
                {
                    text = _"Sign in (generate API token) and save",
                    timeout = 5,
                    callback = function()
                        local fields = dialog:getFields()
                        local token, err = self.api:authenticate(fields[2], fields[3])
                        if not token then
                            UIManager:show(InfoMessage:new{ text = err })
                            return
                        end

                        fields[4] = token
                        UIManager:show(InfoMessage:new{
                            text = _"Logged in successfully.",
                            timeout = 5,
                        })

                        saveSettings(fields)
                        UIManager:close(dialog)
                    end,
                }
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Readeck:newBookmarksConfigDialog()
    local function saveSettings(fields)
        self.settings:saveSetting("default_labels", parseLabels(fields[1]))
            :flush()
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = _"New bookmarks settings",
        fields = {
            {
                description = _"Default labels",
                text = labelsToString(self:getSetting("default_labels")),
                hint = _"E.g.: from koreader, label 2, ... (optional)",
            },
        },
        buttons = {
            {
                {
                    text = _"Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end
                }, {
                    text = _"Save",
                    callback = function()
                        saveSettings(dialog:getFields())
                        UIManager:close(dialog)
                    end
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Readeck
