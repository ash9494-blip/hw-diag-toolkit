import socket, sys, time
def cmd(c):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect("/tmp/diagvm/mon")
    time.sleep(0.25); s.recv(65536)
    s.sendall((c+"\n").encode()); time.sleep(0.4)
    try: out = s.recv(65536).decode(errors="replace")
    except Exception: out = ""
    s.close(); return out
if __name__ == "__main__":
    print(cmd(" ".join(sys.argv[1:])))
