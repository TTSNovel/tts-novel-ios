# Kiwi TCMS — local test-case management for WebnovelReader

Local-only setup for now (no CI YAML yet — no git remote exists on this repo).

## One-time setup

```sh
cd Scripts/kiwi/server && docker-compose up -d
```

Kiwi TCMS web UI: http://localhost:8080 (default admin login printed in
`docker-compose logs web` on first boot — change it immediately).

The bundled `pub.kiwitcms.eu/kiwitcms/kiwi` image is amd64-only and built
against CentOS Stream 10 (requires x86-64-v3 / AVX2), which QEMU emulation on
Apple Silicon can't run. `docker-compose.yml` here instead points `web` at
`kiwitcms-arm64:local`, built natively for arm64 from source:

```sh
docker build -t kiwitcms-arm64:local https://github.com/kiwitcms/Kiwi.git#master
```

Rosetta emulation is enabled in Docker Desktop settings as a fallback for any
other amd64-only tooling, but the Kiwi image itself no longer needs it once
built natively.

## Scripts

- `setup_test_cases.py` — idempotently creates the Product/Version/Plan and
  one Test Case per XCUITest method, writes `test_case_map.yml` (gitignored
  — it's specific to this local Kiwi instance's case IDs).
- `run_and_report.sh` — runs `xcodebuild test` against a booted simulator,
  then reports pass/fail per case into a new Kiwi Test Run.
- `report_results.py` — called by `run_and_report.sh`; parses the
  `.xcresult` bundle and talks to Kiwi's XML-RPC API.
- `kiwi_client.py` — thin XML-RPC wrapper shared by the two scripts above.

## Credentials

Set via environment variables, never committed:

```sh
export KIWI_TCMS_URL=http://localhost:8080/xml-rpc/
export KIWI_USERNAME=admin
export KIWI_PASSWORD=...
```
