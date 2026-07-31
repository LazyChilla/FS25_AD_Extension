--
-- FS25_AD_Extension v1.3.0.0
-- Refresh-Button (fest, Platz 1) + Werkstatt-Button (fest, Platz 2)
-- + dynamische Slots (links davon) + Icon-Picker
-- Autor: LazyChilla | Lizenz: MIT
--
-- Bedienung:
--   Linksklick          = Fahre zu Ziel
--   Rechtsklick         = AD-Ziel setzen
--   SHIFT+Linksklick    = Dynamischen Button loeschen
--   + Button            = Icon-Picker oeffnen/schliessen
--
--   Refresh-Button (ganz rechts):
--     Linksklick        = vorherigen AD-Zustand wiederherstellen
--     Rechtsklick       = aktuellen AD-Zustand merken
--     Tooltip           = zeigt "Zurueck zu: <Ziel>"
--   Der vorherige Zustand wird ausserdem AUTOMATISCH gemerkt, bevor
--   ueber einen Icon-Slot oder die Werkstatt ein neues Ziel gesetzt wird
--   (1 Ebene tief), und ueberlebt pro Fahrzeug das Neuladen (Spielstand).
--

ADExtension = {}
ADExtension.modDirectory      = g_currentModDirectory
ADExtension.initialized       = false
-- Werkstatt (fester Button, Platz 2)
ADExtension.workshopMarkerID  = -1
ADExtension.workshopButtonRef = nil
-- Refresh (fester Button, Platz 1)
ADExtension.refreshButtonRef  = nil
-- Dynamische Slots
ADExtension.slots             = {}    -- [{icon, markerID}]
ADExtension.buttonRefs        = {}
ADExtension.plusRef           = nil
-- Picker
ADExtension.pickerOpen        = false
ADExtension.pickerRefs        = {}
ADExtension.pickerOvs         = nil
-- Zustand
ADExtension.headerH           = 0
ADExtension.hudSelf           = nil
ADExtension.clickCooldown     = 0
ADExtension.pendingRefresh    = false
ADExtension.schemaRegistered  = false

ADExtension.ICONS = {
    "silo","kalk","duenger","saatgut",
    "fabrik","tank","kuh","huhn","schwein","ziege","schaf","pferd",
    "lager","traktor","mahdrescher","anhaenger","wald",
    "biogas","windrad","solar","biene","fisch",
    "location","zahnrad",
}

-- ============================================================
--  AD-ENVIRONMENT
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
        local ad = findAutoDriveInListeners(vehicleType)
        if ad ~= nil then
            local env = getfenv(ad.loadMap)
            if env ~= nil and env.AutoDriveHud ~= nil and env.ADInputManager ~= nil then
                if env.AutoDrive == nil then env.AutoDrive = ad end
                adEnvCache = env
                return adEnvCache
            end
        end
    end
    return nil
end

-- ============================================================
--  PERSISTENZ (Button-Layout, global in modSettings)
-- ============================================================
function ADExtension.getSettingsPath()
    local folder = getUserProfileAppPath() .. "modSettings/FS25_AD_Extension/"
    createFolder(folder)
    return folder .. "buttons_config.xml"
end

