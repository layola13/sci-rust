#!/bin/sh

# SA (System Architecture) Release Packager
#
# Automates compiling and packaging SA toolchain for multiple platforms.
# Leverages Zig's out-of-the-box cross-compilation capabilities.

set -eu

# Color and Styling Definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info() {
    printf "${BLUE}[i]${RESET} %s\n" "$1"
}

working() {
    printf "${CYAN}[>]${RESET} %s..." "$1"
}

success() {
    printf "${GREEN}[✓]${RESET} %s\n" "$1"
}

warn() {
    printf "${YELLOW}[!]${RESET} %s\n" "$1"
}

error() {
    printf "${RED}[✗]${RESET} ${BOLD}Error:${RESET} %s\n" "$1" >&2
    exit 1
}

# Verify Zig compiler is present
if ! command -v zig >/dev/null 2>&1; then
    error "Zig compiler not found. Zig is required to build SA releases."
fi

# Root directory of the repository
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

latest_source_tag() {
    if command -v git >/dev/null 2>&1; then
        GIT_TAG="$(git -C "$REPO_ROOT" tag --sort=-v:refname 2>/dev/null | sed -n '1p')"
        if [ -n "$GIT_TAG" ]; then
            printf "%s" "$GIT_TAG"
            return 0
        fi
    fi

    printf "0.0.1"
}

VERSION="${SA_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(latest_source_tag)"
fi
VERSION="${VERSION#v}"
LLVM_INCLUDE_DIR="${LLVM_INCLUDE_DIR:-/usr/lib/llvm-14/include}"
LLVM_LIB_DIR="${LLVM_LIB_DIR:-/usr/lib/llvm-14/lib}"
LLVM_LIB_NAME="${LLVM_LIB_NAME:-LLVM-14}"

info "Cleaning up old build environments..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Targets definition: OS, ARCH, Zig Target String, Format (tar.gz or zip)
# Format: "OS;ARCH;ZIG_TARGET;ARCHIVE_FORMAT"
DEFAULT_TARGETS="
linux;x86_64;x86_64-linux-gnu;tar.gz
# linux;aarch64;aarch64-linux-gnu;tar.gz
# macos;x86_64;x86_64-macos;tar.gz
# macos;aarch64;aarch64-macos;tar.gz
# windows;x86_64;x86_64-windows-gnu;zip
# windows;aarch64;aarch64-windows-gnu;zip
"
TARGETS="${SA_TARGETS:-$DEFAULT_TARGETS}"

