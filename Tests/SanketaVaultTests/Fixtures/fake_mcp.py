"""A fake vishalakshi MCP server for the Sanketa tests: stdio by default, Streamable HTTP with `--http PORT`.

`--slow` waits 3 s before each tool reply; `--fail` makes each tool fail. Each tool call is added as one JSON line to
the file that `FAKE_MCP_LOG` names."""
import json, os, sys, time, uuid

SLOW, FAIL = '--slow' in sys.argv, '--fail' in sys.argv
HITS = [  # the shelves interleave, as RRF gives them; ids are those of Fixtures/vault.db
    dict(source='shelf:learning', ref='acc857fa078e3c68#1', title='Vowel sandhi', where='learning > Vowel sandhi',
         text='Vowel sandhi joins two vowels at a word boundary: a + i becomes e.'),
    dict(source='prose', ref='967d57f702e6b703#2', title='Notes on sandhi', where='Notes on sandhi',
         text='Sandhi is the joining of sounds at word boundaries.'),
    dict(source='shelf:learning', ref='3b0b840e003df9b2#1', title='Zucchini watering', where='learning',
         text='Water zucchini deeply twice a week.'),
    dict(source='prose', ref='967d57f702e6b703#3', title='Notes on sandhi', where='Notes on sandhi > more', text='A second chunk.'),
    dict(source='repo', ref='x.py:1', title='x.py', where='x.py:1', text='code is not a shelf'),
]

def log(name, args):
    if p := os.environ.get('FAKE_MCP_LOG'):
        with open(p, 'a') as f: f.write(json.dumps(dict(tool=name, arguments=args)) + '\n')

def reply(m):
    "The reply to one JSON-RPC message, or None for a notification."
    if 'id' not in m: return None
    if m['method'] == 'initialize':
        return dict(jsonrpc='2.0', id=m['id'], result=dict(protocolVersion='2025-06-18', capabilities=dict(tools={}),
                                                         serverInfo=dict(name='vishalakshi', version='fake')))
    if m['method'] != 'tools/call': return dict(jsonrpc='2.0', id=m['id'], error=dict(code=-32601, message='no method'))
    name, args = m['params']['name'], m['params'].get('arguments', {})
    log(name, args)
    if SLOW: time.sleep(3)
    if FAIL: out, err = [f'Error executing tool {name}: boom'], True
    elif name == 'federate': out, err = [json.dumps(dict(query=args['q'], hits=HITS, legs={}, note='RRF'))], False
    elif name == 'note': out, err = [json.dumps(dict(doc_id='abc', title=args.get('title'), chunks=1))], False
    else: out, err = [f'Unknown tool: {name}'], True
    return dict(jsonrpc='2.0', id=m['id'], result=dict(content=[dict(type='text', text=t) for t in out], isError=err))

def stdio():
    # the server's own notification first: a client must skip it
    print(json.dumps(dict(jsonrpc='2.0', method='notifications/message', params=dict(level='info', data='hi'))), flush=True)
    for line in sys.stdin:
        if line.strip() and (r := reply(json.loads(line))) is not None: print(json.dumps(r), flush=True)

def http(port):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    sid = uuid.uuid4().hex
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_POST(self):
            m = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if m.get('method') != 'initialize' and self.headers.get('Mcp-Session-Id') != sid:
                self.send_response(400); self.end_headers(); return
            r = reply(m)
            if r is None: self.send_response(202); self.end_headers(); return
            # server-sent events, as vishalakshi-mcp --http sends them
            body = f'event: message\r\ndata: {json.dumps(r)}\r\n\r\n'.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Mcp-Session-Id', sid)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)
    s = ThreadingHTTPServer(('127.0.0.1', port), H)
    print('ready', s.server_address[1], flush=True)
    s.serve_forever()

if '--http' in sys.argv: http(int(sys.argv[sys.argv.index('--http') + 1]))
else: stdio()
