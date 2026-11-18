"""Join a Bitkit simulator to its run/attempt/shard's private Linux fixture."""
import base64
import hashlib
import hmac
import http.client
import ipaddress
import json
import os
from pathlib import Path
import secrets
import select
import signal
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SHARD = os.environ['SHARD']
if SHARD not in ('1', '2'):
    raise ValueError('SHARD must be 1 or 2')
RUN = os.environ['GITHUB_RUN_ID']
ATTEMPT = os.environ['GITHUB_RUN_ATTEMPT']
PAIR = f'{RUN}-{ATTEMPT}-{SHARD}'
STATE = Path(os.environ['RUNNER_TEMP']) / f'bitkit-{PAIR}'
CONTROL = 8081
# Published ports from BITKIT_DOCKER_REVISION, including fee estimates and LDK backup.
PORTS = [43782, 60001, 23009, 23180, 23735, 23080, 23003] + ([21325] if SHARD == '2' else [])


def github_env(values):
    with open(os.environ['GITHUB_ENV'], 'a') as out:
        for key, value in values.items():
            print(f'{key}={value}', file=out)


def authorize():
    # Domain separation keeps credentials unique to this workflow attempt and shard.
    context = f'bitkit-hosted-ios-v1/{os.environ["GITHUB_REPOSITORY"]}/{PAIR}'.encode()
    secret = os.environ['TS_AUTHKEY']
    if not secret:
        raise RuntimeError('The Tailscale Actions secret is unavailable')
    token = hmac.new(secret.encode(), context, hashlib.sha256).hexdigest()
    print(f'::add-mask::{token}', flush=True)
    github_env({'HOSTED_E2E_PAIR_TOKEN': token})


def signature(message):
    return hmac.new(os.environ['HOSTED_E2E_PAIR_TOKEN'].encode(), message, hashlib.sha256).hexdigest()


def auth():
    return {'Authorization': 'Bearer ' + signature(b'client authorization')}


def jobs():
    endpoint = f'repos/{os.environ["GITHUB_REPOSITORY"]}/actions/runs/{RUN}/attempts/{ATTEMPT}/jobs?per_page=100'
    try:
        raw = subprocess.check_output(['gh', 'api', endpoint], timeout=20, stderr=subprocess.DEVNULL)
        return {job['name']: job for job in json.loads(raw)['jobs']}
    except (subprocess.SubprocessError, OSError, ValueError):
        print('::warning::Transient error reading this attempt\'s jobs', file=sys.stderr, flush=True)
        return {}


def failed_job(snapshot):
    for role in ('iOS', 'Ubuntu'):
        for shard in ('1', '2'):
            job = snapshot.get(f'Hosted {role} shard {shard}', {})
            if job.get('status') == 'completed' and job.get('conclusion') != 'success':
                raise RuntimeError(f'{job["name"]} ended with {job.get("conclusion")}')


def wait_for(description, probe, seconds, check_jobs=True):
    deadline = time.monotonic() + seconds
    next_status = 0
    last_error = 'not ready'
    while time.monotonic() < deadline:
        if check_jobs and time.monotonic() >= next_status:
            failed_job(jobs())
            next_status = time.monotonic() + 30
        try:
            result = probe()
            if result:
                return result
        except (OSError, http.client.HTTPException, subprocess.SubprocessError, ValueError) as exc:
            # Only exception classes go to public logs. Responses may contain credentials.
            last_error = type(exc).__name__
        time.sleep(3)
    raise TimeoutError(f'Timed out waiting for {description} ({last_error}); rerun all jobs together')


def peer(role):
    name = f'bk-{role}-{PAIR}'
    def lookup():
        status = json.loads(subprocess.check_output(['tailscale', 'status', '--json'], timeout=10))
        matches = [ip for device in (status.get('Peer') or {}).values()
                   if device.get('Online') and device['HostName'] == name
                   for ip in device['TailscaleIPs'] if ipaddress.ip_address(ip).version == 4]
        if len(matches) > 1:
            raise RuntimeError(f'Multiple live Tailscale peers named {name}')
        return matches[0] if matches else None
    return wait_for(name, lookup, 600)


def request(host, port, method, path, body=None, headers=None, tls=None, timeout=10):
    conn = (http.client.HTTPSConnection(host, port, timeout=timeout, context=tls) if tls
            else http.client.HTTPConnection(host, port, timeout=timeout))
    try:
        conn.request(method, path, body=body, headers=headers or {})
        response = conn.getresponse()
        if response.status != 200:
            raise OSError(f'HTTP status {response.status}')
        return response.read()
    finally:
        conn.close()


