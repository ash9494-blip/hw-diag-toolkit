import sys, time, socket
s=socket.socket(socket.AF_UNIX); s.connect("/tmp/diagvm/mon"); time.sleep(0.2); s.recv(65536)
s.setblocking(False)
for k in sys.argv[1:]:
    if k.startswith("sleep:"): time.sleep(float(k[6:])); continue
    s.sendall(("sendkey %s\n" % k).encode()); time.sleep(0.15)
    try: s.recv(65536)
    except BlockingIOError: pass
time.sleep(0.3); s.close()
