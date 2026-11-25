#!/usr/bin/env bash
set -Eeuo pipefail

BREP_DIR="/usr/src/brep"
JOBS="$(nproc 2>/dev/null || echo 1)"

die() { echo "brep: error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  brep --add URL [--name NAME] [--mkdir]
  brep --remove NAME
  brep -i NAME
  brep -iq NAME
  brep --help

Options:
  --add URL       Download/clone a repository
  --name NAME     Specify repository name
  --remove NAME   Remove a repository
  -i NAME         Build and install
  -iq NAME        Quiet build and install
  --mkdir         Create repository directory
  --help          Show this message

Supported: git, .tar.gz, .tgz, .tar.xz, .tar.bz2, .tar, .zip { soon srcmake still finishing up some bloat }
EOF
}

valid_name() {
    [[ "$1" =~ ^[a-zA-Z0-9._+-]+$ && "$1" != "." && "$1" != ".." ]]
}

check_dir() {
    [[ -d "$BREP_DIR" ]] || {
        [[ "$MKDIR" == 1 ]] || die "$BREP_DIR doesn't exist. Use --mkdir."
        mkdir -p "$BREP_DIR"
    }
}

repo_name_from_url() {
    local name="${1%%\?*}"
    name="${name%%\#*}"
    name="${name##*/}"
    name="${name%.git}"
    name="${name%.tar.gz}"
    name="${name%.tgz}"
    name="${name%.tar.xz}"
    name="${name%.tar.bz2}"
    name="${name%.tar}"
    name="${name%.zip}"
    echo "$name"
}

add_repo() {
    local url="$1" name="${2:-$(repo_name_from_url "$1")}"
    local target="$BREP_DIR/$name" tmp archive entries

    [[ "$url" =~ ^https?://|^git@|^ssh:// ]] || die "Unsupported URL: $url"
    valid_name "$name" || die "Invalid repository name."
    [[ ! -e "$target" ]] || die "$name already exists."

    tmp="$(mktemp -d "$BREP_DIR/.brep-tmp.XXXXXX")"
    trap 'rm -rf -- "$tmp"' RETURN
    echo "brep: fetching $name"

    if [[ "$url" == *.git || "$url" == git@* || "$url" == ssh://* ]]; then
        command -v git >/dev/null || die "Git is required."
        git clone "$url" "$tmp/source"
    else
        command -v curl >/dev/null || die "curl is required."
        archive="$tmp/archive"
        mkdir "$tmp/source"
        curl -fL --progress-bar "$url" -o "$archive"

        case "$url" in
            *.tar.gz*|*.tgz*) tar -xzf "$archive" -C "$tmp/source" ;;
            *.tar.xz*)        tar -xJf "$archive" -C "$tmp/source" ;;
            *.tar.bz2*)       tar -xjf "$archive" -C "$tmp/source" ;;
            *.tar*)           tar -xf "$archive" -C "$tmp/source" ;;
            *.zip*)
                command -v unzip >/dev/null || die "unzip is required."
                unzip -q "$archive" -d "$tmp/source"
                ;;
            *) die "Unknown archive format." ;;
        esac

        entries=("$tmp/source"/* "$tmp/source"/.[!.]*)
        if [[ ${#entries[@]} == 1 && -d "${entries[0]}" ]]; then
            mv "${entries[0]}" "$tmp/repo"
        else
            mv "$tmp/source" "$tmp/repo"
        fi
    fi

    mv "${tmp}/repo" "$target" 2>/dev/null ||
        mv "${tmp}/source" "$target"

    echo "brep: added $name"
    echo "brep: location: $target"
}

remove_repo() {
    local name="$1" repo="$BREP_DIR/$1"

    valid_name "$name" || die "Invalid repository name."
    [[ -d "$repo" ]] || die "Repository $name does not exist."

    echo "brep: uninstalling $name"
    if [[ -f "$repo/Makefile" || -f "$repo/makefile" ]]; then
        (cd "$repo" && make uninstall) || die "Uninstall failed. Source directory preserved."
        echo "brep: package uninstalled"
    else
        echo "brep: warning: no Makefile found; skipping uninstall" >&2
    fi

    rm -rf -- "$repo"
    echo "brep: removed $name"
}

install_repo() {
    local name="$1" quiet="$2" repo="$BREP_DIR/$1" log

    valid_name "$name" || die "Invalid repository name."
    [[ -d "$repo" ]] || die "Repository $name not found."

    echo "brep: building $name with $JOBS jobs"

    if [[ -f "$repo/INSTALL" ]]; then
        if [[ "$quiet" == 1 ]]; then
            log="$(mktemp)"
            if ! (cd "$repo" && sh ./INSTALL) >"$log" 2>&1; then
                cat "$log" >&2
                rm -f "$log"
                die "Installation failed."
            fi
            rm -f "$log"
        else
            (cd "$repo" && sh ./INSTALL) || die "Installation failed."
        fi

    elif [[ -f "$repo/configure" ]]; then
        if [[ "$quiet" == 1 ]]; then
            log="$(mktemp)"
            if ! (cd "$repo" && ./configure && make -s -j"$JOBS" && make -s install) >"$log" 2>&1; then
                cat "$log" >&2
                rm -f "$log"
                die "Build or installation failed."
            fi
            rm -f "$log"
        else
            (cd "$repo" && ./configure && make -j"$JOBS" && make install) ||
                die "Build or installation failed."
        fi

    elif [[ -f "$repo/Makefile" || -f "$repo/makefile" ]]; then
        if [[ "$quiet" == 1 ]]; then
            make_args=(-s)
        else
            make_args=()
        fi

        (cd "$repo" && make "${make_args[@]}" -j"$JOBS" &&
            make "${make_args[@]}" install) ||
            die "Build or installation failed."
    else
        die "No INSTALL, configure, or Makefile found in $repo."
    fi

    echo "brep: $name successfully installed"
}

ACTION="" URL="" NAME="" MKDIR=0

while (($#)); do
    case "$1" in
        --add)    ACTION=add; URL="${2:?Missing URL}"; shift 2 ;;
        --name)   NAME="${2:?Missing name}"; shift 2 ;;
        --remove) ACTION=remove; NAME="${2:?Missing repository name}"; shift 2 ;;
        -i)       ACTION=install; NAME="${2:?Missing repository name}"; shift 2 ;;
        -iq)      ACTION=quiet; NAME="${2:?Missing repository name}"; shift 2 ;;
        --mkdir)  MKDIR=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

[[ -n "$ACTION" ]] || { usage; exit 1; }
check_dir

case "$ACTION" in
    add)     add_repo "$URL" "$NAME" ;;
    remove)  remove_repo "$NAME" ;;
    install) install_repo "$NAME" 0 ;;
    quiet)   install_repo "$NAME" 1 ;;
esac
