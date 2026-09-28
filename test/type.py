import sys, time, socket
M = {' ':'spc','-':'minus','=':'equal','/':'slash','.':'dot',',':'comma',';':'semicolon',
     "'":"apostrophe",'\\':'backslash','[':'bracket_left',']':'bracket_right','`':'grave_accent','\n':'ret','\t':'tab'}
S = {'|':'backslash','_':'minus','"':'apostrophe',':':'semicolon','>':'dot','<':'comma','$':'4','*':'8','(':'9',')':'0','&':'7','!':'1','@':'2','#':'3','%':'5','^':'6','+':'equal','?':'slash','{':'bracket_left','}':'bracket_right','~':'grave_accent'}
s=socket.socket(socket.AF_UNIX); s.connect("/tmp/diagvm/mon"); time.sleep(0.2); s.recv(65536)
s.setblocking(False)
for ch in sys.argv[1]:
    if ch in S: k = 'shift-' + S[ch]
    elif ch in M: k = M[ch]
    elif ch.isupper(): k = 'shift-' + ch.lower()
    else: k = ch
    s.sendall(("sendkey %s\n" % k).encode()); time.sleep(0.03)
    try: s.recv(65536)
    except BlockingIOError: pass
time.sleep(0.3); s.close()
