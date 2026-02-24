#!/bin/bash
set -euo pipefail
set -x

: "${PYTHON_VERSION:?PYTHON_VERSION is required (example: cp311-cp311)}"
: "${PLAT:?PLAT is required (example: manylinux2014_x86_64)}"

# Clone GTSAM
# GTSAM_BRANCH="os-updates"
GTSAM_BRANCH="codex/rebase-4.3a1-os-compat"
EXPECTED_GTSAM_VERSION="4.3a1"
rm -rf /gtsam
git clone --depth 1 https://github.com/openspacelabs/gtsam.git -b "$GTSAM_BRANCH" /gtsam

# Set the build directory
BUILDDIR="/io/gtsam_build"
rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR"
cd "$BUILDDIR"

mkdir -p /io/wheelhouse
shopt -s nullglob
old_wheels=(/io/wheelhouse/gtsam-*.whl)
if [ ${#old_wheels[@]} -gt 0 ]; then
    rm -f "${old_wheels[@]}"
fi
shopt -u nullglob

PYBIN="/opt/python/$PYTHON_VERSION/bin"
PYVER_NUM_FULL=$($PYBIN/python -c "import sys;print(sys.version.split(\" \")[0])")
PYVER_NUM=${PYVER_NUM_FULL%.*}
PYTHONVER="$(basename $(dirname $PYBIN))"
# Wheel python tag must not contain '-' (e.g. cp311, not cp311-cp311).
WHEEL_PYTHON_TAG="${PYTHON_VERSION%%-*}"
if [ -z "$WHEEL_PYTHON_TAG" ]; then
    echo "ERROR: Could not derive wheel python tag from PYTHON_VERSION=$PYTHON_VERSION" >&2
    exit 1
fi

export PATH=$PYBIN:$PATH

${PYBIN}/pip install -r /io/requirements.txt
# setup.py in this GTSAM branch imports setuptools; manylinux cp311 images may not include it.
${PYBIN}/pip install "setuptools>=65" wheel

PYTHON_EXECUTABLE=${PYBIN}/python
# We use distutils to get the include directory and the library path directly from the selected interpreter
# We provide these variables to CMake to hint what Python development files we wish to use in the build.
PYTHON_INCLUDE_DIR=$(${PYTHON_EXECUTABLE} -c "from sysconfig import get_paths as gp; print(gp()['include'])")
PYTHON_LIBRARY=$(${PYTHON_EXECUTABLE} -c "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))")

echo ""
echo "PYBIN:${PYBIN}"
echo "PYVER_NUM:${PYVER_NUM}"
echo "PYTHON_EXECUTABLE:${PYTHON_EXECUTABLE}"
echo "PYTHON_INCLUDE_DIR:${PYTHON_INCLUDE_DIR}"
echo "PYTHON_LIBRARY:${PYTHON_LIBRARY}"
echo ""

set +e
cmake /gtsam -DCMAKE_BUILD_TYPE=Release \
    -DGTSAM_BUILD_TESTS=OFF -DGTSAM_BUILD_UNSTABLE=ON \
    -DGTSAM_USE_QUATERNIONS=OFF \
    -DGTSAM_BUILD_EXAMPLES_ALWAYS=OFF \
    -DGTSAM_ALLOW_DEPRECATED_SINCE_V42=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_PREFIX=$BUILDDIR/../gtsam_install \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBoost_USE_STATIC_RUNTIME=ON \
    -DBOOST_ROOT=/usr/local \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DBUILD_STATIC_METIS=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DGTSAM_BUILD_WITH_MARCH_NATIVE=OFF \
    -DGTSAM_WITH_TBB=OFF \
    -DGTSAM_BUILD_PYTHON=ON \
    -DGTSAM_PYTHON_VERSION=$PYVER_NUM;
ec=$?
set -e

if [ "$ec" -ne 0 ]; then
    echo "Error:"
    [ -f ./CMakeCache.txt ] && cat ./CMakeCache.txt
    exit $ec
fi

make -j$(nproc) install

cd python

"${PYBIN}/python" setup.py bdist_wheel --python-tag="$WHEEL_PYTHON_TAG" --plat-name="$PLAT"

shopt -s nullglob
dist_wheels=(./dist/*.whl)
shopt -u nullglob

if [ ${#dist_wheels[@]} -eq 0 ]; then
    echo "ERROR: No wheels were produced in $(pwd)/dist." >&2
    exit 1
fi

# Bundle external shared libraries into the wheels
for whl in "${dist_wheels[@]}"; do
    auditwheel repair "$whl" --plat "$PLAT" -w /io/wheelhouse/
done

shopt -s nullglob
repaired_wheels=(/io/wheelhouse/gtsam-*.whl)
shopt -u nullglob

if [ ${#repaired_wheels[@]} -eq 0 ]; then
    echo "ERROR: auditwheel did not produce any gtsam wheel in /io/wheelhouse." >&2
    exit 1
fi

if [ ${#repaired_wheels[@]} -ne 1 ]; then
    echo "ERROR: Expected exactly one repaired gtsam wheel candidate, got ${#repaired_wheels[@]}." >&2
    printf 'Candidate: %s\n' "${repaired_wheels[@]}" >&2
    exit 1
fi

source_wheel="${repaired_wheels[0]}"
source_wheel_name="$(basename "$source_wheel")"

if [[ "$source_wheel_name" != gtsam-* ]]; then
    echo "ERROR: Upstream produced unexpected wheel name format: $source_wheel_name (expected prefix gtsam-)" >&2
    exit 1
fi

version_and_rest="${source_wheel_name#gtsam-}"
wheel_version="${version_and_rest%%-*}"
wheel_base_version="${wheel_version%%+*}"

if [[ "$wheel_base_version" != "$EXPECTED_GTSAM_VERSION" ]]; then
    echo "ERROR: Upstream produced unexpected wheel version: ${wheel_version} (expected base ${EXPECTED_GTSAM_VERSION}; local suffix +... is allowed)" >&2
    exit 1
fi

case "$PLAT" in
    manylinux2014_x86_64)
        dual_suffix="-manylinux2014_x86_64.manylinux_2_17_x86_64.whl"
        normalized_suffix="-manylinux2014_x86_64.whl"
        ;;
    manylinux2014_aarch64)
        dual_suffix="-manylinux2014_aarch64.manylinux_2_17_aarch64.whl"
        normalized_suffix="-manylinux2014_aarch64.whl"
        ;;
    *)
        echo "ERROR: Unsupported PLAT for wheel name normalization: $PLAT" >&2
        exit 1
        ;;
esac

if [[ "$source_wheel_name" == *"$dual_suffix" ]]; then
    final_wheel_name="${source_wheel_name%"$dual_suffix"}${normalized_suffix}"
elif [[ "$source_wheel_name" == *"$normalized_suffix" ]]; then
    final_wheel_name="$source_wheel_name"
else
    echo "ERROR: Wheel has unexpected platform tags: $source_wheel_name" >&2
    exit 1
fi

FINAL_WHEEL="/io/wheelhouse/$final_wheel_name"
if [ "$source_wheel" != "$FINAL_WHEEL" ]; then
    mv "$source_wheel" "$FINAL_WHEEL"
fi

echo "Final wheel artifact: $FINAL_WHEEL"
