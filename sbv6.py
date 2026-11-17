#!/usr/bin/env python3
"""Independent dual-stack companion for fscarmen/sing-box. Python 3.9+."""
import argparse
import base64
import copy
import fcntl
import hashlib
import ipaddress
import json
import os
import platform
from pathlib import Path
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import tarfile
import uuid
from urllib.parse import quote, urlencode

ROOT = Path(os.environ.get('SBV6_DIR', '/etc/sbv6'))
SB = Path(os.environ.get('SB_DIR', '/etc/sing-box'))
BIN = os.environ.get('SB_BINARY', str(ROOT / 'bin/sing-box' if (ROOT / 'bin/sing-box').exists() and not (SB / 'sing-box').exists() else SB / 'sing-box'))
TAGS = dict(zip('bcdefghijklmn', ['xtls-reality', 'hysteria2', 'tuic', 'ShadowTLS', 'shadowsocks', 'trojan', 'vmess-ws', 'vless-ws-tls', 'h2-reality', 'grpc-reality', 'anytls', 'naive', 'snell-v6']))
CORE_VERSION = '1.15.0-alpha.13'
UPSTREAM_URL = 'https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh'

def download(url, target):
    # HTTPS verification remains enabled for executable downloads.
    run('curl', '-fL', '--retry', '2', '--connect-timeout', '15', '--max-time', '180', url, '-o', str(target))

def upstream_installed():
    return (SB / 'sing-box').is_file() and bool(list((SB / 'conf').glob('*_inbounds.json')))

def manage_upstream():
    command = shutil.which('sb')
    if upstream_installed() and command:
        subprocess.run([command], check=True)
        return
    with tempfile.TemporaryDirectory(prefix='sbv6-upstream-') as temp:
        script = Path(temp) / 'sing-box.sh'
        download(UPSTREAM_URL, script)
        subprocess.run(['bash', str(script)], check=True)
    if not upstream_installed(): raise ValueError('上游安装未完成；可重新选择安装或使用独立模式')

def ensure_ready(choice=None):
    global BIN
    if not upstream_installed() and choice != 'skip':
        if choice is None:
            choice = input('未安装上游 sing-box：1 安装上游；2 仅用 sbv6（只下载核心）；0 取消 [2]: ').strip() or '2'
            choice = {'1': 'install', '2': 'skip', '0': 'cancel'}.get(choice)
        if choice == 'install': manage_upstream()
        elif choice != 'skip': raise ValueError('已取消安装')
    standalone = ROOT / 'bin/sing-box'
    if 'SB_BINARY' not in os.environ:
        BIN = str(SB / 'sing-box') if (SB / 'sing-box').exists() else str(standalone)
    if Path(BIN).is_file():
        run(BIN, 'version'); return
    if 'SB_BINARY' in os.environ: raise ValueError('SB_BINARY 指定的核心不存在')
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64', 'armv7l': 'armv7', 'i686': '386'}.get(platform.machine())
    if not arch: raise ValueError('暂不支持此架构：' + platform.machine())
    asset = f'sing-box-{CORE_VERSION}-linux-{arch}'
    with tempfile.TemporaryDirectory(prefix='sbv6-core-') as temp:
        archive = Path(temp) / 'core.tar.gz'
        download(f'https://github.com/SagerNet/sing-box/releases/download/v{CORE_VERSION}/{asset}.tar.gz', archive)
        standalone.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as tf:
            member = tf.getmember(asset + '/sing-box')
            if not member.isfile(): raise ValueError('核心归档无效')
            with tf.extractfile(member) as src: payload = src.read()
        stage = standalone.with_suffix('.new'); stage.write_bytes(payload); stage.chmod(0o755)
        run(str(stage), 'version'); os.replace(stage, standalone)
    BIN = str(standalone)

def run(*args, **kw):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kw).stdout.strip()

def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def load():
    p = ROOT / 'state.json'
    return json.loads(p.read_text()) if p.exists() else {'follow': True, 'nodes': [], 'patches': {}}

