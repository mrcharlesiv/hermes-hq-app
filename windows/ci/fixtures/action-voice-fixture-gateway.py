#!/usr/bin/env python3
"""Local, synthetic Hermes gateway for Action Button / inline memo UI regression tests.

All bot/session data is invented. This server has no upstream URL or network client.
Prompts are rejected unless --accept-prompts is explicit; accepted prompts stay in memory.
/__fixture/state exposes requests so tests can verify the intended destination and send count.
Run: python3 scripts/action-voice-fixture-gateway.py --port 9337 --credentials /tmp/voice-qa.json
"""
import argparse, base64, hashlib, importlib.util, json, os, pathlib, secrets, socket, struct, threading, time, sys, traceback
from http.server import ThreadingHTTPServer
from email.parser import BytesParser
from email.policy import default as email_policy
from urllib.parse import urlparse

_spec = importlib.util.spec_from_file_location('auth_fixture', pathlib.Path(__file__).parent/'native-startup/fake-gateway.py')
auth = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(auth)
SIDS = {'default': '20260929_120000_aabbcc01', 'sam': '20260929_120000_aabbcc02'}
state = {'rpc': [], 'rest': [], 'promptAttempts': 0, 'upstreamCalls': 0, 'uploads': []}
lock = threading.Lock()
ACCEPT_PROMPTS = False
# --label names this gateway's bots and chats ("Alpha Chat", "Alpha Sam"), so two fixtures' data can be told
# apart on screen (multi-gateway checks); the session ids stay the same, so a cache keyed only by id would leak.
LABEL = ''
def title(): return (LABEL + ' Chat') if LABEL else 'Bot Chat'

def row(profile):
    return {'id': SIDS[profile], 'title': title(), 'profile': profile, 'profile_name': profile,
            'hidden': True, 'model': 'fixture-model', 'billing_provider': 'fixture', 'message_count': 1,
            'started_at': 1790686800, 'last_active': 1790686800, 'source': 'desktop', 'cwd': '/fixture'}

def resumed(profile):
    stored = SIDS[profile]
    return {'session_id': hashlib.sha256(stored.encode()).hexdigest()[:8], 'resumed': stored,
            'session_key': stored, 'stored_session_id': stored, 'messages': [], 'messages_omitted': True,
            'message_count': 1, 'status': 'idle', 'running': False, 'inflight': None,
            'info': {'model': 'fixture-model', 'provider': 'fixture', 'cwd': '/fixture', 'title': title(),
                     'tools': {}, 'skills': {}, 'mcp_servers': [], 'lazy': True, 'running': False,
                     'stored_session_id': stored, 'profile_name': profile, 'desktop_contract': 8}}

