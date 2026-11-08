"""设备层验收：定制 VID/PID 复合枚举 / in 字段 / 多串口绑定 / RNDIS 网口"""
from conftest import guest, rndis_netif


def _modalias(i):
    return guest(f"grep MODALIAS /sys/bus/usb/devices/1-1:1.{i}/uevent 2>/dev/null").strip()


def test_custom_vid_pid_enumerated():
    out = guest("for d in /sys/bus/usb/devices/1-1*; do "
                "[ -f \"$d/idVendor\" ] && echo \"$(cat $d/idVendor):$(cat $d/idProduct)\"; done")
    assert "1234:5678" in out


def test_in_field_layout():
    """软件通过 uevent MODALIAS 的 in 字段识别串口与网卡 —— 布局必须为
    in00/01/02 = 0xff 串口, in03 = RNDIS 控制(0xEF/0x04/0x01), in04 = RNDIS 数据(0x0A)"""
    m0 = _modalias(0)
    assert "icFFisc00ip00" in m0 and "in00" in m0
    assert "in01" in _modalias(1) and "icFF" in _modalias(1)
    assert "in02" in _modalias(2) and "icFF" in _modalias(2)
    m3 = _modalias(3)
    assert "icEFisc04ip01" in m3 and "in03" in m3
    m4 = _modalias(4)
    assert "ic0A" in m4 and "in04" in m4


def test_three_serial_ports_bound_to_option():
    out = guest("ls -l /dev/ttyUSB* 2>/dev/null; "
                "basename \"$(readlink -f /sys/bus/usb/devices/1-1:1.0/driver)\"")
    for port in ("ttyUSB0", "ttyUSB1", "ttyUSB2"):
        assert port in out
    assert "option" in out
    # 字符设备（防假文件遮蔽回归）
    assert "crw" in out


def test_rndis_netif_present():
    assert rndis_netif().startswith("enx")
