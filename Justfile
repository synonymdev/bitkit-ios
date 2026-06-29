set dotenv-load
set dotenv-filename := ".env"
set windows-shell := ["sh", "-cu"]

default:
    @just list

list:
    @printf "%s\n" \
        "run [release] [logs]" \
        "clean [build|derived-data|spm|all]..."

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
    clean_spm=false

    for target in "$@"; do
        case "$target" in
            build)
                clean_build=true
                ;;
            derived-data | derived)
                clean_derived_data=true
                ;;
            spm | swiftpm)
                clean_spm=true
                ;;
            all)
                clean_build=true
                clean_derived_data=true
                clean_spm=true
                ;;
            *)
                echo "usage: just clean [build|derived-data|spm|all]..." >&2
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

    if [ "$clean_build" = "true" ]; then
        remove_path "${BITKIT_DERIVED_DATA_PATH:-build}"
    fi

    if [ "$clean_derived_data" = "true" ]; then
        xcode_derived_data_root="${BITKIT_XCODE_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
        for path in "$xcode_derived_data_root"/Bitkit-*; do
            remove_path "$path"
        done
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
