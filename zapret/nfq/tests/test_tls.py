"""Offline TLS transfers through the real utunws parser and packet handler."""

import contextlib
import pathlib
import select
import socket
import ssl
import struct
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PAYLOAD = ROOT.parent / "payload"
HOST = "steamcloudsweden.blob.core.windows.net"
HOSTS = (HOST, "steamcloud-bkk.oss-ap-southeast-7.aliyuncs.com", "www.youtube.com", "discord.com")


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    value = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while value >> 16:
        value = (value & 65535) + (value >> 16)
    return ~value & 65535


def packet(seq, data=b"", syn=False, timestamps=False, ack=1000000):
    options = struct.pack("!BBIIH", 8, 10, 1000000, 999999, 0x0101) if timestamps else b""
    tcp = struct.pack("!HHIIBBHHH", 49152, 443, seq & 0xffffffff, 0 if syn else ack & 0xffffffff,
                      (5 + len(options) // 4) << 4, 2 if syn else 0x18, 65535, 0, 0)
    tcp += options + data
    addresses = socket.inet_aton("192.0.2.1") + socket.inet_aton("198.51.100.1")
    pseudo = addresses + struct.pack("!BBH", 0, 6, len(tcp))
    tcp = tcp[:16] + struct.pack("!H", checksum(pseudo + tcp)) + tcp[18:]
    ip = struct.pack("!BBHHHBBH", 0x45, 0, 20 + len(tcp), 0, 0x4000, 64, 6, 0) + addresses
    return ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:] + tcp


class Receiver:
    """An in-window, first-arrival TCP receiver, including PAWS when negotiated."""

    def __init__(self, timestamps):
        self.timestamps = timestamps
        self.next = 0
        self.pending = {}
        self.sent = 1000000
        self.future_acks = 0

    def receive(self, pkt):
        ihl = (pkt[0] & 15) * 4
        tcp = pkt[ihl:]
        length = (tcp[12] >> 4) * 4
        pseudo = pkt[12:20] + struct.pack("!BBH", 0, 6, len(tcp))
        if checksum(pseudo + tcp):
            return b""
        # RFC 9293 3.10.7.4: an old ACK can be ignored; a future ACK drops the segment.
        ack_delta = (struct.unpack("!I", tcp[8:12])[0] - self.sent) & 0xffffffff
        if 0 < ack_delta < 0x80000000:
            self.future_acks += 1
            return b""
        if self.timestamps:
            opts = tcp[20:length]
            if opts[:2] == b"\x08\x0a" and struct.unpack("!I", opts[2:6])[0] != 1000000:
                return b""
        start = (struct.unpack("!I", tcp[4:8])[0] - 1001) & 0xffffffff
        for offset, value in enumerate(tcp[length:], start):
            if self.next <= offset < self.next + 131072:
                self.pending.setdefault(offset, value)
        data = bytearray()
        while self.next in self.pending:
            data.append(self.pending.pop(self.next))
            self.next += 1
        return bytes(data)


class TLSReplayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="zapret-tls-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.work = pathlib.Path(cls.temp.name)
        cls.engine = cls.work / "replay"
        sources = [p for p in ROOT.glob("*.c") if p.name not in
                   ("nfqws.c", "macsend.c", "macos_utun.c")]
        subprocess.run(["clang", "-std=gnu99", "-O0", "-Wno-address-of-packed-member",
                        str(ROOT / "tests/replay.c"), *map(str, sources),
                        *map(str, (ROOT / "crypto").glob("*.c")), "-lz", "-o", str(cls.engine)],
                       check=True, capture_output=True)
        cls.cert, cls.key = cls.work / "cert.pem", cls.work / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(cls.key), "-out", str(cls.cert), "-days", "1",
                        "-subj", f"/CN={HOST}", "-addext", "subjectAltName=" +
                        ",".join("DNS:" + host for host in HOSTS)],
                       check=True, capture_output=True)

    def transfer(self, strategy="general-alt4", mode="any", timestamps=False,
                 version=ssl.TLSVersion.TLSv1_3, curve="X25519", host=HOST,
                 bypass=False, legacy_badack=False, initial_ack=1000000):
        config = (PAYLOAD / "strategies" / f"{strategy}.conf.in").read_text()
        config = config.replace("@BASE@", str(PAYLOAD)).replace("@LISTS@", str(PAYLOAD / "default-lists"))
        ipset = PAYLOAD / f"ipset-{mode}.txt"
        if mode == "loaded":
            ipset = self.work / "ipset-loaded.txt"
            ipset.write_text("198.51.100.1/32\n")
        config = config.replace("@IPSET@", str(ipset))
        if bypass:
            config = f"--filter-tcp=1-65535\n--hostlist-domains={host}\n--new\n" + config
        if legacy_badack:
            config = config.replace("--dpi-desync-fooling=badseq",
                                    "--dpi-desync-fooling=badseq\n--dpi-desync-badack-increment=-66000")
        config_path = self.work / "replay.conf"
        config_path.write_text(config)
        with contextlib.ExitStack() as cleanup:
            log = cleanup.enter_context((self.work / "engine.log").open("wb"))
            engine = subprocess.Popen([str(self.engine), "@" + str(config_path)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
            def close_engine():
                engine.stdin.close()
                try:
                    engine.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    engine.kill()
                    engine.wait()
                engine.stdout.close()
            cleanup.callback(close_engine)

            def read_exact(length):
                data = bytearray()
                while len(data) < length:
                    if not select.select([engine.stdout], [], [], 3)[0]:
                        self.fail("engine replay timed out")
                    part = engine.stdout.read(length - len(data))
                    if not part:
                        self.fail((self.work / "engine.log").read_text())
                    data.extend(part)
                return bytes(data)

            def replay(pkt):
                engine.stdin.write(struct.pack("!I", len(pkt)) + pkt)
                engine.stdin.flush()
                packets = []
                while True:
                    size = struct.unpack("!I", read_exact(4))[0]
                    if not size:
                        return packets
                    packets.append(read_exact(size))

            client_context = ssl.create_default_context(cafile=str(self.cert))
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(str(self.cert), str(self.key))
            client_context.minimum_version = client_context.maximum_version = version
            client_context.set_ecdh_curve(curve)
            server_context.minimum_version = server_context.maximum_version = version
            ci, co, si, so = (ssl.MemoryBIO() for _ in range(4))
            client = client_context.wrap_bio(ci, co, server_hostname=host)
            server = server_context.wrap_bio(si, so, server_side=True)
            receiver = Receiver(timestamps)
            receiver.sent = initial_ack
            seq = 1001
            replay(packet(1000, syn=True, timestamps=timestamps))

            def send():
                nonlocal seq
                data = co.read()
                for start in range(0, len(data), 1400):
                    part = data[start:start + 1400]
                    for output in replay(packet(seq, part, timestamps=timestamps, ack=receiver.sent)):
                        si.write(receiver.receive(output))
                    seq += len(part)

            for _ in range(10):
                for peer in (client, server):
                    try:
                        peer.do_handshake()
                    except ssl.SSLWantReadError:
                        pass
                    if peer is client:
                        send()
                    else:
                        data = so.read()
                        receiver.sent += len(data)
                        ci.write(data)
                if client.version() and server.version():
                    break
            self.assertIsNotNone(server.version(), "TLS handshake stalled")
            # A Cloud-like request with headers crosses the fake's +1000 sequence.
            request = b"GET /cloud/test HTTP/1.1\r\nHost: " + host.encode() + b"\r\nX-Test: " + b"a" * 3000 + b"\r\n\r\n"
            client.write(request)
            send()
            self.assertEqual(server.read(len(request)), request)
            response = b"test-save" * 512
            server.write(response)
            ci.write(so.read())
            self.assertEqual(client.read(len(response)), response)
            upload = b"test-upload" * 512
            client.write(upload)
            send()
            self.assertEqual(server.read(len(upload)), upload)
            if not legacy_badack:
                if bypass or (mode == "none" and host == HOST):
                    self.assertEqual(receiver.future_acks, 0)
                else:
                    self.assertGreater(receiver.future_acks, 0, "test did not exercise badseq fakes")

    def test_general_alt4_tls_transfers(self):
        for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
            for curve in ("X25519", "prime256v1"):
                for timestamps in (False, True):
                    with self.subTest(version=version.name, curve=curve, timestamps=timestamps):
                        self.transfer(version=version, curve=curve, timestamps=timestamps)

    def test_badseq_profiles_with_small_sequence_offsets(self):
        for strategy in ("general-alt8", "general-simple-fake-alt", "general-fake-tls-auto-alt"):
            with self.subTest(strategy=strategy):
                self.transfer(strategy=strategy)

    def test_general_alt4_none_tls13(self):
        self.transfer(mode="none")

    def test_general_alt4_loaded_tls13(self):
        self.transfer(mode="loaded")

    def test_cloud_and_service_profiles(self):
        for host in HOSTS:
            with self.subTest(host=host):
                self.transfer(host=host, mode="any" if host in HOSTS[:2] else "none")

    def test_site_bypass_takes_priority_over_any(self):
        self.transfer(bypass=True)

    def test_fake_ack_wraps(self):
        self.transfer(initial_ack=0xf0000000)

    def test_legacy_badack_corrupts_tls(self):
        with self.assertRaises(ssl.SSLError):
            self.transfer(legacy_badack=True)


if __name__ == "__main__":
    unittest.main()
