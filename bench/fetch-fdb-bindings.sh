#!/usr/bin/env bash
# The foundationdb image ships libfdb_c.so and python3 but not the Python bindings.
# They are pure Python (ctypes), so fetch the sdist next to this script.
set -eu
cd "$(dirname "$0")"
v=7.3.79
mkdir -p fdbpy
curl -sL "https://files.pythonhosted.org/packages/source/f/foundationdb/foundationdb-$v.tar.gz" \
  | tar -xz -C fdbpy --strip-components=1
echo "fdb bindings $v -> $(pwd)/fdbpy/fdb"
