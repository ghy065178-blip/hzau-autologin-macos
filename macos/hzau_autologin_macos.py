# -*- coding: utf-8 -*-
"""
HZAU 校园网自动认证 —— macOS 平台适配入口。

设计原则：**不修改上游 srun_login.py 的任何一行**。本文件以模块方式导入原版脚本，
复用其全部认证协议、配置解析、日志、重试与错误处理逻辑，只在运行时替换其中
依赖 Windows 的实现（DPAPI、MessageBoxW、IsUserAnAdmin、CREATE_NO_WINDOW、
ipconfig、本机网卡枚举）。因此 Windows 与 macOS 两个版本的协议行为逐字节一致，
任何对 srun_login.py 的升级都会自动被 macOS 版本继承。

被覆盖的 srun_login 全局符号：
    alert           -> NSAlert / osascript 弹窗（原: user32.MessageBoxW）
    load_password   -> macOS 钥匙串（原: crypt32.CryptUnprotectData / DPAPI）
    is_elevated     -> geteuid()==0 或已装特权网络修复助手（原: IsUserAnAdmin）
    _run_cmd        -> 系统命令翻译层（原: subprocess + CREATE_NO_WINDOW + ipconfig）
    list_local_ips  -> ifconfig 枚举并排除 TUN 虚拟网卡
    get_local_ip    -> 优先默认路由的物理网卡 IP（原: UDP connect 选路，会被 TUN 劫持）
    log             -> 原版 log 的包装，仅把提示文案里的 Windows 路径换成 macOS 路径

额外补充（保持与 Windows 计划任务等价）：
    - 文件锁 flock：等价 MultipleInstances IgnoreNew，防止登录任务与巡检任务重叠
    - --reconnect：等价 Windows「首次巡检延后 2 分钟」的触发偏移
    - 清除继承的 HTTP(S)_PROXY：macOS 上代理工具常经 shell 注入这些变量，
      urllib 会自动走本地代理，可能把门户响应变成假「已在线」。认证请求必须直连。
    - fake-ip 检测：认证域名被解析到 28.x / 198.18.x 等 TUN 保留地址时给出明确日志

运行环境：
    * PyInstaller 冻结二进制：BASE_DIR = dirname(sys.executable)
    * 源码模式：BASE_DIR = 环境变量 HZAU_AUTOLOGIN_DIR 或 dirname(__file__)
      （install.sh 生成的启动器会把三者一起放进安装目录并设置该环境变量）
"""

import base64
import errno
import fcntl
import json
import os
import pwd
import re
import signal
import subprocess
import sys
import time

import srun_login as srun

# ---------------------------------------------------------------- 常量

KC_SERVICE = 'HZAU-AutoLogin'
KC_LABEL = 'HZAU Campus Network Password'
KC_ACCOUNT = pwd.getpwuid(os.getuid()).pw_name     # 与 keychain.sh 的 `id -un` 一致
SECURITY = '/usr/bin/security'
OSASCRIPT = '/usr/bin/osascript'
SUDO = '/usr/bin/sudo'
HELPER = '/Library/PrivilegedHelperTools/hzau-autologin-network-repair'
SUDOERS = '/etc/sudoers.d/hzau-autologin'

FIRST_RECONNECT_MARKER = '.first_reconnect_done'
LOCK_NAME = '.run.lock'

