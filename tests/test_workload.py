import json
import sys
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from azure.core.exceptions import ResourceNotFoundError
from azure.eventhub import EventHubConsumerClient, EventHubProducerClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "workload"))
import app


class Blobs:
    def __init__(self):
        self.data = {}

    def upload_blob(self, name, data, overwrite):
        self.data[name] = data

    def download_blob(self, name):
        if name not in self.data:
            raise ResourceNotFoundError("Not ready")
        return SimpleNamespace(readall=lambda: self.data[name].encode())


class WorkloadTests(unittest.TestCase):
    def setUp(self):
        self.blobs = Blobs()
        self.order = app.validate_order({"product": "latte"})

    def test_bad_products_never_create_orders(self):
        for value in (None, [], {"product": "../invalid"}, {"product": "unknown"},
                      {"product": []}, {"product": {}}, {"product": None}, {"product": True}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                app.validate_order(value)

    def test_failure_does_not_store_order_and_recovery_is_idempotent(self):
        with self.assertRaises(RuntimeError):
            app.prepare_order(self.order, self.blobs, True)
        self.assertEqual(self.blobs.data, {})
        app.prepare_order(self.order, self.blobs, False)
        app.prepare_order(self.order, self.blobs, False)
        self.assertEqual(len(self.blobs.data), 1)
        self.assertEqual(json.loads(next(iter(self.blobs.data.values())))["status"], "ready")

    def test_pending_order_becomes_ready_after_recovery(self):
        fake = type("Clients", (), {"orders": self.blobs})()
        with patch.object(app, "ROLE", "api"), patch.object(app, "clients", fake):
            path = "/api/orders/" + self.order["id"]
            self.assertEqual(app.route("GET", path)[0], 202)
            app.prepare_order(self.order, self.blobs, False)
            status, body = app.route("GET", path)
            self.assertEqual((status, body["status"]), (200, "ready"))
            with self.assertRaises(ValueError):
                app.route("GET", "/api/orders/../../anything")

    def test_sdk_clients_use_correct_hub_and_consumer_group(self):
        credential = type("Credential", (), {"get_token": lambda *_: None})()
        producer = EventHubProducerClient("demo.servicebus.windows.net", "orders", credential)
        consumer = EventHubConsumerClient("demo.servicebus.windows.net", "orders", "$Default", credential)
        self.assertEqual(producer.eventhub_name, "orders")
        self.assertEqual(consumer.eventhub_name, "orders")
        producer.close()
        consumer.close()

    def test_http_validation_and_unavailable_dependency(self):
        server = app.ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            with patch.object(app, "ROLE", "api"), patch.object(app, "clients", None):
                with urlopen(base + "/healthz") as response:
                    self.assertEqual(response.status, 200)
                with patch.object(app, "report") as report:
                    for body in (b"{", b"x" * 4097, b"", b'{"product":[]}', b'{"product":{}}'):
                        with self.subTest(body=body[:20]), self.assertRaises(HTTPError) as ctx:
                            urlopen(Request(base + "/api/orders", data=body))
                        self.assertEqual(ctx.exception.code, 400)
                    report.assert_not_called()
                with self.assertRaises(HTTPError) as ctx:
                    urlopen(base + "/api/menu")
                self.assertEqual(ctx.exception.code, 503)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_frontend_proxies_orders_without_dropping_payload(self):
        with patch.object(app, "ROLE", "frontend"), patch.object(app, "request_json") as upstream:
            upstream.return_value = (202, self.order)
            self.assertEqual(app.route("POST", "/api/orders", {"product": "latte"})[0], 202)
            upstream.assert_called_once_with(app.API_URL + "/api/orders", {"product": "latte"})

    def test_publishing_reports_real_eventhub_success_and_failure(self):
        for failed in (False, True):
            with self.subTest(failed=failed):
                client = SimpleNamespace(send=Mock(side_effect=RuntimeError() if failed else None))
                with patch.object(app, "ROLE", "api"), patch.object(app, "clients", client), \
                        patch.object(app, "report") as report, patch("builtins.print"):
                    if failed:
                        with self.assertRaises(RuntimeError):
                            app.route("POST", "/api/orders", {"product": "latte"})
                    else:
                        self.assertEqual(app.route("POST", "/api/orders", {"product": "latte"})[0], 202)
                    report.assert_called_once_with("eventhub", failed)

    def test_worker_fault_is_separate_from_process_and_dependency_health(self):
        for broken, storage_fails in ((True, False), (False, False), (True, True)):
            with self.subTest(broken=broken, storage_fails=storage_fails):
                container = SimpleNamespace(get_container_properties=Mock(
                    side_effect=RuntimeError() if storage_fails else None))
                with patch.object(app, "ROLE", "worker"), patch.object(app, "FAIL_PROCESSING", broken), \
                        patch.object(app, "clients", SimpleNamespace(orders=container)), \
                        patch.object(app, "failures", {}), patch.object(app, "report") as report, \
                        patch.object(app.time, "sleep", side_effect=InterruptedError), patch("builtins.print"):
                    with self.assertRaises(InterruptedError):
                        app.heartbeat()
                    self.assertEqual(report.call_args_list[0].args, ("worker-pod", broken))
                    self.assertEqual(report.call_args_list[1].args, ("orders", storage_fails))

    def test_consumer_processing_failure_and_recovery_only_report_on_worker_leaf(self):
        class StopLoop(BaseException):
            pass

        for broken in (True, False):
            with self.subTest(broken=broken):
                event = SimpleNamespace(body_as_str=lambda: json.dumps(self.order))

                def receive(**kwargs):
                    kwargs["on_event"](None, event)
                    raise StopLoop()

                with patch.object(app, "FAIL_PROCESSING", broken), \
                        patch.object(app, "clients", SimpleNamespace(orders=self.blobs, credential=Mock())), \
                        patch.dict(app.os.environ, EVENT_NAMESPACE="demo.servicebus.windows.net", EVENT_HUB="orders"), \
                        patch("azure.eventhub.EventHubConsumerClient") as consumer, \
                        patch.object(app, "report") as report, patch("builtins.print"), \
                        patch.object(app.time, "sleep", side_effect=StopLoop):
                    consumer.return_value.__enter__.return_value.receive.side_effect = receive
                    with self.assertRaises(StopLoop):
                        app.consume()
                    report.assert_called_once_with("worker-pod", broken)
                    self.assertEqual(bool(self.blobs.data), not broken)

    def test_receive_error_stays_unhealthy_until_successful_processing(self):
        class StopLoop(BaseException):
            pass

        def receive(**kwargs):
            kwargs["on_error"](None, RuntimeError())
            raise StopLoop()

        client = SimpleNamespace(orders=SimpleNamespace(get_container_properties=Mock()), credential=Mock())
        with patch.object(app, "ROLE", "worker"), patch.object(app, "FAIL_PROCESSING", False), \
                patch.object(app, "clients", client), patch.object(app, "failures", {}), \
                patch.dict(app.os.environ, EVENT_NAMESPACE="demo.servicebus.windows.net", EVENT_HUB="orders"), \
                patch("azure.eventhub.EventHubConsumerClient") as consumer, \
                patch.object(app.time, "sleep", side_effect=StopLoop), patch("builtins.print") as output:
            consumer.return_value.__enter__.return_value.receive.side_effect = receive
            with self.assertRaises(StopLoop):
                app.consume()
            with self.assertRaises(StopLoop):
                app.heartbeat()
            reports = [json.loads(call.args[0]) for call in output.call_args_list]
            health = [r for r in reports if r["kind"] == "health"]
            self.assertEqual([(r["flow"], r["failures"]) for r in health],
                             [("worker-pod", 1), ("worker-pod", 1), ("orders", 0)])

    def test_slow_event_publish_does_not_block_health_reports(self):
        client = app.AzureClients.__new__(app.AzureClients)
        client.producer = Mock()
        sending, release, reported = threading.Event(), threading.Event(), threading.Event()

        def send_batch(*_, **__):
            sending.set()
            release.wait(5)

        client.producer.send_batch.side_effect = send_batch
        sender = threading.Thread(target=client.send, args=(self.order,))
        reporter = threading.Thread(target=lambda: (app.report("browse", False), reported.set()))
        with patch("builtins.print"), patch.object(app, "failures", {}):
            sender.start()
            try:
                self.assertTrue(sending.wait(2))
                reporter.start()
                self.assertTrue(reported.wait(2), "Network I/O must not block heartbeat logging")
            finally:
                release.set()
                sender.join(5)
                if reporter.ident is not None:
                    reporter.join(5)
        self.assertFalse(sender.is_alive())
        client.producer.send_batch.assert_called_once_with(client.producer.create_batch.return_value, timeout=10)


if __name__ == "__main__":
    unittest.main()
