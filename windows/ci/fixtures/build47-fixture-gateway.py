#!/usr/bin/env python3
"""Loopback-only build 47 acceptance gateway. Invented state; no upstream client.

Extends the native voice fixture with real WebSocket streaming, retained transcripts,
controllable prompt acknowledgements and a request ledger. POST /__fixture/plan sets
plans for subsequent prompts; GET /__fixture/state proves send count and destinations.

[WIN-DELIVERY-WALK] A plan's refusal can carry JSON-RPC error data: {"reject": message, "code": 4090,
"data": {"reason": "SESSION_OWNER_UNCONFIRMED"}} answers prompt.submit with {"error": {"code", "message", "data"}}
(the gateway's session authority refusals: SESSION_NOT_OWNED, SESSION_OWNER_BUSY, SESSION_OWNER_UNCONFIRMED, and
4001 profile_mismatch). Two more controls, for the external-turn watch (ExternalTurn):
  POST /__fixture/working   {"sessions": [{"profile", "id", "status", "kind"}]}: what the Hermes HQ add-on's
       GET /api/plugins/hermes-hq-push/sessions/working answers from then on (404 until set, as with no add-on).
  POST /__fixture/external  {"profile", "text"}: a stored prompt another app wrote just now (no answer, no frames).
"""
import argparse, base64, hashlib, importlib.util, json, os, pathlib, secrets, socket, struct, threading, time, sys, traceback
from urllib.parse import urlparse
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location('voice_fixture', pathlib.Path(__file__).with_name('action-voice-fixture-gateway.py'))
voice = importlib.util.module_from_spec(spec); spec.loader.exec_module(voice)
voice.ACCEPT_PROMPTS = True
LOCK = threading.RLock()
PLANS = []
CLIENTS = set()
ACKS = []
MESSAGES = {p: [{'role': 'assistant', 'content': 'Build 47 synthetic acceptance chat.', 'row_id': 1, 'timestamp': 1790852400}] for p in voice.SIDS}
RUNNING = {p: False for p in voice.SIDS}
CANCEL = {p: threading.Event() for p in voice.SIDS}
LEDGER = []
NEXT_ROW = 2
UPLOAD_DELAY = 0
ATTACH_FAILURES = 0
WORKING = None   # [WIN-DELIVERY-WALK] the add-on's sessions/working answer; None: 404 (no add-on)
WORKING_PATH = '/api/plugins/hermes-hq-push/sessions/working'
_original_resumed = voice.resumed
_original_rpc = voice.rpc

def owner(params):
    identity = params.get('session_id')
    return next((p for p,s in voice.SIDS.items() if identity in (s, hashlib.sha256(s.encode()).hexdigest()[:8])), params.get('profile') if params.get('profile') in voice.SIDS else 'default')

def resumed(profile):
    answer = _original_resumed(profile)
    answer.update(message_count=len(MESSAGES[profile]), status='running' if RUNNING[profile] else 'idle', running=RUNNING[profile])
    answer['info']['running'] = RUNNING[profile]
    return answer
voice.resumed = resumed

def emit(profile, kind, payload=None):
    frame = {'jsonrpc':'2.0','method':'event','params':{'type':kind,'session_id':resumed(profile)['session_id'],'payload':payload or {}}}
    with LOCK: clients = list(CLIENTS)
    for client in clients:
        try: client.send(frame)
        except OSError: pass

def append(profile, role, text):
    global NEXT_ROW
    with LOCK:
        row = {'role':role,'content':text,'row_id':NEXT_ROW,'timestamp':int(time.time())}
        NEXT_ROW += 1; MESSAGES[profile].append(row)
    return row['row_id']

def stream(profile, plan):
    cancel = CANCEL[profile]
    if cancel.wait(float(plan.get('replyDelay', .4))): return
    text = plan.get('replyText', 'Synthetic reply for build 47.')
    if text is None: return
    emit(profile, 'message.start')
    chunks = plan.get('chunks') or [text]
    for chunk in chunks:
        if cancel.wait(float(plan.get('chunkDelay', .08))): return
        emit(profile, 'message.delta', {'text':chunk})
    text = ''.join(chunks)
    row = append(profile, 'assistant', text)
    RUNNING[profile] = False
    emit(profile, 'message.complete', {'text':text,'row_id':row})