build_target() {
    OS="$1"
    ARCH="$2"
    ZIG_TARGET="$3"
    FORMAT="$4"
    
    TARGET_NAME="sa-${OS}-${ARCH}"
    TARGET_DIR="$DIST_DIR/$TARGET_NAME"
    
    info "--------------------------------------------------"
    info "Building target: ${BOLD}$TARGET_NAME${RESET} ($ZIG_TARGET, version $VERSION)"
    
    # 1. Clean previous build artifact directories
    rm -rf "$REPO_ROOT/zig-out"
    rm -rf "$REPO_ROOT/.zig-cache"
    
    # 2. Build SA Compiler
    working "Compiling sa compiler"
    LLVM_OPTION=""
    # Cross targets cannot link the host's libLLVM (arch mismatch), so only
    # a native linux build keeps the LLVM backend; every other archive is
    # explicitly bootstrap-level (matches CI: only linux-full enables LLVM).
    NATIVE_ARCH="$(uname -m)"
    case "$NATIVE_ARCH" in
        x86_64|amd64) NATIVE_ARCH="x86_64" ;;
        aarch64|arm64) NATIVE_ARCH="aarch64" ;;
    esac
    if [ "$OS" != "linux" ] || [ "$ARCH" != "$NATIVE_ARCH" ]; then
        LLVM_OPTION="-Dllvm=false"
    fi
    if ! zig build -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSafe -Dversion="$VERSION" $LLVM_OPTION -Dllvm-include-dir="$LLVM_INCLUDE_DIR" -Dllvm-lib-dir="$LLVM_LIB_DIR" -Dllvm-lib-name="$LLVM_LIB_NAME" >/dev/null 2>&1; then
        printf " failed.\n"
        error "Zig compilation failed for target: $ZIG_TARGET"
    fi
    printf " done!\n"
    
    # 3. Create target directory layout
    mkdir -p "$TARGET_DIR/bin"
    mkdir -p "$TARGET_DIR/lib"
    mkdir -p "$TARGET_DIR/std"
    
    # 4. Copy SAASM Executable
    EXE_FILE="sa"
    if [ "$OS" = "windows" ]; then
        EXE_FILE="sa.exe"
    fi
    
    if [ -f "$REPO_ROOT/zig-out/bin/$EXE_FILE" ]; then
        cp -f "$REPO_ROOT/zig-out/bin/$EXE_FILE" "$TARGET_DIR/bin/"
        if [ "$OS" != "windows" ]; then
            chmod +x "$TARGET_DIR/bin/$EXE_FILE"
        fi
    else
        error "Compiled binary $EXE_FILE not found in zig-out/bin"
    fi
    
    # 5. Copy Standard Library sources
    if [ -d "$REPO_ROOT/sa_std" ]; then
        cp -rf "$REPO_ROOT/sa_std/"* "$TARGET_DIR/std/"
    else
        error "Standard library source directory not found: $REPO_ROOT/sa_std"
    fi

    # 6. Copy static runtime library if built
    # Some targets compile static libraries in zig-out/lib
    LIB_FILE="libsa_std.a"
    if [ "$OS" = "windows" ]; then
        LIB_FILE="sa_std.lib"
    fi
    
    if [ -f "$REPO_ROOT/zig-out/lib/$LIB_FILE" ]; then
        cp -f "$REPO_ROOT/zig-out/lib/$LIB_FILE" "$TARGET_DIR/std/"
    else
        # Try finding standard library from workspace artifacts if zig build skips cross-compiling static library in standard step
        if [ -f "$REPO_ROOT/artifacts/sa_std/libsa_std.a" ] && [ "$OS" = "linux" ]; then
            cp -f "$REPO_ROOT/artifacts/sa_std/libsa_std.a" "$TARGET_DIR/std/$LIB_FILE"
        fi
    fi
    
    # Copy header
    if [ -f "$REPO_ROOT/src/runtime/sa_std.h" ]; then
        cp -f "$REPO_ROOT/src/runtime/sa_std.h" "$TARGET_DIR/std/"
    elif [ -f "$REPO_ROOT/zig-out/include/sa_std.h" ]; then
        cp -f "$REPO_ROOT/zig-out/include/sa_std.h" "$TARGET_DIR/std/"
    fi

    # State the support level inside every archive. Windows is intentionally
    # labeled bootstrap/core rather than being presented as Linux runtime
    # parity while its unsupported ABI manifest remains non-empty.
    if [ "$OS" = "windows" ]; then
        cp -f "$REPO_ROOT/docs/windows_support_level.txt" "$TARGET_DIR/SUPPORT_LEVEL.txt"
        cp -f "$REPO_ROOT/docs/runtime_abi_windows_unsupported.txt" "$TARGET_DIR/std/"
        cp -f "$REPO_ROOT/docs/runtime_abi_windows_extra.txt" "$TARGET_DIR/std/"
    elif [ "$OS" = "linux" ]; then
        cp -f "$REPO_ROOT/docs/linux_support_level.txt" "$TARGET_DIR/SUPPORT_LEVEL.txt"
    fi

    [ -f "$TARGET_DIR/std/io/print.sai" ] || error "Package std payload missing std/io/print.sai"
    [ -f "$TARGET_DIR/std/core/sa_core.sars" ] || error "Package std payload missing std/core/sa_core.sars"
    [ -f "$TARGET_DIR/std/core/result.sars" ] || error "Package std payload missing std/core/result.sars"
    [ -f "$TARGET_DIR/std/core/option.sars" ] || error "Package std payload missing std/core/option.sars"
    [ -f "$TARGET_DIR/std/$LIB_FILE" ] || error "Package std payload missing std/$LIB_FILE"
    [ -f "$TARGET_DIR/std/sa_std.h" ] || error "Package std payload missing std/sa_std.h"
    [ -f "$TARGET_DIR/SUPPORT_LEVEL.txt" ] || error "Package support-level file missing"
    if [ "$OS" = "windows" ]; then
        [ -f "$TARGET_DIR/std/runtime_abi_windows_unsupported.txt" ] || error "Package Windows ABI manifest missing"
        [ -f "$TARGET_DIR/std/runtime_abi_windows_extra.txt" ] || error "Package Windows extra-export manifest missing"
    fi
    
    # 7. Compress Package
    working "Packaging archive"
    cd "$DIST_DIR"
    if [ "$FORMAT" = "tar.gz" ]; then
        tar -czf "$TARGET_NAME.tar.gz" "$TARGET_NAME"
        success "Created $TARGET_NAME.tar.gz"
    elif [ "$FORMAT" = "zip" ]; then
        if command -v zip >/dev/null 2>&1; then
            zip -rq "$TARGET_NAME.zip" "$TARGET_NAME"
            success "Created $TARGET_NAME.zip"
        elif command -v powershell.exe >/dev/null 2>&1; then
            # GitHub's Windows images do not promise a POSIX zip utility. Use
            # the native archive tool when running from Git Bash/MSYS, then
            # verify the same artifact contract as the zip path above.
            powershell.exe -NoProfile -NonInteractive -Command \
                "Compress-Archive -Path '$TARGET_NAME' -DestinationPath '$TARGET_NAME.zip' -Force"
            success "Created $TARGET_NAME.zip with Compress-Archive"
        else
            error "Neither 'zip' nor powershell.exe is available for ZIP packaging"
        fi
        [ -f "$TARGET_NAME.zip" ] || error "ZIP packaging did not create $TARGET_NAME.zip"
    fi
    
    # Clean raw target dir after archiving
    rm -rf "$TARGET_DIR"
    cd "$REPO_ROOT"
}

