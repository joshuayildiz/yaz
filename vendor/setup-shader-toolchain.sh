#!/bin/sh
# Fetches the shader compiler into vendor/toolchain. Invoked by `zig build`.
#
#   setup-shader-toolchain.sh spirv   glslang only  (Linux and Windows targets)
#   setup-shader-toolchain.sh msl     adds SPIRV-Cross and SDL_shadercross (macOS)
#
# Idempotent: re-running with an already-satisfied target does nothing.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFIX="$ROOT/vendor/toolchain"
SRC="$ROOT/vendor/src"

# Pinned, so the same sources always produce the same bytecode.
GLSLANG_VERSION="16.5.0"
SDL_TAG="release-3.4.14"
CMAKE_VERSION="4.4.3"

WANT=${1:-spirv}

case "$(uname -s)" in
    Linux)
        GLSLANG_ARCHIVE="glslang-$GLSLANG_VERSION-linux-x86_64-release.tar.gz"
        CMAKE_ARCHIVE="cmake-$CMAKE_VERSION-linux-x86_64.tar.gz"
        ;;
    Darwin)
        GLSLANG_ARCHIVE="glslang-$GLSLANG_VERSION-macos-universal-release.tar.gz"
        CMAKE_ARCHIVE="cmake-$CMAKE_VERSION-macos-universal.tar.gz"
        ;;
    *)
        echo "setup-shader-toolchain: unsupported host '$(uname -s)'." >&2
        echo "Shaders are compiled during the build; see README.md." >&2
        exit 1
        ;;
esac

# glslang compiles GLSL to SPIR-V, and is all that Vulkan and D3D12 targets need.
if [ ! -x "$PREFIX/bin/glslang" ]; then
    echo ">> fetching glslang $GLSLANG_VERSION"
    command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
    mkdir -p "$SRC" "$PREFIX"
    curl -fsSL --retry 3 -o "$SRC/glslang.tar.gz" \
        "https://github.com/KhronosGroup/glslang/releases/download/$GLSLANG_VERSION/$GLSLANG_ARCHIVE"
    tar -xzf "$SRC/glslang.tar.gz" -C "$PREFIX"
    rm -f "$SRC/glslang.tar.gz"
fi

[ "$WANT" = "msl" ] || exit 0

# Metal needs SPIR-V translated to MSL. SDL_shadercross wraps SPIRV-Cross with
# the binding conventions SDL's Metal backend expects, so use it rather than
# driving SPIRV-Cross directly. Built without DXC: the HLSL front end it exists
# for is not needed now that shaders are authored in GLSL.
if [ -x "$PREFIX/shadercross" ]; then
    exit 0
fi

echo ">> building the Metal shader translator (this takes a few minutes)"
for tool in git c++; do
    command -v "$tool" >/dev/null 2>&1 || { echo "'$tool' is required for macOS builds" >&2; exit 1; }
done
mkdir -p "$SRC"

if command -v cmake >/dev/null 2>&1; then
    CMAKE=cmake
else
    CMAKE="$PREFIX/cmake/bin/cmake"
    if [ ! -x "$CMAKE" ]; then
        curl -fsSL --retry 3 -o "$SRC/cmake.tar.gz" \
            "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/$CMAKE_ARCHIVE"
        mkdir -p "$PREFIX/cmake"
        # The macOS archive nests everything under CMake.app.
        tar -xzf "$SRC/cmake.tar.gz" -C "$PREFIX/cmake" --strip-components=1
        [ -d "$PREFIX/cmake/CMake.app" ] && CMAKE="$PREFIX/cmake/CMake.app/Contents/bin/cmake"
    fi
fi

# shadercross links SDL for I/O and logging; it never opens a window, so
# UNIX_CONSOLE_BUILD skips the desktop-video dependency check.
if [ ! -f "$PREFIX/lib/libSDL3.so" ] && [ ! -f "$PREFIX/lib/libSDL3.dylib" ]; then
    [ -d "$SRC/SDL" ] || git clone -q --depth 1 -b "$SDL_TAG" https://github.com/libsdl-org/SDL.git "$SRC/SDL"
    "$CMAKE" -S "$SRC/SDL" -B "$SRC/SDL/build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DSDL_SHARED=ON -DSDL_STATIC=OFF \
        -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_X11=OFF -DSDL_WAYLAND=OFF \
        -DSDL_UNIX_CONSOLE_BUILD=ON >/dev/null
    "$CMAKE" --build "$SRC/SDL/build" -j >/dev/null
    "$CMAKE" --install "$SRC/SDL/build" >/dev/null
fi

[ -d "$SRC/SPIRV-Cross" ] || git clone -q --depth 1 https://github.com/KhronosGroup/SPIRV-Cross.git "$SRC/SPIRV-Cross"
"$CMAKE" -S "$SRC/SPIRV-Cross" -B "$SRC/SPIRV-Cross/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
"$CMAKE" --build "$SRC/SPIRV-Cross/build" -j >/dev/null
"$CMAKE" --install "$SRC/SPIRV-Cross/build" >/dev/null

[ -d "$SRC/SDL_shadercross" ] || git clone -q --depth 1 https://github.com/libsdl-org/SDL_shadercross.git "$SRC/SDL_shadercross"
"$CMAKE" -S "$SRC/SDL_shadercross" -B "$SRC/SDL_shadercross/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DSDLSHADERCROSS_VENDORED=OFF -DSDLSHADERCROSS_DXC=OFF -DSDLSHADERCROSS_CLI=ON \
    -DSDLSHADERCROSS_SHARED=ON -DSDLSHADERCROSS_STATIC=OFF >/dev/null
"$CMAKE" --build "$SRC/SDL_shadercross/build" -j >/dev/null
"$CMAKE" --install "$SRC/SDL_shadercross/build" >/dev/null

cat > "$PREFIX/shadercross" <<'WRAPPER'
#!/bin/sh
PREFIX=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
DYLD_LIBRARY_PATH="$PREFIX/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    exec "$PREFIX/bin/shadercross" "$@"
WRAPPER
chmod +x "$PREFIX/shadercross"

# Sources and object files, none of it needed to run the compilers.
[ -n "${YAZ_KEEP_SOURCES:-}" ] || rm -rf "$SRC"
