#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${NUXIE_FLOW_RUNTIME_OUTPUT_DIR:-$ROOT_DIR/test-results/flow-runtime}"
RESULT_BUNDLE="$OUTPUT_DIR/NuxieFlowRuntimeUITests.xcresult"
SCREENSHOTS_DIR="$OUTPUT_DIR/screenshots"
VIDEOS_DIR="$OUTPUT_DIR/videos"
VIDEO_FILE="$VIDEOS_DIR/flow-runtime-ui.mp4"
DESTINATION="${TEST_DESTINATION:-platform=iOS Simulator,name=${TEST_SIMULATOR_NAME:-iPhone 17 Pro},OS=${TEST_SIMULATOR_OS:-26.4}}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$SCREENSHOTS_DIR"
mkdir -p "$VIDEOS_DIR"

start_recording() {
  (
    for _ in $(seq 1 120); do
      if xcrun simctl list devices booted 2>/dev/null | grep -q "(Booted)"; then
        xcrun simctl io booted recordVideo --codec=h264 "$VIDEO_FILE"
        exit 0
      fi
      sleep 1
    done
  ) >/dev/null 2>&1 &
  RECORDER_PID=$!
}

stop_recording() {
  local pid="${1:-}"
  if [ -z "$pid" ]; then
    return
  fi
  if kill -0 "$pid" 2>/dev/null; then
    pkill -INT -f "simctl io booted recordVideo.*$VIDEO_FILE" 2>/dev/null || true
    kill -INT "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

set +e
RECORDER_PID=""
start_recording
if [ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]; then
  NUXIE_FLOW_RUNTIME_OUTPUT_DIR="$OUTPUT_DIR" xcodebuild test \
    -project NuxieSDK.xcodeproj \
    -scheme NuxieFlowRuntimeUITests \
    -configuration Debug \
    -derivedDataPath DerivedData \
    -destination "$DESTINATION" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH"
else
  NUXIE_FLOW_RUNTIME_OUTPUT_DIR="$OUTPUT_DIR" xcodebuild test \
    -project NuxieSDK.xcodeproj \
    -scheme NuxieFlowRuntimeUITests \
    -configuration Debug \
    -derivedDataPath DerivedData \
    -destination "$DESTINATION" \
      -resultBundlePath "$RESULT_BUNDLE"
fi
STATUS=$?
stop_recording "$RECORDER_PID"
set -e

python3 - "$RESULT_BUNDLE" "$SCREENSHOTS_DIR" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

result_bundle = Path(sys.argv[1])
screenshots_dir = Path(sys.argv[2])

if not result_bundle.exists():
    sys.exit(0)

screenshots_dir.mkdir(parents=True, exist_ok=True)

def xcresult_json(object_id=None):
    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "--legacy",
        "--format",
        "json",
        "--path",
        str(result_bundle),
    ]
    if object_id:
        command.extend(["--id", object_id])
    return json.loads(subprocess.check_output(command))

def value(node):
    if isinstance(node, dict):
        return node.get("_value")
    return None

def walk(node):
    if isinstance(node, dict):
        yield node
        for child in node.values():
            yield from walk(child)
    elif isinstance(node, list):
        for child in node:
            yield from walk(child)

def references(node, target_type):
    for item in walk(node):
        if item.get("_type", {}).get("_name") != "Reference":
            continue
        if value(item.get("targetType", {}).get("name")) != target_type:
            continue
        ref_id = value(item.get("id"))
        if ref_id:
            yield ref_id

def safe_name(raw):
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", raw).strip("-._")
    return name or "screenshot"

root = xcresult_json()

for tests_ref in references(root, "ActionTestPlanRunSummaries"):
    tests = xcresult_json(tests_ref)
    for summary_ref in references(tests, "ActionTestSummary"):
        summary = xcresult_json(summary_ref)
        for attachment in walk(summary):
            if attachment.get("_type", {}).get("_name") != "ActionTestAttachment":
                continue
            if value(attachment.get("uniformTypeIdentifier")) != "public.png":
                continue

            payload_id = value(attachment.get("payloadRef", {}).get("id"))
            if not payload_id:
                continue

            name = value(attachment.get("name")) or value(attachment.get("filename")) or payload_id
            output = screenshots_dir / f"{safe_name(name)}.png"
            index = 2
            while output.exists():
                output = screenshots_dir / f"{safe_name(name)}-{index}.png"
                index += 1

            subprocess.check_call([
                "xcrun",
                "xcresulttool",
                "export",
                "object",
                "--legacy",
                "--path",
                str(result_bundle),
                "--id",
                payload_id,
                "--type",
                "file",
                "--output-path",
                str(output),
            ])
PY

REPORT="$OUTPUT_DIR/index.html"
{
  cat <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Nuxie iOS Flow Runtime UI Report</title>
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f6f7f9; color: #14171f; }
    main { max-width: 1120px; margin: 0 auto; padding: 32px 20px 48px; }
    header { display: flex; justify-content: space-between; gap: 24px; align-items: flex-start; margin-bottom: 28px; }
    h1 { font-size: 24px; line-height: 1.2; margin: 0 0 8px; }
    p { margin: 0; color: #596170; }
    .status { padding: 8px 12px; border-radius: 999px; font-weight: 700; font-size: 13px; background: $(if [ "$STATUS" -eq 0 ]; then echo "#def7ec"; else echo "#fde8e8"; fi); color: $(if [ "$STATUS" -eq 0 ]; then echo "#03543f"; else echo "#9b1c1c"; fi); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 18px; }
    .card { background: white; border: 1px solid #dde2ea; border-radius: 10px; padding: 14px; box-shadow: 0 1px 2px rgba(20, 23, 31, 0.05); }
    .card h2 { font-size: 15px; margin: 0 0 12px; }
    img { display: block; width: 100%; border-radius: 8px; border: 1px solid #e6e9ef; background: white; }
    video { display: block; width: 100%; border-radius: 8px; border: 1px solid #e6e9ef; background: black; margin-bottom: 24px; }
    code { background: #edf0f5; border-radius: 5px; padding: 2px 5px; }
    .empty { background: white; border: 1px dashed #b8c0cc; border-radius: 10px; padding: 28px; color: #596170; }
  </style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>Nuxie iOS Flow Runtime UI Report</h1>
      <p>Destination: <code>$DESTINATION</code></p>
      <p>Result bundle: <code>$(basename "$RESULT_BUNDLE")</code></p>
    </div>
    <div class="status">$(if [ "$STATUS" -eq 0 ]; then echo "Passed"; else echo "Failed ($STATUS)"; fi)</div>
  </header>
HTML

  if [ -s "$VIDEO_FILE" ]; then
    cat <<HTML
  <section>
    <h2>Simulator Recording</h2>
    <video controls src="videos/$(basename "$VIDEO_FILE")"></video>
  </section>
HTML
  fi

  shopt -s nullglob
  screenshots=("$SCREENSHOTS_DIR"/*.png)
  if [ "${#screenshots[@]}" -eq 0 ]; then
    echo '  <div class="empty">No screenshots were written by the UI tests.</div>'
  else
    echo '  <section class="grid">'
    for screenshot in "${screenshots[@]}"; do
      filename="$(basename "$screenshot")"
      name="${filename%.png}"
      cat <<HTML
    <article class="card">
      <h2>$name</h2>
      <img src="screenshots/$filename" alt="$name screenshot">
    </article>
HTML
    done
    echo '  </section>'
  fi

  cat <<HTML
</main>
</body>
</html>
HTML
} > "$REPORT"

echo "Flow runtime UI report: $REPORT"
exit "$STATUS"