def rpc(method, params):
    global ATTACH_FAILURES
    profile = owner(params)
    if method == 'file.attach' and ATTACH_FAILURES:
        ATTACH_FAILURES -= 1
        with LOCK: voice.state['rpc'].append({'method':method,'params':{**{k:v for k,v in params.items() if k!='data_url'},**({'dataUrlBytes':len(params['data_url'])} if 'data_url' in params else {})}})
        raise ValueError('Synthetic attachment refused before prompt submission')
    if method in ('session.resume','session.activate'): return resumed(profile)
    if method in ('session.info','session.get'): return resumed(profile)['info']
    if method in ('display.status', 'display.observe'):
        status={'profile':profile,'profile_key':'build47:'+profile,'supported':True,'installed':True,'running':True,'display':':47','geometry':'1280x720','lease':{'holder':'agent','epoch':1},'missing':[]}
        return {**status, **({'viewer_id':'build47-viewer','ticket':'build47-no-frame-stream'} if method=='display.observe' else {})}
    if method == 'session.active_list':
        return {'sessions':[{'session_id':resumed(p)['session_id'],'stored_session_id':voice.SIDS[p],'status':'running','running':True} for p in voice.SIDS if RUNNING[p]]}
    if method == 'session.interrupt':
        with LOCK: voice.state['rpc'].append({'method':method,'params':params})
        CANCEL[profile].set(); RUNNING[profile]=False
        emit(profile,'message.complete',{'text':'Stopped synthetic reply.'})
        return {'status':'interrupted'}
    if method == 'session.redirect':
        with LOCK: voice.state['rpc'].append({'method':method,'params':params}); voice.state['promptAttempts'] += 1
        rid=append(profile,'user',params.get('text',''))
        with LOCK: LEDGER.append({'profile':profile,'method':method,'text':params.get('text',''),'row_id':rid,'accepted':True})
        return {'status':'redirected','user_row_id':rid}
    return _original_rpc(method,params)
voice.rpc = rpc

class Client:
    def __init__(self, connection): self.connection=connection; self.lock=threading.Lock()
    def send(self,value):
        body=json.dumps(value).encode(); n=len(body)
        header=bytes([0x81])+(bytes([n]) if n<126 else bytes([126])+struct.pack('>H',n) if n<65536 else bytes([127])+struct.pack('>Q',n))
        with self.lock: self.connection.sendall(header+body)
    def prompt(self, frame):
        params=frame.get('params') or {}; profile=owner(params)
        with LOCK:
            plan=PLANS.pop(0) if PLANS else {}
            voice.state['rpc'].append({'method':'prompt.submit','params':params})
            voice.state['promptAttempts'] += 1
        entry={'profile':profile,'method':'prompt.submit','text':params.get('text',''),'accepted':not plan.get('reject') and plan.get('persist',True), 'plan':plan}
        if not plan.get('reject') and plan.get('persist',True):
            entry['row_id']=append(profile,'user',params.get('text',''))
            CANCEL[profile].set(); CANCEL[profile]=threading.Event(); RUNNING[profile]=True
        with LOCK: LEDGER.append(entry)
        if plan.get('disconnect'):
            try: self.connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            return
        if plan.get('holdAck'):
            gate=threading.Event()
            with LOCK: ACKS.append(gate)
            gate.wait(90)
        else:time.sleep(float(plan.get('ackDelay',0)))
        if plan.get('dropAck'): return
        try:
            if plan.get('reject'):
                error={'code':plan.get('code',-32001),'message':plan['reject']}
                if isinstance(plan.get('data'),dict):error['data']=plan['data']   # [WIN-DELIVERY-WALK] {reason}
                self.send({'jsonrpc':'2.0','id':frame['id'],'error':error})
            else:
                self.send({'jsonrpc':'2.0','id':frame['id'],'result':{'status':'streaming','user_row_id':entry['row_id']}})
                threading.Thread(target=stream,args=(profile,plan),daemon=True).start()
        except OSError: pass

def websocket(connection,key):
    accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode())
    client=Client(connection)
    def read(n):
        data=b''
        while len(data)<n:
            chunk=connection.recv(n-len(data))
            if not chunk: raise ConnectionError()
            data+=chunk
        return data
    with LOCK: CLIENTS.add(client)
    try:
        client.send({'jsonrpc':'2.0','method':'event','params':{'type':'gateway.ready','payload':{'heartbeat':True,'change_events':True,'replay_epoch':'build47','desktop_contract':8}}})
        fragments=bytearray()
        while True:
            first,second=read(2); opcode,n,final=first&15,second&127,bool(first&128)
            if n==126:n=struct.unpack('>H',read(2))[0]
            elif n==127:n=struct.unpack('>Q',read(8))[0]
            if n>16*1024*1024:raise ValueError('Oversized fixture frame')
            mask=read(4) if second&128 else b'\0'*4
            payload=bytes(b^mask[i%4] for i,b in enumerate(read(n)))
            if opcode==8:return
            if opcode==9:
                with client.lock:connection.sendall(bytes([0x8A,len(payload)])+payload)
                continue
            if opcode==1:fragments=bytearray(payload)
            elif opcode==0:fragments.extend(payload)
            else:continue
            if not final:continue
            frame=json.loads(fragments);fragments.clear()
            if 'id' not in frame or 'method' not in frame:continue
            if frame['method']=='prompt.submit':
                threading.Thread(target=client.prompt,args=(frame,),daemon=True).start();continue
            answer={'jsonrpc':'2.0','id':frame['id']}
            try:answer['result']=rpc(frame['method'],frame.get('params') or {})
            except ValueError as error:answer['error']={'code':-32001,'message':str(error)}
            client.send(answer)
    except ConnectionError:
        pass
    except Exception as error:   # The app only sees WebSocketException when this loop ends; stderr says why (WIN-29). The app hanging up is quiet.
        print(f'[ws] socket loop ended: {type(error).__name__}: {error}', file=sys.stderr)
        traceback.print_exc(file=sys.stderr); sys.stderr.flush()
    finally:
        with LOCK:CLIENTS.discard(client)
