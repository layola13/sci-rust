#!/bin/sh

# SA (System Architecture) Toolchain Installer
#
# Safe, POSIX-compliant, and fully automated installation script.
# Installs to ~/.sa/bin and configures your environment.
#
# Usage:
#   curl -fsSL https://example.com/install.sh | sh
#   sh install.sh [options]
#
# Options:
#   -h, --help             Show this help message and exit
#   --version <tag>        Install a specific release tag (e.g. v0.3.1)
#   --dir <path>           Override installation directory (default: ~/.sa)
#   --no-shell             Skip shell profile modification
#   --dry-run              Print what would be done without making changes

set -eu

# ── Color and Styling ───────────────────────────────────────────────────────

setup_colors() {
    if [ -t 1 ]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        BLUE='\033[0;34m'
        MAGENTA='\033[0;35m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        RESET='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        MAGENTA=''
        CYAN=''
        BOLD=''
        RESET=''
    fi
}

info()    { printf "${BLUE}[i]${RESET} %s\n" "$1"; }
step()    { printf "${CYAN}[>]${RESET} %s\n" "$1"; }
success() { printf "${GREEN}[✓]${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}[!]${RESET} %s\n" "$1"; }
error()   { printf "${RED}[✗]${RESET} ${BOLD}Error:${RESET} %s\n" "$1" >&2; exit 1; }

# Dry-run wrapper: prints command instead of running it when --dry-run is set
run_or_echo() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf "  ${YELLOW}dry-run:${RESET} %s\n" "$*"
    else
        "$@"
    fi
}

# ── ASCII Header ────────────────────────────────────────────────────────────

print_header() {
    printf "${MAGENTA}${BOLD}"
    printf "   _____         \n"
    printf "  / ___/ ____ _  \n"
    printf "  \\__ \\ / __ \`/  \n"
    printf " ___/ // /_/ /   \n"
    printf "/____/ \\__,_/    ${CYAN}System Architecture Toolchain${RESET}\n"
    printf "                 Linear Ownership & Zero-Trust Assembly\n\n"
}

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
    print_header
    printf "Install the SA toolchain to your system.\n\n"
    printf "${BOLD}USAGE${RESET}\n"
    printf "  sh install.sh [options]\n\n"
    printf "${BOLD}OPTIONS${RESET}\n"
    printf "  %-26s %s\n" "-h, --help"       "Show this help message and exit"
    printf "  %-26s %s\n" "--version <tag>"  "Install a specific release tag (e.g. v0.3.1)"
    printf "  %-26s %s\n" "--dir <path>"     "Override installation directory (default: \$HOME/.sa)"
    printf "  %-26s %s\n" "--no-shell"       "Skip shell profile modification"
    printf "  %-26s %s\n" "--dry-run"        "Print what would be done without making changes"
    printf "\n${BOLD}ENVIRONMENT${RESET}\n"
    printf "  %-26s %s\n" "SA_DIR"           "Installation directory (overridden by --dir)"
    printf "  %-26s %s\n" "SA_RELEASE_URL"   "Base URL for release downloads (overrides GitHub)"
    printf "\n${BOLD}EXAMPLES${RESET}\n"
    printf "  sh install.sh\n"
    printf "  sh install.sh --version v0.3.1\n"
    printf "  sh install.sh --dir /opt/sa --no-shell\n"
    printf "  sh install.sh --dry-run\n\n"
}

# ── Platform Detection ──────────────────────────────────────────────────────

detect_platform() {
    OS_NAME="$(uname -s)"
    ARCH_NAME="$(uname -m)"

    case "$OS_NAME" in
        Linux)  OS="linux"  ;;
        Darwin) OS="macos"  ;;
        *) error "Unsupported Operating System: $OS_NAME. SA supports Linux and macOS." ;;
    esac

    case "$ARCH_NAME" in
        x86_64|amd64)   ARCH="x86_64"  ;;
        arm64|aarch64)  ARCH="aarch64" ;;
        *) error "Unsupported architecture: $ARCH_NAME. SA supports x86_64 and aarch64." ;;
    esac
}

# ── Downloader Detection ────────────────────────────────────────────────────

get_downloader() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        error "Neither 'curl' nor 'wget' found in PATH. Please install one to proceed."
    fi
}

# ── Secure Download ─────────────────────────────────────────────────────────

download_file() {
    URL="$1"
    OUTPUT="$2"

    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fsSL --connect-timeout 15 "$URL" -o "$OUTPUT"
    else
        wget -qO "$OUTPUT" "$URL"
    fi
}

# ── Checksum Verification ───────────────────────────────────────────────────

