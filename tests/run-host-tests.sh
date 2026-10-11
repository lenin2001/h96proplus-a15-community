#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d -t h96-host-tests.XXXXXX)"
trap 'rm -f -- "$test_dir/h96mouse" "$test_dir/test_remote" "$test_dir/test_nv12"; rmdir -- "$test_dir"' EXIT
cd "$repo_dir"
cc -std=gnu11 -Wall -Wextra -Werror device/h96proplus/h96mouse/h96mouse.c -o "$test_dir/h96mouse"
cc -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
    tests/test_remote.c -o "$test_dir/test_remote"
c++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
    tests/test_nv12.cpp -o "$test_dir/test_nv12"
"$test_dir/test_remote"
"$test_dir/test_nv12"
python3 tests/test_integration.py
# Unified diff context lines deliberately contain a single space.
git diff --check -- . ':(exclude)*.patch' ':(exclude)*.diff'