def rpc(method, params):
    logged = {k:v for k,v in params.items() if k not in ('data_url','soul')}
    if 'data_url' in params: logged['dataUrlBytes'] = len(params['data_url'])
    with lock: state['rpc'].append({'method': method, 'params': logged})
    profile = params.get('profile') or 'default'
    profile = profile if profile in SIDS else 'default'
    if method.startswith('prompt.'):
        with lock: state['promptAttempts'] += 1
        if ACCEPT_PROMPTS and method == 'prompt.submit': return {'status':'streaming','user_row_id':state['promptAttempts']}
        raise ValueError('Synthetic voice test never accepts prompts')
    if method == 'file.attach': return {'attached':True,'path':'/fixture/voice-memo.wav','ref_text':'@file:/fixture/voice-memo.wav'}
    if method == 'gateway.ping': return {'ok': True}
    if method == 'model.options': return {'model':'fixture-model','provider':'fixture','providers':[{'slug':'fixture','name':'Fixture','models':['fixture-model'],'authenticated':True}]}
    if method == 'session.active_list': return {'sessions': []}
    if method == 'free_tier.status': return {'enabled':False}
    if method == 'setup.status': return {'configured':True,'ready':True,'complete':True}
    if method == 'profiles.list':
        return {'active': 'default', 'profiles': [{'name': key, 'is_active': key == 'default', 'description': 'Synthetic voice QA',
                    'model': 'fixture-model', 'canonical_session': row(key), 'sessions': [row(key)],
                    'ui_meta': {'hermes-bots': {'display_name': (LABEL + ' ' if LABEL else '') + ('Hermes' if key == 'default' else 'Sam')}}} for key in SIDS]}
    if method == 'session.list': return {'sessions': [row(profile)], 'total': 1}
    if method == 'session.most_recent': return {'session_id': None}
    if method in ('session.resume', 'session.activate'):
        asked = params.get('session_id')
        owner = next((p for p, s in SIDS.items() if asked in (s, resumed(p)['session_id'])), profile)
        return resumed(owner)
    if method in ('session.info', 'session.get'): return resumed(profile)['info']
    if method == 'session.events.since': return {'events': [], 'latest_seq': 0, 'truncated': False, 'count': 0, 'epoch': 'fixture', 'open_requests': []}
    if method == 'session.usage': return {'calls': 0, 'input': 0, 'output': 0, 'total': 0}
    if method == 'session.control.read': return {'control': {'goal': None, 'loop': None, 'heartbeat': None, 'revision': 'fixture', 'updated_at': 0}}
    if method == 'setup.runtime_check': return {'ok': True, 'provider': 'fixture', 'model': 'fixture-model', 'profile': profile}
    if method in ('model.list', 'models.list'): return {'models': [{'id': 'fixture-model', 'name': 'Fixture Model', 'provider': 'fixture'}]}
    if method == 'config.get': return {'config': {'model': 'fixture-model', 'provider': 'fixture'}, 'model': 'fixture-model'}
    if method == 'approval.pending': return {'approvals': []}
    if method == 'process.list': return {'processes': []}
    if method == 'subagent.list': return {'subagents': [], 'delegations': []}
    if method in ('commands.catalog', 'commands.list'): return {'commands': []}
    if method in ('tools.list', 'toolsets.list'): return {'tools': [], 'toolsets': []}
    if method == 'cron.list' or method == 'cron.manage': return {'jobs': []}
    if method == 'plugins.list' or method == 'plugins.manage': return {'plugins': []}
    if method == 'skills.list' or method == 'skills.manage': return {'skills': []}
    if method in ('status.get', 'gateway.status'): return {'connected': True, 'model': 'fixture-model', 'profile': profile}
    if method == 'settings.get': return {}
    return {}

def websocket(connection: socket.socket, key: str):
    accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode())
    def read(count):
        data = b''
        while len(data) < count:
            chunk = connection.recv(count-len(data))
            if not chunk: raise ConnectionError()
            data += chunk
        return data
    def send(value):
        body = json.dumps(value).encode(); size = len(body)
        header = bytes([0x81])+(bytes([size]) if size < 126 else bytes([126])+struct.pack('>H',size) if size < 65536 else bytes([127])+struct.pack('>Q',size))
        connection.sendall(header+body)
    try:
        send({'jsonrpc':'2.0','method':'event','params':{'type':'gateway.ready','payload':{'heartbeat':True,'change_events':True,'replay_epoch':'fixture','desktop_contract':8}}})
        fragments = bytearray()
        while True:
            first, second = read(2); opcode, length, final = first&15, second&127, bool(first&128)
            if length == 126: length = struct.unpack('>H',read(2))[0]
            elif length == 127: length = struct.unpack('>Q',read(8))[0]
            mask = read(4) if second&128 else b'\0\0\0\0'
            payload = bytes(b ^ mask[i%4] for i,b in enumerate(read(length)))
            if opcode == 8: return
            if opcode == 9: connection.sendall(bytes([0x8A,len(payload)])+payload); continue
            # URLSession may split a large audio data URL over continuation frames.
            if opcode == 1: fragments = bytearray(payload)
            elif opcode == 0: fragments.extend(payload)
            else: continue
            if len(fragments) > 16 * 1024 * 1024: raise ValueError('Fixture message exceeds16MiB')
            if not final: continue
            frame = json.loads(fragments)
            fragments.clear()
            if 'id' not in frame or 'method' not in frame: continue
            answer = {'jsonrpc':'2.0','id':frame['id']}
            try: answer['result'] = rpc(frame['method'], frame.get('params') or {})
            except ValueError as error: answer['error'] = {'code':-32001,'message':str(error)}
            send(answer)
    except ConnectionError:
        return
    except Exception as error:   # The app only sees WebSocketException when this loop ends; stderr says why (WIN-29). The app hanging up is quiet.
        print(f'[ws] socket loop ended: {type(error).__name__}: {error}', file=sys.stderr)
        traceback.print_exc(file=sys.stderr); sys.stderr.flush()

