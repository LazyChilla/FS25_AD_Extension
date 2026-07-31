--
-- ADExtInputEvent.lua (v1.3.0.0)
-- Client -> Server Aktionsevent fuer AD Extension.
--
-- actionType:
--   ACTION_DRIVE   (1) -> Fahrzeug zu markerID fahren (Snapshot davor).
--                         Die markerID hat der Client aus seiner eigenen
--                         Slot-/Werkstatt-Konfig aufgeloest; der Server
--                         braucht die Button-Tabellen nicht.
--   ACTION_CAPTURE (2) -> aktuellen AD-Zustand als Snapshot merken.
--   ACTION_RESTORE (3) -> gemerkten AD-Zustand wiederherstellen.
--
-- Buchhaltung (Slot/Werkstatt anlegen, loeschen, Ziel setzen) laeuft NICHT
-- ueber dieses Event, sondern lokal beim klickenden Spieler.
--
-- Nach jeder server-seitigen Aktion wird per ADExtSnapshotEvent der
-- Anzeige-Marker des Snapshots an die Clients gebroadcastet (Refresh-Button
-- Aktiv-Status + Tooltip).
--

ADExtInputEvent = {}
ADExtInputEvent_mt = Class(ADExtInputEvent, Event)
InitEventClass(ADExtInputEvent, "ADExtInputEvent")

ADExtInputEvent.ACTION_DRIVE   = 1
ADExtInputEvent.ACTION_CAPTURE = 2
ADExtInputEvent.ACTION_RESTORE = 3

function ADExtInputEvent.emptyNew()
    local self = Event.new(ADExtInputEvent_mt)
    return self
end

function ADExtInputEvent.new(vehicle, actionType, farmId, markerID)
    local self      = ADExtInputEvent.emptyNew()
    self.vehicle    = vehicle
    self.actionType = actionType
    self.farmId     = farmId
    self.markerID   = markerID or 0
    return self
end

function ADExtInputEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.vehicle))
    streamWriteUInt8(streamId, self.actionType)
    streamWriteUInt8(streamId, self.farmId)
    streamWriteInt32(streamId, self.markerID)   -- Marker-IDs passen nicht in 8 Bit
end

function ADExtInputEvent:readStream(streamId, connection)
    self.vehicle    = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    self.actionType = streamReadUInt8(streamId)
    self.farmId     = streamReadUInt8(streamId)
    self.markerID   = streamReadInt32(streamId)
    self:run(connection)
end

-- Zentrale Verteilung (server-seitig). Wird von run() UND sendEvent() genutzt.
function ADExtInputEvent.dispatch(vehicle, actionType, farmId, markerID)
    if vehicle == nil or ADExtension == nil then return end

    if actionType == ADExtInputEvent.ACTION_DRIVE then
        ADExtension.driveToMarker(vehicle, farmId, markerID)
    elseif actionType == ADExtInputEvent.ACTION_CAPTURE then
        ADExtension.capturePrevState(vehicle)
    elseif actionType == ADExtInputEvent.ACTION_RESTORE then
        ADExtension.restorePrevState(vehicle, farmId)
    end

    -- Snapshot kann sich geaendert haben -> Anzeige-Sync an alle Clients.
    if ADExtSnapshotEvent ~= nil then
        ADExtSnapshotEvent.broadcast(vehicle)
    end
end

function ADExtInputEvent:run(connection)
    if g_server ~= nil and self.vehicle ~= nil then
        ADExtInputEvent.dispatch(self.vehicle, self.actionType, self.farmId, self.markerID)
    end
end

function ADExtInputEvent.sendEvent(vehicle, actionType, farmId, markerID)
    local mid = markerID or 0
    if g_server ~= nil then
        -- Host / Singleplayer: direkt ausfuehren
        ADExtInputEvent.dispatch(vehicle, actionType, farmId, mid)
    elseif g_client ~= nil then
        -- Client: an den Server schicken
        g_client:getServerConnection():sendEvent(
            ADExtInputEvent.new(vehicle, actionType, farmId, mid))
    end
end