def upstream():
    result = {}
    for p in sorted((SB / 'conf').glob('*_inbounds.json')):
        raw = p.read_text()
        data = json.loads(re.sub(r'^\s*//.*$', '', raw, flags=re.M))
        for ib in data.get('inbounds', []):
            for key, tag in TAGS.items():
                if ib.get('tag', '').endswith(' ' + tag):
                    ib = copy.deepcopy(ib)
                    if key == 'e':
                        ib['_inner'] = next(copy.deepcopy(i) for i in data['inbounds'] if i.get('tag') == ib.get('detour'))
                    pub = re.search(r'"public_key"\s*:\s*"([^"]+)"', raw)
                    result[key] = (ib, pub.group(1) if pub else '', p)
    return result

def detect6():
    data = json.loads(run('ip', '-j', '-6', 'addr', 'show', 'scope', 'global'))
    addresses = [a['local'] for i in data for a in i.get('addr_info', [])
                 if a.get('scope') == 'global' and not a.get('temporary') and not a.get('tentative')
                 and ipaddress.ip_address(a['local']).is_global]
    try:
        route = json.loads(run('ip', '-j', '-6', 'route', 'get', '2606:4700:4700::1111'))
        source = route[0].get('prefsrc', route[0].get('src'))
        if source in addresses: return source
    except (subprocess.CalledProcessError, IndexError): pass
    if not addresses: raise ValueError('未发现稳定的公网 IPv6；请先配置网卡，或用 --ipv6 指定本机地址')
    return addresses[0]

def cert(sni, naive=False):
    d = ROOT / ('cert-naive' if naive else 'cert-v6')
    d.mkdir(parents=True, exist_ok=True)
    if not (d / 'cert.pem').exists():
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '200' if naive else '3650', '-addext', 'subjectAltName=DNS:' + sni,
            '-subj', '/CN=' + sni, '-keyout', str(d / 'key.pem'), '-out', str(d / 'cert.pem'))
        (d / 'key.pem').chmod(0o600)
    return {'enabled': True, 'server_name': sni, 'certificate_path': str(d / 'cert.pem'), 'key_path': str(d / 'key.pem')}

def fresh(key, name):
    types = {'b': 'vless', 'c': 'hysteria2', 'd': 'tuic', 'e': 'shadowtls', 'f': 'shadowsocks', 'g': 'trojan', 'h': 'vmess', 'i': 'vless', 'j': 'vless', 'k': 'vless', 'l': 'anytls', 'm': 'naive', 'n': 'snell'}
    ib = {'type': types[key], 'tag': name + ' ' + TAGS[key]}
    user = {'uuid': str(uuid.uuid4())} if key in 'bdhijk' else {}
    if key in 'cdeglm': user['password'] = str(uuid.uuid4())
    if key == 'm': user['username'] = str(uuid.uuid4())
    if key == 'b': user['flow'] = 'xtls-rprx-vision'
    if key == 'f':
        ib.update(method='2022-blake3-aes-128-gcm', password=base64.b64encode(secrets.token_bytes(16)).decode())
    else: ib['users'] = [user]
    pub = ''
    if key in 'bjk':
        output = run(BIN, 'generate', 'reality-keypair')
        private = re.search(r'PrivateKey:\s*(\S+)', output)
        public = re.search(r'PublicKey:\s*(\S+)', output)
        if not private or not public: raise ValueError('无法解析 Reality 密钥')
        pub = public.group(1)
        ib['tls'] = {'enabled': True, 'server_name': 'addons.mozilla.org', 'reality': {
            'enabled': True, 'handshake': {'server': 'addons.mozilla.org', 'server_port': 443},
            'private_key': private.group(1), 'short_id': [secrets.token_hex(4)]}}
    elif key not in 'efhn': ib['tls'] = cert('addons.mozilla.org', key == 'm')
    if key == 'e':
        ib.update(version=3, strict_mode=True, handshake={'server': 'addons.mozilla.org', 'server_port': 443})
        ib['_inner'] = {'type': 'shadowsocks', 'method': '2022-blake3-aes-128-gcm', 'password': base64.b64encode(secrets.token_bytes(16)).decode(), 'network': 'tcp'}
    if key == 'n':
        ib.pop('users', None); ib.update(version=6, psk=str(uuid.uuid4()), mode='default')
    if key in 'hi': ib['transport'] = {'type': 'ws', 'path': '/' + str(uuid.uuid4())}
    if key == 'd': ib.update(congestion_control='bbr'); ib['tls']['alpn'] = ['h3']
    if key == 'j': ib['transport'] = {'type': 'http'}
    if key == 'k': ib['transport'] = {'type': 'grpc', 'service_name': 'grpc'}
    return ib, pub

