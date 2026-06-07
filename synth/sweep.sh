#!/bin/sh
seed="$1"
shift

log="sweep_tmp/log_$seed"

"$@" --seed "$seed" --timing-allow-fail --textcfg /dev/null >"$log" 2>&1

mhz=$(grep "Max frequency for clock" "$log" | grep cpu_clk | tail -1 |
  grep -oE '[0-9]+\.[0-9]+ MHz' | head -1 | cut -d' ' -f1)

printf '%s %s\n' "${mhz:-0}" "$seed"
