green() { 
  echo -e "\033[32m$1\033[0m"
}

red() {
  echo -e "\033[31m$1\033[0m"
}

blue() {
  echo -e "\033[36m$1\033[0m"
}

PROJECT_ROOT=$(dirname "$(realpath "$0")")/..
cd "$PROJECT_ROOT"
green "Project root: $PROJECT_ROOT"



if ! command -v flutter &> /dev/null
then
    red "Flutter is not installed. Please install Flutter to build the project."
    exit
fi

if ! command -v tar &> /dev/null
then
    red "tar is not installed. Please install tar to create the Linux package."
    exit
fi

SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build)
			SKIP_BUILD=1
			shift
			;;
		*)
			fail "Unknown argument: $1"
			;;
	esac
done

if [[ $SKIP_BUILD -eq 0 ]]; then
  blue "Starting build process..."

  blue "Building release versions for Android"
  flutter build apk --release
  green "Android release build complete."

  blue "Building release version for Linux"
  flutter build linux --release
else
  blue "Skipping build..."
fi

blue "Creating package for Linux"
bundle_root=./build/linux/x64/release
bundle_dir="$bundle_root/bundle"

cp ./linux/install.sh "$bundle_dir/"
cp ./linux/linia.desktop "$bundle_dir/"

cd "$bundle_dir"
tar -czvf linia-linux-x64.tar.gz .

green "Linux release build complete."


