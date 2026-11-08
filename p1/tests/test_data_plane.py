"""数据面验收：RNDIS 网口 DHCP + 经蜂窝口真实联网"""
import time

from conftest import NETIF, curl_via_rndis, guest, rndis_netif


def test_netif_is_usb_device_child():
    assert rndis_netif().startswith("enx")


def test_dhcp_lease_from_cellular():
    guest(f"sudo ip link set {NETIF} up; sudo dhclient -1 {NETIF} 2>/dev/null")
    out = guest(f"ip -4 addr show {NETIF}")
    assert "inet 10.0.3.15" in out


def test_gateway_reachable():
    out = guest(f"ping -c 1 -I {NETIF} -W 3 10.0.3.2 2>&1")
    assert "1 received" in out or "0% packet loss" in out


def test_internet_via_rndis_interface():
    guest("sudo ip route replace default via 10.0.3.2 dev "
          f"{NETIF} 2>/dev/null")
    code = curl_via_rndis(timeout=20)
    assert code == "200", f"经 RNDIS 口联网失败: {code}"


def test_traffic_counters_increase():
    """DHCP/流量使 usbnet 计数增长（数据确实经 USB 管道）"""
    before = guest(f"ip -s link show {NETIF} | awk '/TX/{{getline; print $2}}'")
    time.sleep(0.5)
    curl_via_rndis(timeout=20)
    after = guest(f"ip -s link show {NETIF} | awk '/TX/{{getline; print $2}}'")
    assert int(after.strip() or 0) > int(before.strip() or 0)
