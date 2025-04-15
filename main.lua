--[[--
@module koplugin.readeck
]]

local logger = require("logger")

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Event = require("ui/event")
local Bd = require("ui/bidi")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local FFIUtil = require("ffi/util")
local FileManager = require("apps/filemanager/filemanager")
local InputDialog = require("ui/widget/inputdialog")
local Math = require("optmath")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local ReadHistory = require("readhistory")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = FFIUtil.template


local Api = require("readeckapi")

local defaults = require("defaultsettings")

local Readeck = WidgetContainer:extend {
    name = "readeck",
}

function Readeck:onDispatcherRegisterActions()
    -- TODO do I need actions for anything?
    Dispatcher:registerAction("helloworld_action", {
        category="none",
        event="HelloWorld",
        title=_("Hello World"),
        general=true,
    })
end

function Readeck:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/readeck.lua")
    -- TODO remove debug
    logger:setLevel(logger.levels.dbg)

    -- TODO
    --if not self.settings:readSetting("api_token") then
    --    self:authenticate()
    --end
    self.api = Api:new({
        url = self.settings:readSetting("server_url", defaults.server_url),
        token = self.settings:readSetting("api_token", defaults.api_token)
    })
    if not self.api then
        logger.err("Readeck error: Couldn't load API.")
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self.ui.link:addToExternalLinkDialog("22_readeck", function(this, link_url)
        return {
            text = _("Add to Readeck"),
            callback = function()
                UIManager:close(this.external_link_dialog)
                this.ui:handleEvent(Event:new("AddArticleToReadeck", link_url))
            end,
        }
    end)
end

function Readeck:onAddArticleToReadeck(article_url)
    -- TODO option to add tags, custom title, etc.
    if not NetworkMgr:isOnline() then
        -- TODO store article link to upload on next sync
        UIManager:show(InfoMessage:new{
            text = T(_("Not connected to the internet. Couldn't add article:\n%1"), Bd.url(article_url)),
            timeout = 1,
        })
        return nil, "Not connected"
    end

    local bookmark_id, err = self.api:bookmarkCreate(article_url)
    if bookmark_id then
        UIManager:show(InfoMessage:new{
            text = T(_("Bookmark for %1 successfully created with id %2\n"), Bd.url(article_url), bookmark_id),
            --timeout = 1,
        })
    end

    return bookmark_id, err
end

function Readeck:addToMainMenu(menu_items)
    menu_items.readeck = {
        text = _("Readeck"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Bookmark List"),
                callback = function()
                    -- TODO this is just debugging
                    local result, err = self.api:bookmarkList()
                    local text = ""
                    if result then
                        for key, value in pairs(result) do
                            text = text .. " " .. key .. ": { " .. value.title .. " }"
                        end
                    else
                        text = err
                    end
                    UIManager:show(InfoMessage:new{
                        text = _(text),
                    })
                end,
            },
            {
                text = _("Add bookmark"),
                callback = function()
                    -- TODO this is just debugging
                    local result, err = self.api:bookmarkCreate("https://koreader.rocks/", "", { "Testing", "koplugin" })
                    if result then
                        result = self.api:bookmarkDetails(result)
                        local text = ""
                        for key, value in pairs(result) do
                            text = text .. tostring(key) .. ": " .. tostring(value) .. ",\n"
                        end
                        UIManager:show(InfoMessage:new{
                            text = _(text),
                        })
                        UIManager:show(InfoMessage:new{
                            text = _("Created bookmark " .. tostring(result)),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _(err),
                        })
                    end
                end,
            },
        },
    }
end

function Readeck:onHelloWorld()
    local popup = InfoMessage:new{
        text = _("Hello World"),
    }
    UIManager:show(popup)
end

return Readeck