def available(family, address, port, udp):
    for kind in ([socket.SOCK_STREAM, socket.SOCK_DGRAM] if udp == 'both' else [socket.SOCK_DGRAM] if udp else [socket.SOCK_STREAM]):
        with socket.socket(socket.AF_INET6 if family == 6 else socket.AF_INET, kind) as s:
            if family == 6: s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            try: s.bind((address, port))
            except OSError: return False
    return True

def add(state, args, dual=False):
    address = str(ipaddress.IPv6Address(args.ipv6 or detect6()))
    keys = args.protocols or input('协议 b=Reality c=Hy2 d=TUIC e=ShadowTLS f=SS g=Trojan h=VMess-WS i=VLESS-WS-TLS j=H2 k=gRPC l=AnyTLS m=Naive n=Snell；a=全部: ').strip() or 'a'
    keys = list(TAGS) if keys == 'a' else list(dict.fromkeys(keys.replace(' ', '')))
    if any(k not in TAGS for k in keys): raise ValueError('无效协议字母')
    sources = upstream()
    port = args.port or int(input('起始端口 [35000]: ') or 35000)
    for key in keys:
        owned = next((n for n in state['nodes'] if n['family'] == 4 and n['key'] == key), None)
        if state['follow'] and owned and key not in sources:
            ib, pub = copy.deepcopy(owned['inbound']), owned['public_key']
        elif state['follow'] and key in sources:
            ib, pub, _ = sources[key]
            ib = copy.deepcopy(ib)
            if ib.get('tls', {}).get('reality') and not pub: raise ValueError('上游缺少 Reality public_key 注释')
        else: ib, pub = fresh(key, args.name)
        families = [4, 6] if dual else [6]
        occupied = {n['inbound']['listen_port'] for n in state['nodes']}
        # Never reuse a port owned by the upstream, even if its listener is stopped.
        occupied.update(v[0]['listen_port'] for v in sources.values())
        while port <= 65535 and (port in occupied or any(not available(f, '0.0.0.0' if f == 4 else address, port, 'both' if key == 'm' else key in 'cd') for f in families)):
            print('跳过占用端口', port, file=sys.stderr); port += 1
        if not 1 <= port <= 65535: raise ValueError('无可用端口')
        state['nodes'] = [n for n in state['nodes'] if not (n['key'] == key and n['family'] in families)]
        for family in families:
            inbound = copy.deepcopy(ib)
            inbound.update(listen='0.0.0.0' if family == 4 else address, listen_port=port)
            inbound['tag'] = f'{ib["tag"].rsplit(" ", 1)[0]} IPv{family} {TAGS[key]}'
            host = args.ipv4 if family == 4 else address
            if not host: raise ValueError('双栈添加需要 --ipv4 公网地址（支持 NAT）')
            ipaddress.ip_address(host)
            state['nodes'].append({'key': key, 'family': family, 'host': host, 'public_key': pub, 'inbound': inbound})
        port += 1

def config(state):
    inbounds = []
    for n in state['nodes']:
        ib = copy.deepcopy(n['inbound']); inner = ib.pop('_inner', None)
        if inner:
            inner['tag'] = ib['tag'] + '-inner'; inner.pop('listen_port', None); inner['listen'] = '127.0.0.1'
            ib['detour'] = inner['tag']; inbounds.append(inner)
        inbounds.append(ib)
    return {'log': {'level': 'warn'}, 'inbounds': inbounds, 'outbounds': [{'type': 'direct', 'tag': 'direct'}]}