def bitcoin(method, *params):
    body = json.dumps({'jsonrpc': '1.0', 'id': 1, 'method': method, 'params': params})
    headers = {'Authorization': 'Basic ' + base64.b64encode(b'polaruser:polarpass').decode()}
    result = json.loads(request('127.0.0.1', 43782, 'POST', '/', body, headers))
    if result['error']:
        raise OSError(f'Bitcoin RPC {method} failed')
    return result['result']


def pipe(left, right):
    # Preserve half-close: a peer can finish writing and still wait for a response.
    readers = {left: right, right: left}
    while readers:
        for src in select.select(list(readers), [], [])[0]:
            chunk = src.recv(65536)
            if chunk:
                readers[src].sendall(chunk)
            else:
                readers.pop(src).shutdown(socket.SHUT_WR)


class Fixture(BaseHTTPRequestHandler):
    rbufsize = 0  # CONNECT must leave all application bytes on the socket.

    def log_message(self, *_):
        pass

    def allowed(self):
        if (self.client_address[0] == self.server.mac_ip
                and hmac.compare_digest(self.headers.get('Authorization', ''), auth()['Authorization'])):
            return True
        self.send_error(403)
        return False

    def reply(self, data):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.allowed():
            return
        if self.path != '/session':
            return self.send_error(404)
        challenge = self.headers.get('X-Pair-Challenge', '')
        if len(challenge) != 64 or any(c not in '0123456789abcdef' for c in challenge):
            return self.send_error(400)
        proof = signature(b'server response:' + challenge.encode() + self.server.session)
        self.reply(json.dumps({'session': self.server.session.decode(), 'proof': proof}).encode())

    def do_CONNECT(self):
        if not self.allowed():
            return
        allowed = {f'127.0.0.1:{port}': port for port in PORTS}
        if self.path not in allowed:
            return self.send_error(403)
        try:
            remote = socket.create_connection(('127.0.0.1', allowed[self.path]), timeout=8)
        except OSError:
            return self.send_error(502)
        with remote:
            self.send_response(200)
            self.end_headers()
            remote.settimeout(None)
            try:
                pipe(self.connection, remote)
            except OSError:
                pass

    def do_POST(self):
        if not self.allowed():
            return
        if self.path != '/trezor' or SHARD != '2':
            return self.send_error(404)
        commands = {'start': ['start', '--json'], 'status': ['status', '--json'], 'stop': ['stop'],
                    'press-yes': ['send-json', '{"type":"emulator-press-yes"}']}
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size < 256:
                raise ValueError()
            command = json.loads(self.rfile.read(size))['command']
            args = commands[command]
        except (KeyError, TypeError, ValueError):
            return self.send_error(400)
        helper = Path(os.environ['BITKIT_LOCAL_BACKEND_ROOT']) / 'scripts/trezor-emulator'
        try:
            with self.server.trezor_lock:
                output = subprocess.check_output([str(helper), *args], stderr=subprocess.DEVNULL, timeout=300)
            self.reply(json.dumps(json.loads(output)).encode() if command in ('status', 'start') else b'{}')
        except (OSError, ValueError, subprocess.SubprocessError):
            self.send_error(502, 'Trezor fixture command failed')


def serve():
    ip = subprocess.check_output(['tailscale', 'ip', '-4'], text=True, timeout=10).strip()
    credentials = Path(os.environ['E2E_DIR']) / '.cache/local-backend/lnd'
    with ThreadingHTTPServer((ip, CONTROL), Fixture) as server:
        server.mac_ip = os.environ['HOSTED_MAC_IP']
        server.trezor_lock = threading.Lock()
        server.session = json.dumps({
            'pair': PAIR, 'wallet_address': bitcoin('getnewaddress', PAIR),
            'cert': (credentials / 'tls.cert').read_text(),
            'macaroon': (credentials / 'admin.macaroon').read_bytes().hex(),
        }).encode()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f'Serving the private backend for shard {SHARD}', flush=True)
        # Wait specifically for this attempt's Mac. Other shards may still be running.
        def finished():
            job = jobs().get(f'Hosted iOS shard {SHARD}', {})
            return job.get('status') == 'completed'
        deadline = time.monotonic() + 165 * 60
        while time.monotonic() < deadline:
            if finished():
                return
            time.sleep(15)
        raise TimeoutError('Paired Mac did not finish before the backend deadline')


class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        port = self.server.server_address[1]
        try:
            if port == CONTROL:
                with socket.create_connection((self.server.backend_ip, CONTROL), timeout=8) as remote:
                    remote.settimeout(None)
                    pipe(self.request, remote)
                return
            conn = http.client.HTTPConnection(self.server.backend_ip, CONTROL, timeout=8)
            try:
                conn.set_tunnel('127.0.0.1', port, headers=auth())
                conn.connect()
                conn.sock.settimeout(None)
                pipe(self.request, conn.sock)
            finally:
                conn.close()
        except (OSError, http.client.HTTPException):
            return


