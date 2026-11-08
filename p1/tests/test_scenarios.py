"""场景验收：拔卡/搜网/拒绝/去附着/飞行模式 + URC + 信号/弱网注入"""
import time

from conftest import at, curl_via_rndis, guest


def test_scenario_no_sim(modem):
    modem.scenario("no_sim")
    time.sleep(1)
    assert "+CME ERROR: 10" in at("AT+CPIN?")        # SIM not inserted
    assert ",0" in at("AT+CEREG?")                   # 未注册
    assert modem.status()["sim"] == "absent"


def test_no_sim_recovery(modem):
    modem.scenario("no_sim")
    time.sleep(1)
    modem.scenario("normal")
    time.sleep(1)
    assert "+CPIN: READY" in at("AT+CPIN?")
    assert ",1" in at("AT+CEREG?")


def test_scenario_searching(modem):
    modem.scenario("searching")
    time.sleep(1)
    out = at("AT+CEREG?")
    assert ",2" in out                                # searching
    modem.scenario("normal")


def test_scenario_denied(modem):
    modem.scenario("denied")
    time.sleep(1)
    assert ",3" in at("AT+CEREG?")                    # denied
    modem.scenario("normal")


def test_scenario_detached_real_link_drop(modem):
    """去附着 = AT 层 CGATT:0 + QMP 真断链路 → 数据面实际不通"""
    modem.scenario("detached")
    time.sleep(1)
    assert "+CGATT: 0" in at("AT+CGATT?")
    assert curl_via_rndis(timeout=8) not in ("200",)
    # 恢复由 modem fixture 兜底（scenario normal + set_link on）


def test_scenario_offline_airplane(modem):
    modem.scenario("offline")
    time.sleep(1)
    assert "+CFUN: 0" in at("AT+CFUN?")
    assert ",0" in at("AT+CEREG?")
    assert "+CGATT: 0" in at("AT+CGATT?")
    modem.scenario("normal")
    assert "OK" in at("AT+CFUN=1")


def test_urc_delivery(modem):
    """注入的 URC 必须经 USB 串口到达 guest（挂在下一次 AT 交互的数据流里）"""
    modem.inject_urc("+WMTEST: 42")
    out = at("AT")
    assert "+WMTEST: 42" in out


def test_signal_injection(modem):
    modem.set_signal(5)
    assert "+CSQ: 5,99" in at("AT+CSQ")
    modem.set_signal(28)
    assert "+CSQ: 28,99" in at("AT+CSQ")


def test_weak_network_delay(modem):
    """弱网注入：filter-buffer 拉高时延；清除后回落"""
    base = float(curl_via_rndis(timeout=20) and
                 guest("curl -4 --interface enx525400123457 -s -m 20 -o /dev/null "
                       "-w '%{time_total}' http://www.baidu.com") or 0)
    modem.set_delay(500)
    time.sleep(1)
    slow = float(guest("curl -4 --interface enx525400123457 -s -m 20 -o /dev/null "
                       "-w '%{time_total}' http://www.baidu.com"))
    modem.set_delay(0)
    time.sleep(1)
    back = float(guest("curl -4 --interface enx525400123457 -s -m 20 -o /dev/null "
                       "-w '%{time_total}' http://www.baidu.com"))
    assert slow >= base + 0.2, f"弱网延迟未生效: base={base} slow={slow}"
    assert back < slow - 0.1, f"延迟未回落: slow={slow} back={back}"


def test_normal_scenario_sets_everything(modem):
    modem.scenario("normal")
    time.sleep(1)
    st = modem.status()
    assert st["sim"] == "ready" and st["reg"] == "home" \
        and st["data"] == "attached" and st["link"] == "up"