def client(n):
    ib = n['inbound']; key = n['key']; user = ib.get('users', [{}])[0]
    out = {'type': ib['type'], 'tag': ib['tag'], 'server': n['host'], 'server_port': ib['listen_port']}
    for field in ('uuid', 'password', 'flow', 'username'):
        if user.get(field): out[field] = user[field]
    if key == 'f': out.update(method=ib['method'], password=ib['password'])
    if 'transport' in ib: out['transport'] = ib['transport']
    if 'tls' in ib:
        tls = ib['tls']; out['tls'] = {'enabled': True, 'server_name': tls.get('server_name', '')}
        if tls.get('reality'):
            out['tls'].update(utls={'enabled': True, 'fingerprint': 'chrome'}, reality={'enabled': True, 'public_key': n['public_key'], 'short_id': tls['reality'].get('short_id', [''])[0]})
        else:
            # Embed the exact certificate rather than silently disabling TLS verification.
            path = tls.get('certificate_path')
            if path: out['tls']['certificate'] = Path(path).read_text()
            elif 'certificate' in tls: out['tls']['certificate'] = tls['certificate']
            else: raise ValueError('TLS 节点缺少可导出的证书')
        if tls.get('alpn'): out['tls']['alpn'] = tls['alpn']
    if key == 'd': out['congestion_control'] = ib.get('congestion_control', 'bbr')
    if key == 'h': out['security'] = 'auto'
    if key == 'm': out.update(quic=False, udp_over_tcp=True)
    if key == 'n': out.update(version=6, psk=ib['psk'], mode=ib.get('mode', 'default'), reuse=True)
    if key == 'e':
        out.update(version=3, tls={'enabled': True, 'server_name': ib['handshake']['server'], 'utls': {'enabled': True, 'fingerprint': 'chrome'}})
    return out

def client_outbounds(n):
    o = client(n)
    if n['key'] == 'm':
        quic = copy.deepcopy(o); quic.update(tag=o['tag'] + ' quic', quic=True, udp_over_tcp=False, quic_congestion_control='bbr')
        o['tag'] += ' http2'
        return [o, quic]
    if n['key'] != 'e': return [o]
    inner = n['inbound']['_inner']
    o['tag'] += '-tls'
    return [{'type': 'shadowsocks', 'tag': n['inbound']['tag'], 'method': inner['method'], 'password': inner['password'], 'detour': o['tag']}, o]

def uri(n):
    o = client(n); key = n['key']; tls = o.get('tls', {})
    host = '[' + o['server'] + ']' if ':' in o['server'] else o['server']
    auth = o.get('uuid', o.get('password', ''))
    scheme = o['type']; query = {}
    if key == 'h':
        payload = {'v': '2', 'ps': o['tag'], 'add': o['server'], 'port': str(o['server_port']), 'id': o['uuid'], 'aid': '0', 'scy': 'auto', 'net': 'ws', 'type': 'none', 'host': '', 'path': o['transport']['path'], 'tls': ''}
        return 'vmess://' + base64.b64encode(json.dumps(payload, ensure_ascii=False).encode()).decode()
    if key == 'e':
        inner = n['inbound']['_inner']; auth = base64.b64encode((inner['method'] + ':' + inner['password']).encode()).decode()
        plugin = {'version': '3', 'host': o['tls']['server_name'], 'password': o['password']}
        return f'ss://{auth}@{host}:{o["server_port"]}?' + urlencode({'shadow-tls': base64.b64encode(json.dumps(plugin).encode()).decode()}) + '#' + quote(o['tag'], safe='')
    if key == 'n': return f'snell://{quote(o["psk"], safe="")}@{host}:{o["server_port"]}?version=6&mode=default&reuse=1#' + quote(o['tag'], safe='')
    if key == 'm':
        return f'naive+https://{quote(o["username"], safe="")}:{quote(o["password"], safe="")}@{host}:{o["server_port"]}?' + urlencode({'uot': '1', 'security': 'tls', 'sni': tls['server_name'], 'tls_certificate': tls.get('certificate', '')}) + '#' + quote(o['tag'], safe='')
    if key == 'f': scheme = 'ss'; auth = base64.urlsafe_b64encode((o['method'] + ':' + o['password']).encode()).decode().rstrip('=')
    else: auth = quote(auth, safe='')
    if key == 'd': auth += ':' + quote(o['password'], safe=''); query['congestion_control'] = o['congestion_control']
    if tls:
        query.update(sni=tls['server_name'], security='reality' if 'reality' in tls else 'tls')
        if 'reality' in tls: query.update(pbk=n['public_key'], sid=tls['reality']['short_id'], fp='chrome')
        else: query['allowInsecure'] = '1'  # URI formats cannot embed PEM trust; JSON output pins it.
    if o.get('flow'): query['flow'] = o['flow']
    if 'transport' in o:
        t = o['transport']; query['type'] = t['type']
        if t['type'] == 'grpc': query['serviceName'] = t['service_name']
        if t['type'] == 'ws': query['path'] = t['path']
    return f'{scheme}://{auth}@{host}:{o["server_port"]}?' + urlencode(query) + '#' + quote(o['tag'], safe='')

