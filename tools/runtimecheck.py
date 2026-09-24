"""Harmless denial probes for tools/check-runtime. Never read real credentials."""
import ctypes
import errno
import os
from pathlib import Path
import socket


def denied_open(path, flags):
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EACCES), (path, error.errno)
    else:
        os.close(descriptor)
        raise AssertionError(f"sandbox allowed open: {path}; no contents read or written")


# The launcher creates this harmless sentinel outside the readable repository.
# A run without the sandbox fails here, before any Mach or network probe.
sentinel = Path(os.environ["MAGNETITE_RUNTIME_PROBE"])
denied_open(sentinel, os.O_RDONLY)
denied_open(sentinel, os.O_WRONLY)
repo = Path(__file__).resolve().parent.parent
denied_open(repo / "README.md", os.O_WRONLY)
assert (repo / "README.md").read_bytes(), "repository input is unreadable"
assert set(os.environ) <= {
    "HOME", "LANG", "LC_ALL", "LC_CTYPE", "PATH", "TMPDIR",
    "CFFIXED_USER_HOME", "MAGNETITE_RUNTIME_PROBE", "PWD", "SHLVL", "_",
    # Apple's /usr/bin/python3 shim adds toolchain paths; Core Foundation may
    # add its text encoding. These are generated after the clean child launch.
    "CPATH", "LIBRARY_PATH", "MANPATH", "SDKROOT", "__CF_USER_TEXT_ENCODING",
}, "unexpected inherited environment variable"
fixture = Path(os.environ["TMPDIR"]) / "runtime-write-probe"
fixture.write_text("fixture")
assert fixture.read_text() == "fixture"
fixture.unlink()

# Look up service names only. No Keychain item or preference operation is sent.
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
bootstrap = ctypes.c_uint.in_dll(lib, "bootstrap_port").value
lib.bootstrap_look_up.argtypes = [ctypes.c_uint, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint)]
lib.bootstrap_look_up.restype = ctypes.c_int
for service in ("com.apple.SecurityServer", "com.apple.securityd.xpc",
                "com.apple.cfprefsd.agent", "com.apple.cfprefsd.daemon"):
    port = ctypes.c_uint(0)
    result = lib.bootstrap_look_up(bootstrap, service.encode(), ctypes.byref(port))
    assert result != 0 and port.value == 0, f"service lookup allowed: {service}"

for address in ("127.0.0.1", "192.0.2.1"):  # Loopback and RFC 5737 documentation address.
    with socket.socket() as connection:
        connection.settimeout(1)
        try:
            connection.connect((address, 9))
        except OSError as error:
            assert error.errno in (errno.EPERM, errno.EACCES), (address, error.errno)
        else:
            raise AssertionError(f"network allowed: {address}")

print("runtimecheck: personal state, service access, writes, environment and network isolated")
