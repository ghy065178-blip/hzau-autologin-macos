# -*- coding: utf-8 -*-
"""
HZAU-AutoLogin macOS —— 钥匙串跨语言一致性测试。

真实链路是「安装/改密码 shell 脚本写入钥匙串」+「Python 主程序读取钥匙串」，
两者必须严格共享同一套格式约定。本测试用一个**一次性、独立命名的钥匙串项**
验证这条链路，并在 finally 中删除，不改动用户真实保存的密码项。

运行： python3 macos/tests/test_keychain.py
"""

import base64
import json
import os
import pwd
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MACOS = os.path.join(ROOT, 'macos')
sys.path.insert(0, ROOT)
sys.path.insert(0, MACOS)

import srun_login as srun                       # noqa: E402
import hzau_autologin_macos as mac             # noqa: E402

PASSWORD = 'P@ssw0rd-测试-123'
SERVICE = 'HZAU-AutoLogin-UNITTEST-%d' % os.getpid()
ACCOUNT = pwd.getpwuid(os.getuid()).pw_name
SECURITY = '/usr/bin/security'


def delete_item():
    subprocess.run([SECURITY, 'delete-generic-password', '-a', ACCOUNT, '-s', SERVICE],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class KeychainTest(unittest.TestCase):

    def setUp(self):
        delete_item()
        self.tmp = tempfile.mkdtemp(prefix='hzau-kc-test-')

    def tearDown(self):
        delete_item()

    def test_01_shell_writes_python_reads(self):
        env = dict(os.environ)
        env['HZAU_KC_SERVICE'] = SERVICE
        env['HZAU_KC_ACCOUNT'] = ACCOUNT
        env['HZAU_TEST_PW'] = PASSWORD
        code = '. "%s/keychain.sh"; hzau_kc_save "$HZAU_TEST_PW"; hzau_write_password_handle "%s"' \
               % (MACOS, self.tmp)
        r = subprocess.run(['/bin/bash', '-c', code], env=env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

        # password.bin 句柄：base64(JSON)，不含明文，且指向测试用钥匙串项
        with open(os.path.join(self.tmp, 'password.bin'), encoding='ascii') as f:
            raw = f.read().strip()
        desc = json.loads(base64.b64decode(raw).decode('utf-8'))
        self.assertEqual(desc['backend'], 'keychain')
        self.assertEqual(desc['service'], SERVICE)
        self.assertNotIn(PASSWORD, raw)

        # 让主程序按生产路径读取
        mac.apply_overrides(self.tmp)
        self.assertEqual(mac.mac_load_password(), PASSWORD)

        # 原版 main() 的异常处理分支不变量：句柄丢失时抛 FileNotFoundError
        os.remove(os.path.join(self.tmp, 'password.bin'))
        with self.assertRaises(FileNotFoundError):
            mac.mac_load_password()

    def test_02_shell_read_and_length(self):
        env = dict(os.environ)
        env['HZAU_KC_SERVICE'] = SERVICE
        env['HZAU_KC_ACCOUNT'] = ACCOUNT
        env['HZAU_TEST_PW'] = PASSWORD
        code = '. "%s/keychain.sh"; hzau_kc_save "$HZAU_TEST_PW"' % MACOS
        self.assertEqual(subprocess.run(['/bin/bash', '-c', code], env=env,
                                       capture_output=True).returncode, 0)

        code2 = '. "%s/keychain.sh"; hzau_kc_load' % MACOS
        r = subprocess.run(['/bin/bash', '-c', code2], env=env, capture_output=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.decode('utf-8'), PASSWORD)

        code3 = '. "%s/keychain.sh"; hzau_kc_length' % MACOS
        r = subprocess.run(['/bin/bash', '-c', code3], env=env, capture_output=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.decode().strip(), str(len(PASSWORD)))

    def test_03_handle_validation(self):
        env = dict(os.environ)
        env['HZAU_KC_SERVICE'] = SERVICE
        code = '. "%s/keychain.sh"; hzau_check_password_handle "%s"' % (MACOS, self.tmp)
        r = subprocess.run(['/bin/bash', '-c', code], env=env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('password.bin 不存在', r.stdout)

        with open(os.path.join(self.tmp, 'password.bin'), 'w', encoding='ascii') as f:
            f.write(base64.b64encode(b'{"backend":"dpapi"}').decode('ascii'))
        r = subprocess.run(['/bin/bash', '-c', code], env=env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Windows 版残留', r.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
