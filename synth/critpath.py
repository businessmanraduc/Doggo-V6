# critpath.py - pulls the Fmax and the critical path out of a nextpnr log.
# usage: python3 critpath.py soc.timing.log

import sys

# trim nextpnr's long mangled cell/net name down to the signal it came from
def short(name):
    name = name.replace("u_cpu.u_core.", "").replace("u_cpu.", "")
    if name.startswith("$nextpnr"):
        return "carry"
    for cut in ("_TRELLIS", "_LUT", "_PFUMX", "_L6MUX", "_CCU2", "_MULT", "_DI_", "$", "["):
        if cut in name:
            name = name[:name.index(cut)]
    return name or "?"

lines = open(sys.argv[1]).read().splitlines()

# --- Fmax: last "Max frequency" line per clock is the one after routing ---
fmax = {}
for line in lines:
    if "Max frequency for clock" in line:
        clk = line.split("'")[1].replace("$glbnet$", "")
        mhz = line.split(":")[-1].split("MHz")[0].split()[-1]
        fmax[clk] = mhz

# --- grab the cpu_clk critical path block ---
hops = []      # (type, this_delay, running_total, name)
split = ""     # the "x ns logic, y ns routing" summary line
inside = False
for line in lines:
    if "Critical path report for clock" in line and "cpu_clk" in line:
        inside = True
        continue
    if inside:
        if "ns logic," in line:
            split = line.split("Info:")[-1].strip()
            break
        w = line.split()
        if len(w) >= 6 and w[1] in ("clk-to-q", "routing", "logic", "setup"):
            hops.append((w[1], float(w[2]), float(w[3]), short(w[5])))

# --- merge neighbouring hops on the same signal (collapses the carry chains) ---
rows = []      # [delay, total, name, is_endpoint]
for kind, delay, total, name in hops:
    endpoint = kind in ("clk-to-q", "setup")
    if not endpoint and rows and not rows[-1][3] and rows[-1][2] == name:
        rows[-1][0] += delay
        rows[-1][1] = total
    else:
        rows.append([delay, total, name, endpoint])

# --- print ---
print()
for clk, mhz in fmax.items():
    print("Fmax  %s : %s MHz" % (clk, mhz))
print()

if not hops:
    print("no cpu_clk path found in the log")
    sys.exit()

end = rows[-1][1]
print("critical path : %.2f ns  ->  %.1f MHz" % (end, 1000.0 / end))
if split:
    print(split)
print()

worst = max(r[0] for r in rows if not r[3])
print("    ns   cumul   signal")
for i, (delay, total, name, endpoint) in enumerate(rows):
    tag = ""
    if i == 0:
        tag = "  (start)"
    elif i == len(rows) - 1:
        tag = "  (end)"
    elif delay == worst:
        tag = "  <= worst"
    print("  %5.2f  %6.2f   %s%s" % (delay, total, name, tag))
