#!/bin/bash
set -e

echo "Starting macOS build for Filmulator..."

# Ensure Homebrew is in path
if [[ $(arch) == "arm64" ]]; then
    HOMEBREW_PREFIX="/opt/homebrew"
else
    HOMEBREW_PREFIX="/usr/local"
fi
eval "$($HOMEBREW_PREFIX/bin/brew shellenv)"

# Fix for git clone in CI
export GIT_TERMINAL_PROMPT=0

# Help compilers find keg-only dependencies
export LDFLAGS="-L$HOMEBREW_PREFIX/opt/libarchive/lib -L$HOMEBREW_PREFIX/opt/curl/lib $LDFLAGS"
export CPPFLAGS="-I$HOMEBREW_PREFIX/opt/libarchive/include -I$HOMEBREW_PREFIX/opt/curl/include $CPPFLAGS"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/opt/libarchive/lib/pkgconfig:$HOMEBREW_PREFIX/opt/curl/lib/pkgconfig:$PKG_CONFIG_PATH"

# Dependencies
DEPENDENCIES=(
    "qt@5"
    "libraw"
    "lensfun"
    "exiv2"
    "libarchive"
    "libomp"
    "libjpeg-turbo"
    "libtiff"
    "curl"
    "pkg-config"
)

echo "Checking dependencies..."
for dep in "${DEPENDENCIES[@]}"; do
    if ! brew list --versions "$dep" > /dev/null; then
        echo "Installing $dep..."
        brew install "$dep"
    fi
done

# Paths
PROJECT_ROOT=$(pwd)
DEPS_INSTALL_DIR="$PROJECT_ROOT/deps"
mkdir -p "$DEPS_INSTALL_DIR"

# Build librtprocess if not found in brew or local deps
if ! cmake --find-package -DNAME=rtprocess -DCOMPILER_ID=AppleClang -DLANGUAGE=CXX -DMODE=EXIST -DCMAKE_PREFIX_PATH="$DEPS_INSTALL_DIR" > /dev/null 2>&1; then
    echo "rtprocess (librtprocess) not found. Building from source..."
    TMP_RT_DIR="/tmp/librtprocess_build"
    rm -rf "$TMP_RT_DIR"
    
    # Use plain HTTPS for public repo. 
    # Token-based URL caused "Repository not found" in CI.
    git clone --depth 1 https://github.com/Beep6581/librtprocess.git "$TMP_RT_DIR" || \
    git clone --depth 1 https://github.com/CarVac/librtprocess.git "$TMP_RT_DIR"
    
    cd "$TMP_RT_DIR"
    mkdir build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL_DIR"
    make -j$(sysctl -n hw.ncpu) install
    cd "$PROJECT_ROOT"
fi

# Paths for Filmulator build
QT_PATH=$(brew --prefix qt@5)
LIBOMP_PATH=$(brew --prefix libomp)
LIBARCHIVE_PATH=$(brew --prefix libarchive)

# Build Filmulator
cd filmulator-gui
rm -rf build
mkdir -p build
cd build

echo "Configuring with CMake..."
# On macOS with AppleClang, FindOpenMP often needs help.
cmake ../ \
    -DCMAKE_BUILD_TYPE="RELEASE" \
    -DCMAKE_PREFIX_PATH="$QT_PATH;$DEPS_INSTALL_DIR;$LIBARCHIVE_PATH;$HOMEBREW_PREFIX" \
    -DOpenMP_CXX_FLAGS="-Xpreprocessor;-fopenmp;-I$LIBOMP_PATH/include" \
    -DOpenMP_CXX_LIB_NAMES="omp" \
    -DOpenMP_C_FLAGS="-Xpreprocessor;-fopenmp;-I$LIBOMP_PATH/include" \
    -DOpenMP_C_LIB_NAMES="omp" \
    -DOpenMP_omp_LIBRARY="$LIBOMP_PATH/lib/libomp.dylib" \
    -DOpenMP_libomp_LIBRARY="$LIBOMP_PATH/lib/libomp.dylib" \
    -G "Unix Makefiles"

echo "Compiling..."
make -j$(sysctl -n hw.ncpu) install

# Run macdeployqt to bundle Qt dependencies
echo "Running macdeployqt..."
$QT_PATH/bin/macdeployqt Filmulator.app -qmldir=../qml -verbose=2

# Create zip archive
echo "Creating zip archive..."
zip -r Filmulator-macOS-arm64.zip Filmulator.app

echo "Build complete! Binary at filmulator-gui/build/Filmulator-macOS-arm64.zip"
cd "$PROJECT_ROOT"
