--
-- ADExtSnapshotEvent.lua (v1.3.0.0)
-- Server -> Client Anzeige-Sync fuer den Refresh-Button.
--
-- Der Snapshot des vorherigen AD-Zustands (vehicle.ADExt_prev) lebt und wird
-- server-seitig gepflegt (Anlegen beim Fahren/Merken, Anwenden beim
-- Wiederherstellen, Persistenz im Spielstand). Ein Client hat diesen Snapshot
-- nicht. Damit der Refresh-Button am Client trotzdem korrekt aktiv/ausgegraut
-- ist und den Ziel-Namen im Tooltip zeigt, broadcastet der Server nach jeder
-- Snapshot-Aenderung nur die Anzeige-MarkerID. Der Client legt sie in
-- vehicle.ADExt_prevShadow ab (nur fuer Anzeige, nicht fuer die echte
-- Wiederherstellung -- die liest weiter den vollen Snapshot am Server).
--
-- Bekannte Grenze: ein Client, der einem laufenden MP-Spiel beitritt, sieht
-- einen bereits aus dem Spielstand geladenen Snapshot erst, nachdem die erste
-- Snapshot-aendernde Aktion (Fahren/Merken/Wiederherstellen) passiert.
--

ADExtSnapshotEvent = {}
ADExtSnapshotEvent_mt = Class(ADExtSnapshotEvent, Event)
InitEventClass(ADExtSnapshotEvent, "ADExtSnapshotEvent")

function ADExtSnapshotEvent.emptyNew()
    local self = Event.new(ADExtSnapshotEvent_mt)
    return self
end

function ADExtSnapshotEvent.new(vehicle, prevFirst)
    local self     = ADExtSnapshotEvent.emptyNew()
    self.vehicle   = vehicle
    self.prevFirst = prevFirst or -1
    return self
end

function ADExtSnapshotEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.vehicle))
    streamWriteInt32(streamId, self.prevFirst)
end

function ADExtSnapshotEvent:readStream(streamId, connection)
    self.vehicle   = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    self.prevFirst = streamReadInt32(streamId)
    self:run(connection)
end

-- Laeuft auf dem Client: Anzeige-Schatten setzen/loeschen.
function ADExtSnapshotEvent:run(connection)
    if self.vehicle == nil then return end
    if self.prevFirst ~= nil and self.prevFirst >= 1 then
        self.vehicle.ADExt_prevShadow = self.prevFirst
    else
        self.vehicle.ADExt_prevShadow = nil
    end
end

-- Server: aktuellen Snapshot-Marker des Fahrzeugs an alle Clients broadcasten.
function ADExtSnapshotEvent.broadcast(vehicle)
    if g_server == nil or vehicle == nil then return end
    local prevFirst = -1
    local prev = vehicle.ADExt_prev
    if prev ~= nil and prev.firstMarkerId ~= nil and prev.firstMarkerId >= 1 then
        prevFirst = prev.firstMarkerId
    end
    -- false = NICHT lokal auf dem Server ausfuehren (Host liest echten Snapshot).
    g_server:broadcastEvent(ADExtSnapshotEvent.new(vehicle, prevFirst), false)
end
