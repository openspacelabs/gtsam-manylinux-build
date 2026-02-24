#!/bin/bash
set -euo pipefail
set -x

# Install a system package required by our library
yum install -y wget libicu libicu-devel

CURRDIR=$(pwd)

# # Build Boost staticly
# mkdir -p boost_build
# cd boost_build
# # The jfrog is no longer active as on Feb 9th 2026, going back the boost archives
# # wget https://boostorg.jfrog.io/artifactory/main/release/1.65.1/source/boost_1_65_1.tar.gz
# wget https://archives.boost.io/release/1.65.1/source/boost_1_65_1.tar.gz
# tar xzf boost_1_65_1.tar.gz
# cd boost_1_65_1
# ./bootstrap.sh --with-libraries=serialization,filesystem,thread,system,atomic,date_time,timer,chrono,program_options,regex
# ./b2 -j$(nproc) cxxflags="-fPIC" runtime-link=static variant=release link=static install



# Build Boost staticly
mkdir -p boost_build
cd boost_build
wget https://archives.boost.io/release/1.90.0/source/boost_1_90_0.tar.gz
tar xzf boost_1_90_0.tar.gz
cd boost_1_90_0
./bootstrap.sh --with-libraries=serialization,filesystem,thread,system,atomic,date_time,timer,chrono,program_options,regex
./b2 -j$(nproc) cxxflags="-fPIC" runtime-link=static variant=release link=static install











cd $CURRDIR

PYTHON_LIBRARY=$(cd $(dirname $0); pwd)/libpython-not-needed-symbols-exported-by-interpreter
touch ${PYTHON_LIBRARY}

# FIX auditwheel
# https://github.com/pypa/auditwheel/issues/136
shopt -s nullglob
auditwheel_candidates=(
    /opt/_internal/cpython-*/lib/python*/site-packages/auditwheel
    /opt/_internal/pipx/venvs/auditwheel/lib/python*/site-packages/auditwheel
    /usr/local/lib/python*/site-packages/auditwheel
)
shopt -u nullglob

if [ ${#auditwheel_candidates[@]} -eq 0 ]; then
    echo "ERROR: Unable to locate auditwheel site-packages directory." >&2
    exit 1
fi

AUDITWHEEL_DIR="${auditwheel_candidates[0]}"
cd "$AUDITWHEEL_DIR"
AUDITWHEEL_PATCH="/io/auditwheel.txt"
if [ -f "$AUDITWHEEL_PATCH" ]; then
    if patch --batch --forward -p2 < "$AUDITWHEEL_PATCH"; then
        echo "Applied auditwheel legacy patch in $AUDITWHEEL_DIR"
    elif patch --batch --dry-run --reverse -p2 < "$AUDITWHEEL_PATCH" >/dev/null 2>&1; then
        echo "Auditwheel legacy patch already present in $AUDITWHEEL_DIR"
    else
        echo "WARN: Legacy auditwheel patch does not match current auditwheel; skipping." >&2
    fi
else
    echo "INFO: /io/auditwheel.txt not found; skipping legacy auditwheel patch."
fi
cd "$CURRDIR"

mkdir -p /io/wheelhouse

echo "fix-wheels.sh completed setup. Wheel repair happens in build-wheels-new.sh."

# Install packages and test
# for PYBIN in /opt/python/*/bin/; do
#     "${PYBIN}/pip" install python-manylinux-demo --no-index -f /io/wheelhouse
#     (cd "$HOME"; "${PYBIN}/nosetests" pymanylinuxdemo)
# done
