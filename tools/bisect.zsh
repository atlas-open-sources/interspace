#!/bin/zsh
# Runs space-probe against each interferer mode and prints how many switches landed wrong.
#   tools/bisect.zsh <folder with built space-probe and interferer> [modes…]
# Build first:  swiftc -O -o <bin>/space-probe tools/space-probe.swift
#               swiftc -O -o <bin>/interferer tools/interferer.swift
set -u
bin="$1"
shift
modes=("$@")
[[ ${#modes} -eq 0 ]] && modes=(none panel panel-front front key-listen key-tap)

for mode in $modes; do
  pid=""
  if [[ $mode != none ]]; then
    "$bin/interferer" "$mode" > "$bin/interferer-$mode.out" 2>&1 &
    pid=$!
    sleep 2
  fi
  wrong=0
  for round in 1 2 3; do
    count=$("$bin/space-probe" loop 2 1100 | awk '/^wrong/ {print $2}')
    wrong=$(( wrong + count ))
  done
  print "$mode: wrong $wrong of 12"
  if [[ -n $pid ]]; then
    kill "$pid"
    wait "$pid" 2>/dev/null
    sleep 1
  fi
done