def export(state):
    nodes = list(state['nodes'])
    if state.get('ipv4'):
        for key, (ib, pub, _) in upstream().items():
            if ib.get('listen') not in ('127.0.0.1', '::1'):
                nodes.append({'key': key, 'family': 4, 'host': state['ipv4'], 'public_key': pub, 'inbound': ib})
    links = []
    for n in nodes:
        link = uri(n); links.append(link)
        if n['key'] == 'm': links.append(link.replace('naive+https://', 'naive+quic://', 1).replace('uot=1', 'congestion_control=bbr') + '%20quic')
    atomic(ROOT / 'nodes.txt', '\n'.join(links) + ('\n' if links else ''))
    atomic(ROOT / 'subscription.txt', base64.b64encode('\n'.join(links).encode()).decode())
    atomic(ROOT / 'client.json', {'outbounds': [o for n in nodes for o in client_outbounds(n)] + [{'type': 'direct', 'tag': 'direct'}]})
    proxies = []
    for n in nodes:
        o = client(n); tls = o.get('tls', {})
        if n['key'] == 'm': continue  # Upstream also exports Naive to sing-box/Throne, not Clash.
        proxy = {'name': o['tag'], 'type': o['type'], 'server': o['server'], 'port': o['server_port'], 'udp': True}
        for field in ('uuid', 'password', 'flow'):
            if field in o: proxy[field] = o[field]
        if o['type'] == 'shadowsocks': proxy.update(type='ss', cipher=o['method'])
        if n['key'] == 'e':
            inner = n['inbound']['_inner']
            proxy.update(type='ss', cipher=inner['method'], password=inner['password'], plugin='shadow-tls', **{'plugin-opts': {'host': tls['server_name'], 'password': o['password'], 'version': 3}})
        if n['key'] == 'n': proxy.update(psk=o['psk'], version=6, mode=o['mode'], reuse=True)
        if n['key'] == 'h': proxy.update(alterId=0, cipher='auto')
        if tls:
            proxy.update(tls=True, servername=tls['server_name'], **{'client-fingerprint': 'chrome'})
            if 'reality' in tls:
                proxy['reality-opts'] = {'public-key': n['public_key'], 'short-id': tls['reality']['short_id']}
            else: proxy['skip-cert-verify'] = True
        if 'transport' in o:
            t = o['transport']; proxy['network'] = 'h2' if t['type'] == 'http' else t['type']
            if t['type'] == 'grpc': proxy['grpc-opts'] = {'grpc-service-name': t['service_name']}
            if t['type'] == 'http': proxy['h2-opts'] = {'host': [tls['server_name']], 'path': '/'}
            if t['type'] == 'ws': proxy['ws-opts'] = {'path': t['path']}
        if o['type'] == 'tuic': proxy.update(**{'congestion-controller': o['congestion_control'], 'alpn': ['h3']})
        proxies.append(proxy)
    # JSON is also valid YAML 1.2; no third-party YAML dependency required.
    atomic(ROOT / 'clash.yaml', {'proxies': proxies, 'proxy-groups': [{'name': 'PROXY', 'type': 'select', 'proxies': [p['name'] for p in proxies] or ['DIRECT']}], 'rules': ['MATCH,PROXY']})
    return links

def service(action):
    if Path('/run/systemd/system').exists():
        run('systemctl', action, 'sbv6.service')
        if action == 'restart': run('systemctl', 'is-active', '--quiet', 'sbv6.service')
    elif shutil.which('rc-service'): run('rc-service', 'sbv6', action)
    else: raise ValueError('需要 systemd 或 OpenRC；WSL 请启用 systemd')

