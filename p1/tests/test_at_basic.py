"""AT 命令基本流程：TS 27.007 子集 + 错误路径 + 厂商扩展"""
from conftest import at


def test_at_ready():
    assert "OK" in at("AT")


def test_cpin_ready():
    assert "+CPIN: READY" in at("AT+CPIN?")


def test_manufacturer_model_revision():
    assert "WModem" in at("AT+CGMI")
    assert "WM650-GL" in at("AT+CGMM")
    assert "WModem Engine" in at("AT+CGMR")


def test_imei():
    assert "860000000000001" in at("AT+CGSN")


def test_signal_quality_format():
    out = at("AT+CSQ")
    assert "+CSQ: " in out and "OK" in out


def test_cereg_registered_home():
    out = at("AT+CEREG?")
    assert "+CEREG:" in out and ",1" in out


def test_cgatt_attached():
    assert "+CGATT: 1" in at("AT+CGATT?")


def test_cops_operator():
    out = at("AT+COPS?")
    assert "CMCC" in out and ",7" in out  # LTE


def test_cgdcont_context():
    assert '+CGDCONT: 1,"IP","wmnet"' in at("AT+CGDCONT?")


def test_cgpaddr_needs_attached():
    out = at("AT+CGPADDR")
    assert "+CGPADDR: 1,10.0.3.15" in out


def test_unknown_command_error():
    out = at("AT+THIS_DOES_NOT_EXIST")
    assert "ERROR" in out and "OK" not in out


def test_echo_toggle():
    assert "OK" in at("ATE0")
    assert "OK" in at("ATE1")
    assert "OK" in at("ATE0")   # 恢复默认，避免污染后续用例


def test_vendor_extension_wmstat():
    out = at("AT+WMSTAT")
    assert "+WMSTAT: " in out
    # ready,home,attached 三态联报
    assert "ready" in out and "home" in out and "attached" in out
