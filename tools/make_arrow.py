"""Generate QuestRoute/arrow.tga: a 64x64 white arrow pointing UP, anti-aliased, transparent background.

WoW reads uncompressed 32-bit TGA with power-of-two sizes. White lets the addon tint it with SetVertexColor.
Run: python tools/make_arrow.py
"""
import pathlib
import struct

SIZE = 64
SS = 4  # supersamples per axis for anti-aliasing


def inside(x: float, y: float) -> bool:
    """x, y in 0..1, y=0 at the TOP. Arrow head is a triangle, then a shaft."""
    # head: apex (0.5, 0.06), base corners (0.12, 0.52) and (0.88, 0.52)
    if 0.06 <= y <= 0.52:
        half = (y - 0.06) / (0.52 - 0.06) * 0.38
        if abs(x - 0.5) <= half:
            return True
    # shaft
    return 0.52 <= y <= 0.94 and abs(x - 0.5) <= 0.13


def main() -> None:
    rows = []
    for py in range(SIZE):
        row = bytearray()
        for px in range(SIZE):
            hits = sum(
                inside((px + (sx + 0.5) / SS) / SIZE, (py + (sy + 0.5) / SS) / SIZE)
                for sx in range(SS)
                for sy in range(SS)
            )
            alpha = round(255 * hits / (SS * SS))
            row += bytes((255, 255, 255, alpha))  # BGRA
        rows.append(bytes(row))

    # descriptor 0x28 = 8 alpha bits + top-left origin, so rows are written top to bottom
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
    out = pathlib.Path(__file__).resolve().parent.parent / "QuestRoute" / "arrow.tga"
    out.write_bytes(header + b"".join(rows))
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