def firewall(state):
    """Reconcile only rules explicitly owned by sbv6. No firewall flushes."""
    for family, command in ((4, 'iptables'), (6, 'ip6tables')):
        if not shutil.which(command): continue
        desired = set()
        for n in state['nodes']:
            if n['family'] != family: continue
            for proto in (('tcp', 'udp') if n['key'] == 'm' else ('udp',) if n['key'] in 'cd' else ('tcp',)):
                desired.add(('-p', proto, '--dport', str(n['inbound']['listen_port']), '-m', 'comment', '--comment', 'sbv6', '-j', 'ACCEPT'))
        existing = []
        for line in run(command, '-w', '-S', 'INPUT').splitlines():
            rule = shlex.split(line)
            if '--comment' in rule and rule[rule.index('--comment') + 1] == 'sbv6': existing.append(tuple(rule[2:]))
        for rule in desired:
            check = subprocess.run([command, '-w', '-C', 'INPUT', *rule], capture_output=True)
            if check.returncode: run(command, '-w', '-I', 'INPUT', '1', *rule)
        # iptables normalizes rule order; compare with -C rather than string equality.
        ports = {(r[r.index('-p') + 1], r[r.index('--dport') + 1]) for r in desired}
        for rule in existing:
            if ('-p' not in rule or '--dport' not in rule or
                    (rule[rule.index('-p') + 1], rule[rule.index('--dport') + 1]) not in ports):
                run(command, '-w', '-D', 'INPUT', *rule)

def commit(state):
    cfg = json.dumps(config(state), ensure_ascii=False, indent=2)
    candidate = ROOT / 'candidate.json'
    atomic(candidate, cfg)
    try: run(BIN, 'check', '-c', str(candidate))
    finally: candidate.unlink(missing_ok=True)
    # Validate exports before touching running configuration.
    for n in state['nodes']: client(n)
    target = ROOT / 'config.json'; old = target.read_text() if target.exists() else None
    changed = old != cfg
    if changed:
        atomic(target, cfg)
        try:
            service('restart')
            firewall(state)
        except Exception:
            if old is not None: atomic(target, old); service('restart')
            else: target.unlink(missing_ok=True)
            raise
    else: firewall(state)
    atomic(ROOT / 'state.json', state)
    export(state)

def sync(state):
    if any(n['family'] == 6 for n in state['nodes']):
        address = detect6()
        for n in state['nodes']:
            if n['family'] == 6: n['host'] = address; n['inbound']['listen'] = address
    commit(state)

def change_mode(state):
    state['follow'] = not state['follow']
    print('参考 IPv4' if state['follow'] else '完全独立')
    if state['nodes'] and input('立即套用到已有 IPv6 节点（保留端口）？[y/N]: ').lower() == 'y':
        sources = upstream()
        for n in state['nodes']:
            if n['family'] != 6: continue
            key = n['key']; old = n['inbound']
            if state['follow'] and key in sources:
                ib, pub, _ = sources[key]; ib = copy.deepcopy(ib)
            else: ib, pub = fresh(key, old['tag'].rsplit(' ', 2)[0])
            for field in ('tag', 'listen', 'listen_port'): ib[field] = old[field]
            n.update(inbound=ib, public_key=pub)
        commit(state)
    else: atomic(ROOT / 'state.json', state)

def pin_upstream(state, restore=False):
    """Only change wildcard direct listeners; never touch loopback tunnel origins."""
    changes = []
    for path in sorted((SB / 'conf').glob('*_inbounds.json')):
        raw = path.read_text()
        data = json.loads(re.sub(r'^\s*//.*$', '', raw, flags=re.M))
        if restore:
            saved = state.get('patches', {}).get(str(path))
            if saved and hashlib.sha256(raw.encode()).hexdigest() == saved['hash']:
                changes.append((path, raw, saved['original']))
            continue
        inbounds = data.get('inbounds', [])
        # Keep comments, whitespace and every non-listen field byte-for-byte.
        if not any(i.get('listen') in ('::', '0.0.0.0') for i in inbounds): continue
        updated = re.sub(r'("listen"\s*:\s*)"::"', r'\1"0.0.0.0"', raw)
        if updated != raw:
            state['patches'][str(path)] = {'original': raw, 'hash': hashlib.sha256(updated.encode()).hexdigest()}
            changes.append((path, raw, updated))
    if not changes: return
    for path, _, updated in changes: atomic(path, updated)
    try:
        run(BIN, 'check', '-C', str(SB / 'conf'))
        if Path('/run/systemd/system').exists(): run('systemctl', 'restart', 'sing-box')
        else: run('rc-service', 'sing-box', 'restart')
    except Exception:
        for path, original, _ in changes: atomic(path, original)
        raise
    atomic(ROOT / 'state.json', state)

