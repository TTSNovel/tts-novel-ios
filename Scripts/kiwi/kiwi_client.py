"""Thin XML-RPC wrapper around Kiwi TCMS, shared by setup_test_cases.py and
report_results.py. Raw xmlrpc.client instead of the tcms-api package — the
API surface is small enough that a direct wrapper is easier to keep in sync
with what this specific Kiwi version actually exposes (checked once via
system.listMethods against the running server) than trusting an SDK's
abstraction to match.
"""
import os
import ssl
import xmlrpc.client


def _env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Missing required env var {name} (see Scripts/kiwi/README.md)")
    return value


class _CookieTransport(xmlrpc.client.SafeTransport):
    """Kiwi's XML-RPC endpoint authenticates via Auth.login + session
    cookie, not HTTP Basic Auth — Transport.send_headers/parse_response are
    the documented Python 3 hooks for carrying a cookie across calls on the
    same ServerProxy."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._cookies = []

    def send_headers(self, connection, headers):
        if self._cookies:
            connection.putheader("Cookie", "; ".join(self._cookies))
        super().send_headers(connection, headers)

    def parse_response(self, response):
        cookies = response.msg.get_all("Set-Cookie")
        if cookies:
            self._cookies.extend(c.split(";")[0] for c in cookies)
        return super().parse_response(response)


class KiwiClient:
    def __init__(self):
        url = _env("KIWI_TCMS_URL")
        username = _env("KIWI_USERNAME")
        password = _env("KIWI_PASSWORD")

        # Local dev server uses a self-signed cert (see Scripts/kiwi/README.md).
        context = ssl._create_unverified_context()
        transport = _CookieTransport(context=context)
        self.rpc = xmlrpc.client.ServerProxy(url, transport=transport, allow_none=True)
        self.rpc.Auth.login(username, password)
        self.username = username

    def get_or_create_classification(self, name: str) -> int:
        existing = self.rpc.Classification.filter({"name": name})
        if existing:
            return existing[0]["id"]
        return self.rpc.Classification.create({"name": name})["id"]

    def get_or_create_product(self, name: str, description: str, classification: str = "Mobile Apps") -> int:
        existing = self.rpc.Product.filter({"name": name})
        if existing:
            return existing[0]["id"]
        classification_id = self.get_or_create_classification(classification)
        return self.rpc.Product.create({
            "name": name, "description": description, "classification": classification_id,
        })["id"]

    def get_or_create_version(self, product_id: int, value: str) -> int:
        existing = self.rpc.Version.filter({"product": product_id, "value": value})
        if existing:
            return existing[0]["id"]
        return self.rpc.Version.create({"product": product_id, "value": value})["id"]

    def get_or_create_plan(self, name: str, product_id: int, version_id: int, plan_type_id: int = 11) -> int:
        # PlanType 11 = "Regression" on a stock Kiwi install (see
        # PlanType.filter({}) — checked against this running instance).
        existing = self.rpc.TestPlan.filter({"name": name, "product": product_id})
        if existing:
            return existing[0]["id"]
        return self.rpc.TestPlan.create({
            "name": name,
            "product": product_id,
            "product_version": version_id,
            "type": plan_type_id,
            "is_active": True,
        })["id"]

    def get_or_create_case(self, summary: str, plan_id: int, product_id: int, category_id: int, text: str, is_automated: bool) -> int:
        existing = self.rpc.TestCase.filter({"summary": summary, "plan": plan_id})
        if existing:
            case_id = existing[0]["id"]
        else:
            case_id = self.rpc.TestCase.create({
                "summary": summary,
                "product": product_id,
                "category": category_id,
                "case_status": 2,  # CONFIRMED
                "priority": 3,     # P3
                "is_automated": is_automated,
                "text": text,
            })["id"]
            self.rpc.TestPlan.add_case(plan_id, case_id)
        return case_id

    def add_tag(self, case_id: int, tag: str):
        try:
            self.rpc.TestCase.add_tag(case_id, tag)
        except xmlrpc.client.Fault:
            pass  # already tagged

    def create_run(self, plan_id: int, summary: str, build_id: int) -> int:
        return self.rpc.TestRun.create({
            "plan": plan_id,
            "summary": summary,
            "build": build_id,
            "manager": self.username,
        })["id"]

    def get_or_create_build(self, version_id: int, name: str) -> int:
        existing = self.rpc.Build.filter({"version": version_id, "name": name})
        if existing:
            return existing[0]["id"]
        return self.rpc.Build.create({"version": version_id, "name": name})["id"]

    def add_case_to_run(self, run_id: int, case_id: int) -> int:
        """Returns the TestExecution id for this case within this run."""
        existing = self.rpc.TestExecution.filter({"run": run_id, "case": case_id})
        if existing:
            return existing[0]["id"]
        result = self.rpc.TestRun.add_case(run_id, case_id)
        # TestRun.add_case returns either the execution dict or the case
        # dict depending on version — resolve via a follow-up filter either way.
        if isinstance(result, dict) and "id" in result and "case" in result:
            return result["id"]
        return self.rpc.TestExecution.filter({"run": run_id, "case": case_id})[0]["id"]

    def record_execution(self, execution_id: int, status: str, log: str = ""):
        # Kiwi status names: PASSED, FAILED, ERROR, BLOCKED, IDLE, WAIVED
        status_map = self.rpc.TestExecutionStatus.filter({"name": status})
        if not status_map:
            raise RuntimeError(f"Unknown TestExecution status {status!r}")
        self.rpc.TestExecution.update(execution_id, {
            "status": status_map[0]["id"],
        })
        if log:
            self.rpc.TestExecution.add_comment(execution_id, log)
