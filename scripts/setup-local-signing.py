#!/usr/bin/env python3
"""一次性创建 Ermi 本机签名身份；私钥仅保留在用户钥匙串。"""
import hashlib
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile

NAME = "Ermi Local Development"
DIRECTORY = Path.home() / "Library/Application Support/Ermi/signing"
CERTIFICATE = DIRECTORY / "certificate.der"
IDENTITY = DIRECTORY / "identity.sha1"


def run(args, **kwargs):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        # 不回显完整命令，避免临时封装密码进入日志。
        raise SystemExit(result.stderr.decode(errors="replace").strip() or "签名身份准备失败")
    return result.stdout


def main():
    os.umask(0o077)
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    if IDENTITY.exists():
        fingerprint = IDENTITY.read_text().strip()
        if not CERTIFICATE.exists() or hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest().upper() != fingerprint:
            raise SystemExit("本机签名配置不一致，请检查原证书；不会自动更换身份。")
        identities = run(["/usr/bin/security", "find-identity", "-p", "codesigning"]).decode()
        if fingerprint not in identities:
            raise SystemExit("原签名私钥不可用，请解锁或恢复钥匙串；不会生成新身份覆盖授权。")
        print("已复用本机签名身份：" + fingerprint)
        return
    # 中断后优先恢复已经导入的唯一同名身份，不盲目重复生成私钥。
    existing = subprocess.run(["/usr/bin/security", "find-certificate", "-c", NAME, "-p"], capture_output=True)
    if existing.returncode == 0:
        raise SystemExit("钥匙串已有同名证书但缺少本机配置，请先核实并恢复配置，避免重复身份。")
    openssl = shutil.which("openssl")
    if not openssl:
        raise SystemExit("找不到 openssl")
    keychain = run(["/usr/bin/security", "default-keychain", "-d", "user"]).decode().strip().strip('"')
    with tempfile.TemporaryDirectory(prefix="ermi-signing-") as temp:
        folder = Path(temp)
        config = folder / "certificate.cnf"
        config.write_text("""[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Ermi Local Development
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
""")
        key, cert, archive = [folder / name for name in ("key.pem", "certificate.pem", "identity.p12")]
        run([openssl, "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650",
             "-config", str(config), "-keyout", str(key), "-out", str(cert)])
        password = secrets.token_urlsafe(32)
        environment = dict(os.environ, ERMI_TEMP_P12_PASSWORD=password)
        run([openssl, "pkcs12", "-export", "-legacy", "-inkey", str(key), "-in", str(cert),
             "-name", NAME, "-out", str(archive), "-passout", "env:ERMI_TEMP_P12_PASSWORD"], env=environment)
        # 仅授权系统 codesign 使用，禁止导出私钥；不使用允许任意应用访问的 -A。
        run(["/usr/bin/security", "import", str(archive), "-k", keychain, "-f", "pkcs12",
             "-P", password, "-x", "-T", "/usr/bin/codesign"])
        der = run([openssl, "x509", "-in", str(cert), "-outform", "DER"])
        CERTIFICATE.write_bytes(der)
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        IDENTITY.write_text(fingerprint + "\n")
    print("本机签名身份已创建：" + fingerprint)
    print("私钥保留在用户钥匙串，临时私钥和封装文件已清理。")


if __name__ == "__main__":
    main()
