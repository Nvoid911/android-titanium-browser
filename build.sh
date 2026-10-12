#!/bin/bash
source common.sh
set_keys
export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://chromium.googlesource.com/chromium/src.git # https://github.com/chromium/chromium.git
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow imagemagick librsvg2-bin
sudo dpkg --add-architecture i386; sudo apt-get update; sudo apt-get install -y libgcc-s1:i386

git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"
mkdir -p chromium/src/out/Default; cd chromium/src
# Chromium and Vanadium hooks create commits while applying patches.
# Set an identity before any git am invocation, including gclient hooks.
git config --global user.name "GitHub Actions"
git config --global user.email "github-actions[bot]@users.noreply.github.com"
git init
git remote add origin $CHROMIUM_SOURCE
git fetch --depth 1 $CHROMIUM_SOURCE +refs/tags/$VERSION:chromium_$VERSION
git checkout $VERSION
cp $SCRIPT_DIR/.gclient ../.gclient

# https://grapheneos.org/build#browser-and-webview
rm -rf $SCRIPT_DIR/vanadium/patches/*trichrome-{apk-build-targets,browser-apk-targets}.patch
rm -rf $SCRIPT_DIR/vanadium/patches/*{detailed,supported}-language*.patch
rm -rf $SCRIPT_DIR/vanadium/patches/*javascript-optimizer-{site-setting,settings-UI}.patch
rm -rf $SCRIPT_DIR/vanadium/patches/*component-updates.patch
rm -rf $SCRIPT_DIR/vanadium/patches/*{pdf,PDF,for-content-public,toolbar-button,configs-from-config-app,config-app-parsing,new-tab-card,predictive-back}*.patch
# rm -rf $SCRIPT_DIR/vanadium/patches/*crashpad*.patch
replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "TITANIUM"
replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Titanium"
replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "titanium"
git am --whitespace=nowarn --keep-non-patch "$SCRIPT_DIR"/vanadium/patches/*.patch || {
    echo "ERROR: failed to apply Vanadium patches to Chromium." >&2
    echo "Check the first git am error above; do not continue with an incomplete source tree." >&2
    exit 1
}

gclient sync -D --no-history --nohooks
# The filter-list hook writes into this Titanium-specific directory.
# Chromium checkout does not guarantee that the parent directory exists.
mkdir -p titanium/android_config/filter_lists
# Surface the actual git-am failure from Vanadium's subproject patch hook.
python3 - <<'PY'
from pathlib import Path
p = Path("../vanadium/tools/common/apply_subprojects_patches.py")
s = p.read_text()
old = """            git_am_stdout_lines = git_am_stdout_str.splitlines()
            git_am_patch_msg = git_am_stdout_lines[0].replace('Applying: ', '')
"""
new = """            git_am_stdout_lines = git_am_stdout_str.splitlines()
            if not git_am_stdout_lines:
                print(f"Subproject patch failed: {patches_path}", file=sys.stderr)
                print(git_am_completed_proc.stderr.decode('utf-8', errors='replace'), file=sys.stderr)
                git_am_completed_proc.check_returncode()
            git_am_patch_msg = git_am_stdout_lines[0].replace('Applying: ', '')
"""
if old not in s:
    raise SystemExit("Could not safely patch Vanadium subproject hook")
p.write_text(s.replace(old, new))
PY
gclient runhooks || { echo "ERROR: gclient runhooks failed; stopping before patch.sh."; exit 1; }
./build/install-build-deps.sh --no-prompt

source $SCRIPT_DIR/patch.sh
cp $SCRIPT_DIR/args.gn out/Default/args.gn
if [ "$F11_TEST_BUILD" = "1" ]; then
    # F11 behavior testing needs an arm64 APK, not production debugging symbols.
    # Keep official/release optimization, but omit symbols and linker maps to
    # reduce compile time, disk usage, and memory pressure on hosted runners.
    sed -i 's/target_cpu = "arm"/target_cpu = "arm64"/' out/Default/args.gn
    sed -i 's/^symbol_level = .*/symbol_level = 0/' out/Default/args.gn
    printf '\\nblink_symbol_level = 0\\nv8_symbol_level = 0\\ngenerate_linker_map = false\\n' >> out/Default/args.gn
fi
python3 build/util/lastchange.py -o build/util/LASTCHANGE || { echo "ERROR: failed to generate Chromium LASTCHANGE metadata."; exit 1; }
gn gen out/Default || { echo "ERROR: gn gen failed; stopping before compilation/signing."; exit 1; }
mkdir -p out/tmp out/release

if [ "$F11_TEST_BUILD" = "1" ]; then
    # Build only the arm64 APK for the F11 feature test.
    autoninja -C out/Default chrome_public_apk || { echo "ERROR: Chromium APK build failed; stopping before signing."; exit 1; }
    APK=$(find out/Default/apks -name 'Chrome*.apk' -print -quit)
    if [ -z "$APK" ]; then echo "ERROR: Chromium APK was not generated."; exit 1; fi
    mv "$APK" out/tmp/$VERSION-arm64-v8a.apk
else
    autoninja -C out/Default chrome_public_apk
    mv $(find out/Default/apks -name 'Chrome*.apk') out/tmp/$VERSION-armeabi-v7a.apk
    sed -i 's/target_cpu = "arm"/target_cpu = "arm64"/' out/Default/args.gn
    autoninja -C out/Default chrome_public_apk chrome_public_bundle
    mv $(find out/Default/apks -name 'Chrome*.apk') out/tmp/$VERSION-arm64-v8a.apk
    mv $(find out/Default/apks -name 'Chrome*.aab') out/tmp/$VERSION-arm64-v8a.aab
fi

export PATH=$PWD/third_party/jdk/current/bin/:$PATH
export ANDROID_HOME=$PWD/third_party/android_sdk/public
if [ "$F11_TEST_BUILD" = "1" ]; then
    sign_apk out/tmp/$VERSION-arm64-v8a.apk out/release/$VERSION-arm64-v8a.apk
else
    sign_apk out/tmp/$VERSION-armeabi-v7a.apk out/release/$VERSION-armeabi-v7a.apk
    sign_apk out/tmp/$VERSION-arm64-v8a.apk out/release/$VERSION-arm64-v8a.apk
    sign_aab out/tmp/$VERSION-arm64-v8a.aab out/release/$VERSION-arm64-v8a.aab
fi
rm -rf $SCRIPT_DIR/keys
