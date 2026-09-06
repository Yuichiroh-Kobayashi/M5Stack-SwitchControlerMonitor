#!/usr/bin/env python3
"""Reference codec and self-tests for CoRE Control Protocol Draft v1."""

from __future__ import annotations

import argparse
import binascii
import struct

FRAME_SIZE = 32
MAGIC = b"CR"
VERSION = 1
CONTROL = 0x01
STATUS = 0x02


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def finish(frame: bytearray) -> bytes:
    frame[30:32] = struct.pack(">H", crc16(frame[:30]))
    return bytes(frame)


def control_frame(sequence: int = 0x1234, uptime_ms: int = 0x01020304) -> bytes:
    frame = bytearray(FRAME_SIZE)
    struct.pack_into(">2sBBHI", frame, 0, MAGIC, VERSION, CONTROL, sequence, uptime_ms)
    struct.pack_into(">HHBBBBBBBB", frame, 10, 0, 0, 8, 128, 128, 128, 128, 0, 0, 255)
    return finish(frame)


def status_frame(sequence: int = 0xABCD, uptime_ms: int = 0x10203040) -> bytes:
    frame = bytearray(FRAME_SIZE)
    struct.pack_into(">2sBBHI", frame, 0, MAGIC, VERSION, STATUS, sequence, uptime_ms)
    # receiver_ready | control_timeout, no last control, battery unknown, UART enabled
    struct.pack_into(">HHHHHBBH", frame, 10, 0x0005, 0, 0xFFFF, 0, 0, 255, 1, 0)
    return finish(frame)


def uart_control_frame(sequence: int, receiver_uptime_ms: int,
                       source: bytes | None, source_age_ms: int,
                       force_neutral: bool = False) -> bytes:
    """Receiver-owned UART header; never renew source age by retransmission."""
    if source_age_ms < 0:
        raise ValueError('negative source age')
    frame = bytearray(control_frame(sequence, receiver_uptime_ms))
    if source is not None:
        decoded = decode(source)
        if decoded['message_type'] != CONTROL:
            raise ValueError('UART source must be CONTROL')
        if not force_neutral and source_age_ms < 100 and decoded['control_flags'] & 1:
            frame[10:22] = source[10:22]
    return finish(frame)


def decode(frame: bytes) -> dict[str, int | bytes]:
    if len(frame) != FRAME_SIZE:
        raise ValueError("bad length")
    if frame[:2] != MAGIC:
        raise ValueError("bad magic")
    if frame[2] != VERSION:
        raise ValueError("bad version")
    if frame[3] not in (CONTROL, STATUS):
        raise ValueError("bad message type")
    if struct.unpack_from(">H", frame, 30)[0] != crc16(frame[:30]):
        raise ValueError("bad CRC")
    result: dict[str, int | bytes] = {
        "message_type": frame[3],
        "sequence": struct.unpack_from(">H", frame, 4)[0],
        "uptime_ms": struct.unpack_from(">I", frame, 6)[0],
        "reserved": frame[22:30] if frame[3] == CONTROL else frame[24:30],
    }
    if frame[3] == CONTROL:
        result.update(
            control_flags=struct.unpack_from(">H", frame, 10)[0],
            buttons=struct.unpack_from(">H", frame, 12)[0],
            dpad=frame[14], left_x=frame[15], left_y=frame[16],
            right_x=frame[17], right_y=frame[18], left_trigger=frame[19],
            right_trigger=frame[20], battery=frame[21],
        )
        if frame[14] > 8:
            raise ValueError("bad dpad")
        if frame[21] > 100 and frame[21] != 255:
            raise ValueError("bad battery")
    else:
        result.update(
            status_flags=struct.unpack_from(">H", frame, 10)[0],
            last_control_sequence=struct.unpack_from(">H", frame, 12)[0],
            control_age_ms=struct.unpack_from(">H", frame, 14)[0],
            sequence_gap_count=struct.unpack_from(">H", frame, 16)[0],
            invalid_frame_count=struct.unpack_from(">H", frame, 18)[0],
            battery=frame[20], uart_state=frame[21],
            error_code=struct.unpack_from(">H", frame, 22)[0],
        )
    return result


def expect_error(frame: bytes, text: str) -> None:
    try:
        decode(frame)
    except ValueError as exc:
        assert text in str(exc), (text, exc)
    else:
        raise AssertionError(f"expected {text}")


def self_test() -> None:
    control = control_frame()
    status = status_frame()
    assert decode(control)["dpad"] == 8
    assert decode(status)["uart_state"] == 1
    bad = bytearray(control); bad[0] ^= 1; expect_error(bytes(bad), "magic")
    bad = bytearray(control); bad[2] = 2; bad = bytearray(finish(bad)); expect_error(bytes(bad), "version")
    bad = bytearray(control); bad[15] ^= 1; expect_error(bytes(bad), "CRC")
    bad = bytearray(control); bad[14] = 9; bad = bytearray(finish(bad)); expect_error(bytes(bad), "dpad")
    reserved = bytearray(control); reserved[22] = 0xA5; reserved = bytearray(finish(reserved))
    assert decode(bytes(reserved))["reserved"][0] == 0xA5
    assert crc16(b"123456789") == 0x29B1
    print("PROTOCOL_REFERENCE_SELF_TEST=OK")
    print("CONTROL_GOLDEN=" + binascii.hexlify(control).decode().upper())
    print("STATUS_GOLDEN=" + binascii.hexlify(status).decode().upper())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decode", metavar="HEX", help="decode one 32-byte hexadecimal frame")
    args = parser.parse_args()
    if args.decode:
        for key, value in decode(bytes.fromhex(args.decode)).items():
            print(f"{key}={value.hex().upper() if isinstance(value, bytes) else value}")
    else:
        self_test()


if __name__ == "__main__":
    main()
