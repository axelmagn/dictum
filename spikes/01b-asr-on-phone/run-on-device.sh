#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/app"

echo "=== Dictum Spike 1b: Device Runner ==="

# 1. Check adb and device
if ! command -v adb &> /dev/null; then
    echo "ERROR: adb not found in PATH." >&2
    exit 1
fi

DEVICE_COUNT=$(adb devices | grep -v "List" | grep "device$" | wc -l)
if [ "$DEVICE_COUNT" -eq 0 ]; then
    echo "ERROR: No connected Android device found in 'device' state." >&2
    echo "Check 'adb devices' output and permissions." >&2
    exit 1
fi

DEVICE_MODEL=$(adb shell getprop ro.product.model | tr -d '\r' | tr ' ' '_')
DEVICE_MANUF=$(adb shell getprop ro.product.manufacturer | tr -d '\r' | tr ' ' '_')
DEVICE_TAG="${DEVICE_MANUF}_${DEVICE_MODEL}"

echo "Connected device: ${DEVICE_TAG}"

APP_PKG="dev.dictum.spike.app"
DEVICE_FILES_DIR="/sdcard/Android/data/${APP_PKG}/files"

# 2. Build release APK
echo ""
echo "=== Building Release APK ==="
(cd "${APP_DIR}" && fvm flutter build apk --release)

APK_PATH="${APP_DIR}/build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK_PATH" ]; then
    echo "ERROR: APK not found at $APK_PATH" >&2
    exit 1
fi

# 3. Install APK
echo ""
echo "=== Installing Release APK ==="
adb install -r "$APK_PATH"

# 4. Prepare device directories and push models & audio
echo ""
echo "=== Setting up test assets on device ==="
adb shell "mkdir -p '${DEVICE_FILES_DIR}/models' '${DEVICE_FILES_DIR}/audio' '${DEVICE_FILES_DIR}/out'"

echo "Pushing models..."
adb push "${SCRIPT_DIR}/models/ggml-small.en-q5_0.bin" "${DEVICE_FILES_DIR}/models/"
adb push "${SCRIPT_DIR}/models/ggml-medium.en-q5_0.bin" "${DEVICE_FILES_DIR}/models/"
adb push "${SCRIPT_DIR}/models/ggml-silero-v6.2.0.bin" "${DEVICE_FILES_DIR}/models/"

echo "Pushing audio..."
adb push "${SCRIPT_DIR}/audio/clip8.wav" "${DEVICE_FILES_DIR}/audio/"
adb push "${SCRIPT_DIR}/audio/long30.wav" "${DEVICE_FILES_DIR}/audio/"

# 5. Launch app
echo ""
echo "=== Launching App ==="
adb shell am start -n "${APP_PKG}/.MainActivity"

echo ""
echo "App is now running on device."
echo "Tap 'Run All Benchmarks (Matrix)' on screen to execute the benchmark suite."
echo "If testing battery on long30, you may unplug USB now (or use Wi-Fi adb)."
echo ""
read -r -p "Press ENTER after the benchmarks have completed on device to pull results..."

# 6. Pull results
OUT_DEST="${SCRIPT_DIR}/out/${DEVICE_TAG}"
mkdir -p "$OUT_DEST"
echo ""
echo "=== Pulling results from device to ${OUT_DEST} ==="
adb pull "${DEVICE_FILES_DIR}/out/." "${OUT_DEST}/" || true

# Also copy into spike root out/ if this is the primary run
cp -r "${OUT_DEST}"/* "${SCRIPT_DIR}/out/" 2>/dev/null || true

echo ""
echo "=== Benchmark Results Summary ==="
ls -la "${OUT_DEST}"

echo ""
echo "=== To uninstall the test app from device: ==="
echo "adb uninstall ${APP_PKG}"
