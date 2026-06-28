--
-- FS25_AD_Extension v1.0.0.1
-- Werkstatt-Schnellzugriff fuer AutoDrive (FS25_AutoDrive)
-- Autor: LazyChilla | Lizenz: MIT
--
-- Zugriff auf AD via vehicleType.eventListeners (SpecializationUtil.registerEventListener).
-- Das AD-Environment wird einmalig gecacht, kein wiederholter Scan.
--

ADExtension = {}
ADExtension.workshopMarkerID  = -1
ADExtension.modDirectory      = g_currentModDirectory
ADExtension.initialized       = false
ADExtension.workshopButtonRef = nil
ADExtension.headerH           = 0

-- ============================================================
--  AD-ENVIRONMENT (einmalig gecacht nach erstem Fund)
-- ============================================================
local adEnvCache = nil

local function findAutoDriveInListeners(vehicleType)
    if vehicleType == nil or vehicleType.eventListeners == nil then return nil end
    for _, listeners in pairs(vehicleType.eventListeners) do
        if type(listeners) == "table" then
            for _, obj in ipairs(listeners) do
                if type(obj) == "table" and obj.MODE_DRIVETO ~= nil and obj.loadMap ~= nil then
                    return obj
                end
            end
        end
    end
    return nil
end

local function getADEnv()
    if adEnvCache ~= nil then return adEnvCache end
    if g_vehicleTypeManager == nil or g_vehicleTypeManager.types == nil then return nil end
    for _, vehicleType in pairs(g_vehicleTypeManager.types) do
        local AutoDrive = findAutoDriveInListeners(vehicleType)
        if AutoDrive ~= nil then
            local env = getfenv(AutoDrive.loadMap)
            if env ~= nil and env.AutoDriveHud ~= nil and env.ADInputManager ~= nil then
                if env.AutoDrive == nil then env.AutoDrive = AutoDrive end
                adEnvCache = env
                return adEnvCache
            end
        end
    end
    return nil
end

-- ============================================================
--  PERSISTENZ
-- ============================================================
function ADExtension.getSettingsPath()
    local folder = getUserProfileAppPath() .. "modSettings/FS25_AD_Extension/"
    createFolder(folder)
    return folder .. "workshop_config.xml"
end

function ADExtension.saveSettings()
    local path    = ADExtension.getSettingsPath()
    local xmlFile = createXMLFile("ADExt_XML", path, "ADExtension")
    if xmlFile == nil then return end
    setXMLInt(xmlFile, "ADExtension.workshopMarkerID", ADExtension.workshopMarkerID)
    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function ADExtension.loadSettings()
    local path = ADExtension.getSettingsPath()
    if not fileExists(path) then return end
    local xmlFile = loadXMLFile("ADExt_XML", path)
    if xmlFile == nil then return end
    local id = getXMLInt(xmlFile, "ADExtension.workshopMarkerID")
    if id ~= nil then ADExtension.workshopMarkerID = id end
    delete(xmlFile)
end

-- ============================================================
--  HILFSFUNKTIONEN
-- ============================================================
function ADExtension.getWorkshopMarkerName()
    if ADExtension.workshopMarkerID < 1 then return nil end
    local env = getADEnv()
    if env == nil then return nil end
    local marker = env.ADGraphManager:getMapMarkerById(ADExtension.workshopMarkerID)
    if marker == nil then
        ADExtension.workshopMarkerID = -1
        ADExtension.saveSettings()
        return nil
    end
    return marker.name
end

function ADExtension.hasWorkshopDestination()
    return ADExtension.getWorkshopMarkerName() ~= nil
end

-- ============================================================
--  AKTIONEN
-- ============================================================
function ADExtension.setWorkshopDestination(vehicle)
    if vehicle == nil or vehicle.ad == nil then return end
    local env = getADEnv()
    if env == nil then return end

    local markerID = vehicle.ad.stateModule:getFirstMarkerId()
    if markerID == nil or markerID <= 0 then
        env.AutoDriveMessageEvent.sendMessageOrNotification(
            vehicle, env.ADMessagesManager.messageTypes.ERROR,
            g_i18n:getText("ADExt_workshop_noPosSet"), 5000,
            vehicle.ad.stateModule:getName()
        )
        return
    end

    local mapMarker = env.ADGraphManager:getMapMarkerById(markerID)
    if mapMarker == nil or mapMarker.isADDebug == true then return end

    ADExtension.workshopMarkerID = markerID
    ADExtension.saveSettings()

    local msg = g_i18n:getText("ADExt_workshop_selected") .. " " .. mapMarker.name
    env.ADMessagesManager:addMessage(vehicle, env.ADMessagesManager.messageTypes.INFO, msg, 5000)
