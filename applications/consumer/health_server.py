#!/usr/bin/env python3
"""
Health check server for Kubernetes probes
"""

import os
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                'status': 'healthy',
                'service': 'cdc-consumer'
            }
            self.wfile.write(json.dumps(response).encode())
        elif self.path == '/ready':
            # Check if the main application is ready
            if hasattr(self.server, 'app_ready') and self.server.app_ready:
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                response = {
                    'status': 'ready',
                    'service': 'cdc-consumer'
                }
                self.wfile.write(json.dumps(response).encode())
            else:
                self.send_response(503)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                response = {
                    'status': 'not ready',
                    'service': 'cdc-consumer'
                }
                self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress access logs
        pass

def start_health_server(port=8080):
    server = HTTPServer(('0.0.0.0', port), HealthHandler)
    server.app_ready = False
    
    def run_server():
        server.serve_forever()
    
    thread = threading.Thread(target=run_server)
    thread.daemon = True
    thread.start()
    
    return server

if __name__ == "__main__":
    server = start_health_server()
    print("Health server started on port 8080")
    # Keep the server running
    try:
        while True:
            pass
    except KeyboardInterrupt:
        print("Shutting down health server")