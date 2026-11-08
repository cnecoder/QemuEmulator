#!/usr/bin/env python3
"""QMP 客户端: 用原生 snapshot-save 任务对 qcow2 磁盘做内部快照（绕过不支持快照的 pflash）
用法: qmp_savevm.py <qmp_sock> <tag>"""
import json
import socket
import sys
import time

def main():
    sock_path, tag = sys.argv[1], sys.argv[2]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(180)
    f = s.makefile("rw")

    def recv():
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError("QMP closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def qmp(obj):
        f.write(json.dumps(obj) + "\n")
        f.flush()
        return recv()

    greeting = recv()
    assert "QMP" in greeting, greeting
    qmp({"execute": "qmp_capabilities"})

    # 找到 boot 磁盘的 node-name（按文件名匹配 disk.qcow2）
    blocks = qmp({"execute": "query-block"})["return"]
    node = None
    for b in blocks:
        ins = b.get("inserted") or {}
        if "disk.qcow2" in ins.get("file", ""):
            node = ins.get("node-name")
            break
    if not node:
        print("SAVEVM_FAILED: cannot find disk.qcow2 in query-block")
        sys.exit(1)

    t0 = time.time()
    # 清除同名旧快照（避免旧快照干扰校验）
    qmp({"execute": "human-monitor-command",
         "arguments": {"command-line": f"delvm {tag}"}})
    resp = qmp({"execute": "snapshot-save",
                "arguments": {"job-id": "snapjob", "tag": tag,
                              "vmstate": node, "devices": [node]}})
    if "error" in resp:
        print(f"SAVEVM_FAILED: {json.dumps(resp['error'])}")
        sys.exit(1)

    # 轮询任务状态（ concluded 且无 error 才算成功）
    job_err = None
    while True:
        jobs = qmp({"execute": "query-jobs"})["return"]
        job = next((j for j in jobs if j["id"] == "snapjob"), None)
        if job is None:
            break
        if job["status"] == "concluded":
            job_err = job.get("error")
            break
        time.sleep(0.2)
    dt = time.time() - t0
    qmp({"execute": "job-dismiss", "arguments": {"id": "snapjob"}})
    if job_err:
        print(f"SAVEVM_FAILED after {dt:.2f}s: job error: {json.dumps(job_err)}")
        sys.exit(1)

    # 确认快照真的写入
    info = qmp({"execute": "human-monitor-command",
                "arguments": {"command-line": "info snapshots"}})["return"]
    if tag in info:
        print(f"SAVEVM_OK {dt:.2f}s (node={node})")
    else:
        print("SAVEVM_FAILED: snapshot tag not found after job")
        print(info)
        sys.exit(1)

if __name__ == "__main__":
    main()