# macOS 上 Clash / Mihomo / Surge / Radmin VPN 的 TUN 模式会创建这些虚拟接口，
# 并把域名解析到保留网段（fake-ip）。这些地址不是能直连校园网门户的出口。
_VIRTUAL_IFACE = re.compile(r'^(utun|tun|tap|ppp|vpn|ipsec|wg|bridge|awdl|llw|lo)\d*$', re.I)
_FAKEIP_PREFIX = ('28.', '198.18.', '198.19.', '240.')
_PROXY_ENV_KEYS = ('http_proxy', 'https_proxy', 'all_proxy', 'ftp_proxy',
                   'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'FTP_PROXY')

_ORIG_LOG = srun.log                     # 必须在覆盖之前保存
_ORIG_LIST_LOCAL_IPS = srun.list_local_ips
_ORIG_GET_LOCAL_IP = srun.get_local_ip
_LOCK_FD = None                          # 持有 fd，进程存活期间不释放


# ---------------------------------------------------------------- 文案适配

_TEXT_MAP = (
    ('%LOCALAPPDATA%\\HZAU-AutoLogin\\', '~/Library/Application Support/HZAU-AutoLogin/'),
    ('%LOCALAPPDATA%\\HZAU-AutoLogin', '~/Library/Application Support/HZAU-AutoLogin'),
    ('change_password.bat', 'change_password.command'),
    ('uninstall.bat', 'uninstall.command'),
    ('diagnose.bat', 'diagnose.command'),
    ('install.bat', 'install.command'),
    ('DPAPI 加密', 'macOS 钥匙串加密'),
    ('DPAPI', 'macOS 钥匙串'),
    ('Windows 用户', 'macOS 用户'),
    ('Windows 的账号', 'macOS 的账号'),
    ('Windows 账号', 'macOS 账号'),
    ('登录 Windows', '登录 macOS'),
    ('Windows', 'macOS'),
)


def translate(text):
    """只做提示文案的平台词替换，不触碰任何控制流与协议数据。"""
    s = str(text)
    for old, new in _TEXT_MAP:
        s = s.replace(old, new)
    return s


def mac_log(msg):
    _ORIG_LOG(translate(msg))


def _as_literal(text):
    """把字符串转成 AppleScript 字符串字面量。"""
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


def mac_alert(msg):
    """等价 MessageBoxW(0, msg, 'HZAU-AutoLogin', MB_ICONINFORMATION)。

    Windows 版是 --noconsole 程序，配置/密码出错时靠弹窗告知；macOS 版由
    launchd 启动、无终端，因此同样用 osascript 弹出非阻塞式提示（20 秒自动关闭）。
    无 GUI 会话时 osascript 会失败，已被静默捕获，日志仍完整保留。
    """
    text = translate(msg)
    script = (
        'display dialog %s with title "HZAU-AutoLogin" '
        'buttons {"好"} default button 1 with icon note giving up after 20'
        % _as_literal(text)
    )
    try:
        subprocess.run([OSASCRIPT, '-e', script], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=25)
    except Exception:
        pass


# ---------------------------------------------------------------- 密码存储

def mac_load_password():
    """等价 DPAPI 解密：从 password.bin 读取句柄，再从当前用户登录钥匙串取回密码。

    password.bin 的内容是 base64(JSON 描述符)，**不含任何机密**；机密只存在
    「本机 + 当前 macOS 用户」的登录钥匙串里，语义与 DPAPI CurrentUser 一致。
    """
    with open(srun.PASSWORD_PATH, 'r', encoding='ascii') as f:
        raw = f.read().strip()          # FileNotFoundError 原样抛给 main() 处理
    try:
        desc = json.loads(base64.b64decode(raw).decode('utf-8'))
    except Exception as e:
        raise OSError('password.bin 格式错误（%s），请重新运行 install.command' % e)
    if desc.get('backend') != 'keychain':
        raise OSError('password.bin 不是 macOS 钥匙串格式，请重新运行 install.command')
    svc = desc.get('service') or KC_SERVICE
    acct = desc.get('account') or KC_ACCOUNT
    try:
        r = subprocess.run(
            [SECURITY, 'find-generic-password', '-a', acct, '-s', svc, '-w'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    except Exception as e:
        raise OSError('读取 macOS 钥匙串失败: %s' % e)
    if r.returncode != 0:
        raise OSError(
            '钥匙串读取失败（security 退出码 %d）：password.bin 与当前 macOS 用户不匹配，'
            '或登录钥匙串处于锁定状态。请用平时登录的账号重新运行 install.command / '
            'change_password.command 保存密码。' % r.returncode)
    payload = r.stdout.decode('ascii', 'replace').rstrip('\r\n')
    try:
        return base64.b64decode(payload).decode('utf-8')
    except Exception as e:
        raise OSError('钥匙串中保存的密码格式错误: %s' % e)


# ---------------------------------------------------------------- 权限与命令

def _helper_available():
    return os.path.isfile(SUDOERS) and os.access(HELPER, os.X_OK)


def mac_is_elevated():
    """语义等价 IsUserAnAdmin()：是否具备执行 DHCP 续租的权限。

    LaunchAgent 以普通用户运行（否则读不到该用户的登录钥匙串），因此 macOS 版
    通过安装期一次性授权安装的特权助手获得等价能力；未授权时返回 False，
    run_repair() 会走与 Windows「普通权限」完全相同的降级分支。
    """
    return os.geteuid() == 0 or _helper_available()


def _native(argv, timeout):
    """静默执行命令；不使用 Windows 专属的 creationflags=CREATE_NO_WINDOW。"""
    try:
        r = subprocess.run(list(argv), stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=timeout)
        return r.returncode
    except Exception as e:
        mac_log('命令执行失败 %s: %s' % (' '.join(str(x) for x in argv), e))
        return -1


def _sudo_helper(action, timeout):
    if os.geteuid() == 0:
        argv = [HELPER, action]
    elif _helper_available():
        argv = [SUDO, '-n', HELPER, action]
    else:
        mac_log('无管理员权限，跳过网络修复动作 %s，仅被动等待' % action)
        return -1
    return _native(argv, timeout)


def mac_run_cmd(args, timeout=90):
    """把 Windows 网络修复命令翻译成 macOS 等价命令。

        ipconfig /flushdns -> dscacheutil -flushcache (+ killall -HUP mDNSResponder，尽力而为)
        ipconfig /release  -> 特权助手 release（ipconfig set <iface> NONE）
        ipconfig /renew    -> 特权助手 renew  （ipconfig set <iface> DHCP）

    srun_login.py 中 run_repair() 与 wait_for_network() 都通过全局 _run_cmd 调用，
    因此覆盖这一个符号即可让原版网络修复流程在 macOS 上原样工作。
    """
    argv = list(args)
    if argv and os.path.basename(str(argv[0])).lower() == 'ipconfig':
        sub = str(argv[1]).lower() if len(argv) > 1 else ''
        if sub == '/flushdns':
            rc = _native(['/usr/bin/dscacheutil', '-flushcache'], min(timeout, 30))
            if _helper_available():
                _sudo_helper('flushdns', min(timeout, 30))
            return rc
        if sub == '/release':
            return _sudo_helper('release', timeout)
        if sub == '/renew':
            return _sudo_helper('renew', timeout)
    return _native(argv, timeout)


def _iface_ipv4():
    """解析 /sbin/ifconfig -a，返回 [(接口名, IPv4)]。"""
    pairs = []
    try:
        r = subprocess.run(['/sbin/ifconfig', '-a'], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=10)
        text = r.stdout.decode('utf-8', 'replace')
    except Exception:
        return pairs
    iface = ''
    for line in text.splitlines():
        m = re.match(r'^([A-Za-z0-9]+):\s', line)
        if m:
            iface = m.group(1)
            continue
        m = re.search(r'\binet\s+(\d{1,3}(?:\.\d{1,3}){3})\b', line)
        if m:
            pairs.append((iface, m.group(1)))
    return pairs


def _physical_ipv4():
    """物理网卡 IPv4，排除 TUN/回环/链路本地地址。"""
    out = []
    for iface, ip in _iface_ipv4():
        if _VIRTUAL_IFACE.match(iface):
            continue
        if ip.startswith('127.') or ip.startswith('169.254.'):
            continue
        out.append((iface, ip))
    return out


def _default_iface():
    try:
        r = subprocess.run(['/sbin/route', '-n', 'get', 'default'],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
        m = re.search(r'interface:\s*(\S+)', r.stdout.decode('utf-8', 'replace'))
        return m.group(1) if m else ''
    except Exception:
        return ''


def mac_get_local_ip(server_host=''):
    """等价原版 get_local_ip()，但在 TUN/fake-ip 环境下不被虚拟网卡带偏。

    原版向认证服务器 IP 做 UDP connect 选路；代理 TUN 会把该域名解析成 fake-ip
    并插入 utun 主机路由，于是 getsockname() 返回 28.0.0.1 一类虚拟地址。
    这里改为取「默认路由物理接口」的地址，语义仍是「访问门户所用的本机 IP」。
    """
    if server_host:
        try:
            server_ip = srun._resolve_server_ip(server_host)
        except Exception:
            server_ip = None
        if server_ip and server_ip.startswith(_FAKEIP_PREFIX):
            mac_log('警告: 认证域名 %s 被解析到 %s（代理 TUN 的 fake-ip 保留地址）。'
                    '门户无法直连，请退出 Clash / Mihomo / Surge / Radmin VPN 的 TUN（增强）模式，'
                    '或把该域名加入代理的 DIRECT 直连规则。' % (server_host, server_ip))
    pairs = _physical_ipv4()
    if pairs:
        default_iface = _default_iface()
        for iface, ip in pairs:
            if default_iface and iface == default_iface:
                return ip
        return pairs[0][1]
    return _ORIG_GET_LOCAL_IP(server_host)


def mac_list_local_ips():
    """网卡自动切换的候选集；虚拟网卡不是可用的校园网出口，必须排除。"""
    ips = []
    for _, ip in _physical_ipv4():
        if ip not in ips:
            ips.append(ip)
    return ips or _ORIG_LIST_LOCAL_IPS()


def disable_inherited_proxies():
    """认证请求必须直连门户；清除 shell 注入的代理变量，避免 urllib 走本地代理。

    设置 HZAU_KEEP_PROXY=1 可保留（仅供确实需要代理访问门户的特殊网络）。
    """
    if os.environ.get('HZAU_KEEP_PROXY') == '1':
        return
    removed = [k for k in _PROXY_ENV_KEYS if os.environ.pop(k, None)]
    if removed:
        mac_log('已忽略继承的代理设置（%s）：认证请求直连校园网门户'
                % ', '.join(removed))


# ---------------------------------------------------------------- 并发保护

def acquire_lock(base):
    """非阻塞文件锁，等价计划任务的 MultipleInstances IgnoreNew。"""
    global _LOCK_FD
    try:
        _LOCK_FD = open(os.path.join(base, LOCK_NAME), 'a+')
        fcntl.flock(_LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError as e:
        blocked = e.errno in (errno.EACCES, errno.EAGAIN)
        try:
            if _LOCK_FD is not None:
                _LOCK_FD.close()
        finally:
            _LOCK_FD = None
        if blocked:
            return False
        mac_log('运行锁不可用（%s），继续执行' % e)
        return True


def reconnect_delay(base):
    """等价 Windows 巡检任务「首次触发延后 2 分钟」。

    用安装目录内的标记文件区分首次运行；后续每 30 分钟的巡检立即开始，
    不会累积延迟。睡眠发生在加锁之前，不阻塞登录任务的认证。
    """
    if '--reconnect' not in sys.argv[1:]:
        return
    marker = os.path.join(base, FIRST_RECONNECT_MARKER)
    if os.path.exists(marker):
        return
    mac_log('首次巡检按配置延后 120 秒启动（等价 Windows 计划任务首次触发偏移）')
    time.sleep(120)
    try:
        with open(marker, 'w', encoding='utf-8') as f:
            f.write(time.strftime('%Y-%m-%d %H:%M:%S\n'))
    except OSError:
        pass


def _watchdog():
    """等价 ExecutionTimeLimit 20 分钟：launchd 没有单次数运行时限，这里自行兜底。"""
    if not hasattr(signal, 'SIGALRM'):
        return

    def _on_timeout(signum, frame):
        mac_log('单次运行超过 20 分钟，按计划任务时限退出')
        raise SystemExit(1)

    try:
        signal.signal(signal.SIGALRM, _on_timeout)
        signal.alarm(20 * 60)
    except (ValueError, OSError):
        pass


# ---------------------------------------------------------------- 装配

def resolve_base_dir():
    if getattr(sys, 'frozen', False):
        return os.path.dirname(os.path.abspath(sys.executable))
    env = os.environ.get('HZAU_AUTOLOGIN_DIR')
    if env:
        return os.path.abspath(env)
    return os.path.dirname(os.path.abspath(__file__))


def apply_overrides(base_dir=None):
    """把平台相关实现注入原版模块。可供离线测试复用。"""
    base = base_dir or resolve_base_dir()
    srun.BASE_DIR = base
    srun.CONFIG_PATH = os.path.join(base, 'config.json')
    srun.PASSWORD_PATH = os.path.join(base, 'password.bin')
    srun.LOG_PATH = os.path.join(base, 'srun_login.log')
    srun.log = mac_log
    srun.alert = mac_alert
    srun.load_password = mac_load_password
    srun.is_elevated = mac_is_elevated
    srun._run_cmd = mac_run_cmd
    srun.list_local_ips = mac_list_local_ips
    srun.get_local_ip = mac_get_local_ip
    disable_inherited_proxies()
    return base


def run():
    base = apply_overrides()
    reconnect_delay(base)
    if not acquire_lock(base):
        mac_log('已有认证进程在运行，跳过本次（等价 MultipleInstances IgnoreNew）')
        return 0
    _watchdog()
    return srun.main()               # 原版 main()：读配置 -> 读密码 -> 等网络 -> 认证


if __name__ == '__main__':
    sys.exit(run())
