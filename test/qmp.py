import socket, json, sys, time
class Q:
    def __init__(self, path="/tmp/diagvm/qmp"):
        self.s = socket.socket(socket.AF_UNIX); self.s.connect(path)
        self.f = self.s.makefile("rw"); self.f.readline()
        self.cmd("qmp_capabilities")
    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}) + "\n"); self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r: return r
    def touch(self, events):
        return self.cmd("input-send-event", events=events)
def mtdown(slot, x, y):
    return [{"type":"mtt","data":{"type":"begin","slot":slot,"tracking-id":slot+1,"axis":"x","value":x}},
            {"type":"mtt","data":{"type":"begin","slot":slot,"tracking-id":slot+1,"axis":"y","value":y}}]