verify_checksum() {
    FILE="$1"
    EXPECTED_SHA="$2"

    # Try sha256sum (Linux), then shasum -a 256 (macOS)
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL_SHA="$(sha256sum "$FILE" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL_SHA="$(shasum -a 256 "$FILE" | awk '{print $1}')"
    else
        warn "No SHA-256 utility found (sha256sum / shasum). Skipping checksum verification."
        return 0
    fi

    if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
        success "Checksum verified."
    else
        error "Checksum mismatch!\n  expected: $EXPECTED_SHA\n  got:      $ACTUAL_SHA"
    fi
}

verify_std_payload() {
    STD_ROOT="$1"
    [ -f "$STD_ROOT/io/print.sai" ] || error "Installed std payload is incomplete: missing std/io/print.sai"
    [ -f "$STD_ROOT/core/sa_core.sars" ] || error "Installed std payload is incomplete: missing std/core/sa_core.sars"
    [ -f "$STD_ROOT/core/result.sars" ] || error "Installed std payload is incomplete: missing std/core/result.sars"
    [ -f "$STD_ROOT/core/option.sars" ] || error "Installed std payload is incomplete: missing std/core/option.sars"
    [ -f "$STD_ROOT/sa_std.h" ] || error "Installed std payload is incomplete: missing std/sa_std.h"
    [ -f "$STD_ROOT/libsa_std.a" ] || error "Installed std payload is incomplete: missing std/libsa_std.a"
}

detect_source_version() {
    if [ -n "${RELEASE_TAG:-}" ]; then
        printf "%s" "$RELEASE_TAG"
        return 0
    fi

    if command -v git >/dev/null 2>&1; then
        GIT_TAG="$(git tag --sort=-v:refname 2>/dev/null | sed -n '1p')"
        if [ -n "$GIT_TAG" ]; then
            printf "%s" "$GIT_TAG"
            return 0
        fi
    fi

    printf "0.0.1"
}

# ── Shell Profile Integration ───────────────────────────────────────────────