def install():
    dest = Path('/usr/local/lib/sbv6'); dest.mkdir(parents=True, exist_ok=True)
    src = Path(__file__).resolve()
    if src != dest / 'sbv6.py': shutil.copy2(src, dest / 'sbv6.py')
    atomic('/usr/local/bin/sbv6', '#!/bin/sh\nexec python3 /usr/local/lib/sbv6/sbv6.py "$@"\n')
    Path('/usr/local/bin/sbv6').chmod(0o755)
    if Path('/run/systemd/system').exists():
        atomic('/etc/systemd/system/sbv6.service', f'[Unit]\nDescription=Independent sing-box dual stack nodes\nAfter=network-online.target\nWants=network-online.target\n[Service]\nExecStart={BIN} run -c {ROOT}/config.json\nRestart=on-failure\nRestartSec=5\nUMask=0077\n[Install]\nWantedBy=multi-user.target\n')
        atomic('/etc/systemd/system/sbv6-sync.service', '[Unit]\nDescription=Refresh sbv6 IPv6 address\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/sbv6 -s\n')
        atomic('/etc/systemd/system/sbv6-sync.timer', '[Unit]\nDescription=Watch sbv6 IPv6 address\n[Timer]\nOnBootSec=30\nOnUnitActiveSec=60\n[Install]\nWantedBy=timers.target\n')
        run('systemctl', 'daemon-reload'); run('systemctl', 'enable', 'sbv6.service'); run('systemctl', 'enable', '--now', 'sbv6-sync.timer')
    elif shutil.which('rc-service'):
        atomic('/etc/init.d/sbv6', f'#!/sbin/openrc-run\ncommand="{BIN}"\ncommand_args="run -c {ROOT}/config.json"\ncommand_background=true\npidfile=/run/sbv6.pid\ndepend() {{ need net; }}\n')
        Path('/etc/init.d/sbv6').chmod(0o755); run('rc-update', 'add', 'sbv6', 'default')
        atomic('/etc/periodic/1min/sbv6', '#!/bin/sh\n/usr/local/bin/sbv6 -s\n'); Path('/etc/periodic/1min/sbv6').chmod(0o755)
    else: raise ValueError('无法安装守护服务：需要 systemd 或 OpenRC')

def delete(state):
    while True:
        for i, n in enumerate(state['nodes'], 1): print(i, n['inbound']['tag'], n['inbound']['listen_port'])
        answer = input('删除编号（空格分隔 / a=全部 / 0=取消）: ').strip()
        if answer == '0': return
        try:
            ids = set(range(1, len(state['nodes']) + 1)) if answer == 'a' else set(map(int, answer.split()))
            if not ids or not ids <= set(range(1, len(state['nodes']) + 1)): raise ValueError()
        except ValueError: print('编号无效，请重试'); continue
        if input('确认删除？[y/N]: ').lower() == 'y':
            state['nodes'] = [n for i, n in enumerate(state['nodes'], 1) if i not in ids]; commit(state)
        return

def uninstall():
    if input('确认卸载 sbv6 全部节点与命令？[y/N]: ').lower() != 'y': return
    pin_upstream(load(), restore=True)
    firewall({'nodes': []})
    if Path('/run/systemd/system').exists():
        for unit in ('sbv6-sync.timer', 'sbv6.service'):
            subprocess.run(['systemctl', 'disable', '--now', unit], capture_output=True)
        for unit in ('sbv6.service', 'sbv6-sync.service', 'sbv6-sync.timer'):
            Path('/etc/systemd/system', unit).unlink(missing_ok=True)
        run('systemctl', 'daemon-reload')
    elif shutil.which('rc-service'):
        subprocess.run(['rc-service', 'sbv6', 'stop'], capture_output=True)
        subprocess.run(['rc-update', 'del', 'sbv6'], capture_output=True)
        Path('/etc/init.d/sbv6').unlink(missing_ok=True); Path('/etc/periodic/1min/sbv6').unlink(missing_ok=True)
    shutil.rmtree(ROOT)
    Path('/usr/local/bin/sbv6').unlink(missing_ok=True)
    shutil.rmtree('/usr/local/lib/sbv6', ignore_errors=True)

