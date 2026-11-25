# -*- coding: utf-8 -*-
"""
可选验证：对 PyInstaller 产出的 **真实 macOS 二进制** 跑一遍完整认证流程。

与 test_offline.py 的区别：这里执行的是 dist/hzau-autologin（frozen 模式），
因此同时验证了 sys.frozen 路径解析、模块打包、钥匙串读取与 launchd 无窗口运行形态。
未构建二进制时自动跳过。

运行： python3 macos/tests/test_frozen_binary.py
"""

import base64
import json
import os
import pwd
import shutil
import subprocess
import sys
import tempfile
import threading
import http.server

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from test_offline import MockPortal, PASSWORD, TOKEN, CLIENT_IP  # noqa: E402

BINARY = os.path.join(ROOT, 'dist', 'hzau-autologin')
SECURITY = '/usr/bin/security'


def main():
    if not os.path.isfile(BINARY):
        print('SKIP: 未找到 dist/hzau-autologin，先运行 bash macos/build.sh')
        return 0
    if not os.access(BINARY, os.X_OK):
        print('FAIL: 二进制不可执行')
        return 1

    service = 'HZAU-AutoLogin-FROZEN-TEST-%d' % os.getpid()
    account = pwd.getpwuid(os.getuid()).pw_name
    payload = base64.b64encode(PASSWORD.encode('utf-8')).decode('ascii')

    def cleanup():
        subprocess.run([SECURITY, 'delete-generic-password', '-a', account, '-s', service],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    cleanup()
    r = subprocess.run([SECURITY, 'add-generic-password', '-a', account, '-s', service,
                        '-l', 'HZAU frozen test', '-T', SECURITY, '-U', '-w', payload],
                       capture_output=True)
    if r.returncode != 0:
        print('FAIL: 无法写入测试钥匙串项')
        return 1

    server = http.server.HTTPServer(('127.0.0.1', 0), MockPortal)
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()

    tmp = tempfile.mkdtemp(prefix='hzau-frozen-test-')
    # frozen 模式按 sys.executable 所在目录定位 config/password/log —— 与生产一致
    shutil.copy2(BINARY, os.path.join(tmp, 'hzau-autologin'))
    os.chmod(os.path.join(tmp, 'hzau-autologin'), 0o755)
    with open(os.path.join(tmp, 'config.json'), 'w', encoding='utf-8') as f:
        json.dump({
            'server': 'http://127.0.0.1:%d' % port,
            'ac_id': '5', 'username': '20210001', 'domain': '',
            'max_attempts': 3, 'retry_interval': 1,
            'network_wait_seconds': 20, 'repair_interval_seconds': 60,
        }, f, ensure_ascii=False)
    desc = {'backend': 'keychain', 'service': service, 'account': account, 'v': 1}
    with open(os.path.join(tmp, 'password.bin'), 'w', encoding='ascii') as f:
        f.write(base64.b64encode(json.dumps(desc).encode('utf-8')).decode('ascii'))

    MockPortal.logged_in = False
    MockPortal.checks = []
    exe = os.path.join(tmp, 'hzau-autologin')
    try:
        r = subprocess.run([exe], cwd=tmp, capture_output=True, timeout=90)
    except subprocess.TimeoutExpired:
        print('FAIL: 二进制运行超时')
        return 1
    finally:
        server.shutdown()
        server.server_close()

    log_path = os.path.join(tmp, 'srun_login.log')
    log = open(log_path, encoding='utf-8').read() if os.path.exists(log_path) else ''
    ok = True
    if r.returncode != 0:
        print('FAIL: 退出码 %d\n--- stdout ---\n%s\n--- stderr ---\n%s\n--- log ---\n%s'
              % (r.returncode, r.stdout.decode('utf-8', 'replace'),
                 r.stderr.decode('utf-8', 'replace'), log))
        ok = False
    elif '认证成功' not in log or '在线验证: 通过' not in log:
        print('FAIL: 日志未显示认证成功\n' + log)
        ok = False
    elif 'chksum_match=True' not in MockPortal.checks:
        print('FAIL: 服务端校验和未通过: %r' % MockPortal.checks)
        ok = False

    print(('PASS' if ok else 'FAIL') + ': frozen 二进制完整认证流程')
    print('    日志尾部: ' + ' | '.join(log.strip().splitlines()[-3:]))
    shutil.rmtree(tmp, ignore_errors=True)
    cleanup()
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
