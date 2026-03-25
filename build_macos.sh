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

# Paths
PROJECT_ROOT=$(pwd)
DEPS_INSTALL_DIR="$PROJECT_ROOT/deps"
mkdir -p "$DEPS_INSTALL_DIR"

# Fix for git clone in CI
export GIT_TERMINAL_PROMPT=0
# Disable interactive prompts for git
git config --global core.askPass "" || true

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

# Paths for dependency builds
QT_PATH=$(brew --prefix qt@5)
LIBOMP_PATH=$(brew --prefix libomp)
LIBARCHIVE_PATH=$(brew --prefix libarchive)

# Build librtprocess if not found in brew or local deps
if ! cmake --find-package -DNAME=rtprocess -DCOMPILER_ID=AppleClang -DLANGUAGE=CXX -DMODE=EXIST -DCMAKE_PREFIX_PATH="$DEPS_INSTALL_DIR" > /dev/null 2>&1; then
    echo "rtprocess (librtprocess) not found. Building from source..."
    TMP_RT_DIR="/tmp/librtprocess_build"
    rm -rf "$TMP_RT_DIR"

    # Official Filmulator-preferred fork
    CLONE_URL="https://github.com/CarVac/librtprocess.git"

    git clone --depth 1 "$CLONE_URL" "$TMP_RT_DIR"

    cd "$TMP_RT_DIR"
    mkdir -p build
    cd build
    # librtprocess also needs OpenMP help on macOS
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL_DIR" \
        -DOpenMP_CXX_FLAGS="-Xpreprocessor;-fopenmp;-I$LIBOMP_PATH/include" \
        -DOpenMP_CXX_LIB_NAMES="omp" \
        -DOpenMP_C_FLAGS="-Xpreprocessor;-fopenmp;-I$LIBOMP_PATH/include" \
        -DOpenMP_C_LIB_NAMES="omp" \
        -DOpenMP_omp_LIBRARY="$LIBOMP_PATH/lib/libomp.dylib" \
        -DOpenMP_libomp_LIBRARY="$LIBOMP_PATH/lib/libomp.dylib"
    make -j$(sysctl -n hw.ncpu) install
    cd "$PROJECT_ROOT"
fi

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

APP_DIR="Filmulator.app"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
EXE_PATH="$APP_DIR/Contents/MacOS/filmulator"

# Remove the wrapper script if it exists to avoid macdeployqt errors
if [ -f "$APP_DIR/Contents/MacOS/filmulator-gui" ]; then
    rm "$APP_DIR/Contents/MacOS/filmulator-gui"
fi

# Run macdeployqt to bundle Qt dependencies
echo "Running macdeployqt..."
$QT_PATH/bin/macdeployqt Filmulator.app -qmldir=../qml -verbose=2 -executable="$EXE_PATH"

# Manual fixup for non-Qt libraries
echo "Manually fixing non-Qt library references..."

# List of libraries we want to ensure are referenced relatively
LIBS_TO_FIX=(
    "libraw"
    "libexiv2"
    "liblensfun"
    "libarchive"
    "libomp"
    "librtprocess"
    "libjpeg"
    "libtiff"
    "libcurl"
    "libcrypto"
    "libssl"
)

# Ensure everything in Frameworks is writable
chmod -R +w "$FRAMEWORKS_DIR"

# Add @executable_path/../Frameworks to RPATH if not already there
echo "Fixing RPATH in binary..."
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE_PATH" || true

# 1. Update the executable to use @rpath/ for our libs
echo "Fixing references in binary..."
for lib_pattern in "${LIBS_TO_FIX[@]}"; do
    otool -L "$EXE_PATH" | grep -i "$lib_pattern" | awk '{print $1}' | while read -r CURRENT_REF; do
        if [ -z "$CURRENT_REF" ] || [[ "$CURRENT_REF" == "@executable_path"* ]] || [[ "$CURRENT_REF" == "@rpath"* ]]; then continue; fi
        
        if [[ "$CURRENT_REF" == /opt/homebrew* ]] || [[ "$CURRENT_REF" == /usr/local* ]] || [[ "$CURRENT_REF" == "$DEPS_INSTALL_DIR"* ]]; then
            LIB_NAME=$(basename "$CURRENT_REF")
            echo "  Fixing $lib_pattern: $CURRENT_REF -> @rpath/$LIB_NAME"
            install_name_tool -change "$CURRENT_REF" "@rpath/$LIB_NAME" "$EXE_PATH" || true
        fi
    done
done

# 2. Update the dylibs themselves
echo "Fixing dylibs..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -e "$dylib" ] || continue
    # Skip if not a Mach-O file
    if ! file "$dylib" | grep -q "Mach-O"; then continue; fi
    
    LIB_NAME=$(basename "$dylib")
    echo "  Processing $LIB_NAME..."
    
    # Fix ID to use @rpath
    install_name_tool -id "@rpath/$LIB_NAME" "$dylib" || true
    
    # Fix its own dependencies
    for lib_pattern in "${LIBS_TO_FIX[@]}"; do
        otool -L "$dylib" | grep -i "$lib_pattern" | awk '{print $1}' | while read -r CURRENT_REF; do
            if [ -z "$CURRENT_REF" ] || [[ "$CURRENT_REF" == "@executable_path"* ]] || [[ "$CURRENT_REF" == "@rpath"* ]]; then continue; fi
            
            if [[ "$CURRENT_REF" == /opt/homebrew* ]] || [[ "$CURRENT_REF" == /usr/local* ]] || [[ "$CURRENT_REF" == "$DEPS_INSTALL_DIR"* ]]; then
                DEP_NAME=$(basename "$CURRENT_REF")
                echo "    Fixing dependency $lib_pattern: $CURRENT_REF -> @rpath/$DEP_NAME"
                install_name_tool -change "$CURRENT_REF" "@rpath/$DEP_NAME" "$dylib" || true
            fi
        done
    done
done

# 3. Ad-hoc sign everything (Required for Apple Silicon after modifying binaries)
echo "Ad-hoc signing the bundle..."
# Sign dylibs first, then plugins, then the main app
find "$APP_DIR" -type f \( -name "*.dylib" -o -name "*.so" \) -exec codesign --force --verify --verbose --sign - {} \;
find "$APP_DIR/Contents/PlugIns" -type f -name "*.dylib" -exec codesign --force --verify --verbose --sign - {} \;
codesign --force --verify --verbose --sign - "$EXE_PATH"
codesign --force --verify --verbose --sign - "$APP_DIR"

# Create zip archive
echo "Creating zip archive..."
zip -r Filmulator-macOS-arm64.zip Filmulator.app

echo "Build complete! Binary at filmulator-gui/build/Filmulator-macOS-arm64.zip"
cd "$PROJECT_ROOT"