configure_shell() {
    SA_DIR="$1"
    SA_BIN_DIR="$SA_DIR/bin"
    SA_STD_DIR="$SA_DIR/std"

    SHELL_PROFILE=""
    CURRENT_SHELL="$(basename "${SHELL:-sh}")"

    case "$CURRENT_SHELL" in
        zsh)  SHELL_PROFILE="$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                SHELL_PROFILE="$HOME/.bash_profile"
            else
                SHELL_PROFILE="$HOME/.bashrc"
            fi
            ;;
        *)
            if [ -f "$HOME/.profile" ]; then
                SHELL_PROFILE="$HOME/.profile"
            fi
            ;;
    esac

    ENV_LINE=". \"$SA_DIR/env\""
    PATH_UPDATED=0

    if [ -n "$SHELL_PROFILE" ] && [ -f "$SHELL_PROFILE" ]; then
        if grep -F -q "$SA_DIR/env" "$SHELL_PROFILE" >/dev/null 2>&1 || grep -F -q "$SA_BIN_DIR" "$SHELL_PROFILE" >/dev/null 2>&1; then
            info "PATH settings already exist in $SHELL_PROFILE."
            PATH_UPDATED=1
        else
            step "Adding SA environment to $SHELL_PROFILE"
            run_or_echo sh -c "printf '\n# SA Toolchain Environment\n%s\n' '$ENV_LINE' >> '$SHELL_PROFILE'"
            PATH_UPDATED=1
        fi
    fi

    # Fish shell
    if command -v fish >/dev/null 2>&1 || [ -f "$HOME/.config/fish/config.fish" ]; then
        FISH_CONF="$HOME/.config/fish/config.fish"
        run_or_echo mkdir -p "$(dirname "$FISH_CONF")"
        if ! grep -F -q "$SA_BIN_DIR" "$FISH_CONF" >/dev/null 2>&1; then
            step "Configuring Fish shell PATH"
            run_or_echo sh -c "printf '\n# SA Toolchain Path\nfish_add_path %s\nset -gx SA_STD_DIR %s\n' '$SA_BIN_DIR' '$SA_STD_DIR' >> '$FISH_CONF'"
        fi
    fi

    printf "\n"
    success "SA Toolchain installed successfully!"
    printf "\n"
    printf "  ${BOLD}Executable:${RESET}  %s\n" "$SA_BIN_DIR/sa  (and symlink 'saasm')"
    printf "  ${BOLD}Std Library Root:${RESET} %s\n" "$SA_STD_DIR"
    printf "\n"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "(dry-run: no files were written)"
    elif [ "$PATH_UPDATED" -eq 1 ]; then
        info "To activate SA in your current session, run:"
        printf "    ${BOLD}source %s${RESET}\n\n" "$SHELL_PROFILE"
    else
        info "Add SA to your PATH by appending this to your shell profile:"
        printf "    ${BOLD}export PATH=\"\$HOME/.sa/bin:\$PATH\"${RESET}\n\n"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    setup_colors

    # ── Argument Parsing ──────────────────────────────────────────────────
    SA_DIR=""
    RELEASE_TAG=""
    NO_SHELL=0
    DRY_RUN=0

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            --version)
                [ $# -lt 2 ] && error "--version requires a tag argument (e.g. v0.3.1)"
                RELEASE_TAG="$2"
                shift 2
                ;;
            --dir)
                [ $# -lt 2 ] && error "--dir requires a path argument"
                SA_DIR="$2"
                shift 2
                ;;
            --no-shell)
                NO_SHELL=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            *)
                error "Unknown option: $1  (run with --help for usage)"
                ;;
        esac
    done

    print_header

    if [ "$DRY_RUN" = "1" ]; then
        warn "Running in dry-run mode — no files will be written."
        printf "\n"
    fi

    detect_platform
    info "Detected platform: ${BOLD}${OS}-${ARCH}${RESET}"

    get_downloader

    # ── Directories ───────────────────────────────────────────────────────
    SA_DIR="${SA_DIR:-${SA_DIR:-$HOME/.sa}}"
    SA_BIN_DIR="$SA_DIR/bin"
    SA_STD_DIR="$SA_DIR/std"

    info "Installation directory: ${BOLD}$SA_DIR${RESET}"

    run_or_echo mkdir -p "$SA_BIN_DIR"
    run_or_echo mkdir -p "$SA_STD_DIR"

    # ── Release URL ───────────────────────────────────────────────────────
    DEFAULT_BASE_URL="https://github.com/sci/sa/releases"
    if [ -n "$RELEASE_TAG" ]; then
        RELEASE_URL="${SA_RELEASE_URL:-$DEFAULT_BASE_URL/download/$RELEASE_TAG}"
        info "Pinned release: ${BOLD}$RELEASE_TAG${RESET}"
    else
        RELEASE_URL="${SA_RELEASE_URL:-$DEFAULT_BASE_URL/latest/download}"
    fi

    TARBALL_NAME="sa-${OS}-${ARCH}.tar.gz"
    DOWNLOAD_URL="${RELEASE_URL}/${TARBALL_NAME}"
    CHECKSUM_URL="${RELEASE_URL}/${TARBALL_NAME}.sha256"

    # ── Temp Directory ────────────────────────────────────────────────────
    TEMP_DIR="$SA_DIR/tmp_install"
    run_or_echo rm -rf "$TEMP_DIR"
    run_or_echo mkdir -p "$TEMP_DIR"

    # ── Download & Install ────────────────────────────────────────────────
    INSTALLED_FROM_SOURCE=0

    if [ "$DRY_RUN" = "1" ]; then
        step "Would download: $DOWNLOAD_URL"
        step "Would verify checksum from: $CHECKSUM_URL"
        step "Would extract to: $SA_BIN_DIR and $SA_STD_DIR"
    elif [ -f "build.zig" ] && command -v zig >/dev/null 2>&1; then
        info "Source tree detected and Zig is available. Building from source directly."
        SOURCE_VERSION="$(detect_source_version)"
        info "Source version: ${BOLD}$SOURCE_VERSION${RESET}"
        step "Building via 'zig build -Doptimize=ReleaseFast -Dversion=$SOURCE_VERSION'"
        if zig build -Doptimize=ReleaseFast -Dversion="$SOURCE_VERSION"; then
            cp -f zig-out/bin/sa "$SA_BIN_DIR/sa"
            mkdir -p "$SA_STD_DIR"
            if [ -d sa_std ]; then
                cp -rf sa_std/* "$SA_STD_DIR/"
            fi
            if [ -f zig-out/lib/libsa_std.a ]; then
                cp -f zig-out/lib/libsa_std.a "$SA_STD_DIR/"
            fi
            if [ -f src/runtime/sa_std.h ]; then
                cp -f src/runtime/sa_std.h "$SA_STD_DIR/"
            fi
            verify_std_payload "$SA_STD_DIR"
            INSTALLED_FROM_SOURCE=1
            success "Built from source."
        else
            rm -rf "$TEMP_DIR"
            error "Build from source failed."
        fi
        rm -rf "$TEMP_DIR"
    else
        step "Downloading SA package archive"
        if ! download_file "$DOWNLOAD_URL" "$TEMP_DIR/$TARBALL_NAME"; then
            printf "\n"
            warn "Could not fetch release from: $DOWNLOAD_URL"

            if command -v zig >/dev/null 2>&1; then
                info "Zig compiler detected — attempting to build from source..."
                SOURCE_VERSION="$(detect_source_version)"
                info "Source version: ${BOLD}$SOURCE_VERSION${RESET}"
                step "Building via 'zig build -Doptimize=ReleaseFast -Dversion=$SOURCE_VERSION'"
                if zig build -Doptimize=ReleaseFast -Dversion="$SOURCE_VERSION"; then
                    cp -f zig-out/bin/sa "$SA_BIN_DIR/sa"
                    mkdir -p "$SA_STD_DIR"
                    if [ -d sa_std ]; then
                        cp -rf sa_std/* "$SA_STD_DIR/"
                    fi
                    if [ -f zig-out/lib/libsa_std.a ]; then
                        cp -f zig-out/lib/libsa_std.a "$SA_STD_DIR/"
                    fi
                    if [ -f src/runtime/sa_std.h ]; then
                        cp -f src/runtime/sa_std.h "$SA_STD_DIR/"
                    fi
                    verify_std_payload "$SA_STD_DIR"
                    INSTALLED_FROM_SOURCE=1
                    success "Built from source."
                else
                    rm -rf "$TEMP_DIR"
                    error "Build from source failed. Ensure you are in the SA project root."
                fi
            else
                rm -rf "$TEMP_DIR"
                error "Remote download failed and 'zig' is not available for a local build."
            fi
        else
            success "Download complete."

            # Optional checksum verification (best-effort)
            step "Verifying checksum"
            if download_file "$CHECKSUM_URL" "$TEMP_DIR/${TARBALL_NAME}.sha256" 2>/dev/null; then
                EXPECTED_SHA="$(cat "$TEMP_DIR/${TARBALL_NAME}.sha256" | awk '{print $1}')"
                verify_checksum "$TEMP_DIR/$TARBALL_NAME" "$EXPECTED_SHA"
            else
                warn "No checksum file found at $CHECKSUM_URL — skipping verification."
            fi

            # Extract
            step "Extracting toolchain files"
            tar -xzf "$TEMP_DIR/$TARBALL_NAME" -C "$TEMP_DIR"
            success "Extraction complete."

            # Locate extracted root
            EXTRACTED_DIR="$(find "$TEMP_DIR" -maxdepth 1 -type d | grep -v "^$TEMP_DIR$" | head -n 1)"
            if [ -z "$EXTRACTED_DIR" ]; then
                EXTRACTED_DIR="$TEMP_DIR"
            fi

            if [ -f "$EXTRACTED_DIR/bin/sa" ]; then
                cp -f "$EXTRACTED_DIR/bin/sa" "$SA_BIN_DIR/sa"
                chmod +x "$SA_BIN_DIR/sa"
            else
                rm -rf "$TEMP_DIR"
                error "Archive structure invalid: 'bin/sa' not found."
            fi

            if [ -d "$EXTRACTED_DIR/std" ]; then
                cp -rf "$EXTRACTED_DIR/std/"* "$SA_STD_DIR/"
            else
                rm -rf "$TEMP_DIR"
                error "Archive structure invalid: 'std/' not found."
            fi
            verify_std_payload "$SA_STD_DIR"

        fi

        rm -rf "$TEMP_DIR"
    fi

    # ── Symlink sa ───────────────────────────────────────────────────────
    if [ "$DRY_RUN" != "1" ] && [ -f "$SA_BIN_DIR/sa" ]; then
        run_or_echo chmod +x "$SA_BIN_DIR/sa"
        rm -f "$SA_BIN_DIR/saasm"
        ln -s "sa" "$SA_BIN_DIR/saasm"
    fi

    # ── Environment File ──────────────────────────────────────────────────
    if [ "$DRY_RUN" != "1" ]; then
cat <<EOF > "$SA_DIR/env"
# SA (System Architecture) Environment Configuration
# Source this file to enable SA commands in your terminal.

export PATH="$SA_BIN_DIR:\$PATH"
export SA_STD_DIR="$SA_STD_DIR"
EOF
        chmod +x "$SA_DIR/env"
    else
        step "Would write: $SA_DIR/env"
    fi

    # ── Shell Integration ─────────────────────────────────────────────────
    if [ "$NO_SHELL" = "1" ]; then
        printf "\n"
        success "SA Toolchain installed successfully!"
        printf "\n"
        printf "  ${BOLD}Executable:${RESET}  %s\n" "$SA_BIN_DIR/sa  (and symlink 'saasm')"
        printf "  ${BOLD}Std Library:${RESET} %s\n" "$SA_STD_DIR"
        printf "\n"
        info "Shell profile modification skipped (--no-shell)."
        printf "  Add this to your shell profile to activate SA:\n"
        printf "    ${BOLD}. \"$SA_DIR/env\"${RESET}\n\n"
    else
        configure_shell "$SA_DIR"
    fi
}

main "$@"