voice.auth.websocket=websocket

def handler(gateway):
    base=voice.handler(gateway)
    class Handler(base):
        def do_GET(self):
            path=urlparse(self.path).path
            if path=='/__fixture/state':
                with LOCK:return self.reply(200,{**voice.state,'ledger':list(LEDGER),'messages':MESSAGES,'running':RUNNING,'plans':PLANS})
            if path=='/api/status':return self.reply(200,{'version':'1.0.0','release_date':'2026.10.01','desktop_contract':8})
            if path==WORKING_PATH:
                with LOCK:working=WORKING
                return self.reply(404,{'detail':'Not Found'}) if working is None else self.reply(200,working)
            if path.startswith('/api/sessions/') and path.endswith('/messages'):
                profile=next((p for p,s in voice.SIDS.items() if s in path),'default')
                with LOCK:return self.reply(200,{'messages':list(MESSAGES[profile]),'total':len(MESSAGES[profile]),'has_more':False})
            return super().do_GET()
        def do_POST(self):
            global UPLOAD_DELAY, ATTACH_FAILURES, WORKING
            if self.path=='/__fixture/working':
                body=json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)))
                with LOCK:WORKING={'sessions':list(body.get('sessions') or [])}
                return self.reply(200,{'ok':True})
            if self.path=='/__fixture/external':
                body=json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)))
                profile=body.get('profile','default')
                if profile not in MESSAGES:return self.reply(404,{'detail':'Unknown synthetic profile'})
                rid=append(profile,'user',body.get('text','Synthetic prompt from another app.'))
                return self.reply(200,{'ok':True,'row_id':rid,'session_id':voice.SIDS[profile]})
            if self.path=='/__fixture/release-acks':
                self.rfile.read(int(self.headers.get('Content-Length') or 0))
                with LOCK:
                    for gate in ACKS:gate.set()
                    ACKS.clear()
                return self.reply(200,{'ok':True})
            if self.path=='/__fixture/plan':
                body=json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)))
                with LOCK:PLANS.extend(body.get('plans',[]));UPLOAD_DELAY=float(body.get('uploadDelay',UPLOAD_DELAY));ATTACH_FAILURES=int(body.get('attachFailures',ATTACH_FAILURES))
                return self.reply(200,{'ok':True})
            if self.path=='/__fixture/finish':
                body=json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)))
                profile=body.get('profile','default');CANCEL[profile].set();RUNNING[profile]=False
                text=body.get('text','Synthetic reply completed.')
                rid=append(profile,'assistant',text);emit(profile,'message.start');emit(profile,'message.complete',{'text':text,'row_id':rid})
                return self.reply(200,{'ok':True})
            if urlparse(self.path).path=='/api/files/upload-stream' and UPLOAD_DELAY:time.sleep(UPLOAD_DELAY)
            return super().do_POST()
    return Handler

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--port',type=int,default=19447);parser.add_argument('--credentials',required=True);parser.add_argument('--keep-credentials',action='store_true')
    args=parser.parse_args();username,password='build47-fixture',secrets.token_urlsafe(24)
    if args.keep_credentials and pathlib.Path(args.credentials).exists():
        kept=json.loads(pathlib.Path(args.credentials).read_text());username,password=kept['username'],kept['password']
    descriptor=os.open(args.credentials,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(descriptor,'w') as file:json.dump({'username':username,'password':password,'url':f'http://127.0.0.1:{args.port}'},file)
    server=ThreadingHTTPServer(('127.0.0.1',args.port),handler(voice.auth.Gateway(username,password,True,None)))
    print(f'Build 47 synthetic gateway on 127.0.0.1:{args.port}',flush=True);server.serve_forever()
if __name__=='__main__':main()
