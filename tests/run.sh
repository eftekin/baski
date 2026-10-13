#!/bin/zsh
# compiles main.swift with the test entry point and runs the parser tests
set -e
cd "${0:A:h}/.."
mkdir -p build
swiftc -D TEST -o build/tests main.swift tests/tests.swift 2>&1 | grep -E 'error' -A3 || true
build/tests tests/fixture.h264