end

function ADExtension.driveToWorkshop(vehicle, farmId)
    if vehicle == nil or vehicle.ad == nil then return end
    local env = getADEnv()
    if env == nil then return end

    if not ADExtension.hasWorkshopDestination() then
        env.AutoDriveMessageEvent.sendMessageOrNotification(
            vehicle, env.ADMessagesManager.messageTypes.ERROR,
            g_i18n:getText("ADExt_workshop_noPosSet"), 5000,
            vehicle.ad.stateModule:getName()
        )
        return
    end

    vehicle.ad.stateModule:setFirstMarker(ADExtension.workshopMarkerID)
    env.AutoDrive:StopCP(vehicle)
    if vehicle.ad.stateModule:isActive() then
        env.ADInputManager:input_start_stop(vehicle, farmId)
    end
    vehicle.ad.stateModule:setMode(env.AutoDrive.MODE_DRIVETO)
    env.ADInputManager:input_start_stop(vehicle, farmId)
end

-- ============================================================
--  HOOKS
-- ============================================================
function ADExtension.installHooks()
    if ADExtension.initialized then return end

    local env = getADEnv()
    if env == nil then
        Logging.error("[ADExt] AD-Environment nicht gefunden.")
        return
    end

    local AutoDrive      = env.AutoDrive
    local AutoDriveHud   = env.AutoDriveHud
    local ADInputManager = env.ADInputManager

    -- HUD-Button Hook
    local originalCreateHudAt = AutoDriveHud.createHudAt
    AutoDriveHud.createHudAt = function(self, hudX, hudY)
        originalCreateHudAt(self, hudX, hudY)

        local btnW  = self.buttonWidth
        local btnH  = self.buttonHeight
        local posX  = self.posX + self.width - btnW
        local baseY = self.rowHeader + self.headerHeight + self.gapHeight

        local ovActive   = Overlay.new(ADExtension.modDirectory .. "textures/workshop_active.png",   posX, baseY, btnW, btnH)
        local ovInactive = Overlay.new(ADExtension.modDirectory .. "textures/workshop_inactive.png", posX, baseY, btnW, btnH)

        local headerIconRef = nil
        for _, element in ipairs(self.hudElements) do
            if element.name == "header" then headerIconRef = element; break end
        end

        local uiScale = g_gameSettings:getValue("uiScale")
        if AutoDrive.getSetting("guiScale") ~= 0 then uiScale = AutoDrive.getSetting("guiScale") end
        local lineHeight = getTextHeight(0.011 * uiScale, "text") + self.gapHeight

        local workshopButton = {
            position        = {x = posX, y = baseY},
            size            = {width = btnW, height = btnH},
            isVisible       = false,
            primaryAction   = "input_workshopVehicle",
            secondaryAction = "input_setWorkshopDestination",
            ovActive        = ovActive,
            ovInactive      = ovInactive,
            baseY           = baseY,
            headerRef       = headerIconRef,
            lineHeight      = lineHeight,
            layer           = 0,
        }

        workshopButton.update = function(self2, dt) end

        workshopButton.hit = function(self2, x, y, z)
            return x >= self2.position.x
               and x <= self2.position.x + self2.size.width
               and y >= self2.position.y
               and y <= self2.position.y + self2.size.height
        end

        workshopButton.onDraw = function(self2, vehicle2, uiScale2)
            -- Y-Position immer aktualisieren (auch unsichtbar, fuer hit())
            local extraLines = 0
            if self2.headerRef ~= nil and self2.headerRef.lastLineCount ~= nil then
                extraLines = self2.headerRef.lastLineCount - 1
            end
            local y = self2.baseY + extraLines * self2.lineHeight
            self2.position.y = y

            local env2 = getADEnv()
            local visible = env2 ~= nil
                and env2.AutoDrive ~= nil
                and env2.AutoDrive.Hud ~= nil
                and g_lastMousePosX ~= nil
                and g_inputBinding ~= nil
                and g_inputBinding:getShowMouseCursor()
                and (env2.AutoDrive.pullDownListExpanded == nil or env2.AutoDrive.pullDownListExpanded == 0)
                and env2.AutoDrive.Hud:isMouseOverHud(g_lastMousePosX, g_lastMousePosY) == true

            self2.isVisible = visible
            if not visible then return end

            local ov = ADExtension.hasWorkshopDestination() and self2.ovActive or self2.ovInactive
            ov:setPosition(self2.position.x, y)
            ov:render()
        end

        workshopButton.mouseEvent = function(self2, vehicle2, posX2, posY2, isDown, isUp, button, layer)
            if not self2.isVisible then return false end
            local px, py = self2.position.x, self2.position.y
            if posX2 >= px and posX2 <= px + self2.size.width
               and posY2 >= py and posY2 <= py + self2.size.height then
                vehicle2.ad.sToolTip         = ""
                vehicle2.ad.nToolTipWait     = 5
                vehicle2.ad.sToolTipInfo     = g_i18n:getText("input_ADExt_WorkshopVehicle")
                vehicle2.ad.toolTipIsSetting = false
                if isDown and button == 1 then return true end
                if isUp and button == 1
                    and not AutoDrive.leftLSHIFTmodifierKeyPressed
                    and not AutoDrive.leftCTRLmodifierKeyPressed then
                    ADExtension.driveToWorkshop(vehicle2)
                    return true
                end
                if isUp and (button == 3 or button == 2) then
                    ADExtension.setWorkshopDestination(vehicle2)
                    return true
                end
            end
            return false
        end

        table.insert(self.hudElements, workshopButton)
        ADExtension.workshopButtonRef = workshopButton
        ADExtension.headerH           = self.headerHeight
        if self.refreshHudElementsLayerSequence ~= nil then
            self:refreshHudElementsLayerSequence()
        end
    end

    -- Keybinding Hook
    local originalOnActionCall = ADInputManager.onActionCall
    ADInputManager.onActionCall = function(vehicle2, actionName)
        if actionName == "ADExt_WorkshopVehicle" then
            ADExtension.driveToWorkshop(vehicle2)
            return
        end
        if actionName == "ADExt_SetWorkshopDestination" then
            ADExtension.setWorkshopDestination(vehicle2)
            return
        end
        return originalOnActionCall(vehicle2, actionName)
    end

    ADExtension.initialized = true
    Logging.info("[ADExt] Hooks installiert.")
