#!/usr/bin/env python3
import argparse
import glob
import json
import os
import select
import subprocess
import sys
import termios
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path


def configure(fd, baud=115200):
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = attrs[2] | termios.CLOCAL | termios.CREAD
    attrs[3] = 0
    speed = getattr(termios, f"B{baud}")
    attrs[4] = speed
    attrs[5] = speed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/cu.wchusbserial*") + glob.glob("/dev/cu.usbserial*"))
    if not ports:
        raise SystemExit("No ESP32 serial port found. Pass --port /dev/cu.usbmodemXXXX.")
    return ports[0]


def write_status(fd, status):
    os.write(fd, (status + "\n").encode())


def read_lines(fd):
    buf = bytearray()
    while True:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            yield None
            continue
        chunk = os.read(fd, 256)
        if not chunk:
            yield None
            continue
        buf.extend(chunk)
        while b"\n" in buf:
            line, _, rest = buf.partition(b"\n")
            buf = bytearray(rest)
            yield line.decode(errors="replace").strip()


def run_ffmpeg(audio_device, duration, out_path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "avfoundation",
        "-i",
        f":{audio_device}",
        "-t",
        str(duration),
        "-ac",
        "1",
        "-ar",
        "16000",
        str(out_path),
    ]
    subprocess.run(cmd, check=True)
    if out_path.stat().st_size < 4000:
        raise RuntimeError(f"Recording too small: {out_path.stat().st_size} bytes")


def upload_recording(app_url, token, wav_path):
    cmd = [
        "curl",
        "-fsS",
        "--max-time",
        "300",
        "-X",
        "POST",
        f"{app_url.rstrip('/')}/api/hardware/ingest",
        "-F",
        f"recording=@{wav_path};type=audio/wav",
        "-F",
        "deviceId=arca-core-mac-bridge",
        "-F",
        f"recordedAt={datetime.utcnow().isoformat()}Z",
    ]
    if token:
        cmd.extend(["-H", f"x-arca-device-token: {token}"])
    return subprocess.run(cmd, text=True, capture_output=True)


