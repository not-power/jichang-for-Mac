from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path.startswith('/slow'): time.sleep(0.2)
  if self.path.endswith('.mrs'): body=b'mrs\x00test'
  elif self.path.startswith('/subscription'): body=b'# comment\nmode: rule\nproxies:\n- name: node\n  type: ss\n  server: example.com\n  port: 443\n  cipher: aes-128-gcm\n  password: test\n'
  elif self.path.startswith('/bad'): body=b'<html>error</html>'
  else: body=b'payload:\n- +.example.com\n- +.example.org\n'
  self.send_response(200);self.send_header('Content-Type','application/yaml');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def log_message(self,*args): pass
ThreadingHTTPServer(('127.0.0.1',19331),Handler).serve_forever()
