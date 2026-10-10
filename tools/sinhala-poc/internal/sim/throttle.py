import http.server, os, sys, time, re
PATH=sys.argv[1]; RATE=int(sys.argv[2])  # bytes/sec
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_HEAD(self): self.send_head()
    def send_head(self):
        size=os.path.getsize(PATH); rng=self.headers.get('Range'); start,end=0,size-1
        if rng:
            m=re.match(r'bytes=(\d*)-(\d*)',rng); 
            if m.group(1): start=int(m.group(1))
            if m.group(2): end=int(m.group(2))
            self.send_response(206); self.send_header('Content-Range',f'bytes {start}-{end}/{size}')
        else: self.send_response(200)
        self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Length',str(end-start+1)); self.send_header('Content-Type','video/x-matroska'); self.end_headers()
        return start,end
    def do_GET(self):
        start,end=self.send_head()
        with open(PATH,'rb') as f:
            f.seek(start); left=end-start+1; chunk=RATE//10
            while left>0:
                b=f.read(min(chunk,left)); 
                try: self.wfile.write(b)
                except Exception: return
                left-=len(b); time.sleep(0.1)
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[3])),H).serve_forever()
