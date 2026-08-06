set dotenv-load
set dotenv-filename := ".env"
set windows-shell := ["sh", "-cu"]

default:
    @just list

list:
    @printf "%s\n" \
        "run [release] [logs]" \
        "clean [build|derived-data|modules|spm|all]..."

run mode="" logs="":
    #!/usr/bin/env sh
    set -eu

    mode="{{ mode }}"
    logs="{{ logs }}"
    configuration="Debug"
    attach_logs=false

    if [ "$mode" = "logs" ]; then
        attach_logs=true
        mode=""
    fi
    if [ -n "$logs" ]; then
        if [ "$logs" != "logs" ]; then
            echo "usage: just run [release] [logs]" >&2
            exit 1
        fi
        attach_logs=true
    fi
    if [ -n "$mode" ]; then
        if [ "$mode" != "release" ]; then
            echo "usage: just run [release] [logs]" >&2
            exit 1
        fi
        configuration="Release"
    fi

    if [ "$configuration" = "Release" ]; then
        echo "Running Release configuration (mainnet)."
    fi

    if [ "$attach_logs" = "true" ]; then
        BITKIT_CONFIGURATION="$configuration" BITKIT_ATTACH_LOGS=1 ./run.sh
    else
        BITKIT_CONFIGURATION="$configuration" BITKIT_ATTACH_LOGS=0 ./run.sh
    fi

clean *targets:
    #!/usr/bin/env sh
    set -eu

    set -- {{ targets }}
    if [ "$#" -eq 0 ]; then
        set -- build
    fi

    clean_build=false
    clean_derived_data=false
    clean_modules=false
    clean_spm=false

    for target in "$@"; do
        case "$target" in
            build)
                clean_build=true
                ;;
            derived-data | derived)
                clean_derived_data=true
                ;;
            modules | module-cache)
                clean_modules=true
                ;;
            spm | swiftpm)
                clean_spm=true
                ;;
            all)
                clean_build=true
                clean_derived_data=true
                clean_modules=true
                clean_spm=true
                ;;
            *)
                echo "usage: just clean [build|derived-data|modules|spm|all]..." >&2
                exit 1
                ;;
        esac
    done

    remove_path() {
        path="$1"

        case "$path" in
            "" | "/" | "$HOME" | "$HOME/")
                echo "Refusing to remove unsafe path: $path" >&2
                exit 1
                ;;
        esac

        if [ -e "$path" ] || [ -L "$path" ]; then
            echo "Removing $path"
            rm -rf "$path"
        fi
    }

    remove_module_caches() {
        derived_data="$1"

        for build_root in "$derived_data/Build" "$derived_data/Index.noindex/Build"; do
            remove_path "$build_root/Intermediates.noindex/SwiftExplicitPrecompiledModules"
            remove_path "$build_root/Intermediates.noindex/ExplicitPrecompiledModules"
            # The build database records the .pcm paths above by hash. Left behind, a
            # target that is not rebuilt immediately fails with "module file not found"
            # instead of re-planning the module it needs.
            remove_path "$build_root/Intermediates.noindex/XCBuildData"
        done

        remove_path "$derived_data/ModuleCache.noindex"
    }

    if [ "$clean_build" = "true" ]; then
        remove_path "${BITKIT_DERIVED_DATA_PATH:-build}"
    fi

    if [ "$clean_derived_data" = "true" ]; then
        xcode_derived_data_root="${BITKIT_XCODE_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
        for path in "$xcode_derived_data_root"/Bitkit-*; do
            remove_path "$path"
        done
    fi

    if [ "$clean_modules" = "true" ]; then
        remove_module_caches "${BITKIT_DERIVED_DATA_PATH:-build}"
        xcode_derived_data_root="${BITKIT_XCODE_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
        for path in "$xcode_derived_data_root"/Bitkit-*; do
            remove_module_caches "$path"
        done
        # MODULE_CACHE_DIR points at the DerivedData root, so this one is shared with
        # every other Xcode project; they will just rebuild it.
        remove_path "$xcode_derived_data_root/ModuleCache.noindex"
    fi

    if [ "$clean_spm" = "true" ]; then
        remove_path "${BITKIT_DERIVED_DATA_PATH:-build}/SourcePackages"
        xcode_derived_data_root="${BITKIT_XCODE_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
        for path in "$xcode_derived_data_root"/Bitkit-*/SourcePackages; do
            remove_path "$path"
        done
        remove_path "${BITKIT_SWIFTPM_CACHE_PATH:-$HOME/Library/Caches/org.swift.swiftpm}"
        remove_path "$HOME/.swiftpm/cache"
        remove_path "$HOME/.swiftpm/repositories"
    fi