def main():
    p = argparse.ArgumentParser(prog='sbv6', description='sbv6：sing-box 独立双栈助手')
    g = p.add_mutually_exclusive_group()
    for flag, dest, helptext in [('-s','sync','同步/自检'),('-b','dual','双栈添加'),('-a','add','IPv6 添加'),('-l','list','输出节点/订阅'),('-d','diagnose','网络诊断'),('-u','uninstall','卸载'),('-i','install','安装命令与守护'),('-f','follow','切换凭据参考模式')]:
        g.add_argument(flag, action='store_true', dest=dest, help=helptext)
    p.add_argument('-p', '--port', type=int); p.add_argument('--protocols'); p.add_argument('--ipv6'); p.add_argument('--ipv4'); p.add_argument('--name', default=socket.gethostname())
    p.add_argument('--upstream', choices=('install', 'skip'), help='未安装上游时：install 安装官方脚本；skip 独立使用（只下载核心）')
    args = p.parse_args()
    if os.geteuid() != 0 and not (args.list or args.diagnose): raise ValueError('请以 root 运行')
    ROOT.mkdir(parents=True, exist_ok=True); ROOT.chmod(0o700)
    with open(ROOT / '.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load()
        if args.ipv4:
            state['ipv4'] = str(ipaddress.IPv4Address(args.ipv4))
        if args.install: ensure_ready(args.upstream); install(); pin_upstream(state); return
        if args.uninstall: uninstall(); return
        if args.diagnose:
            for cmd in [('ip','-6','addr'),('ip','-6','route'),('ss','-lntup')]: print(run(*cmd))
            print(json.dumps(state, ensure_ascii=False, indent=2)); return
        if args.follow:
            change_mode(state); return
        if args.list:
            print('\n'.join(export(state))); print('Base64 订阅:', (ROOT / 'subscription.txt').read_text()); return
        if args.sync: sync(state); return
        if args.add or args.dual:
            ensure_ready(args.upstream)
            if not Path('/usr/local/bin/sbv6').exists(): install()
            add(state, args, args.dual); commit(state); print('\n'.join(export(state))); return
        ensure_ready(args.upstream)
        # The downloaded script is also the installer: save its embedded payload
        # before the temporary extraction directory is removed by the launcher.
        install()
        pin_upstream(state)
        print('sbv6 已就绪；以后直接输入 sbv6 打开管理菜单。')
        while True:
            state = load()
            if args.ipv4: state['ipv4'] = str(ipaddress.IPv4Address(args.ipv4))
            print('\n1 管理上游 IPv4  2 添加 IPv6  3 双栈添加  4 节点/订阅\n5 编号删除  6 同步修复  7 重探 IPv6  8 状态  9 卸载\n10 安装命令/守护  11 参考/独立凭据  0 退出')
            choice = input('选择: ').strip()
            if choice == '0': return
            try:
                if choice == '1':
                    manage_upstream(); pin_upstream(state); sync(state)
                elif choice in ('2','3'):
                    if not Path('/usr/local/bin/sbv6').exists(): install()
                    if choice == '3' and not args.ipv4:
                        args.ipv4 = input('IPv4 公网地址: ').strip(); state['ipv4'] = str(ipaddress.IPv4Address(args.ipv4))
                    add(state, args, choice == '3'); commit(state)
                elif choice == '4': print('\n'.join(export(state))); print((ROOT / 'subscription.txt').read_text())
                elif choice == '5': delete(state)
                elif choice in ('6','7'): sync(state)
                elif choice == '8': print(run('ss','-lntup')); print(len(state['nodes']), 'nodes; follow:', state['follow'])
                elif choice == '9': uninstall(); return
                elif choice == '10': ensure_ready(args.upstream); install()
                elif choice == '11':
                    change_mode(state)
            except (ValueError, OSError, subprocess.CalledProcessError) as e: print('操作失败:', e, file=sys.stderr)

if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        print('sbv6:', e, getattr(e, 'stderr', ''), file=sys.stderr); sys.exit(1)