auth.websocket = websocket

def handler(gateway):
    base = auth.handler(gateway)
    class Handler(base):
        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__fixture/state': return self.reply(200,state)
            if path.startswith('/api/auth/') or path == '/api/ws' or path.startswith('/__fixture/'): return super().do_GET()
            with lock: state['rest'].append({'method':'GET','path':self.path})
            # --hermes-cookies: every API read needs the session, and renews a lapsed one, as Hermes' middleware does.
            if gateway.hermes and path.startswith('/api/') and path != '/api/status' and not self.session():
                return self.reply(401,{'error':'session_expired','detail':'Unauthorized'})
            if path in ('/api/sessions','/api/profiles/sessions'): return self.reply(200,{'sessions':[row(p) for p in SIDS], 'total':2})
            if path.startswith('/api/sessions/'):
                profile = next((p for p,s in SIDS.items() if s in path), 'default')
                if path.endswith('/messages'):
                    return self.reply(200,{'messages':[{'role':'assistant','content':(LABEL + ': ' if LABEL else '') + 'Synthetic voice-note test chat. No live gateway is connected.', 'timestamp':1790686800}], 'total':1,'has_more':False})
                return self.reply(200,row(profile))
            if path == '/api/files': return self.reply(200,{'path':'/fixture/uploads'})
            if path == '/api/config': return self.reply(200,{'model':'fixture-model','provider':'fixture','stt':{'enabled':False}})
            # Hermes answers these in this shape (web_routers/config_env.py, models.py). The catch-all {} below has no
            # `fields`, which Settings reads as a schema still loading: every config-backed page, Main Model included,
            # stayed on its skeleton and never asked for its own reads (fix161-models).
            if path == '/api/config/schema': return self.reply(200,{'fields':{},'category_order':[]})
            if path == '/api/model/info': return self.reply(200,{'model':'fixture-model','provider':'fixture','effective_context_length':128000})
            if path == '/api/model/options': return self.reply(200,{'providers':[{'slug':'fixture','name':'Fixture','models':['fixture-model'],'authenticated':True}]})
            if path == '/api/model/auxiliary': return self.reply(200,{'main':{'model':'fixture-model','provider':'fixture'},'tasks':[]})
            if path == '/api/model/moa':   # Hermes' normalize_moa_config always returns a default preset
                preset = {'enabled':False,'reference_models':[{'provider':'fixture','model':'fixture-model','enabled':True}],'aggregator':{'provider':'fixture','model':'fixture-model'},
                          'reference_temperature':None,'aggregator_temperature':None,'reference_timeout':None,'degraded_reference_policy':'loud','fanout':'user_turn'}
                return self.reply(200,{'default_preset':'default','active_preset':'default','presets':{'default':preset},**preset})
            if path == '/api/profiles': return self.reply(200,rpc('profiles.list',{}))
            if path == '/api/settings': return self.reply(200,{})
            if path == '/api/cron/jobs': return self.reply(200,[])
            if path == '/api/profiles/active': return self.reply(200,{'current':'default'})
            if path == '/api/fs/default-cwd': return self.reply(200,{'path':'/fixture','cwd':'/fixture'})
            if path == '/api/profiles/sessions/sidebar': return self.reply(200,{'recents':{'sessions':[]},'cron':{'sessions':[]},'messaging':{'sessions':[]}})
            if path == '/api/tools/terminal/backends': return self.reply(200,{'backends':[]})
            if path == '/api/models': return self.reply(200,{'models':[]})
            if path.endswith('/setup/status'): return self.reply(200,{'complete':True,'configured':True,'ready':True})
            return self.reply(200,{})
        def do_POST(self):
            if self.path.startswith('/auth/') or self.path.startswith('/api/auth/') or self.path.startswith('/__fixture/'): return super().do_POST()
            body=self.rfile.read(int(self.headers.get('Content-Length') or 0))
            with lock: state['rest'].append({'method':'POST','path':self.path})
            if urlparse(self.path).path == '/api/files/upload-stream' and ACCEPT_PROMPTS:
                message=BytesParser(policy=email_policy).parsebytes(('Content-Type: '+self.headers.get('Content-Type','')+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+body)
                fields={part.get_param('name',header='content-disposition'):part.get_payload(decode=True) for part in message.iter_parts()}
                path=(fields.get('path') or b'').decode()
                audio=fields.get('file') or b''
                if not path.startswith('/fixture/uploads/') or not audio: return self.reply(400,{'detail':'Invalid synthetic upload'})
                with lock: state['uploads'].append({'path':path,'bytes':len(audio),'sha256':hashlib.sha256(audio).hexdigest(),'wav':audio[:4]==b'RIFF'})
                return self.reply(200,{'path':path})
            return self.reply(403,{'detail':'Synthetic voice test refuses changes'})
        def do_DELETE(self):
            body=self.rfile.read(int(self.headers.get('Content-Length') or 0))
            with lock: state['rest'].append({'method':'DELETE','path':self.path})
            try: requested=json.loads(body or b'{}').get('path','')
            except ValueError: requested=''
            if urlparse(self.path).path!='/api/files' or not any(str(pathlib.PurePosixPath(item['path']).parent)==requested for item in state['uploads']):
                return self.reply(403,{'detail':'Unknown synthetic staging folder'})
            return self.reply(200,{'ok':True})
        def do_PATCH(self):
            self.rfile.read(int(self.headers.get('Content-Length') or 0))
            with lock: state['rest'].append({'method':'PATCH','path':self.path})
            return self.reply(200,{'ok':True})
    return Handler

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',type=int,default=9337); parser.add_argument('--credentials',required=True)
    parser.add_argument('--accept-prompts',action='store_true',help='accept synthetic prompts in memory, without running a model')
    parser.add_argument('--keep-credentials',action='store_true')
    # Multi-gateway and Tailscale checks: a second fixture with its own names, Hermes' rotating session cookies,
    # and a listen address other than loopback (this Mac's own Tailscale 100.x address, say).
    parser.add_argument('--host',default='127.0.0.1',help='listen address (default loopback)')
    parser.add_argument('--label',default='',help="prefix this gateway's bot and chat names")
    parser.add_argument('--hermes-cookies',action='store_true',help="Hermes' hermes_session_at/rt session, renewed on any API read")
    parser.add_argument('--access-ttl',type=int,default=12*60*60)
    args = parser.parse_args()
    global ACCEPT_PROMPTS, LABEL
    ACCEPT_PROMPTS = args.accept_prompts
    LABEL = args.label
    username,password = 'voice-fixture',secrets.token_urlsafe(24)
    if args.keep_credentials and pathlib.Path(args.credentials).exists():
        kept=json.loads(pathlib.Path(args.credentials).read_text());username,password=kept['username'],kept['password']
    host = f'[{args.host}]' if ':' in args.host else args.host
    descriptor=os.open(args.credentials,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(descriptor,'w') as output: json.dump({'username':username,'password':password,'url':f'http://{host}:{args.port}'},output)
    server=ThreadingHTTPServer((args.host,args.port),handler(auth.Gateway(username,password,True,None,hermes=args.hermes_cookies,access_ttl=args.access_ttl)))
    print(f'Synthetic voice fixture listening on {host}:{args.port}',flush=True)
    server.serve_forever()

if __name__ == '__main__': main()
