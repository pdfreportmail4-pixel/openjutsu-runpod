#!/usr/bin/env bash
# Clones the custom node packs OpenJutsu uses at pinned commits (state of 11 Nov 2026)
# and installs their Python dependencies into ComfyUI's venv.
set -euo pipefail

CN=/opt/ComfyUI/custom_nodes
PIP=(pip install -c /opt/constraints.txt)

# folder | repo | commit | deps (req = requirements.txt, req-nosam2 = without the sam2 line, none)
NODES=(
  "ComfyUI-MiniMaxH3-Context-Loop|https://github.com/ethanfel/ComfyUI-MiniMaxH3-Context-Loop|43afeffcc570beb5f7382593e79e4b211c7e02f6|none"
  "ComfyUI-Fantastic-MiniMaxH3-PromptBuilder|https://github.com/Adudeguyman/ComfyUI-Fantastic-MiniMaxH3-PromptBuilder|22e719fe89336c628383363182a4da3cb58d4f9b|req"
  "ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes|ab72eda7ffad6280422d71ab7d54d3fb87c0ba18|req"
  "ComfyUI-VideoHelperSuite|https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite|4d907bee61e92c2e65af3bd6383a4e4d356126d1|req"
  "comfyui-h3-oneclick-swap|https://github.com/D3voz/comfyui-h3-oneclick-swap|e44a56e92920000e675d14be484aea0d7498d63e|none"
  "comfyui-websocket-reconnect-fix|https://github.com/D3voz/comfyui-websocket-reconnect-fix|12b5fdf38e8bdbf8a560b9196561244bf65621f4|none"
  "ComfyUI-H3-FaceRefine|https://github.com/Carasibana/ComfyUI-H3-FaceRefine|d8521d14fe0d721d80cd9417fff5a559cbc21aba|req"
  "ComfyUI-Impact-Pack|https://github.com/ltdrdata/ComfyUI-Impact-Pack|ed1bd80650a1d9c9f5d17d6411455e65ad43b58b|req-nosam2"
  "ComfyUI-Impact-Subpack|https://github.com/ltdrdata/ComfyUI-Impact-Subpack|50c7b71a6a224734cc9b21963c6d1926816a97f1|req"
  "comfyui-image-detail-contrast|https://github.com/D3voz/comfyui-image-detail-contrast|485a5e246424ce012b998862b45f06d21e8d63b2|none"
  "Orion4D_FXMax|https://github.com/orion4d/Orion4D_FXMax|7048e8423ad7d1a6a52119d0d4870c2b7fc2885f|req"
  "comfyui_controlnet_aux|https://github.com/Fannovel16/comfyui_controlnet_aux|a587a4c1594524c1d2de5cd1a86cd868ff448e1c|req"
  # SolarRenderer runs in ComfyUI's env; its own pyproject pins an older torch, so do not pip-install it.
  "SolarRenderer|https://github.com/Enderfga/SolarRenderer|0ca4f5e45b062cc9e9aee506de46aabdc22e4c3d|none"
)

# Packs every OpenJutsu swap mode needs; the build fails if one of these does not import.
REQUIRED=(ComfyUI-MiniMaxH3-Context-Loop ComfyUI-Fantastic-MiniMaxH3-PromptBuilder ComfyUI-KJNodes
          ComfyUI-VideoHelperSuite comfyui-h3-oneclick-swap comfyui-websocket-reconnect-fix)

for entry in "${NODES[@]}"; do
  IFS='|' read -r name url sha deps <<< "$entry"
  echo "==> $name @ ${sha:0:7}"
  if [[ ! -d "$CN/$name/.git" ]]; then   # reuse a clone left by an earlier (interrupted) run
    rm -rf "$CN/$name"
    git clone --filter=blob:none --quiet "$url" "$CN/$name"
  fi
  git -C "$CN/$name" checkout --quiet "$sha"
  req="$CN/$name/requirements.txt"
  case "$deps" in
    req)        [[ -f "$req" ]] && "${PIP[@]}" -r "$req" ;;
    req-nosam2) grep -v 'sam2' "$req" > /tmp/req-nosam2.txt && "${PIP[@]}" -r /tmp/req-nosam2.txt ;;
    none)       ;;
  esac
done

# One OpenCV build (several packs pull in both the GUI and headless wheels, which clash)
pip uninstall -y opencv-python opencv-contrib-python opencv-python-headless >/dev/null 2>&1 || true
"${PIP[@]}" opencv-python-headless
# InsightFace must see only onnxruntime-gpu, not the CPU package as well
pip uninstall -y onnxruntime >/dev/null 2>&1 || true
"${PIP[@]}" onnxruntime-gpu
pip check || echo "(pip check warnings above are informational)"

# Import test: ComfyUI loads every pack on CPU and exits (skipped at pod start, ComfyUI logs it anyway)
if [[ "${SKIP_IMPORT_TEST:-0}" == "1" ]]; then echo "import test skipped"; exit 0; fi
cd /opt/ComfyUI
python main.py --cpu --quick-test-for-ci 2>&1 | tee /opt/import_report.txt | grep -E "IMPORT FAILED|seconds" || true
failed=0
if ! grep -q "Import times for custom nodes" /opt/import_report.txt; then
  echo "ERROR: ComfyUI did not finish loading the custom nodes:"; tail -n 40 /opt/import_report.txt; exit 1
fi
for name in "${REQUIRED[@]}"; do
  if grep -q "(IMPORT FAILED).*custom_nodes/$name" /opt/import_report.txt; then
    echo "ERROR: required pack failed to import: $name"; failed=1
  fi
done
if grep -q "(IMPORT FAILED)" /opt/import_report.txt; then
  echo "WARNING: some optional packs failed to import (see /opt/import_report.txt):"
  grep "(IMPORT FAILED)" /opt/import_report.txt || true
fi
exit "$failed"
