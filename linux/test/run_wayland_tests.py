#!/usr/bin/env python3
"""Run native cursor tests in a private GNOME Wayland compositor (Linux only).

Requires g++, pkg-config, GTK 3 development files, GNOME Shell 46, dbus-run-session,
and an existing Linux Flutter engine directory containing libflutter_linux_gtk.so.
Usage: python3 linux/test/run_wayland_tests.py --flutter-engine /path/to/linux-x64
Artifacts are retained in the printed temporary directory. PNGs are input fixtures,
not screenshots. Protocol checks do not validate physical DRM cursor planes.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

TEST_TIMEOUT = 60
BUILD_TIMEOUT = 60
STARTUP_TIMEOUT = 20
STOP_TIMEOUT = 5
POLL_INTERVAL = 0.1
DISPLAY_NAME = "cursor-test-wayland"
BUS_NAME = "org.gnome.Mutter.RemoteDesktop"
BYTES_PER_PIXEL = 4
SHM_ARGB8888 = 0


def compile_test(engine, output):
    engine = engine.resolve(strict=True)
    for required in ("flutter_linux/flutter_linux.h", "libflutter_linux_gtk.so"):
        if not (engine / required).is_file():
            raise FileNotFoundError(engine / required)
    flags = subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "gtk+-3.0"], text=True,
        timeout=BUILD_TIMEOUT)
    command = ["g++", "-std=c++17", "-g", "-I", str(engine),
               str(Path(__file__).with_name("wayland_cursor_test.cc")),
               "-L", str(engine), f"-Wl,-rpath,{engine}", "-lflutter_linux_gtk",
               *shlex.split(flags), "-o", str(output / "wayland-cursor-test")]
    (output / "build-command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (output / "build.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=BUILD_TIMEOUT)


def private_environment(output):
    excluded = {"DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
                "DBUS_STARTER_ADDRESS", "DBUS_STARTER_BUS_TYPE", "WAYLAND_SOCKET",
                "GDK_SCALE", "GDK_DPI_SCALE", "WAYLAND_DEBUG"}
    inherited = {key: value for key, value in os.environ.items() if key not in excluded}
    paths = {"XDG_RUNTIME_DIR": "runtime", "XDG_CONFIG_HOME": "config",
             "XDG_CACHE_HOME": "cache", "XDG_DATA_HOME": "data"}
    for directory in paths.values():
        (output / directory).mkdir(mode=0o700)
    return {**inherited, **{key: str(output / value) for key, value in paths.items()},
            "WAYLAND_DISPLAY": DISPLAY_NAME, "GDK_BACKEND": "wayland",
            "GSETTINGS_BACKEND": "memory", "NO_AT_BRIDGE": "1"}


def terminate(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=STOP_TIMEOUT)
    except subprocess.TimeoutExpired:
        print(f"Process {process.pid} did not stop; killing private test process.",
              file=sys.stderr)
        process.kill()
        process.wait(timeout=STOP_TIMEOUT)


def wait_for_compositor(compositor, output):
    command = ["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
               "--object-path", "/org/freedesktop/DBus", "--method",
               "org.freedesktop.DBus.NameHasOwner", BUS_NAME]
    deadline = time.monotonic() + STARTUP_TIMEOUT
    while time.monotonic() < deadline:
        if compositor.poll() is not None:
            raise RuntimeError(f"Private compositor exited: {compositor.returncode}")
        result = subprocess.run(command, capture_output=True, text=True,
                                check=True, timeout=STOP_TIMEOUT)
        socket = Path(os.environ["XDG_RUNTIME_DIR"]) / DISPLAY_NAME
        # GNOME owns its bus names before its startup animation has completed.
        started = "GNOME Shell started at" in (output / "compositor.log").read_text()
        if "true" in result.stdout and socket.exists() and started:
            return
        time.sleep(POLL_INTERVAL)
    raise TimeoutError("Private compositor did not finish startup with its Wayland socket and D-Bus name")


def run_private_session(output):
    expected_runtime = str(output / "runtime")
    if os.environ.get("XDG_RUNTIME_DIR") != expected_runtime:
        raise RuntimeError("Refusing to run outside the private test runtime directory")
    command = ["gnome-shell", "--headless", "--wayland", "--no-x11",
               "--sm-disable", "--virtual-monitor=800x600",
               f"--wayland-display={DISPLAY_NAME}"]
    with (output / "compositor.log").open("w") as log:
        compositor = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for_compositor(compositor, output)
            with (output / "native.log").open("w") as stdout, \
                    (output / "wayland.log").open("w") as stderr:
                subprocess.run([str(output / "wayland-cursor-test"), str(output)],
                               env={**os.environ, "WAYLAND_DEBUG": "client"},
                               stdout=stdout, stderr=stderr, check=True,
                               timeout=TEST_TIMEOUT - STARTUP_TIMEOUT)
        finally:
            terminate(compositor)


def check_case(header, trace):
    name, width, height, scale, hot_x, hot_y = header.split()
    expected = tuple(map(int, (width, height, scale, hot_x, hot_y)))
    width, height, scale, hot_x, hot_y = expected
    buffers = re.findall(r"wl_shm_pool@\d+\.create_buffer\(new id wl_buffer@(\d+), "
                         r"\d+, (\d+), (\d+), (\d+), (\d+)\)", trace)
    matching = {buffer for buffer, w, h, stride, fmt in buffers
                if tuple(map(int, (w, h, stride, fmt))) ==
                (width, height, width * BYTES_PER_PIXEL, SHM_ARGB8888)}
    if not matching:
        raise AssertionError(f"{name}: no real ARGB buffer with dimensions {width}x{height}")
    cursors = re.findall(r"wl_pointer@\d+\.set_cursor\(\d+, wl_surface@(\d+), "
                         r"(-?\d+), (-?\d+)\)", trace)
    surfaces = {surface for surface, x, y in cursors
                if (int(x), int(y)) == (hot_x, hot_y)}
    for surface in surfaces:
        prefix = f"wl_surface@{surface}."
        attached = re.findall(re.escape(prefix) + r"attach\(wl_buffer@(\d+), 0, 0\)", trace)
        if (matching.intersection(attached) and
                prefix + f"set_buffer_scale({scale})" in trace and
                prefix + "commit()" in trace):
            return {"name": name, "buffer": [width, height], "scale": scale,
                    "hotspot": [hot_x, hot_y]}
    raise AssertionError(f"{name}: missing cursor attachment/commit, scale {scale}, "
                         f"or hotspot ({hot_x}, {hot_y}); observed cursors={cursors}")


def verify_protocol(output):
    compositor_log = (output / "compositor.log").read_text()
    if "CRITICAL" in compositor_log:
        raise AssertionError(f"GNOME reported a critical error; see {output / 'compositor.log'}")
    trace = (output / "wayland.log").read_text()
    if re.search(r"wl_display@\d+\.error\(", trace):
        raise AssertionError("The Wayland compositor reported a protocol error")
    blocks = re.findall(r"CURSOR_BEGIN ([^\n]+)\n(.*?)CURSOR_END ([^\n]+)",
                        trace, flags=re.DOTALL)
    cases = []
    for header, body, end in blocks:
        if header.split()[0] != end:
            raise AssertionError("Mismatched cursor test markers")
        cases.append(check_case(header, body))
    done = re.search(r"NATIVE_DONE accepted=(\d+) rejected=(\d+)",
                     (output / "native.log").read_text())
    if not done or not cases or len(cases) != int(done[1]):
        raise AssertionError("Native tests or cursor protocol records are incomplete")
    summary = {"backend": "GNOME Wayland (private headless compositor)",
               "protocol_cases": cases, "rejected_inputs": int(done[2]),
               "limits": ["Input PNGs are fixtures, not compositor screenshots.",
                          "No physical DRM plane, fractional output, or KDE coverage."]}
    (output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS: {len(cases)} Wayland protocol cases; {done[2]} rejected inputs")


def run_session_process(output, environment):
    command = ["dbus-run-session", "--", sys.executable, str(Path(__file__).resolve()),
               "--private-session", str(output)]
    with (output / "session.log").open("w") as log:
        process = subprocess.Popen(command, env=environment, start_new_session=True,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            if process.wait(timeout=TEST_TIMEOUT) != 0:
                raise RuntimeError(f"Wayland test session failed; see {output / 'session.log'}")
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            os.killpg(process.pid, signal.SIGTERM)
            terminate(process)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-engine", type=Path)
    parser.add_argument("--private-session", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("Native Wayland tests require Linux")
    if args.private_session:
        run_private_session(args.private_session.resolve(strict=True))
        return
    if args.flutter_engine is None:
        parser.error("--flutter-engine is required")
    output = Path(tempfile.mkdtemp(prefix="flutter-cursor-wayland-"))
    print(f"Artifacts: {output}", flush=True)
    compile_test(args.flutter_engine, output)
    run_session_process(output, private_environment(output))
    verify_protocol(output)


if __name__ == "__main__":
    main()
