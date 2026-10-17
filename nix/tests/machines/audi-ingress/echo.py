import pathlib
import selectors
import socket
import sys

selector = selectors.DefaultSelector()
for port in sys.argv[2:]:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", int(port)))
    listener.listen(16)
    listener.setblocking(False)
    selector.register(listener, selectors.EVENT_READ, True)
pathlib.Path("/run/" + sys.argv[1] + ".ready").touch()
while True:
    for key, _ in selector.select():
        if key.data:
            client, _ = key.fileobj.accept()
            client.settimeout(1)
            selector.register(client, selectors.EVENT_READ, False)
        else:
            data = key.fileobj.recv(65536)
            if data:
                key.fileobj.sendall(data)
            else:
                selector.unregister(key.fileobj)
                key.fileobj.close()
