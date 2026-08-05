#!/bin/bash
# Reorder Nucore's configuration/CLI initialization without rebuilding it.
#
# The original flow parses argv and then reloads pb2k.cfg, erasing CLI video
# choices. This patch routes the existing parse call through a 10-byte
# trampoline in executable alignment padding:
#
#   loadAndValidatePB2KConfiguration();
#   jmp parseCommandLineArguments;
#
# It then NOPs the later duplicate load inside
# initializePB2KConfigurationAndHardware(), leaving its parallel-port and
# remaining hardware initialization in their original position.

set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

hex_at() {
    dd if="$1" bs=1 skip="$2" count="$3" status=none |
        od -An -tx1 -v | tr -d ' \n'
}

patch_one() {
    local file="$1"
    local expected_sha="$2"
    local actual_sha main_bytes init_bytes cave_bytes tmp

    main_bytes=$(hex_at "$file" $((0x306bf)) 5)
    init_bytes=$(hex_at "$file" $((0x0e705)) 5)
    cave_bytes=$(hex_at "$file" $((0x425c2)) 10)

    if [ "$main_bytes" = e8fe1e0100 ] &&
       [ "$init_bytes" = 9090909090 ] &&
       [ "$cave_bytes" = e8a800feffe9fcbafcff ]; then
        echo "$file: already patched"
        return
    fi

    actual_sha=$(sha256sum "$file" | awk '{print $1}')
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "$file: refusing unknown binary (sha256 $actual_sha)" >&2
        exit 1
    fi
    if [ "$main_bytes" != e804dafdff ] ||
       [ "$init_bytes" != e8653f0100 ] ||
       [ "$cave_bytes" != 90909090909090909090 ]; then
        echo "$file: refusing unexpected machine code" >&2
        exit 1
    fi

    tmp=$(mktemp "${file}.tmp.XXXXXX")
    cp -p -- "$file" "$tmp"

    # main call: parse_cli -> trampoline at 0x0808a5c2
    printf '\xe8\xfe\x1e\x01\x00' |
        dd of="$tmp" bs=1 seek=$((0x306bf)) conv=notrunc status=none
    # duplicate load_pb2k_cfg call inside the hardware wrapper -> five NOPs
    printf '\x90\x90\x90\x90\x90' |
        dd of="$tmp" bs=1 seek=$((0x0e705)) conv=notrunc status=none
    # executable code cave: call load_pb2k_cfg; jmp parse_cli
    printf '\xe8\xa8\x00\xfe\xff\xe9\xfc\xba\xfc\xff' |
        dd of="$tmp" bs=1 seek=$((0x425c2)) conv=notrunc status=none

    [ "$(hex_at "$tmp" $((0x306bf)) 5)" = e8fe1e0100 ]
    [ "$(hex_at "$tmp" $((0x0e705)) 5)" = 9090909090 ]
    [ "$(hex_at "$tmp" $((0x425c2)) 10)" = e8a800feffe9fcbafcff ]

    mv -f -- "$tmp" "$file"
    echo "$file: patched"
}

patch_one "$ROOT/bin/nucore" \
    83480e27cba13b09e7c2cd38b93457faa906b7ac112d4610cbd5d83246ddb734
patch_one "$ROOT/bin/nucore_nwd" \
    bb9749227ea3782b06fed0d5298da582c684a71fd17407cb5e14e6a6035bff4d