function ADExtension.saveSettings()
    local path    = ADExtension.getSettingsPath()
    local xmlFile = createXMLFile("ADExt_XML", path, "ADExtension")
    if xmlFile == nil then return end
    -- Werkstatt (fest)
    setXMLInt(xmlFile, "ADExtension.workshop#markerID", ADExtension.workshopMarkerID)
    -- Dynamische Slots
    setXMLInt(xmlFile, "ADExtension#slotCount", #ADExtension.slots)
    for i, slot in ipairs(ADExtension.slots) do
        local key = string.format("ADExtension.slot(%d)", i - 1)
        setXMLString(xmlFile, key .. "#icon",     slot.icon)
        setXMLInt(xmlFile,    key .. "#markerID", slot.markerID)
    end
    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function ADExtension.loadSettings()
    local path = ADExtension.getSettingsPath()
    if not fileExists(path) then return end
    local xmlFile = loadXMLFile("ADExt_XML", path)
    if xmlFile == nil then return end
    -- Werkstatt
    local wsID = getXMLInt(xmlFile, "ADExtension.workshop#markerID")
    if wsID ~= nil then ADExtension.workshopMarkerID = wsID end
    -- Dynamische Slots
    local count = getXMLInt(xmlFile, "ADExtension#slotCount") or 0
    ADExtension.slots = {}
    for i = 0, count - 1 do
        local key  = string.format("ADExtension.slot(%d)", i)
        local icon = getXMLString(xmlFile, key .. "#icon") or "location"
        local mid  = getXMLInt(xmlFile,    key .. "#markerID") or -1
        table.insert(ADExtension.slots, {icon = icon, markerID = mid})
    end
    delete(xmlFile)
end

-- ============================================================
--  XML-SCHEMA (Snapshot-Felder im Savegame-Schema anmelden)
-- ============================================================
-- FS25 validiert vehicles.xml gegen ein registriertes Schema. Unsere
-- Zusatz-Attribute unter dem AutoDrive-Zweig muessen im gleichen Schema
-- (Vehicle.xmlSchemaSavegame) angemeldet werden, sonst "Path not registered".
-- Muss VOR dem Laden der Fahrzeuge aus dem Spielstand passieren.
function ADExtension.registerSchemaPaths()
    if ADExtension.schemaRegistered then return end
    if Vehicle == nil or Vehicle.xmlSchemaSavegame == nil or XMLValueType == nil then return end
    local s = Vehicle.xmlSchemaSavegame
    s:register(XMLValueType.INT,    "vehicles.vehicle(?).AutoDrive#ADExt_prevMode",        "ADExt: vorheriger Modus")
    s:register(XMLValueType.INT,    "vehicles.vehicle(?).AutoDrive#ADExt_prevFirst",       "ADExt: vorheriger erster Marker")
    s:register(XMLValueType.INT,    "vehicles.vehicle(?).AutoDrive#ADExt_prevSecond",      "ADExt: vorheriger zweiter Marker")
    s:register(XMLValueType.BOOL,   "vehicles.vehicle(?).AutoDrive#ADExt_prevActive",      "ADExt: war aktiv")
    s:register(XMLValueType.BOOL,   "vehicles.vehicle(?).AutoDrive#ADExt_prevHelper",      "ADExt: Helfer starten")
    s:register(XMLValueType.INT,    "vehicles.vehicle(?).AutoDrive#ADExt_prevFillType",    "ADExt: Fuellgut")
    s:register(XMLValueType.STRING, "vehicles.vehicle(?).AutoDrive#ADExt_prevSelFill",     "ADExt: Fuellgut-Auswahl")
    s:register(XMLValueType.INT,    "vehicles.vehicle(?).AutoDrive#ADExt_prevLoopCounter", "ADExt: Schleifenzaehler")
    s:register(XMLValueType.INT,    "vehicles.vehicle(?).AutoDrive#ADExt_prevLoopsDone",   "ADExt: Schleifen erledigt")
    ADExtension.schemaRegistered = true
end

-- ============================================================
--  PERSISTENZ (Snapshot pro Fahrzeug, im Spielstand am AD-Key)
-- ============================================================
-- Werden per Utils.appendedFunction an ADStateModule:saveToXMLFile /
-- :readFromXMLFile gehaengt (siehe installHooks). key ist dort bereits
-- der AD-eigene Fahrzeug-Key, self.vehicle ist das Fahrzeug.
function ADExtension.onStateSave(stateModule, xmlFile, key)
    local v = stateModule ~= nil and stateModule.vehicle or nil
    if v == nil or xmlFile == nil then return end
    local prev = v.ADExt_prev
    if prev == nil or prev.firstMarkerId == nil or prev.firstMarkerId <= 0 then return end
    xmlFile:setValue(key .. "#ADExt_prevMode",        prev.mode or 1)
    xmlFile:setValue(key .. "#ADExt_prevFirst",       prev.firstMarkerId)
    xmlFile:setValue(key .. "#ADExt_prevSecond",      prev.secondMarkerId or -1)
    xmlFile:setValue(key .. "#ADExt_prevActive",      prev.wasActive == true)
    xmlFile:setValue(key .. "#ADExt_prevHelper",      prev.startHelper == true)
    xmlFile:setValue(key .. "#ADExt_prevFillType",    prev.fillType or 0)
    xmlFile:setValue(key .. "#ADExt_prevSelFill",     table.concat(prev.selectedFillTypes or {}, ","))
    xmlFile:setValue(key .. "#ADExt_prevLoopCounter", prev.loopCounter or 0)
    xmlFile:setValue(key .. "#ADExt_prevLoopsDone",   prev.loopsDone or 0)
end

function ADExtension.onStateRead(stateModule, xmlFile, key)
    local v = stateModule ~= nil and stateModule.vehicle or nil
    if v == nil or xmlFile == nil then return end
    if not xmlFile:hasProperty(key) then return end
    local first = xmlFile:getValue(key .. "#ADExt_prevFirst")
    if first == nil or first <= 0 then return end
    -- Fuellgut-Auswahl (Komma-Liste) parsen
    local selStr  = xmlFile:getValue(key .. "#ADExt_prevSelFill")
    local selList = {}
    if selStr ~= nil and selStr ~= "" then
        for tok in string.gmatch(selStr, "([^,]+)") do
            local n = tonumber(tok)
            if n ~= nil then selList[#selList + 1] = n end
        end
    end
    v.ADExt_prev = {
        mode              = xmlFile:getValue(key .. "#ADExt_prevMode")        or 1,
        firstMarkerId     = first,
        secondMarkerId    = xmlFile:getValue(key .. "#ADExt_prevSecond")      or -1,
        wasActive         = xmlFile:getValue(key .. "#ADExt_prevActive")      == true,
        startHelper       = xmlFile:getValue(key .. "#ADExt_prevHelper")      == true,
        fillType          = xmlFile:getValue(key .. "#ADExt_prevFillType")    or 0,
        selectedFillTypes = selList,
        loopCounter       = xmlFile:getValue(key .. "#ADExt_prevLoopCounter") or 0,
        loopsDone         = xmlFile:getValue(key .. "#ADExt_prevLoopsDone")   or 0,
    }
end

-- ============================================================
--  HILFSFUNKTIONEN
-- ============================================================
local function isHudVisible()
    local env = getADEnv()
    return env ~= nil
        and env.AutoDrive ~= nil
        and env.AutoDrive.Hud ~= nil
        and g_lastMousePosX ~= nil
        and g_inputBinding ~= nil
        and g_inputBinding:getShowMouseCursor()
        and (env.AutoDrive.pullDownListExpanded == nil or env.AutoDrive.pullDownListExpanded == 0)
        and env.AutoDrive.Hud:isMouseOverHud(g_lastMousePosX, g_lastMousePosY) == true
end

local function getButtonY(self2)
    local extra = 0
    if self2.headerRef ~= nil and self2.headerRef.lastLineCount ~= nil then
        extra = self2.headerRef.lastLineCount - 1
    end
    return self2.baseY + extra * self2.lineHeight
end

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

function ADExtension.getSlotMarkerName(slotIdx)
    local slot = ADExtension.slots[slotIdx]
    if slot == nil or slot.markerID < 1 then return nil end
    local env = getADEnv()
    if env == nil then return nil end
    local marker = env.ADGraphManager:getMapMarkerById(slot.markerID)
    if marker == nil then
        slot.markerID = -1
        ADExtension.saveSettings()
        return nil
    end
    return marker.name
end

-- Name des gemerkten Vorher-Ziels (oder nil). Raeumt ungueltige Snapshots auf.
-- MP: Server/Host liest den echten Snapshot (ADExt_prev), der Client den per
-- ADExtSnapshotEvent synchronisierten Anzeige-Schatten (ADExt_prevShadow).
function ADExtension.getPrevMarkerName(vehicle)
    if vehicle == nil then return nil end
    local prev     = vehicle.ADExt_prev
    local markerId = nil
    if prev ~= nil and prev.firstMarkerId ~= nil and prev.firstMarkerId >= 1 then
        markerId = prev.firstMarkerId
    elseif vehicle.ADExt_prevShadow ~= nil and vehicle.ADExt_prevShadow >= 1 then
        markerId = vehicle.ADExt_prevShadow
    end
    if markerId == nil then return nil end
    local env = getADEnv()
    if env == nil then return nil end
    local marker = env.ADGraphManager:getMapMarkerById(markerId)
    if marker == nil then
        if prev ~= nil then vehicle.ADExt_prev = nil end
        vehicle.ADExt_prevShadow = nil
        return nil
    end
    return marker.name
end

-- ============================================================
--  SNAPSHOT (vorheriger AD-Zustand)
-- ============================================================
-- Merkt den aktuellen AD-Zustand des Fahrzeugs (1 Ebene tief).
-- Nur wenn ein echtes Ziel gesetzt ist.
function ADExtension.captureState(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then return end
    local sm = vehicle.ad.stateModule
    local firstId = sm:getFirstMarkerId()
    if firstId == nil or firstId <= 0 then return end
    -- selectedFillTypes ist eine LIVE-Tabelle -> kopieren, sonst mutiert der Snapshot mit
    local selCopy = {}
    local sel = sm:getSelectedFillTypes()
    if sel ~= nil then
        for _, ft in ipairs(sel) do selCopy[#selCopy + 1] = ft end
    end
    vehicle.ADExt_prev = {
        mode              = sm:getMode(),
        firstMarkerId     = firstId,
        secondMarkerId    = sm:getSecondMarkerId() or -1,
        wasActive         = sm:isActive() == true,
        startHelper       = sm:getStartHelper() == true,
        fillType          = sm:getFillType(),
        selectedFillTypes = selCopy,
        loopCounter       = sm:getLoopCounter(),
        loopsDone         = sm:getLoopsDone(),
    }
end

-- Stellt den gemerkten Zustand wieder her (Refresh, Linksklick).
function ADExtension.restorePrevState(vehicle, farmId)
    if vehicle == nil or vehicle.ad == nil then return end
    local env = getADEnv()
    if env == nil then return end
    local sm   = vehicle.ad.stateModule
    local name = ADExtension.getPrevMarkerName(vehicle)  -- prueft Gueltigkeit
    if name == nil then
        env.AutoDriveMessageEvent.sendMessageOrNotification(
            vehicle, env.ADMessagesManager.messageTypes.ERROR,
            g_i18n:getText("ADExt_noPrevState"), 5000,
            sm:getName()
        )
        return
    end
    local prev = vehicle.ADExt_prev
    sm:setFirstMarker(prev.firstMarkerId)
    if prev.secondMarkerId ~= nil and prev.secondMarkerId > 0 then
        sm:setSecondMarker(prev.secondMarkerId)
    end
    -- Fuellgut, Helfer und Schleifen wiederherstellen (fuer Load/Unload/Pickup-Jobs)
    if prev.fillType ~= nil and prev.fillType > 0 then
        sm:setFillType(prev.fillType)
    end
    if prev.selectedFillTypes ~= nil and #prev.selectedFillTypes > 0 then
        local selCopy = {}
        for _, ft in ipairs(prev.selectedFillTypes) do selCopy[#selCopy + 1] = ft end
        sm.selectedFillTypes = selCopy
    end
    if prev.startHelper ~= nil then sm:setStartHelper(prev.startHelper) end
    if prev.loopCounter ~= nil then sm.loopCounter = prev.loopCounter end
    if prev.loopsDone  ~= nil then sm:setLoopsDone(prev.loopsDone) end
    env.AutoDrive:StopCP(vehicle)
    if sm:isActive() then
        env.ADInputManager:input_start_stop(vehicle, farmId)   -- laufende Fahrt stoppen
    end
    sm:setMode(prev.mode or env.AutoDrive.MODE_DRIVETO)
    if prev.wasActive then
        env.ADInputManager:input_start_stop(vehicle, farmId)   -- Vorher fuhr -> wieder losfahren
    end
    env.ADMessagesManager:addMessage(vehicle, env.ADMessagesManager.messageTypes.INFO,
        g_i18n:getText("ADExt_restored") .. name, 5000)
end

-- Merkt den aktuellen Zustand manuell (Refresh, Rechtsklick).
function ADExtension.capturePrevState(vehicle)
    if vehicle == nil or vehicle.ad == nil then return end
    local env = getADEnv()
    if env == nil then return end
    local sm = vehicle.ad.stateModule
    ADExtension.captureState(vehicle)
    local name = ADExtension.getPrevMarkerName(vehicle)
    if name ~= nil then
        env.ADMessagesManager:addMessage(vehicle, env.ADMessagesManager.messageTypes.INFO,
            g_i18n:getText("ADExt_saved") .. name, 5000)
    else
        env.AutoDriveMessageEvent.sendMessageOrNotification(
            vehicle, env.ADMessagesManager.messageTypes.ERROR,
            g_i18n:getText("ADExt_noPosSet"), 5000,
            sm:getName()
        )
    end
end

-- Lokale (client-sichere) Fehlermeldung "kein Ziel gesetzt".
-- WICHTIG: AutoDriveMessageEvent.* darf auf einem Client NICHT aufgerufen
-- werden (loggt "A client is trying to send a message event" + Callstack).
-- Fuer lokale Anzeige immer direkt ADMessagesManager:addMessage nutzen.
function ADExtension.notifyNoDest(vehicle)
    local env = getADEnv()
    if env == nil or vehicle == nil then return end
    env.ADMessagesManager:addMessage(vehicle,
        env.ADMessagesManager.messageTypes.ERROR,
        g_i18n:getText("ADExt_noPosSet"), 5000)
end

-- ============================================================
--  AKTIONEN WERKSTATT
-- ============================================================
-- Werkstattziel setzen = reine Buchhaltung -> LOKAL beim klickenden Spieler.
-- Liest den aktuellen (synchronisierten) Marker und merkt ihn in der eigenen
-- Button-Konfiguration. Kein Server-Event noetig.
function ADExtension.setWorkshopDestination(vehicle)
    if vehicle == nil or vehicle.ad == nil then return end
    local env = getADEnv()
    if env == nil then return end
    local markerID = vehicle.ad.stateModule:getFirstMarkerId()
    if markerID == nil or markerID <= 0 then
        ADExtension.notifyNoDest(vehicle)
        return
    end
    local mapMarker = env.ADGraphManager:getMapMarkerById(markerID)
    if mapMarker == nil or mapMarker.isADDebug == true then return end
    ADExtension.workshopMarkerID = markerID
    ADExtension.saveSettings()
    local msg = g_i18n:getText("ADExt_selected") .. mapMarker.name
    env.ADMessagesManager:addMessage(vehicle, env.ADMessagesManager.messageTypes.INFO, msg, 5000)
end

-- ============================================================
--  AKTIONEN DYNAMISCHE SLOTS
-- ============================================================
-- Slotziel setzen = reine Buchhaltung -> LOKAL beim klickenden Spieler.
function ADExtension.setSlotDestination(vehicle, slotIdx)
    if vehicle == nil or vehicle.ad == nil then return end
    local env  = getADEnv()
    if env == nil then return end
    local slot = ADExtension.slots[slotIdx]
    if slot == nil then return end
    local markerID = vehicle.ad.stateModule:getFirstMarkerId()
    if markerID == nil or markerID <= 0 then
        ADExtension.notifyNoDest(vehicle)
        return
    end
    local mapMarker = env.ADGraphManager:getMapMarkerById(markerID)
    if mapMarker == nil or mapMarker.isADDebug == true then return end
    slot.markerID = markerID
    ADExtension.saveSettings()
    local msg = slot.icon .. ": " .. g_i18n:getText("ADExt_selected") .. mapMarker.name
    env.ADMessagesManager:addMessage(vehicle, env.ADMessagesManager.messageTypes.INFO, msg, 5000)
end

-- SERVER-Ausfuehrung: faehrt Fahrzeug zu markerID (Snapshot davor). Wird nur
-- ueber ADExtInputEvent (ACTION_DRIVE) aufgerufen -> laeuft immer server-seitig.
-- Die markerID hat der Client aus seiner eigenen Slot-/Werkstatt-Konfig
-- aufgeloest; der Server braucht die Button-Tabellen also gar nicht.
function ADExtension.driveToMarker(vehicle, farmId, markerID)
    if vehicle == nil or vehicle.ad == nil then return end
    if markerID == nil or markerID < 1 then return end
    local env = getADEnv()
    if env == nil then return end
    local mapMarker = env.ADGraphManager:getMapMarkerById(markerID)
    if mapMarker == nil then return end
    ADExtension.captureState(vehicle)   -- Snapshot VOR dem Ueberschreiben
    vehicle.ad.stateModule:setFirstMarker(markerID)
    env.AutoDrive:StopCP(vehicle)
    if vehicle.ad.stateModule:isActive() then
        env.ADInputManager:input_start_stop(vehicle, farmId)
    end
    vehicle.ad.stateModule:setMode(env.AutoDrive.MODE_DRIVETO)
    env.ADInputManager:input_start_stop(vehicle, farmId)
end

-- CLIENT-Anfrage: schickt den Fahrbefehl an den Server (Host fuehrt direkt
-- aus). Bei fehlendem Ziel lokale Meldung fuer den klickenden Spieler.
function ADExtension.requestDrive(vehicle, farmId, markerID)
    if vehicle == nil then return end
    if markerID == nil or markerID < 1 then
        ADExtension.notifyNoDest(vehicle)
        return
    end
    ADExtInputEvent.sendEvent(vehicle, ADExtInputEvent.ACTION_DRIVE, farmId, markerID)
end

function ADExtension.requestDriveSlot(vehicle, farmId, slotIdx)
    local slot = ADExtension.slots[slotIdx]
    local mid  = (slot ~= nil) and slot.markerID or -1
    ADExtension.requestDrive(vehicle, farmId, mid)
end

function ADExtension.requestDriveWorkshop(vehicle, farmId)
    ADExtension.requestDrive(vehicle, farmId, ADExtension.workshopMarkerID or -1)
end

-- ============================================================
--  SLOT VERWALTUNG
-- ============================================================
function ADExtension.addSlot(iconName)
    table.insert(ADExtension.slots, {icon = iconName, markerID = -1})
    ADExtension.saveSettings()
    ADExtension.pickerOpen     = false
    ADExtension.pendingRefresh = true
end

function ADExtension.removeSlot(slotIdx)
    table.remove(ADExtension.slots, slotIdx)
    ADExtension.saveSettings()
    ADExtension.pendingRefresh = true
end

-- ============================================================
--  PICKER OVERLAYS (lazy)
-- ============================================================
function ADExtension.loadPickerOverlays(btnW, btnH)
    if ADExtension.pickerOvs ~= nil then return end
    ADExtension.pickerOvs = {}
    for _, name in ipairs(ADExtension.ICONS) do
        local path = ADExtension.modDirectory .. "textures/icons/" .. name .. ".dds"
        if fileExists(path) then
            ADExtension.pickerOvs[name] = Overlay.new(path, 0, 0, btnW, btnH)
        end
    end
end

-- ============================================================
--  HUD-ELEMENTE AUFBAUEN
-- ============================================================
function ADExtension.refreshHudButtons()
    local hudSelf = ADExtension.hudSelf
    if hudSelf == nil then return end

    -- Alte ADExt-Elemente entfernen
    for i = #hudSelf.hudElements, 1, -1 do
        if hudSelf.hudElements[i].isADExt then
            table.remove(hudSelf.hudElements, i)
        end
    end
    ADExtension.buttonRefs        = {}
    ADExtension.plusRef           = nil
    ADExtension.pickerRefs        = {}
    ADExtension.refreshButtonRef  = nil
    ADExtension.workshopButtonRef = nil

    local env = getADEnv()
    if env == nil then return end
    local AutoDrive = env.AutoDrive

    local btnW   = hudSelf.buttonWidth
    local btnH   = hudSelf.buttonHeight
    local gapW   = hudSelf.gapWidth
    local gapH   = hudSelf.gapHeight
    local baseY  = hudSelf.rowHeader + hudSelf.headerHeight + gapH
    local rightX = hudSelf.posX + hudSelf.width
    local perRow = math.max(1, math.floor((hudSelf.width + gapW) / (btnW + gapW)))

    local uiScale = g_gameSettings:getValue("uiScale")
    if AutoDrive.getSetting("guiScale") ~= 0 then uiScale = AutoDrive.getSetting("guiScale") end
    local lineH = getTextHeight(0.011 * uiScale, "text") + gapH

    -- Für draw() speichern
    ADExtension.btnH_norm     = btnH
    ADExtension.gapH_norm     = gapH
    ADExtension.numPickerRows = 0
    ADExtension.numSlotRows   = 1

    local headerRef = nil
    for _, el in ipairs(hudSelf.hudElements) do
        if el.name == "header" then headerRef = el; break end
    end

    -- Rasterposition (gridIndex 0 = ganz rechts, waechst nach links; Umbruch nach oben)
    local function gridX(gridIndex)
        local col = gridIndex % perRow
        return rightX - (col + 1) * (btnW + gapW) + gapW
    end
    local function gridY(gridIndex)
        local row = math.floor(gridIndex / perRow)
        return baseY + row * (btnH + gapH)
    end

    -- Fabrik fuer die beiden FESTEN Buttons (Refresh + Werkstatt)
    local function buildFixedButton(gridIndex, iconFile, onLeftClick, onRightClick, getAlphaOn, getTooltip)
        local bX   = gridX(gridIndex)
        local bY   = gridY(gridIndex)
        local path = ADExtension.modDirectory .. "textures/icons/" .. iconFile
        local ov   = Overlay.new(path, bX, bY, btnW, btnH)
        local btn  = {
            isADExt      = true,
            isFixed      = true,
            onLeftClick  = onLeftClick,
            onRightClick = onRightClick,
            position   = {x = bX, y = bY},
            size       = {width = btnW, height = btnH},
            isVisible  = false,
            overlay    = ov,
            baseY      = bY,
            headerRef  = headerRef,
            lineHeight = lineH,
            layer      = 0,
        }
        btn.update = function(self2, dt) end
        btn.hit = function(self2, x, y, z)
            return x >= self2.position.x and x <= self2.position.x + self2.size.width
               and y >= self2.position.y and y <= self2.position.y + self2.size.height
        end
        btn.onDraw = function(self2, vehicle2, uiScale2)
            local y = getButtonY(self2)
            self2.position.y = y
            self2.isVisible  = isHudVisible()
            if not self2.isVisible then return end
            local alpha = getAlphaOn(vehicle2) and 1.0 or 0.2
            self2.overlay:setColor(1, 1, 1, alpha)
            self2.overlay:setPosition(self2.position.x, y)
            self2.overlay:render()
        end
        btn.mouseEvent = function(self2, vehicle2, posX2, posY2, isDown, isUp, button, layer)
            if not self2.isVisible then return false end
            if ADExtension.pickerOpen then return false end
            local px, py = self2.position.x, self2.position.y
            if posX2 >= px and posX2 <= px + self2.size.width
               and posY2 >= py and posY2 <= py + self2.size.height then
                vehicle2.ad.sToolTip         = ""
                vehicle2.ad.nToolTipWait     = 5
                vehicle2.ad.sToolTipInfo     = getTooltip(vehicle2)
                vehicle2.ad.toolTipIsSetting = false
                if isDown and button == 1 then return true end
                if isUp and button == 1
                    and not AutoDrive.leftLSHIFTmodifierKeyPressed
                    and not AutoDrive.leftCTRLmodifierKeyPressed then
                    local farmId = (AutoDrive.getPlayer() ~= nil and AutoDrive.getPlayer().farmId) or 0
                    if self2.onLeftClick ~= nil then self2.onLeftClick(vehicle2, farmId) end
                    return true
                end
                if isUp and (button == 3 or button == 2) then
                    local farmId = (AutoDrive.getPlayer() ~= nil and AutoDrive.getPlayer().farmId) or 0
                    if self2.onRightClick ~= nil then self2.onRightClick(vehicle2, farmId) end
                    return true
                end
            end
            return false
        end
        table.insert(hudSelf.hudElements, btn)
        return btn
    end

    -- ---- REFRESH BUTTON (fest, Platz 1 = ganz rechts, gridIndex 0) ----
    -- Linksklick = Vorzustand wiederherstellen (Server), Rechtsklick = merken (Server)
    ADExtension.refreshButtonRef = buildFixedButton(
        0,
        "refresh.dds",
        function(vehicle2, farmId)
            ADExtInputEvent.sendEvent(vehicle2, ADExtInputEvent.ACTION_RESTORE, farmId, 0)
        end,
        function(vehicle2, farmId)
            ADExtInputEvent.sendEvent(vehicle2, ADExtInputEvent.ACTION_CAPTURE, farmId, 0)
        end,
        function(vehicle2) return ADExtension.getPrevMarkerName(vehicle2) ~= nil end,
        function(vehicle2)
            local nm = ADExtension.getPrevMarkerName(vehicle2)
            if nm ~= nil then
                return g_i18n:getText("ADExt_backTo") .. nm
            end
            return g_i18n:getText("ADExt_name_refresh")
        end
    )

    -- ---- WERKSTATT BUTTON (fest, Platz 2 = links daneben, gridIndex 1) ----
    -- Linksklick = anfahren (Marker lokal aufloesen -> Server), Rechtsklick = Ziel setzen (LOKAL)
    ADExtension.workshopButtonRef = buildFixedButton(
        1,
        "workshop.dds",
        function(vehicle2, farmId) ADExtension.requestDriveWorkshop(vehicle2, farmId) end,
        function(vehicle2, farmId) ADExtension.setWorkshopDestination(vehicle2) end,
        function(vehicle2) return ADExtension.getWorkshopMarkerName() ~= nil end,
        function(vehicle2) return g_i18n:getText("ADExt_name_workshop") end
    )

    -- ---- DYNAMISCHE SLOT-BUTTONS (Grid, ab gridIndex 2 = links von Werkstatt) ----
    for i, slot in ipairs(ADExtension.slots) do
        local gi        = i + 1            -- 2 feste Buttons davor (gridIndex 0 + 1)
        local bX        = gridX(gi)
        local slotBaseY = gridY(gi)
        local iconPath  = ADExtension.modDirectory .. "textures/icons/" .. slot.icon .. ".dds"
        local ov        = Overlay.new(iconPath, bX, slotBaseY, btnW, btnH)
        local btn = {
            isADExt    = true,
            slotIdx    = i,
            position   = {x = bX, y = slotBaseY},
            size       = {width = btnW, height = btnH},
            isVisible  = false,
            overlay    = ov,
            baseY      = slotBaseY,
            headerRef  = headerRef,
            lineHeight = lineH,
            layer      = 0,
        }
        btn.update = function(self2, dt) end
        btn.hit = function(self2, x, y, z)
            return x >= self2.position.x and x <= self2.position.x + self2.size.width
               and y >= self2.position.y and y <= self2.position.y + self2.size.height
        end
        btn.onDraw = function(self2, vehicle2, uiScale2)
            local y = getButtonY(self2)
            self2.position.y = y
            self2.isVisible  = isHudVisible()
            if not self2.isVisible then return end
            local alpha = (ADExtension.getSlotMarkerName(self2.slotIdx) ~= nil) and 1.0 or 0.2
            self2.overlay:setColor(1, 1, 1, alpha)
            self2.overlay:setPosition(self2.position.x, y)
            self2.overlay:render()
        end
        btn.mouseEvent = function(self2, vehicle2, posX2, posY2, isDown, isUp, button, layer)
            if not self2.isVisible then return false end
            if ADExtension.pickerOpen then return false end
            local px, py = self2.position.x, self2.position.y
            if posX2 >= px and posX2 <= px + self2.size.width
               and posY2 >= py and posY2 <= py + self2.size.height then
                vehicle2.ad.sToolTip         = ""
                vehicle2.ad.nToolTipWait     = 5
                vehicle2.ad.sToolTipInfo     = ADExtension.slots[self2.slotIdx] ~= nil
                    and ADExtension.slots[self2.slotIdx].icon or ""
                vehicle2.ad.toolTipIsSetting = false
                if isDown and button == 1 then return true end
                if isUp and button == 1 and AutoDrive.leftLSHIFTmodifierKeyPressed then
                    if g_currentMission.time > ADExtension.clickCooldown then
                        ADExtension.clickCooldown = g_currentMission.time + 400
                        ADExtension.removeSlot(self2.slotIdx)
                    end
                    return true
                end
                if isUp and button == 1
                    and not AutoDrive.leftLSHIFTmodifierKeyPressed
                    and not AutoDrive.leftCTRLmodifierKeyPressed then
                    local farmId = (AutoDrive.getPlayer() ~= nil and AutoDrive.getPlayer().farmId) or 0
                    ADExtension.requestDriveSlot(vehicle2, farmId, self2.slotIdx)
                    return true
                end
                if isUp and (button == 3 or button == 2) then
                    -- Ziel setzen = LOKAL beim klickenden Spieler
                    ADExtension.setSlotDestination(vehicle2, self2.slotIdx)
                    return true
                end
            end
            return false
        end
        table.insert(hudSelf.hudElements, btn)
        ADExtension.buttonRefs[i] = btn
    end

    -- ---- PLUS BUTTON (folgt dem letzten Slot im Grid) ----
    local nSlots    = #ADExtension.slots
    local plusGrid  = nSlots + 2          -- 2 feste Buttons + nSlots
    local plusW     = btnW * 0.7
    local plusH     = btnH * 0.7
    local plusX     = gridX(plusGrid) + (btnW - plusW) * 0.5
    local plusBaseY = gridY(plusGrid) + (btnH - plusH) * 0.5

    -- Anzahl Button-Zeilen für draw() merken
    ADExtension.numSlotRows = math.floor(plusGrid / perRow) + 1

    local plusPath = ADExtension.modDirectory .. "textures/icons/plus.dds"
    local plusOv   = Overlay.new(plusPath, plusX, plusBaseY, plusW, plusH)
    local plusBtn  = {
        isADExt    = true,
        isPlusBtn  = true,
        position   = {x = plusX, y = plusBaseY},
        size       = {width = plusW, height = plusH},
        isVisible  = false,
        overlay    = plusOv,
        baseY      = plusBaseY,
        headerRef  = headerRef,
        lineHeight = lineH,
        layer      = 0,
    }
    plusBtn.update = function(self2, dt) end
    plusBtn.hit = function(self2, x, y, z)
        return x >= self2.position.x and x <= self2.position.x + self2.size.width
           and y >= self2.position.y and y <= self2.position.y + self2.size.height
    end
    plusBtn.onDraw = function(self2, vehicle2, uiScale2)
        local y = getButtonY(self2)
        self2.position.y = y
        self2.isVisible  = isHudVisible()
        if not self2.isVisible then return end
        self2.overlay:setColor(1, 1, 1, ADExtension.pickerOpen and 1.0 or 0.5)
        self2.overlay:setPosition(self2.position.x, y)
        self2.overlay:render()
    end
    plusBtn.mouseEvent = function(self2, vehicle2, posX2, posY2, isDown, isUp, button, layer)
        if not self2.isVisible then return false end
        local px, py = self2.position.x, self2.position.y
        if posX2 >= px and posX2 <= px + self2.size.width
           and posY2 >= py and posY2 <= py + self2.size.height then
            if isDown and button == 1 then return true end
            if isUp and button == 1 then
                if g_currentMission.time > ADExtension.clickCooldown then
                    ADExtension.clickCooldown  = g_currentMission.time + 400
                    ADExtension.pickerOpen     = not ADExtension.pickerOpen
                    ADExtension.pendingRefresh = true
                end
                return true
            end
        end
        return false
    end
    table.insert(hudSelf.hudElements, plusBtn)
    ADExtension.plusRef = plusBtn

    -- ---- PICKER ICONS (falls offen, UEBER der Button-Reihe) ----
    if ADExtension.pickerOpen then
        ADExtension.loadPickerOverlays(btnW, btnH)
        local perRowP = math.max(1, math.floor((hudSelf.width + gapW) / (btnW + gapW)))
        local col = 0
        local row = 0
        for _, name in ipairs(ADExtension.ICONS) do
            local ov = ADExtension.pickerOvs ~= nil and ADExtension.pickerOvs[name] or nil
            if ov ~= nil then
                local bX     = rightX - (col + 1) * (btnW + gapW) + gapW
                local rowOff = (row + 1) * (btnH + gapH)
                local pName  = name
                local pBtn   = {
                    isADExt    = true,
                    isPickerEl = true,
                    iconName   = pName,
                    position   = {x = bX, y = baseY + rowOff},
                    size       = {width = btnW, height = btnH},
                    isVisible  = false,
                    overlay    = ov,
                    baseY      = baseY,
                    rowOff     = rowOff,
                    headerRef  = headerRef,
                    lineHeight = lineH,
                    layer      = 0,
                }
                pBtn.update = function(self2, dt) end
                pBtn.hit = function(self2, x, y, z)
                    return x >= self2.position.x and x <= self2.position.x + self2.size.width
                       and y >= self2.position.y and y <= self2.position.y + self2.size.height
                end
                pBtn.onDraw = function(self2, vehicle2, uiScale2)
                    local y = getButtonY(self2) + self2.rowOff
                    self2.position.y = y
                    self2.isVisible  = isHudVisible() and ADExtension.pickerOpen
                    if not self2.isVisible then return end
                    self2.overlay:setColor(1, 1, 1, 0.85)
                    self2.overlay:setPosition(self2.position.x, y)
                    self2.overlay:render()
                end
                pBtn.mouseEvent = function(self2, vehicle2, posX2, posY2, isDown, isUp, button, layer)
                    if not self2.isVisible then return false end
                    local px, py = self2.position.x, self2.position.y
                    if posX2 >= px and posX2 <= px + self2.size.width
                       and posY2 >= py and posY2 <= py + self2.size.height then
                        if isDown and button == 1 then return true end
                        if isUp and button == 1 then
                            if g_currentMission.time > ADExtension.clickCooldown then
                                ADExtension.clickCooldown = g_currentMission.time + 400
                                ADExtension.addSlot(self2.iconName)
                            end
                            return true
                        end
                    end
                    return false
                end
                table.insert(hudSelf.hudElements, pBtn)
                table.insert(ADExtension.pickerRefs, pBtn)
                col = col + 1
                if col >= perRowP then col = 0; row = row + 1 end
            end
        end
        ADExtension.numPickerRows = row + (col > 0 and 1 or 0)
    end

    if hudSelf.refreshHudElementsLayerSequence ~= nil then
        hudSelf:refreshHudElementsLayerSequence()
    end
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
    local ADStateModule  = env.ADStateModule

    local originalCreateHudAt = AutoDriveHud.createHudAt
    AutoDriveHud.createHudAt = function(self, hudX, hudY)
        originalCreateHudAt(self, hudX, hudY)
        ADExtension.hudSelf = self
        ADExtension.headerH = self.headerHeight
        ADExtension.refreshHudButtons()
    end

    local originalOnActionCall = ADInputManager.onActionCall
    ADInputManager.onActionCall = function(vehicle2, actionName)
        if actionName == "ADExt_RefreshRestore" then
            local farmId = (AutoDrive.getPlayer() ~= nil and AutoDrive.getPlayer().farmId) or 0
            ADExtInputEvent.sendEvent(vehicle2, ADExtInputEvent.ACTION_RESTORE, farmId, 0)
            return
        end
        if actionName == "ADExt_WorkshopVehicle" then
            local farmId = (AutoDrive.getPlayer() ~= nil and AutoDrive.getPlayer().farmId) or 0
            ADExtension.requestDriveWorkshop(vehicle2, farmId)
            return
        end
        if actionName == "ADExt_SetWorkshopDestination" then
            -- Ziel setzen = LOKAL beim klickenden Spieler
            ADExtension.setWorkshopDestination(vehicle2)
            return
        end
        return originalOnActionCall(vehicle2, actionName)
    end

    -- Snapshot-Persistenz pro Fahrzeug am AD-eigenen Speicher-Key
    if ADStateModule ~= nil then
        if ADStateModule.saveToXMLFile ~= nil then
            ADStateModule.saveToXMLFile =
                Utils.appendedFunction(ADStateModule.saveToXMLFile, ADExtension.onStateSave)
        end
        if ADStateModule.readFromXMLFile ~= nil then
            ADStateModule.readFromXMLFile =
                Utils.appendedFunction(ADStateModule.readFromXMLFile, ADExtension.onStateRead)
        end
    else
        Logging.warning("[ADExt] ADStateModule nicht gefunden - Snapshot-Persistenz deaktiviert.")
    end

    ADExtension.initialized = true
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
    ADExtension.registerSchemaPaths()   -- Fallback, falls Top-Level-Call zu frueh war
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
    end
end

function ADExtensionRegister:deleteMap()
    ADExtension.initialized       = false
    ADExtension.hudSelf           = nil
    ADExtension.refreshButtonRef  = nil
    ADExtension.workshopButtonRef = nil
    ADExtension.buttonRefs        = {}
    ADExtension.plusRef           = nil
    ADExtension.pickerRefs        = {}
    ADExtension.pickerOvs         = nil
    ADExtension.pickerOpen        = false
    ADExtension.pendingRefresh    = false
    adEnvCache                    = nil
end

function ADExtensionRegister:update(dt)
    if ADExtension.pendingRefresh and ADExtension.initialized then
        ADExtension.pendingRefresh = false
        ADExtension.refreshHudButtons()
    end
end

function ADExtensionRegister:draw()
    if not ADExtension.initialized then return end
    local env = getADEnv()
    if env == nil or env.AutoDrive == nil or env.AutoDrive.Hud == nil then return end
    if env.AutoDrive.pullDownListExpanded ~= nil and env.AutoDrive.pullDownListExpanded > 0 then return end

    -- Anker fuer den Versions-Header ist der rechteste (feste) Button = Refresh
    local anchor = ADExtension.refreshButtonRef
    if anchor == nil or not anchor.isVisible then return end

    local selfMod = g_modManager:getModByName("FS25_AD_Extension")
    local version = (selfMod ~= nil and selfMod.version ~= nil) and selfMod.version or "1.3.0.0"
    local fontSize = ADExtension.headerH * 0.55
    local textX    = anchor.position.x - fontSize * 0.3
    -- Eine Zeile über der obersten aktiven Icon-Reihe (Slot-Reihen + Picker-Reihen)
    local totalRows = (ADExtension.numSlotRows or 1)
        + (ADExtension.pickerOpen and (ADExtension.numPickerRows or 0) or 0)
    local textY = anchor.position.y + totalRows * (ADExtension.btnH_norm + ADExtension.gapH_norm)

    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(0.9, 0.9, 0.9, 0.85)
    renderText(textX, textY, fontSize, "AD Extension v" .. version)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(false)

    if ADExtension.pickerOpen then
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(0.9, 0.85, 0.4, 0.9)
        renderText(textX, textY + fontSize * 1.3, fontSize * 0.85, "SHIFT+Klick = loeschen")
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(1, 1, 1, 1)
    end
end

ItemSystem.save = Utils.appendedFunction(ItemSystem.save, function()
    if ADExtension.initialized then ADExtension.saveSettings() end
end)

-- Schema so frueh wie moeglich anmelden (vor dem Laden der Fahrzeuge)
ADExtension.registerSchemaPaths()

addModEventListener(ADExtensionRegister)

Logging.info("[ADExt] FS25_AD_Extension v1.3.0.0 geladen.")
