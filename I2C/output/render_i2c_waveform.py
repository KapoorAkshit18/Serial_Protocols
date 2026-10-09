"""Render the first I2C write transaction from i2c_tb.vcd."""

from pathlib import Path
import re

import matplotlib.pyplot as plt


HERE = Path(__file__).resolve().parent
VCD = HERE / "i2c_tb.vcd"
PNG = HERE / "i2c_simulation_waveform.png"


def read_vcd(path):
    ids = {}
    changes = {}
    in_defs = True
    now = 0
    for line in path.read_text(encoding="ascii", errors="replace").splitlines():
        if in_defs:
            m = re.match(r"\$var\s+\w+\s+\d+\s+(\S+)\s+(.+?)\s+\$end", line)
            if m:
                code, reference = m.groups()
                ids.setdefault(reference, code)
                ids.setdefault(reference.split()[0], code)
            if line.strip() == "$enddefinitions $end":
                in_defs = False
            continue
        if line.startswith("#"):
            now = int(line[1:])
        elif line and line[0] in "01xXzZ":
            value, code = line[0].lower(), line[1:].strip()
            changes.setdefault(code, []).append((now, value.lower()))
        elif line.startswith("b"):
            value, code = line[1:].split()
            changes.setdefault(code, []).append((now, value.lower()))
    return ids, changes


def scalar(changes, code, start, end):
    points = changes.get(code, [])
    before = [v for t, v in points if t <= start]
    times = [start / 1e6]
    initial = before[-1] if before else "0"
    values = [int(initial, 2) if all(c in "01" for c in initial) else 0]
    for t, value in points:
        if start < t <= end and value[-1] in "01":
            times.append(t / 1e6)
            values.append(int(value[-1]))
    times.append(end / 1e6)
    values.append(values[-1])
    return times, values


def main():
    ids, changes = read_vcd(VCD)
    # The first valid-address write begins shortly after reset and completes
    # after its address and data bytes plus ACK bits.
    start, end = 0, 315_000_000  # VCD timescale is 1 ps; display in us.
    rows = [
        ("SCL", "master_scl", 0),
        ("SDA (open drain)", "sda_bus", 1),
        ("Slave busy", "busy", 2),
        ("Receive pulse", "int_rx", 3),
        ("Received byte", "data_rx [7:0]", 4),
        ("LED", "led", 5),
    ]
    fig, ax = plt.subplots(figsize=(14, 5.6), constrained_layout=True)
    for label, signal, row in rows:
        code = ids[signal]
        xs, ys = scalar(changes, code, start, end)
        low, high = row + 0.16, row + 0.76
        if signal == "data_rx [7:0]":
            prev = None
            for t, value in changes.get(code, []):
                if start <= t <= end and all(c in "01" for c in value):
                    num = int(value, 2)
                    if num != prev:
                        ax.text(t / 1e6 + 1.2, row + 0.48, f"0x{num:02X}",
                                color="#0f766e", fontsize=9, va="center")
                    prev = num
            ax.hlines(row + 0.46, start / 1e6, end / 1e6, color="#0f766e", lw=1.8)
        else:
            ax.step(xs, [high - y * (high - low) for y in ys], where="post",
                    color="#0f766e" if signal in ("sda_bus", "led") else "#2457a6",
                    lw=1.35)
        ax.text(-2, row + 0.46, label, ha="right", va="center", fontsize=9)
        ax.axhline(row, color="#e5e7eb", lw=0.6, zorder=0)

    # The testbench stimulus for this first transaction is address 0x32/write,
    # data 0xAA, and slave ACKs on both bytes.
    for xpos, text in [
        (6, "START"), (35, "0x32 + W"), (136, "ACK"),
        (180, "0xAA"), (271, "ACK"), (296, "STOP"),
    ]:
        ax.text(xpos, -0.1, text, color="#374151", fontsize=9,
                weight="bold", ha="center")
    ax.set_xlim(0, end / 1e6)
    ax.set_ylim(len(rows) - 0.02, -0.35)
    ax.set_yticks([])
    ax.set_xlabel("Time (µs)")
    ax.set_title("I²C slave write: address ACK, 0xAA data, receive pulse, LED on",
                 loc="left", weight="bold")
    ax.set_xticks(range(0, int(end / 1e6) + 1, 15))
    ax.grid(axis="x", color="#e5e7eb", lw=0.6)
    for spine in ax.spines.values():
        spine.set_visible(False)
    fig.savefig(PNG, dpi=180, facecolor="white")
    print(PNG)


if __name__ == "__main__":
    main()