# Run through target builds
printf "%s\n" "$TARGETS" | while IFS= read -r TARGET; do
    TARGET="$(printf "%s" "$TARGET" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$TARGET" ] || continue
    case "$TARGET" in
        \#*) continue ;;
    esac

    # Split fields
    OLD_IFS="$IFS"
    IFS=";"
    set -- $TARGET
    IFS="$OLD_IFS"

    [ "$#" -eq 4 ] || error "Invalid target entry: $TARGET"
    build_target "$1" "$2" "$3" "$4"
done

# Compute checksums
info "--------------------------------------------------"
working "Generating SHA256 checksums"
cd "$DIST_DIR"
if command -v sha256sum >/dev/null 2>&1; then
    find . -maxdepth 1 -type f \( -name 'sa-*.tar.gz' -o -name 'sa-*.zip' \) -print | sort | while IFS= read -r ARCHIVE_FILE; do
        ARCHIVE_NAME="${ARCHIVE_FILE#./}"
        sha256sum "$ARCHIVE_NAME"
    done > sha256sums.txt
    find . -maxdepth 1 -type f \( -name 'sa-*.tar.gz' -o -name 'sa-*.zip' \) -print | sort | while IFS= read -r ARCHIVE_FILE; do
        ARCHIVE_NAME="${ARCHIVE_FILE#./}"
        SHA_LINE="$(sha256sum "$ARCHIVE_NAME")"
        printf "%s\n" "$SHA_LINE" > "${ARCHIVE_FILE#./}.sha256"
    done
    printf " done!\n"
    success "Generated checksums file at dist/sha256sums.txt"
elif command -v shasum >/dev/null 2>&1; then
    find . -maxdepth 1 -type f \( -name 'sa-*.tar.gz' -o -name 'sa-*.zip' \) -print | sort | while IFS= read -r ARCHIVE_FILE; do
        ARCHIVE_NAME="${ARCHIVE_FILE#./}"
        shasum -a 256 "$ARCHIVE_NAME"
    done > sha256sums.txt
    find . -maxdepth 1 -type f \( -name 'sa-*.tar.gz' -o -name 'sa-*.zip' \) -print | sort | while IFS= read -r ARCHIVE_FILE; do
        ARCHIVE_NAME="${ARCHIVE_FILE#./}"
        SHA_LINE="$(shasum -a 256 "$ARCHIVE_NAME")"
        printf "%s\n" "$SHA_LINE" > "${ARCHIVE_FILE#./}.sha256"
    done
    printf " done!\n"
    success "Generated checksums file at dist/sha256sums.txt"
else
    printf " skipped (no shasum tool found).\n"
fi

cd "$REPO_ROOT"
success "Release compilation and packaging completed successfully!"
