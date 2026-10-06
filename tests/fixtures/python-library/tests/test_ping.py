from hci_python_lib import ping

def test_ping():
    assert ping() == "pong"
