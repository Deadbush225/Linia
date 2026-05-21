#!/usr/bin/env bash
set -euo pipefail

# User-configurable metadata.
APP_NAME="linia"
INSTALL_DIR="${HOME}/.local/share/${APP_NAME}"
GITHUB_OWNER="Deadbush225"
GITHUB_REPO="Linia"
ASSET_NAME_REGEX="linia-linux.tar.gz"
BUNDLE_MARKER_RELATIVE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
	cat <<'EOF'
Usage: install.sh [--bundle] [--download] [--bundle-root PATH] [--yes]

Modes:
	--bundle       Install from an extracted bundle (no download).
	--download     Download the latest tar.gz from GitHub Releases.

Options:
	--bundle-root  Path to the extracted bundle root.
	--yes          Do not prompt before overwriting an existing install.
EOF
}

log() {
	printf '%s\n' "$*"
}

fail() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

install_desktop_entry() {
	local template="$1"
	local apps_dir="${HOME}/.local/share/applications"
	local target="${apps_dir}/${APP_NAME}.desktop"

	mkdir -p "$apps_dir"
	sed "s|@INSTALL_DIR@|$INSTALL_DIR|g" "$template" > "$target"
	chmod 644 "$target"

	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
	fi
}

check_metadata() {
	if [[ -z "$GITHUB_OWNER" || "$GITHUB_OWNER" == "YOUR_GITHUB_OWNER" ]]; then
		fail "Set GITHUB_OWNER in this script."
	fi
	if [[ -z "$GITHUB_REPO" || "$GITHUB_REPO" == "YOUR_GITHUB_REPO" ]]; then
		fail "Set GITHUB_REPO in this script."
	fi
	if [[ -z "$ASSET_NAME_REGEX" || "$ASSET_NAME_REGEX" == "YOUR_ASSET_REGEX" ]]; then
		fail "Set ASSET_NAME_REGEX in this script."
	fi
}

resolve_bundle_root() {
	local candidate="$1"
	if [[ -n "$BUNDLE_MARKER_RELATIVE" ]]; then
		if [[ -f "$candidate/$BUNDLE_MARKER_RELATIVE" || -d "$candidate/$BUNDLE_MARKER_RELATIVE" ]]; then
			printf '%s' "$candidate"
			return 0
		fi
	fi
	printf '%s' "$candidate"
}

install_from_bundle() {
	local bundle_root="$1"
	local resolved_root
	resolved_root="$(resolve_bundle_root "$bundle_root")"

	if [[ ! -d "$resolved_root" ]]; then
		fail "Bundle root not found: $resolved_root"
	fi

	if [[ -e "$INSTALL_DIR" ]]; then
		if [[ "$AUTO_YES" != "1" ]]; then
			read -r -p "${INSTALL_DIR} exists. Overwrite? [y/N] " reply
			if [[ ! "$reply" =~ ^[Yy]$ ]]; then
				fail "Install cancelled."
			fi
		fi
		rm -rf "$INSTALL_DIR"
	fi

	mkdir -p "$INSTALL_DIR"
	cp -a "$resolved_root/." "$INSTALL_DIR/"
	log "Installed to $INSTALL_DIR"

	local desktop_template="$resolved_root/${APP_NAME}.desktop"
	if [[ -f "$desktop_template" ]]; then
		install_desktop_entry "$desktop_template"
		log "Desktop entry installed to ${HOME}/.local/share/applications/${APP_NAME}.desktop"
	fi
}

download_latest_tarball() {
	local api_url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"
	local asset_url

	need_cmd curl
	need_cmd grep
	need_cmd sed
	need_cmd tar

	asset_url=$(curl -fsSL "$api_url" \
		| grep -Eo '"browser_download_url"\s*:\s*"[^"]+"' \
		| sed -E 's/.*"(https:[^"]+)"/\1/' \
		| grep -E "$ASSET_NAME_REGEX" \
		| head -n 1)

	if [[ -z "$asset_url" ]]; then
		fail "No release asset matched ASSET_NAME_REGEX: $ASSET_NAME_REGEX"
	fi

	log "Downloading $asset_url"
	tmp_dir="$(mktemp -d)"
	tarball_path="$tmp_dir/package.tar.gz"
	curl -fsSL "$asset_url" -o "$tarball_path"

	extract_dir="$tmp_dir/extracted"
	mkdir -p "$extract_dir"
	tar -xzf "$tarball_path" -C "$extract_dir"

	bundle_root="$extract_dir"
	top_level_count=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
	if [[ "$top_level_count" == "1" ]]; then
		bundle_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
	fi

	install_from_bundle "$bundle_root"
	rm -rf "$tmp_dir"
}

AUTO_YES="0"
MODE=""
BUNDLE_ROOT=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--bundle)
			MODE="bundle"
			shift
			;;
		--download)
			MODE="download"
			shift
			;;
		--bundle-root)
			BUNDLE_ROOT="$2"
			shift 2
			;;
		--yes)
			AUTO_YES="1"
			shift
			;;
		-h|--help)
			print_usage
			exit 0
			;;
		*)
			fail "Unknown argument: $1"
			;;
	esac
done

if [[ -z "$MODE" ]]; then
	if [[ -n "$BUNDLE_MARKER_RELATIVE" ]] \
		&& [[ -e "$SCRIPT_DIR/$BUNDLE_MARKER_RELATIVE" ]]; then
		MODE="bundle"
	else
		MODE="download"
	fi
fi

if [[ "$MODE" == "bundle" ]]; then
	if [[ -z "$BUNDLE_ROOT" ]]; then
		BUNDLE_ROOT="$SCRIPT_DIR"
	fi
	install_from_bundle "$BUNDLE_ROOT"
elif [[ "$MODE" == "download" ]]; then
	check_metadata
	download_latest_tarball
else
	fail "Unsupported mode: $MODE"
fi