def call_app_action(bridge_url, name, params=None, timeout=5.0):
    payload = json.dumps({"name": name, "params": params or {}}).encode()
    request = urllib.request.Request(
        f"{bridge_url.rstrip('/')}/action",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode()
    data = json.loads(body)
    if not data.get("ok"):
        raise RuntimeError(data.get("error") or body)
    return data.get("result") or {}


def set_app_transcription(bridge_url, enabled):
    return call_app_action(
        bridge_url,
        "toggle_transcription",
        {"enabled": "true" if enabled else "false"},
    )


def set_app_face(bridge_url, state):
    try:
        return call_app_action(bridge_url, "arca_set_face_state", {"state": state}, timeout=2.0)
    except Exception as exc:
        print(f"WARN: could not update app face to {state}: {exc}", file=sys.stderr)
        return {}


def generate_app_action_pack(bridge_url, trigger):
    return call_app_action(
        bridge_url,
        "arca_generate_action_pack_from_latest_recording",
        {"trigger": trigger},
        timeout=180.0,
    )


def parse_button_event(line):
    if line.startswith("ARCA_HOLD_RECORDING"):
        return "hold_start"
    if line.startswith("ARCA_BUTTON_UP_HOLD_STOP"):
        return "hold_stop"
    if line.startswith("ARCA_SHORT_PRESS_LATCHED"):
        return "short"
    if line.startswith("ARCA_BUTTON_STOP_LATCH"):
        return "short_stop"
    if line.startswith("ARCA_BUTTON_LONG"):
        return "long"
    if line.startswith("ARCA_BUTTON_SHORT") or line.startswith("ARCA_BUTTON_PRESS"):
        return "short"
    return None


def main():
    parser = argparse.ArgumentParser(description="Use ARCA Core button/OLED as a Mac recording remote.")
    parser.add_argument("--port", default=None, help="ESP32 serial port, for example /dev/cu.usbmodem2101")
    parser.add_argument("--mode", choices=["app-toggle", "mac-wav"], default=os.environ.get("ARCA_BUTTON_MODE", "app-toggle"), help="app-toggle controls ARCA Demo's live transcription; mac-wav records with ffmpeg and optionally uploads.")
    parser.add_argument("--bridge-url", default=os.environ.get("ARCA_DESKTOP_BRIDGE_URL", "http://127.0.0.1:47777"), help="ARCA Demo local automation bridge URL.")
    parser.add_argument("--audio-device", default=os.environ.get("ARCA_MAC_AUDIO_DEVICE", "2"), help="AVFoundation audio device index. MacBook Pro Microphone was 2 on this machine.")
    parser.add_argument("--duration", type=float, default=float(os.environ.get("ARCA_RECORD_SECONDS", "12")))
    parser.add_argument("--long-duration", type=float, default=float(os.environ.get("ARCA_LONG_RECORD_SECONDS", "0")), help="In app-toggle mode, 0 means long press toggles until the next long press; otherwise stop after this many seconds.")
    parser.add_argument("--out-dir", default=os.environ.get("ARCA_CAPTURE_DIR", "hardware/captures"))
    parser.add_argument("--app-url", default=os.environ.get("APP_URL", "http://localhost:4174"))
    parser.add_argument("--no-upload", action="store_true", help="Only save the WAV locally.")
    parser.add_argument("--token", default=os.environ.get("ARCA_HARDWARE_TOKEN", ""))
    args = parser.parse_args()

    port = args.port or find_port()
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure(fd)
        time.sleep(1.0)
        write_status(fd, "I")
        print(f"ARCA Mac recorder listening on {port}")
        if args.mode == "app-toggle":
            print(f"Mode app-toggle -> {args.bridge_url}")
            print(f"Short press: toggle app transcription. Hold: app transcription while held.")
        else:
            print(f"Mode mac-wav. Audio device :{args.audio_device}, duration {args.duration}s, out {args.out_dir}")
            print("Press the ARCA button to record from the Mac microphone.")

        app_recording = False

        for line in read_lines(fd):
            if line is None:
                continue
            if line:
                print(f"[device] {line}")
            button_event = parse_button_event(line)
            if button_event is None:
                continue

            if args.mode == "app-toggle":
                try:
                    set_app_face(args.bridge_url, "armed")
                    if button_event == "short":
                        write_status(fd, "R")
                        set_app_face(args.bridge_url, "recording")
                        print("ARCA app transcription ON")
                        set_app_transcription(args.bridge_url, True)
                        app_recording = True
                    elif button_event == "short_stop":
                        set_app_transcription(args.bridge_url, False)
                        app_recording = False
                        write_status(fd, "S")
                        set_app_face(args.bridge_url, "saved")
                        print("ARCA app transcription OFF")
                        result = generate_app_action_pack(args.bridge_url, "esp32_short_press_stop")
                        print(f"ARCA action pack: {result}")
                    elif button_event in ("hold_start", "long"):
                        if app_recording:
                            continue
                        app_recording = True
                        write_status(fd, "R")
                        set_app_face(args.bridge_url, "recording")
                        print("ARCA app transcription ON while held")
                        set_app_transcription(args.bridge_url, True)
                    elif button_event == "hold_stop":
                        if not app_recording:
                            continue
                        app_recording = False
                        set_app_transcription(args.bridge_url, False)
                        write_status(fd, "S")
                        set_app_face(args.bridge_url, "saved")
                        print("ARCA app transcription OFF")
                        result = generate_app_action_pack(args.bridge_url, "esp32_hold_release")
                        print(f"ARCA action pack: {result}")
                    else:
                        app_recording = not app_recording
                        write_status(fd, "R" if app_recording else "S")
                        set_app_face(args.bridge_url, "recording" if app_recording else "saved")
                        print(f"ARCA app transcription {'ON' if app_recording else 'OFF'}")
                        set_app_transcription(args.bridge_url, app_recording)
                        if not app_recording:
                            result = generate_app_action_pack(args.bridge_url, "esp32_long_press_stop")
                            print(f"ARCA action pack: {result}")
                        if app_recording and args.long_duration > 0:
                            time.sleep(args.long_duration)
                            set_app_transcription(args.bridge_url, False)
                            app_recording = False
                            write_status(fd, "S")
                            set_app_face(args.bridge_url, "saved")
                            print("ARCA app transcription OFF")
                            result = generate_app_action_pack(args.bridge_url, "esp32_long_press_timer")
                            print(f"ARCA action pack: {result}")
                except Exception as exc:
                    print(f"ERROR: app bridge failed: {exc}", file=sys.stderr)
                    write_status(fd, "E")
                    set_app_face(args.bridge_url, "error")
                continue

            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            wav_path = Path(args.out_dir) / f"arca-mac-{stamp}.wav"
            try:
                write_status(fd, "R")
                print(f"Recording -> {wav_path}")
                run_ffmpeg(args.audio_device, args.duration, wav_path)
                print(f"Saved {wav_path} ({wav_path.stat().st_size} bytes)")
                write_status(fd, "S")

                if not args.no_upload:
                    print(f"Uploading -> {args.app_url}/api/hardware/ingest")
                    response = upload_recording(args.app_url, args.token, wav_path)
                    if response.returncode == 0:
                        print(response.stdout.strip())
                        write_status(fd, "U")
                    else:
                        print(response.stderr.strip() or response.stdout.strip(), file=sys.stderr)
                        print("Upload failed, but the WAV is saved locally.", file=sys.stderr)
                        write_status(fd, "S")
            except Exception as exc:
                print(f"ERROR: {exc}", file=sys.stderr)
                write_status(fd, "E")
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
