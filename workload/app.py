import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


MENU = [{"id": "espresso", "name": "Espresso"}, {"id": "latte", "name": "Latte"}]
ROLE = os.getenv("ROLE", "frontend")
API_URL = os.getenv("API_URL", "http://api:8080")
FRONTEND_URL = os.getenv("FRONTEND_URL", "http://frontend:8080")
FAIL_PROCESSING = os.getenv("FAIL_PROCESSING", "true").lower() == "true"
failures = {}
lock = threading.Lock()
producer_lock = threading.Lock()
clients = None


def report(flow, failed):
    with lock:
        failures[flow] = int(failed)
    print(json.dumps({"kind": "health", "role": ROLE, "flow": flow,
                      "failures": int(failed)}), flush=True)


def error(flow, exc):
    # Log exception type only; SDK messages can include resource paths or request data.
    print(json.dumps({"kind": "error", "role": ROLE, "flow": flow,
                      "error": type(exc).__name__}), flush=True)
    report(flow, True)


def request_json(url, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    request = Request(url, data=body, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=15) as response:
        return response.status, json.load(response)


class AzureClients:
    def __init__(self):
        from azure.identity import WorkloadIdentityCredential
        from azure.storage.blob import BlobServiceClient

        self.credential = WorkloadIdentityCredential()
        self.orders = BlobServiceClient(
            os.environ["BLOB_URL"], credential=self.credential,
            connection_timeout=5, read_timeout=10, retry_total=1,
        ).get_container_client("orders")
        if ROLE == "api":
            from azure.eventhub import EventHubProducerClient
            from azure.keyvault.secrets import SecretClient

            self.vault = SecretClient(
                os.environ["VAULT_URL"], self.credential,
                connection_timeout=5, read_timeout=10, retry_total=1,
            )
            self.producer = EventHubProducerClient(
                os.environ["EVENT_NAMESPACE"], os.environ["EVENT_HUB"],
                self.credential, retry_total=1,
            )

    def menu(self):
        return {"store": self.vault.get_secret("store-name").value, "menu": MENU}

    def send(self, order):
        from azure.eventhub import EventData

        # Serialize SDK operations without blocking health reports during network I/O.
        with producer_lock:
            batch = self.producer.create_batch()
            batch.add(EventData(json.dumps(order)))
            self.producer.send_batch(batch, timeout=10)


def validate_order(payload):
    product = payload.get("product") if isinstance(payload, dict) else None
    if not isinstance(product, str) or product not in {p["id"] for p in MENU}:
        raise ValueError("Choose espresso or latte")
    return {"id": str(uuid.uuid4()), "product": product}


def prepare_order(order, container, fail):
    if fail:
        raise RuntimeError("Demo coffee preparation failure")
    completed = {**order, "status": "ready"}
    # Stable IDs make replay after recovery idempotent.
    container.upload_blob(f"{order['id']}.json", json.dumps(completed), overwrite=True)
    return completed


def route(method, path, payload=None):
    if method == "GET" and path == "/healthz":
        return 200, {"alive": True}
    if ROLE == "frontend":
        if method == "GET" and path == "/":
            return 200, Path(__file__).with_name("index.html").read_bytes()
        if path.startswith("/api/"):
            return request_json(API_URL + path, payload if method == "POST" else None)
    if ROLE == "api":
        if method == "GET" and path == "/api/menu":
            return 200, clients.menu()
        if method == "GET" and path == "/api/status":
            clients.orders.get_container_properties()
            return 200, {"storage": "reachable"}
        if method == "POST" and path == "/api/orders":
            order = validate_order(payload)
            try:
                clients.send(order)
            except Exception as exc:
                error("eventhub", exc)
                raise
            report("eventhub", False)
            return 202, {**order, "status": "accepted"}
        if method == "GET" and path.startswith("/api/orders/"):
            from azure.core.exceptions import ResourceNotFoundError

            order_id = str(uuid.UUID(path.removeprefix("/api/orders/")))
            try:
                body = clients.orders.download_blob(f"{order_id}.json").readall()
                return 200, json.loads(body)
            except ResourceNotFoundError:
                return 202, {"id": order_id, "status": "waiting for coffee preparation"}
    return 404, {"error": "Not found"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def handle_request(self, method):
        flow = "browse" if self.path in ("/", "/api/menu") else "orders"
        try:
            payload = None
            if method == "POST":
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4096:
                    self.respond(400, {"error": "Request must contain 1-4096 bytes"})
                    return
                payload = json.loads(self.rfile.read(length))
            status, body = route(method, self.path, payload)
            if self.path != "/healthz":
                report(flow, status >= 500)
        except (ValueError, UnicodeDecodeError):
            status, body = 400, {"error": "Invalid request"}
        except HTTPError as exc:
            status, body = exc.code, {"error": "Upstream request failed"}
            if status >= 500:
                error(flow, exc)
        except Exception as exc:
            error(flow, exc)
            status, body = 503, {"error": "A dependency is unavailable"}
        self.respond(status, body)

    def respond(self, status, body):
        html = isinstance(body, bytes)
        data = body if html else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8" if html else "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def heartbeat():
    while True:
        if ROLE == "worker":
            with lock:
                failed = FAIL_PROCESSING or failures.get("worker-pod", 0)
            report("worker-pod", failed)
            try:
                clients.orders.get_container_properties()
                report("orders", False)
            except Exception as exc:
                error("orders", exc)
        else:
            for flow, path in (("browse", "/api/menu"), ("orders", "/api/status")):
                try:
                    status, _ = route("GET", path)
                    report(flow, status >= 500)
                except Exception as exc:
                    error(flow, exc)
        time.sleep(15)


def consume():
    from azure.eventhub import EventHubConsumerClient

    def on_event(_partition, event):
        if event is None:
            return
        while True:
            try:
                order = json.loads(event.body_as_str())
                prepare_order(order, clients.orders, FAIL_PROCESSING)
                report("worker-pod", False)
                return
            except Exception as exc:
                error("worker-pod", exc)
                time.sleep(5)

    # shortcut: one consumer, no durable checkpoint; use BlobCheckpointStore for a larger workload.
    while True:
        try:
            with EventHubConsumerClient(
                os.environ["EVENT_NAMESPACE"], os.environ["EVENT_HUB"], "$Default",
                clients.credential, retry_total=1,
            ) as consumer:
                consumer.receive(
                    on_event=on_event, on_error=lambda _partition, exc: error("worker-pod", exc),
                    starting_position="-1", max_wait_time=15,
                )
        except Exception as exc:
            error("worker-pod", exc)
            time.sleep(5)


def load():
    while True:
        try:
            request_json(FRONTEND_URL + "/api/menu")
            _, order = request_json(FRONTEND_URL + "/api/orders", {"product": "latte"})
            request_json(FRONTEND_URL + "/api/orders/" + order["id"])
        except Exception as exc:
            error("orders", exc)
        time.sleep(15)


if __name__ == "__main__":
    if ROLE == "load":
        load()
    else:
        if ROLE in ("api", "worker"):
            clients = AzureClients()
        threading.Thread(target=heartbeat, daemon=True).start()
        if ROLE == "worker":
            threading.Thread(target=consume, daemon=True).start()
        ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
