"""Minimal HTTP API used to demonstrate the hardening work.

Two endpoints: "/" reports whether the database is reachable, "/healthz" answers
without touching the database so the readiness probe stays cheap. The database
password is read from the environment, which is how the Secret reaches the
container.
"""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

DB_DSN = (
    f"host={os.environ.get('DB_HOST', 'postgres')} "
    f"port={os.environ.get('DB_PORT', '5432')} "
    f"dbname={os.environ.get('DB_NAME', 'app')} "
    f"user={os.environ.get('DB_USER', 'app')} "
    f"password={os.environ.get('DB_PASSWORD', '')} "
    "connect_timeout=3"
)


def database_version():
    with psycopg.connect(DB_DSN) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT version()")
            return cursor.fetchone()[0]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def respond(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.respond(200, {"status": "ok"})
            return
        if self.path == "/":
            try:
                self.respond(200, {"status": "ok", "database": database_version()})
            except Exception as error:  # noqa: BLE001 - surfaced as a 503 below
                self.respond(503, {"status": "degraded", "error": str(error)})
            return
        self.respond(404, {"status": "not found"})

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("", port), Handler).serve_forever()
