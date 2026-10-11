#!/usr/bin/env python3
"""Check URI/YAML/URI round trips without contacting a subscription provider.

Requires PyYAML. Pass --endpoint to test an existing deployed converter.
"""
import argparse
import base64
import pathlib
import socket
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

import yaml


def check(endpoint, directory):
    encryption = "mlkem768x25519plus.native.1rtt." + "a" * 1579
    params = dict(encryption=encryption, security="reality", sni="192.0.2.1",
                  fp="firefox", pbk="b" * 43, sid="0000000000001234", pqv="c" * 2603,
                  type="tcp")
    prefix = "vless://11111111-1111-4111-8111-111111111111@192.0.2.1:443?"
    source = prefix + urllib.parse.urlencode(params) + "#PQ-test"

    def convert(source, target="clash"):
        query = urllib.parse.urlencode(dict(target=target, url=source, list="true",
                                           insert="false", emoji="false", scv="false"))
        request = urllib.request.Request(endpoint + "/sub?" + query,
                                         headers={"User-Agent": "clash.meta"})
        return urllib.request.urlopen(request, timeout=30).read().decode()

    def node(source):
        return yaml.safe_load(convert(source))["proxies"][0]

    proxy = node(source)
    assert proxy["encryption"] == encryption
    assert proxy["client-fingerprint"] == "firefox"
    assert proxy["servername"] == params["sni"]
    assert proxy["reality-opts"]["short-id"] == params["sid"]
    assert proxy["reality-opts"]["support-x25519mlkem768"] is True
    assert proxy.get("skip-cert-verify") is not True
    assert "flow" not in proxy
    print("PASS URI -> Mihomo preserves PQ encryption, TLS MLKEM, fingerprint and authentication")

    for target in ("vless", "mixed"):
        exported = convert(source, target).strip()
        if not exported.startswith("vless://"):
            exported = base64.urlsafe_b64decode(exported + "=" * (-len(exported) % 4)).decode().strip()
        exported_params = urllib.parse.parse_qs(urllib.parse.urlsplit(exported).query)
        assert exported_params["encryption"] == [encryption]
        assert exported_params["pqv"] == [params["pqv"]]
        assert node(exported)["encryption"] == encryption
        print("PASS", target, "export -> import retains encryption and pqv")

    explicit = source.replace("#PQ-test", "&support-x25519mlkem768=false#PQ-test")
    assert node(explicit)["reality-opts"]["support-x25519mlkem768"] is False
    plain = prefix + urllib.parse.urlencode(dict(params, encryption="none")) + "#plain"
    assert "encryption" not in node(plain)
    assert "support-x25519mlkem768" not in node(plain)["reality-opts"]
    print("PASS explicit TLS setting and ordinary VLESS remain unchanged")

    if directory:
        path = directory / "input.yaml"
        proxy["reality-opts"]["support-x25519mlkem768"] = False
        path.write_text(yaml.safe_dump({"proxies": [proxy]}))
        result = node(str(path))
        assert result["reality-opts"].get("support-x25519mlkem768") is False, result["reality-opts"]
        exported = convert(str(path), "vless").strip()
        if not exported.startswith("vless://"):
            exported = base64.urlsafe_b64decode(exported + "=" * (-len(exported) % 4)).decode().strip()
        assert node(exported)["reality-opts"]["support-x25519mlkem768"] is False
        print("PASS YAML -> URI -> YAML retains explicit TLS MLKEM setting")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint")
    parser.add_argument("--fixture-dir", type=pathlib.Path,
                        help="optional directory also readable by the deployed converter")
    parser.add_argument("--binary", default=str(pathlib.Path(__file__).resolve().parents[1] / "build/subconverter"))
    args = parser.parse_args()
    if args.endpoint:
        check(args.endpoint.rstrip("/"), args.fixture_dir)
        return
    with tempfile.TemporaryDirectory(prefix="vless-pq-regression-") as temporary:
        directory = pathlib.Path(temporary)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        pref = directory / "pref.ini"
        pref.write_text("[common]\napi_mode=false\nenable_insert=false\n"
                        "[ruleset]\nenabled=false\n[server]\nlisten=127.0.0.1\nport=" + str(port))
        with (directory / "server.log").open("w") as log:
            process = subprocess.Popen([args.binary, "-f", str(pref)], cwd=directory,
                                       stdout=log, stderr=log)
            try:
                endpoint = "http://127.0.0.1:" + str(port)
                for _ in range(50):
                    try:
                        urllib.request.urlopen(endpoint + "/version", timeout=1)
                        break
                    except OSError:
                        if process.poll() is not None:
                            raise RuntimeError("converter failed to start")
                        time.sleep(.1)
                check(endpoint, directory)
            finally:
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
