#!/usr/bin/env python3
"""对真实签名的 universal helper 验证安装引导校验；不提权、不启动服务、不写硬件。"""
import pathlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else root / 'output/native/Ermi.app').resolve()
script = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else root / 'scripts/local-fan-control.command')
helper = app / 'Contents/MacOS/ErmiFanHelper'
text = script.read_text()
bootstrap = text.split("<<'BOOTSTRAP' || true\n", 1)[1].split('\nBOOTSTRAP', 1)[0]
# 只执行实际引导脚本的复制与验签段；切断安装/卸载分支，临时目录改到用户私有目录。
validation = bootstrap.split('if [ "$mode" = install ]; then', 1)[0]
hashes = {}
for architecture in ('arm64', 'x86_64'):
    info = subprocess.run(['codesign', '-d', '--verbose=4', '--arch', architecture, str(helper)], capture_output=True, text=True, check=True)
    hashes[architecture] = re.search(r'^CDHash=([0-9a-f]{40})$', info.stderr, re.M)[1]
# 不执行安装，只验证显式架构下的计划确实产生该切片的指纹。
for architecture, digest in hashes.items():
    plan = subprocess.run(['/usr/bin/arch', '-' + architecture, str(helper), '--local-plan', str(app)], capture_output=True, text=True, check=True)
    assert plan.stdout.split()[1] == digest, (architecture, plan.stdout)
    print(architecture, 'plan architecture PASS')
with tempfile.TemporaryDirectory(prefix='ermi-signature-test-') as directory:
    validation = validation.replace('/private/var/root/ermi-install.XXXXXX', directory + '/stage.XXXXXX')
    for architecture, digest in hashes.items():
        for label, value, accepted in [('matching', digest, True), ('wrong', '0' * 40, False), ('other-slice', hashes['x86_64' if architecture == 'arm64' else 'arm64'], False)]:
            result = subprocess.run(['/bin/sh', '-c', validation, 'sh', str(helper), value, 'install', str(app), 'unused', '501', architecture], capture_output=True, text=True)
            assert (result.returncode == 0) == accepted, (architecture, label, result.returncode, result.stderr)
            print(architecture, label, 'PASS', 'exit=' + str(result.returncode))
    # 破坏另一架构的签名字节，确认不能只验证本架构而放过被篡改的 universal 文件。
    damaged = pathlib.Path(directory) / 'damaged-helper'
    data = bytearray(helper.read_bytes())
    import struct
    count = struct.unpack_from('>I', data, 4)[0]
    for i in range(count):
        cpu, _, offset, size, _ = struct.unpack_from('>IIIII', data, 8 + 20 * i)
        if cpu == 0x01000007:  # x86_64 切片内 __TEXT 字节，仍保留 Mach-O 头可解析。
            data[offset + 8192] ^= 1
            break
    else:
        raise AssertionError('missing x86_64 slice')
    damaged.write_bytes(data)
    result = subprocess.run(['/bin/sh', '-c', validation, 'sh', str(damaged), hashes['arm64'], 'install', str(app), 'unused', '501', 'arm64'], capture_output=True, text=True)
    assert result.returncode != 0, 'tampered other architecture accepted'
    print('tampered-other-architecture PASS exit=' + str(result.returncode))
