"""
Minimal FLAC container parsing for byte-accurate seeking.

Why this exists: HEOS has no native seek command at all (see
HeosClient.seek_via_reload), so a "seek" here means re-requesting the track
from a byte offset via play_stream. A proportional byte guess alone doesn't
work for FLAC - every valid FLAC stream needs its header (the "fLaC" magic
plus a STREAMINFO metadata block) before a decoder can make sense of any
audio frame after it, and a raw mid-file slice has neither. This module
parses that header once per track, and - when the file has a SEEKTABLE
metadata block, as most professionally-encoded FLAC does - uses it to get an
exact, frame-aligned byte offset for a given time. Without a SEEKTABLE, it
falls back to a proportional guess followed by a scan for the next frame
sync code, which is not guaranteed but works in practice.
"""

from dataclasses import dataclass, field
from typing import Optional

FLAC_MAGIC = b"fLaC"
STREAMINFO_BLOCK_TYPE = 0
SEEKTABLE_BLOCK_TYPE = 3
PLACEHOLDER_SAMPLE_NUMBER = 0xFFFFFFFFFFFFFFFF


@dataclass
class FlacSeekInfo:
    header: bytes  # bytes 0..audio_data_offset, i.e. magic + all metadata blocks
    audio_data_offset: int  # absolute byte offset where frame data begins
    sample_rate: int
    total_samples: int
    # (sample_number, byte_offset_from_audio_data_start, frame_samples), sorted
    seekpoints: list = field(default_factory=list)


def parse_flac_header(data: bytes) -> Optional[FlacSeekInfo]:
    """Parse metadata blocks from the start of a FLAC file.

    Returns None if `data` doesn't start with the FLAC magic, or doesn't yet
    contain the complete metadata block chain (caller should fetch more).
    """
    if not data.startswith(FLAC_MAGIC):
        return None

    pos = 4
    sample_rate = 0
    total_samples = 0
    seekpoints = []

    while pos + 4 <= len(data):
        block_header = data[pos]
        is_last = bool(block_header & 0x80)
        block_type = block_header & 0x7F
        length = int.from_bytes(data[pos + 1 : pos + 4], "big")
        block_start = pos + 4
        block_end = block_start + length
        if block_end > len(data):
            return None  # incomplete - caller should fetch a larger window
        block_data = data[block_start:block_end]

        if block_type == STREAMINFO_BLOCK_TYPE and len(block_data) >= 18:
            sample_rate = int.from_bytes(block_data[10:13], "big") >> 4
            total_samples = ((block_data[13] & 0x0F) << 32) | int.from_bytes(
                block_data[14:18], "big"
            )
        elif block_type == SEEKTABLE_BLOCK_TYPE:
            for i in range(length // 18):
                off = i * 18
                sample_number = int.from_bytes(block_data[off : off + 8], "big")
                if sample_number == PLACEHOLDER_SAMPLE_NUMBER:
                    continue  # unused placeholder point
                byte_offset = int.from_bytes(block_data[off + 8 : off + 16], "big")
                frame_samples = int.from_bytes(block_data[off + 16 : off + 18], "big")
                seekpoints.append((sample_number, byte_offset, frame_samples))

        pos = block_end
        if is_last:
            return FlacSeekInfo(
                header=data[:pos],
                audio_data_offset=pos,
                sample_rate=sample_rate,
                total_samples=total_samples,
                seekpoints=sorted(seekpoints),
            )

    return None  # never hit the last-metadata-block flag - fetch more


def find_seek_byte_offset(info: FlacSeekInfo, position_ms: int) -> Optional[int]:
    """Absolute byte offset to start streaming from for ~position_ms.

    Returns None (frame-exact answer unavailable) when there's no usable
    SEEKTABLE - caller should fall back to a proportional guess plus a frame
    sync scan.
    """
    if info.sample_rate <= 0 or not info.seekpoints:
        return None
    target_sample = int((position_ms / 1000) * info.sample_rate)
    best = info.seekpoints[0]
    for point in info.seekpoints:
        if point[0] <= target_sample:
            best = point
        else:
            break
    return info.audio_data_offset + best[1]


def find_next_frame_sync(data: bytes, start: int = 0) -> int:
    """Scan for a FLAC frame sync code (0xFF F8/F9) from `start`.

    Returns the offset within `data`, or -1 if none found. Not a full frame
    header validation (no CRC check) - a practical heuristic, not a
    guarantee, used only when no SEEKTABLE is available.
    """
    for i in range(start, len(data) - 1):
        if data[i] == 0xFF and (data[i + 1] & 0xFE) == 0xF8:
            return i
    return -1