def relay():
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    servers = []
    for port in [*PORTS, CONTROL]:
        server = socketserver.ThreadingTCPServer(('127.0.0.1', port), Relay)
        server.daemon_threads = True
        server.backend_ip = sys.argv[2]
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    (STATE / 'listening').touch()
    signal.pause()


def connect():
    backend = peer('linux')
    challenge = secrets.token_hex(32)
    headers = {**auth(), 'X-Pair-Challenge': challenge}
    envelope = wait_for('authenticated fixture session',
                        lambda: json.loads(request(backend, CONTROL, 'GET', '/session', headers=headers)), 900)
    proof = signature(b'server response:' + challenge.encode() + envelope['session'].encode())
    if not hmac.compare_digest(proof, envelope['proof']):
        raise RuntimeError('Backend failed the per-pair authentication challenge')
    session = json.loads(envelope['session'])
    if session['pair'] != PAIR:
        raise RuntimeError('Backend session identity mismatch')
    os.umask(0o077)
    STATE.mkdir(exist_ok=True)
    cert = STATE / 'tls.cert'
    macaroon = STATE / 'admin.macaroon'
    cert.write_text(session['cert'])
    macaroon.write_bytes(bytes.fromhex(session['macaroon']))
    with (STATE / 'relay.log').open('w') as log:
        proxy = subprocess.Popen([sys.executable, __file__, 'relay', backend], start_new_session=True,
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    (STATE / 'relay.pid').write_text(str(proxy.pid))
    def listening():
        if proxy.poll() is not None:
            raise RuntimeError('Could not bind all Mac loopback ports; check relay.log')
        return (STATE / 'listening').exists()
    wait_for('local listeners', listening, 20, False)
    tls = ssl.create_default_context(cafile=str(cert))
    def healthy():
        if bitcoin('getblockchaininfo')['chain'] != 'regtest' or session['wallet_address'] not in bitcoin('getaddressesbylabel', PAIR):
            raise RuntimeError('Bitcoin RPC reached the wrong regtest wallet')
        with socket.create_connection(('127.0.0.1', 60001), timeout=8) as electrum:
            electrum.sendall(b'{"id":1,"method":"blockchain.headers.subscribe","params":[]}\n')
            with electrum.makefile('rb') as stream:
                if json.loads(stream.readline(8192))['result']['height'] <= 0:
                    return False
        lnd = json.loads(request('127.0.0.1', 23180, 'GET', '/v1/getinfo', tls=tls,
                                 headers={'Grpc-Metadata-macaroon': session['macaroon']}))
        if not lnd.get('identity_pubkey') or not lnd.get('synced_to_chain'):
            return False
        if SHARD == '2':
            devices = json.loads(request('127.0.0.1', 21325, 'POST', '/enumerate', b''))
            if not any(device.get('path') for device in devices):
                return False
        return True
    wait_for('regtest wallet, Electrum, LND and selected hardware services', healthy, 180)
    env = {'ELECTRUM_PORT': '60001', 'LND_HOST': '127.0.0.1', 'LND_GRPC_PORT': '23009',
           'LND_REST_PORT': '23180', 'LND_P2P_PORT': '23735', 'LND_TLS_PATH': cert, 'LND_MACAROON_PATH': macaroon}
    if SHARD == '2':
        client_token = signature(b'client authorization')
        print(f'::add-mask::{client_token}', flush=True)
        env.update(TREZOR_FIXTURE_URL=f'http://127.0.0.1:{CONTROL}', TREZOR_FIXTURE_TOKEN=client_token)
    github_env(env)
    print(f'Connected shard {SHARD} to {PAIR}; verified its wallet, Electrum and LND over loopback')


def barrier():
    def both_ready():
        snapshot = jobs()
        failed_job(snapshot)
        for shard in ('1', '2'):
            steps = snapshot.get(f'Hosted iOS shard {shard}', {}).get('steps', [])
            if not any(step['name'] == 'Verify paired backend' and step.get('conclusion') == 'success' for step in steps):
                return False
        return True
    # The step that invokes this method must follow Verify paired backend in both jobs.
    wait_for('both simulator/backend pairs to pass preflight', both_ready, 900, False)
    print('Both hosted simulator/backend pairs passed preflight')


def stop():
    pid = STATE / 'relay.pid'
    if pid.exists():
        try:
            os.kill(int(pid.read_text()), signal.SIGTERM)
        except ProcessLookupError:
            pass
    for name in ('admin.macaroon', 'tls.cert', 'relay.pid', 'listening'):
        (STATE / name).unlink(missing_ok=True)


if __name__ == '__main__':
    {'authorize': authorize, 'mac-ip': lambda: print(peer('mac')), 'serve': serve, 'relay': relay, 'connect': connect,
     'barrier': barrier, 'stop': stop}[sys.argv[1]]()
