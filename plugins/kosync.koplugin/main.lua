local InputContainer = require("ui/widget/container/inputcontainer")
local LoginDialog = require("ui/widget/logindialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local DocSettings = require("docsettings")
local NetworkMgr = require("ui/networkmgr")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Device = require("device")
local Event = require("ui/event")
local DEBUG = require("dbg")
local T = require("ffi/util").template
local _ = require("gettext")
local md5 = require("MD5")

local KOSync = InputContainer:new{
    name = "kosync",
    register_title = _("Register an account in Koreader server"),
    login_title = _("Login to Koreader server"),
}

function KOSync:init()
    local settings = G_reader_settings:readSetting("kosync") or {}
    self.kosync_username = settings.username or ""
    self.kosync_userkey = settings.userkey
    self.ui:registerPostInitCallback(function()
        UIManager:scheduleIn(1, function() self:getProgress() end)
    end)
    self.ui.menu:registerToMainMenu(self)
end

function KOSync:addToMainMenu(tab_item_table)
    table.insert(tab_item_table.plugins, {
        text = _("Progress Sync"),
        sub_item_table = {
            {
                text_func = function()
                    return self.kosync_userkey and (_("Logout"))
                        or _("Register") .. " / " .. _("Login")
                end,
                callback_func = function()
                    return self.kosync_userkey and
                        function() self:logout() end or
                        function() self:login() end
                end,
            },
        }
    })
end

function KOSync:login()
    if NetworkMgr:getWifiStatus() == false then
        NetworkMgr:promptWifiOn()
    end
    self.login_dialog = LoginDialog:new{
        title = self.kosync_username and self.login_title or self.register_title,
        username = self.kosync_username or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    enabled = true,
                    callback = function()
                        self:closeDialog()
                    end,
                },
                {
                    text = _("Login"),
                    enabled = true,
                    callback = function()
                        local username, password = self:getCredential()
                        self:closeDialog()
                        UIManager:scheduleIn(0.5, function()
                            self:doLogin(username, password)
                        end)

                        UIManager:show(InfoMessage:new{
                            text = _("Logging in. Please wait..."),
                            timeout = 1,
                        })
                    end,
                },
                {
                    text = _("Register"),
                    enabled = not self.kosync and true or false,
                    callback = function()
                        local username, password = self:getCredential()
                        self:closeDialog()
                        UIManager:scheduleIn(0.5, function()
                            self:doRegister(username, password)
                        end)

                        UIManager:show(InfoMessage:new{
                            text = _("Registering. Please wait..."),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
        width = Screen:getWidth() * 0.8,
        height = Screen:getHeight() * 0.4,
    }

    self.login_dialog:onShowKeyboard()
    UIManager:show(self.login_dialog)
end

function KOSync:closeDialog()
    self.login_dialog:onClose()
    UIManager:close(self.login_dialog)
end

function KOSync:getCredential()
    return self.login_dialog:getCredential()
end

function KOSync:doRegister(username, password)
    local KOSyncClient = require("KOSyncClient")
    local client = KOSyncClient:new{
        service_spec = self.path .. "/api.json"
    }
    local userkey = md5:sum(password)
    local ok, status, body = pcall(client.register, client, username, userkey)
    if not ok and status then
        UIManager:show(InfoMessage:new{
            text = _("An error occurred while registering:") ..
                "\n" .. status,
        })
    elseif ok then
        if status then
            self.kosync_username = username
            self.kosync_userkey = userkey
            UIManager:show(InfoMessage:new{
                text = _("Registered to Koreader server successfully."),
            })
        else
            UIManager:show(InfoMessage:new{
                text = _(body.message or "Unknown server error"),
            })
        end
    end

    self:onSaveSettings()
end

function KOSync:doLogin(username, password)
    local KOSyncClient = require("KOSyncClient")
    local client = KOSyncClient:new{
        service_spec = self.path .. "/api.json"
    }
    local userkey = md5:sum(password)
    local ok, status, body = pcall(client.authorize, client, username, userkey)
    if not ok and status then
        UIManager:show(InfoMessage:new{
            text = _("An error occurred while logging in:") ..
                "\n" .. status,
        })
    elseif ok then
        if status then
            self.kosync_username = username
            self.kosync_userkey = userkey
            UIManager:show(InfoMessage:new{
                text = _("Logged in to Koreader server successfully."),
            })
        else
            UIManager:show(InfoMessage:new{
                text = _(body.message or "Unknown server error"),
            })
        end
    end

    self:onSaveSettings()
end

function KOSync:logout()
    self.kosync_username = nil
    self.kosync_userkey = nil
    self:onSaveSettings()
end

function KOSync:getLastPercent()
    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastPercent()
    else
        return self.ui.rolling:getLastPercent()
    end
end

function KOSync:getLastProgress()
    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastProgress()
    else
        return self.ui.rolling:getLastProgress()
    end
end

function KOSync:syncToProgress(progress)
    DEBUG("sync to", progress)
    if self.ui.document.info.has_pages then
        self.ui:handleEvent(Event:new("GotoPage", tonumber(progress)))
    else
        self.ui:handleEvent(Event:new("GotoXPointer", progress))
    end
end

function KOSync:updateProgress()
    if self.kosync_username and self.kosync_userkey then
        local KOSyncClient = require("KOSyncClient")
        local client = KOSyncClient:new{
            service_spec = self.path .. "/api.json"
        }
        local doc_digest = self.view.document:fastDigest()
        local progress = self:getLastProgress()
        local percentage = self:getLastPercent()
        local ok, err = pcall(client.update_progress, client,
            self.kosync_username, self.kosync_userkey,
            doc_digest, progress, percentage, Device.model,
            function(ok, body)
                DEBUG("update progress for", self.view.document.file, ok)
            end)
        if not ok and err then
            DEBUG("err:", err)
        end
    end
end

function KOSync:getProgress()
    if self.kosync_username and self.kosync_userkey then
        local KOSyncClient = require("KOSyncClient")
        local client = KOSyncClient:new{
            service_spec = self.path .. "/api.json"
        }
        local doc_digest = self.view.document:fastDigest()
        local ok, err = pcall(client.get_progress, client,
            self.kosync_username, self.kosync_userkey,
            doc_digest, function(ok, body)
                DEBUG("get progress for", self.view.document.file, ok, body)
                if body and body.percentage then
                    local percentage = self:getLastPercent()
                    DEBUG("current progress", percentage)
                    if (body.percentage - percentage) > 0.0001 then
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Sync to furthest location from '%1'?"),
                                body.device),
                            ok_callback = function()
                                self:syncToProgress(body.progress)
                            end,
                        })
                    end
                end
            end)
        if not ok and err then
            DEBUG("err:", err)
        end
    end
end

function KOSync:onSaveSettings()
    local settings = {
        username = self.kosync_username,
        userkey = self.kosync_userkey,
    }
    G_reader_settings:saveSetting("kosync", settings)
end

function KOSync:onCloseDocument()
    DEBUG("on close document")
    self:updateProgress()
end

return KOSync
