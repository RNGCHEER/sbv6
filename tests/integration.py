"""Real core validation and listener smoke test. Run under WSL, without changing /etc."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import threading
import http.server

base = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sbv6', base / 'sbv6.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.BIN = str(base / 'tests/bin/sing-box-1.15.0-alpha.13-linux-amd64/sing-box')
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT = Path(tmp)
    nodes = []
    for offset, key in enumerate(m.TAGS):
        inbound, pub = m.fresh(key, 'WSL测试')
        inbound.update(listen='::1', listen_port=43500 + offset)
        nodes.append({'key': key, 'family': 6, 'host': '::1', 'public_key': pub, 'inbound': inbound})
    state = {'nodes': nodes}
    server = m.ROOT / 'server.json'; m.atomic(server, m.config(state))
    print(m.run(m.BIN, 'check', '-c', str(server)))
    m.export(state)
    print(m.run(m.BIN, 'check', '-c', str(m.ROOT / 'client.json')))
    process = subprocess.Popen([m.BIN, 'run', '-c', str(server)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(1)
        assert process.poll() is None, process.communicate()
        for n in nodes:
            if n['key'] in 'cd': continue  # QUIC listeners verified with ss below.
            with socket.socket(socket.AF_INET6) as s:
                s.settimeout(2); s.connect(('::1', n['inbound']['listen_port']))
        listeners = m.run('ss', '-lnut')
        for n in nodes: assert ':' + str(n['inbound']['listen_port']) in listeners
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200); self.end_headers(); self.wfile.write(b'sbv6-e2e-ok')
            def log_message(self, *args): pass
        http = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=http.serve_forever, daemon=True); thread.start()
        try:
            for key in 'cdfghilmn':
                node = next(n for n in nodes if n['key'] == key)
                cfg = {'inbounds': [{'type': 'socks', 'tag': 'socks', 'listen': '127.0.0.1', 'listen_port': 43599}], 'outbounds': m.client_outbounds(node)}
                clientfile = m.ROOT / 'e2e.json'; m.atomic(clientfile, cfg)
                cp = subprocess.Popen([m.BIN, 'run', '-c', str(clientfile)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    time.sleep(0.5)
                    body = m.run('curl', '--noproxy', '', '--max-time', '10', '--socks5-hostname', '127.0.0.1:43599', 'http://127.0.0.1:' + str(http.server_port))
                    assert body == 'sbv6-e2e-ok', body
                    print('PASS: SOCKS -> IPv6 ' + m.TAGS[key] + ' -> local HTTP end-to-end', flush=True)
                except Exception:
                    cp.terminate(); print(cp.communicate(timeout=10)[1].decode()); raise
                finally:
                    if cp.poll() is None: cp.terminate(); cp.communicate(timeout=10)
        finally:
            http.shutdown(); http.server_close()
        print('PASS: all 13 server/client configurations; IPv6 TCP + UDP listeners; exports')
    finally:
        process.terminate(); process.communicate(timeout=10)
