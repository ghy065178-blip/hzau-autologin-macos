# -*- coding: utf-8 -*-
"""
HZAU-AutoLogin macOS 版离线端到端验证（不联网、不接触校园网、不写系统配置）。

用一个本地 HTTP 假门户完整跑通原版 srun_login.main() 的认证路径：
    rad_user_info -> srun_portal_pc -> get_challenge -> srun_portal -> rad_user_info
并在服务端**独立重算** hmd5 / chksum，验证 macOS 适配层没有改动任何协议行为。

运行： python3 macos/tests/test_offline.py
"""

import base64
import hashlib
import hmac
import http.server
import json
import os
import signal
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, 'macos'))

import srun_login as srun                       # noqa: E402  原版协议实现，未做任何修改
import hzau_autologin_macos as mac             # noqa: E402

PASSWORD = 'P@ssw0rd-测试-123'                 # 含中文，验证 UTF-8 / base64 无损
TOKEN = 'unit-test-token-0123456789abcdef'
CLIENT_IP = '127.0.0.1'
_ORIG_APPLY = mac.apply_overrides


def _stubbed_apply(base=None):
    """run() 内部会再次调用 apply_overrides，这里保证测试桩不会被覆盖掉。"""
    b = _ORIG_APPLY(base)
    srun.load_password = lambda: PASSWORD       # 隔离钥匙串，不改生产逻辑
    srun.wait_for_network = lambda cfg: True    # 跳过 5 分钟网络等待
    srun.alert = lambda msg: None               # 禁止测试期间弹窗
    return b


class MockPortal(http.server.BaseHTTPRequestHandler):
    """极简 Srun 假门户；服务端独立校验客户端算出的密码摘要与校验和。"""

    logged_in = False
    checks = []
    handler = None

    def log_message(self, fmt, *args):
        pass

    def _send(self, obj, wrapper='_'):
        body = ('%s(%s)' % (wrapper, json.dumps(obj, ensure_ascii=False))).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/javascript; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, html):
        body = html.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        MockPortal.handler = self
        p = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(p.query)
        if p.path == '/cgi-bin/rad_user_info':
            if MockPortal.logged_in:
                self._send({'error': 'ok', 'user_ip': CLIENT_IP, 'username': '20210001'})
            else:
                self._send({'error': 'not_online'})
        elif p.path == '/srun_portal_pc':
            self._html('<script>var CONFIG = { ip : "%s", ac_id: 5 };</script>' % CLIENT_IP)
        elif p.path == '/cgi-bin/get_challenge':
            self._send({'error': 'ok', 'challenge': TOKEN, 'client_ip': CLIENT_IP}, '_jc')
        elif p.path == '/cgi-bin/srun_portal':
            self._verify_login(q)
        else:
            self.send_error(404)

    def _verify_login(self, q):
        get = lambda k: q.get(k, [''])[0]                       # noqa: E731
        c = MockPortal.checks
        c.append('action=%s' % get('action'))
        c.append('username=%s' % get('username'))
        c.append('ac_id=%s' % get('ac_id'))
        c.append('n=%s type=%s double_stack=%s' %
                 (get('n'), get('type'), get('double_stack')))
        c.append('os=%s name=%s' % (get('os'), get('name')))

        hmd5 = get('password').replace('{MD5}', '', 1)
        expect_hmd5 = hmac.new(TOKEN.encode('ascii'), PASSWORD.encode('utf-8'),
                               hashlib.md5).hexdigest()
        c.append('hmd5_match=%s' % (hmd5 == expect_hmd5))

        info = get('info')
        c.append('info_prefix=%s' % info.startswith('{SRBX1}'))

        # 服务端按 Portal.js 规则独立重算 chksum（不复用被测代码的任何函数）
        chkstr = (TOKEN + get('username') + TOKEN + hmd5 + TOKEN + get('ac_id') +
                  TOKEN + get('ip') + TOKEN + '200' + TOKEN + '1' + TOKEN + info)
        expect_chksum = hashlib.sha1(chkstr.encode('utf-8')).hexdigest()
        c.append('chksum_match=%s' % (get('chksum') == expect_chksum))

        MockPortal.logged_in = True
        self._send({'error': 'ok', 'suc_msg': 'login ok'}, '_lg')


class OfflineTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(('127.0.0.1', 0), MockPortal)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        # 加速：跳过原版中的 2s / 3s 等待
        cls._real_sleep = time.sleep
        time.sleep = lambda s: None if s < 10 else cls._real_sleep(s)

    @classmethod
    def tearDownClass(cls):
        time.sleep = cls._real_sleep
        cls.server.shutdown()
        cls.server.server_close()
        signal.alarm(0)

    def setUp(self):
        if mac._LOCK_FD is not None:
            try:
                mac._LOCK_FD.close()
            except OSError:
                pass
            mac._LOCK_FD = None
        self.tmp = tempfile.mkdtemp(prefix='hzau-macos-test-')
        cfg = {
            'server': 'http://127.0.0.1:%d' % self.port,
            'ac_id': '5',
            'username': '20210001',
            'domain': '',
            'max_attempts': 3,
            'retry_interval': 3,
            'network_wait_seconds': 300,
            'repair_interval_seconds': 60,
        }
        with open(os.path.join(self.tmp, 'config.json'), 'w', encoding='utf-8') as f:
            json.dump(cfg, f, ensure_ascii=False)
        _stubbed_apply(self.tmp)
        mac.apply_overrides = _stubbed_apply
        srun._SRC_IP = None
        MockPortal.logged_in = False
        MockPortal.checks = []

    def _log(self):
        path = os.path.join(self.tmp, 'srun_login.log')
        if not os.path.exists(path):
            return ''
        with open(path, encoding='utf-8') as f:
            return f.read()

    def test_01_full_login_flow(self):
        """完整认证链路 + 服务端独立校验 hmd5 / chksum，退出码必须为 0。"""
        rc = srun.main()
        self.assertEqual(rc, 0, self._log())
        self.assertIn('认证成功', self._log())
        self.assertIn('在线验证: 通过', self._log())
        c = MockPortal.checks
        self.assertIn('action=login', c)
        self.assertIn('username=20210001', c)
        self.assertIn('ac_id=5', c)
        self.assertIn('n=200 type=1 double_stack=0', c)
        self.assertIn('os=Windows NT name=Windows', c, '协议载荷必须与 Windows 版逐字节一致')
        self.assertIn('hmd5_match=True', c, 'HMAC-MD5 与 Portal.js 不一致')
        self.assertIn('info_prefix=True', c, 'info 必须是 {SRBX1} + 自定义 base64')
        self.assertIn('chksum_match=True', c, 'SHA1 chksum 与 Portal.js 不一致')

    def test_02_already_online_short_circuit(self):
        MockPortal.logged_in = True
        rc = srun.main()
        self.assertEqual(rc, 0)
        self.assertIn('当前已在线，无需认证', self._log())

    def test_03_missing_config(self):
        os.remove(os.path.join(self.tmp, 'config.json'))
        rc = srun.main()
        self.assertEqual(rc, 1)
        self.assertIn('读取 config.json 失败', self._log())

    def test_04_missing_password(self):
        # 恢复真实密码读取函数；不创建 password.bin -> 原版 main() 的
        # FileNotFoundError 分支必须生效（等价 Windows「未找到 password.bin」）
        srun.load_password = mac.mac_load_password
        rc = srun.main()
        self.assertEqual(rc, 1)
        self.assertIn('未找到 password.bin', self._log())
        with self.assertRaises(FileNotFoundError):
            mac.mac_load_password()

    def test_05_platform_overrides(self):
        self.assertIsInstance(mac.mac_is_elevated(), bool)
        self.assertEqual(mac.mac_run_cmd(['/bin/echo', 'ok']), 0)
        self.assertIsInstance(mac.mac_list_local_ips(), list)
        self.assertIn('install.command', mac.translate('请双击 install.bat'))
        self.assertIn('diagnose.command', mac.translate('运行 diagnose.bat 检查'))
        self.assertIn('~/Library/Application Support',
                      mac.translate('%LOCALAPPDATA%\\HZAU-AutoLogin\\'))

    def test_06_ignore_new_lock(self):
        """另一个进程持有锁时，新实例必须被挡住（等价 MultipleInstances IgnoreNew）。

        macOS 的 flock 对同一进程的重复加锁会成功，因此这里用子进程模拟
        「登录任务与巡检任务同时启动」的真实场景。
        """
        import subprocess
        lock_path = os.path.join(self.tmp, mac.LOCK_NAME)
        ready = os.path.join(self.tmp, '.child_ready')
        code = (
            'import fcntl,sys,os,time\n'
            'f=open(sys.argv[1],"a+")\n'
            'fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n'
            'open(sys.argv[2],"w").write("1")\n'
            'time.sleep(10)\n'
        )
        child = subprocess.Popen([sys.executable, '-c', code, lock_path, ready])
        try:
            for _ in range(100):
                if os.path.exists(ready):
                    break
                self._real_sleep(0.02)
            self.assertTrue(os.path.exists(ready), '子进程未能取得锁')
            self.assertFalse(mac.acquire_lock(self.tmp))
        finally:
            child.terminate()
            child.wait(timeout=5)
        self.assertTrue(mac.acquire_lock(self.tmp))

    def test_07_keychain_handle_roundtrip(self):
        """password.bin 句柄是 base64(JSON)，不含任何密码明文。"""
        desc = {'backend': 'keychain', 'service': mac.KC_SERVICE,
                'account': mac.KC_ACCOUNT, 'v': 1}
        handle = base64.b64encode(json.dumps(desc).encode('utf-8')).decode('ascii')
        with open(os.path.join(self.tmp, 'password.bin'), 'w', encoding='ascii') as f:
            f.write(handle)
        self.assertNotIn(PASSWORD, handle)
        self.assertEqual(json.loads(base64.b64decode(handle).decode('utf-8'))['backend'],
                         'keychain')

    def test_08_entry_point(self):
        """直接调用 macOS 入口 run()，验证锁 + 看门狗 + 原版 main() 的装配。"""
        MockPortal.logged_in = True
        argv = sys.argv
        old_env = os.environ.get('HZAU_AUTOLOGIN_DIR')
        sys.argv = ['hzau-autologin']
        os.environ['HZAU_AUTOLOGIN_DIR'] = self.tmp
        try:
            rc = mac.run()
        finally:
            sys.argv = argv
            if old_env is None:
                os.environ.pop('HZAU_AUTOLOGIN_DIR', None)
            else:
                os.environ['HZAU_AUTOLOGIN_DIR'] = old_env
            signal.alarm(0)
        self.assertEqual(rc, 0, self._log())
        self.assertIn('启动: 目录 %s' % self.tmp, self._log())

    def test_09_tun_virtual_nic_excluded(self):
        """TUN/fake-ip 环境下不得把 utun 的 28.x 当成本机 IP 或备用网卡候选。"""
        pairs = mac._iface_ipv4()
        self.assertIsInstance(pairs, list)
        virtual = [ip for iface, ip in pairs if mac._VIRTUAL_IFACE.match(iface)]
        physical = [ip for _, ip in mac._physical_ipv4()]
        for ip in virtual:
            self.assertNotIn(ip, physical)
        for ip in mac.mac_list_local_ips():
            self.assertFalse(ip.startswith(('28.', '198.18.', '198.19.', '240.')),
                             '虚拟网卡地址不应进入自动切换候选集: %s' % ip)
        local_ip = mac.mac_get_local_ip('example.invalid')
        self.assertFalse(local_ip.startswith(('28.', '198.18.', '198.19.', '240.')),
                         '本机 IP 不应来自 TUN 虚拟网卡: %s' % local_ip)

    def test_10_inherited_proxy_disabled(self):
        """shell 注入的 HTTP(S)_PROXY 必须被清除，否则 urllib 会走本地代理。"""
        keys = ('http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY')
        saved = {k: os.environ.get(k) for k in keys}
        saved_keep = os.environ.get('HZAU_KEEP_PROXY')
        try:
            os.environ.pop('HZAU_KEEP_PROXY', None)
            for k in keys:
                os.environ[k] = 'http://127.0.0.1:9'
            mac.disable_inherited_proxies()
            for k in keys:
                self.assertNotIn(k, os.environ)
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            if saved_keep is None:
                os.environ.pop('HZAU_KEEP_PROXY', None)
            else:
                os.environ['HZAU_KEEP_PROXY'] = saved_keep


if __name__ == '__main__':
    unittest.main(verbosity=2)
