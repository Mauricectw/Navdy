#!/usr/bin/env python3
"""極簡的假 Sonos（只實作 App 用到的 UPnP 動作），用來離線驗證播放引擎的佇列邏輯。

用法：python3 fake_sonos.py [--max-batch N] [--reject-queue]
監聽 127.0.0.1:1400；GET /__state 回傳內部狀態 JSON，POST /__hw/next 模擬機身按鍵。
"""
import json, re, sys, time, html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UUID = "RINCON_FAKE0000000001400"
MAX_BATCH = 16
REJECT_QUEUE = False
for i, a in enumerate(sys.argv):
    if a == "--max-batch": MAX_BATCH = int(sys.argv[i + 1])
    if a == "--reject-queue": REJECT_QUEUE = True

S = dict(queue=[], transport_uri="", single_uri="", track=0, state="STOPPED", mode="NORMAL",
         volume=22, pos=0.0, played_at=None, calls=[])

def position():
    if S["state"] == "PLAYING" and S["played_at"] is not None:
        return S["pos"] + (time.time() - S["played_at"])
    return S["pos"]

def set_pos(v):
    S["pos"] = float(v)
    S["played_at"] = time.time() if S["state"] == "PLAYING" else None

def hms(sec):
    sec = int(sec)
    return "%d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)

def in_queue_mode():
    return S["transport_uri"].startswith("x-rincon-queue:")

def current_uri():
    if in_queue_mode():
        return S["queue"][S["track"] - 1] if 1 <= S["track"] <= len(S["queue"]) else ""
    return S["single_uri"]

def arg(body, name):
    m = re.search(r"<%s>(.*?)</%s>" % (name, name), body, re.S)
    return html.unescape(m.group(1)) if m else ""

def ok(action, service, inner=""):
    return 200, ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                 '<s:Body><u:%sResponse xmlns:u="%s">%s</u:%sResponse></s:Body></s:Envelope>'
                 % (action, service, inner, action))

def fault(code):
    return 500, ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
                 '<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>'
                 '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>%d</errorCode></UPnPError>'
                 '</detail></s:Fault></s:Body></s:Envelope>' % code)

