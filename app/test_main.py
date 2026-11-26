from main import app


def test_healthz():
    assert app.test_client().get("/healthz").status_code == 200


def test_readyz():
    assert app.test_client().get("/readyz").status_code == 200


def test_bags_returns_json():
    r = app.test_client().get("/bags")
    assert r.status_code == 200
    assert "bags_left" in r.get_json()


def test_metrics_exposed():
    client = app.test_client()
    client.get("/bags")
    body = client.get("/metrics").get_data(as_text=True)
    assert "http_requests_total" in body
