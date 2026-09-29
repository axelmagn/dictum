#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/app"

echo "=== Dictum Spike 02: Dictation Prototype Runner ==="

# 1. Check adb and device
if ! command -v adb &> /dev/null; then
    echo "ERROR: adb not found in PATH." >&2
    exit 1
fi

DEVICE_COUNT=$(adb devices | grep -v "List" | grep "device$" | wc -l)
if [ "$DEVICE_COUNT" -eq 0 ]; then
    echo "ERROR: No connected Android device found in 'device' state." >&2
    exit 1
fi

DEVICE_MODEL=$(adb shell getprop ro.product.model | tr -d '\r' | tr ' ' '_')
DEVICE_MANUF=$(adb shell getprop ro.product.manufacturer | tr -d '\r' | tr ' ' '_')
DEVICE_TAG="${DEVICE_MANUF}_${DEVICE_MODEL}"

echo "Connected device: ${DEVICE_TAG}"

APP_PKG="dev.dictum.spike.app"
DEVICE_FILES_DIR="/sdcard/Android/data/${APP_PKG}/files"

# 2. Build release APK if requested or not present
APK_PATH="${APP_DIR}/build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK_PATH" ] || [ "${1:-}" = "--build" ]; then
    echo ""
    echo "=== Building Release APK ==="
    export PATH="/home/axel/fvm/versions/3.47.1/bin:$PATH"
    (cd "${APP_DIR}" && flutter build apk --release)
fi

# 3. Install APK
echo ""
echo "=== Installing Release APK ==="
adb install -r "$APK_PATH"

# 4. Grant RECORD_AUDIO permission directly via adb
echo "Granting RECORD_AUDIO permission..."
adb shell pm grant "${APP_PKG}" android.permission.RECORD_AUDIO || true

# 5. Prepare device directories and push models & audio
echo ""
echo "=== Setting up assets on device ==="
adb shell "mkdir -p '${DEVICE_FILES_DIR}/models' '${DEVICE_FILES_DIR}/audio' '${DEVICE_FILES_DIR}/out'"

echo "Pushing models..."
adb push "${SCRIPT_DIR}/models/ggml-small.en-q5_0.bin" "${DEVICE_FILES_DIR}/models/"
adb push "${SCRIPT_DIR}/models/ggml-silero-v6.2.0.bin" "${DEVICE_FILES_DIR}/models/"

echo "Pushing audio assets..."
if [ -f "${SCRIPT_DIR}/audio/phonetic_test.wav" ]; then
    adb push "${SCRIPT_DIR}/audio/phonetic_test.wav" "${DEVICE_FILES_DIR}/audio/"
fi
if [ -f "${SCRIPT_DIR}/../01b-asr-on-phone/audio/clip8.wav" ]; then
    adb push "${SCRIPT_DIR}/../01b-asr-on-phone/audio/clip8.wav" "${DEVICE_FILES_DIR}/audio/"
fi
if [ -f "${SCRIPT_DIR}/../01b-asr-on-phone/audio/long30.wav" ]; then
    adb push "${SCRIPT_DIR}/../01b-asr-on-phone/audio/long30.wav" "${DEVICE_FILES_DIR}/audio/"
fi

# 6. Launch app
echo ""
echo "=== Launching Prototype App ==="
adb shell am start -n "${APP_PKG}/.MainActivity"

echo ""
echo "App is now running on device."
echo "You can record live speech or tap the Assessment icon in the app bar to run the Phonetic Test Script benchmark."