def handle(action, service, body):
    S["calls"].append(action)
    if action == "RemoveAllTracksFromQueue":
        S["queue"] = []
        return ok(action, service)
    if action == "AddMultipleURIsToQueue":
        n = int(arg(body, "NumberOfURIs"))
        uris = arg(body, "EnqueuedURIs").split(" ")
        metas = arg(body, "EnqueuedURIsMetaData")
        if REJECT_QUEUE or n > MAX_BATCH or n != len(uris):
            return fault(402)
        if metas.count("<DIDL-Lite") != n:      # 中繼資料必須剛好轉義一層、每首一段
            return fault(402)
        first = int(arg(body, "DesiredFirstTrackNumberEnqueued") or 0)
        at = len(S["queue"]) if first <= 0 else min(first - 1, len(S["queue"]))
        S["queue"][at:at] = uris
        if in_queue_mode() and S["track"] and at < S["track"]:
            S["track"] += n
        return ok(action, service, "<FirstTrackNumberEnqueued>%d</FirstTrackNumberEnqueued>" % (at + 1))
    if action == "SetAVTransportURI":
        uri, meta = arg(body, "CurrentURI"), arg(body, "CurrentURIMetaData")
        if not meta.startswith("<DIDL-Lite"):
            return fault(402)
        S["transport_uri"] = uri
        if uri.startswith("x-rincon-queue:"):
            S["track"] = 1 if S["queue"] else 0
        else:
            S["single_uri"] = uri
            S["track"] = 1
        S["state"] = "STOPPED"
        set_pos(0)
        return ok(action, service)
    if action == "SetPlayMode":
        S["mode"] = arg(body, "NewPlayMode")
        return ok(action, service)
    if action == "Seek":
        unit, target = arg(body, "Unit"), arg(body, "Target")
        if unit == "TRACK_NR":
            t = int(target)
            if not in_queue_mode() or not (1 <= t <= len(S["queue"])):
                return fault(711)
            S["track"] = t
            set_pos(0)
        else:
            h, m, s = [int(x) for x in target.split(":")]
            set_pos(h * 3600 + m * 60 + s)
        return ok(action, service)
    if action == "Play":
        if not current_uri():
            return fault(701)
        S["state"] = "PLAYING"
        set_pos(S["pos"])
        return ok(action, service)
    if action == "Pause":
        p = position()
        S["state"] = "PAUSED_PLAYBACK"
        set_pos(p)
        return ok(action, service)
    if action == "Stop":
        S["state"] = "STOPPED"
        set_pos(0)
        return ok(action, service)
    if action in ("Next", "Previous"):
        if not in_queue_mode() or not S["queue"]:
            return fault(711)
        step = 1 if action == "Next" else -1
        S["track"] = (S["track"] - 1 + step) % len(S["queue"]) + 1
        set_pos(0)
        return ok(action, service)
    if action == "GetPositionInfo":
        uri = current_uri()
        meta = html.escape('<DIDL-Lite><item><dc:title>fake &apos;title&apos;</dc:title></item></DIDL-Lite>')
        return ok(action, service,
                  "<Track>%d</Track><TrackDuration>0:03:20</TrackDuration><TrackMetaData>%s</TrackMetaData>"
                  "<TrackURI>%s</TrackURI><RelTime>%s</RelTime>" % (S["track"], meta, html.escape(uri), hms(position())))
    if action == "GetMediaInfo":
        n = len(S["queue"]) if in_queue_mode() else (1 if S["single_uri"] else 0)
        return ok(action, service, "<NrTracks>%d</NrTracks><CurrentURI>%s</CurrentURI>" % (n, html.escape(S["transport_uri"])))
    if action == "GetTransportInfo":
        return ok(action, service, "<CurrentTransportState>%s</CurrentTransportState>" % S["state"])
    if action == "GetVolume":
        return ok(action, service, "<CurrentVolume>%d</CurrentVolume>" % S["volume"])
    if action == "SetVolume":
        S["volume"] = int(arg(body, "DesiredVolume"))
        return ok(action, service)
    if action == "GetZoneGroupState":
        inner = ('<ZoneGroupState><ZoneGroups><ZoneGroup Coordinator="%s" ID="%s:1">'
                 '<ZoneGroupMember UUID="%s" Location="http://127.0.0.1:1400/xml/device_description.xml" '
                 'ZoneName="Fake Room" SWGen="2" SoftwareVersion="86.10-1"/></ZoneGroup></ZoneGroups></ZoneGroupState>'
                 % (UUID, UUID, UUID))
        return ok(action, service, "<ZoneGroupState>%s</ZoneGroupState>" % html.escape(inner))
    return fault(401)

DESCRIPTION = """<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
<deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType><friendlyName>127.0.0.1 - Sonos Fake</friendlyName>
<manufacturer>Sonos, Inc.</manufacturer><modelName>Sonos Fake</modelName><softwareVersion>86.10-1</softwareVersion>
<swGen>2</swGen><roomName>Fake Room</roomName><UDN>uuid:%s</UDN><deviceList><device><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
<controlURL>/MediaRenderer/RenderingControl/Control</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
<controlURL>/MediaRenderer/AVTransport/Control</controlURL></service>
</serviceList></device></deviceList></device></root>""" % UUID

PATHS = {"/MediaRenderer/AVTransport/Control", "/MediaRenderer/RenderingControl/Control", "/ZoneGroupTopology/Control"}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, text, ctype="text/xml"):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == "/xml/device_description.xml":
            return self.send(200, DESCRIPTION)
        if self.path == "/__state":
            d = dict(S); d["pos"] = position(); d["current_uri"] = current_uri()
            return self.send(200, json.dumps(d), "application/json")
        self.send(404, "nope", "text/plain")
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path.startswith("/__hw/"):
            cmd = self.path.split("/")[-1]
            if cmd == "next": handle("Next", "hw", "")
            if cmd == "pause": handle("Pause", "hw", "")
            if cmd == "external":
                S["transport_uri"] = "x-sonos-spotify:whatever"; S["single_uri"] = S["transport_uri"]; S["track"] = 1
            if cmd == "volume": S["volume"] = int(body or 40)
            if cmd == "end": S["state"] = "STOPPED"; set_pos(0)
            return self.send(200, "ok", "text/plain")
        if self.path not in PATHS:
            return self.send(405, "Method Not Allowed", "text/plain")
        sa = self.headers.get("SOAPACTION", "").strip('"')
        if "#" not in sa:
            return self.send(400, "no soapaction", "text/plain")
        service, action = sa.split("#", 1)
        if ("<u:%s " % action) not in body:
            return self.send(400, "bad envelope", "text/plain")
        code, text = handle(action, service, body)
        self.send(code, text)

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 1400), H).serve_forever()