end

-- ============================================================
--  EINSTIEGSPUNKT
-- ============================================================
if TypeManager ~= nil and TypeManager.validateTypes ~= nil then
    TypeManager.validateTypes = Utils.appendedFunction(
        TypeManager.validateTypes,
        function(self) end
    )
end

ADExtensionRegister = {}

function ADExtensionRegister:loadMap(name)
    if not ADExtension.initialized then
        if getADEnv() ~= nil then
            ADExtension.installHooks()
        else
            Logging.error("[ADExt] AutoDrive-Environment nicht gefunden.")
            return
        end
    end
    if ADExtension.initialized then
        ADExtension.loadSettings()
        Logging.info("[ADExt] Bereit. MarkerID: %d", ADExtension.workshopMarkerID)
    end
end

function ADExtensionRegister:deleteMap()
    ADExtension.initialized       = false
    ADExtension.workshopButtonRef = nil
    adEnvCache                    = nil
end

function ADExtensionRegister:update(dt) end

function ADExtensionRegister:draw()
    if not ADExtension.initialized then return end
    local btn = ADExtension.workshopButtonRef
    if btn == nil or not btn.isVisible then return end

    local env = getADEnv()
    if env == nil or env.AutoDrive == nil or env.AutoDrive.Hud == nil then return end
    if env.AutoDrive.pullDownListExpanded ~= nil and env.AutoDrive.pullDownListExpanded > 0 then return end

    local selfMod = g_modManager:getModByName("FS25_AD_Extension")
    local version = (selfMod ~= nil and selfMod.version ~= nil) and selfMod.version or "1.0.0.1"

    local fontSize = ADExtension.headerH * 0.55
    local textX    = btn.position.x - fontSize * 0.3
    local textY    = btn.position.y + btn.size.height * 0.28

    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(0.9, 0.9, 0.9, 0.85)
    renderText(textX, textY, fontSize, "AD Extension v" .. version)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
end

ItemSystem.save = Utils.appendedFunction(ItemSystem.save, function()
    if ADExtension.initialized then ADExtension.saveSettings() end
end)

addModEventListener(ADExtensionRegister)

Logging.info("[ADExt] FS25_AD_Extension v1.0.0.1 geladen.")
