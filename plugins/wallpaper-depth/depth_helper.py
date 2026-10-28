#!/usr/bin/env python3
"""Bootstrap a depth model and render source-aligned wallpaper foreground masks.

Ported from the Noctalia "Wallpaper Depth" plugin (MIT licensed). The model is
downloaded once into the plugin data directory and never leaves the machine;
inference, depth caches and masks stay local.

The pipeline, thresholds and defaults follow upstream: the relative depth is
normalized, guided-filtered against the source image, and cut at an absolute
normalised depth of `threshold` with a soft `feather` band around it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

MODEL_REPO = "onnx-community/depth-anything-v2-small-ONNX"
MODEL_REVISION = "c3b67641fd837b2368757101311e5d21e511441e"
# (file name, byte size, sha256) of the quantized ONNX export, weights included.
MODEL_FILES = (
    ("model_quantized.onnx", 162_005, "ed7680047cd210143f9f9c4468d049c1f19f8a7a58631d52868831376fe152c9"),
    ("model_quantized.onnx_data", 38_414_848, "1595c419ac7d75a356c6835890f2e64fd370a38444ddfcb741ca6b6b96e1a42a"),
)
MODEL_NAME = "depth-anything-v2-small-quantized"
MODEL_SIZE = sum(entry[1] for entry in MODEL_FILES)
MODEL_SHA256 = MODEL_FILES[0][2]
INPUT_SIZE = 518
MODEL_PATCH_SIZE = 14
DEPTH_PIPELINE_VERSION = 2
MASK_PIPELINE_VERSION = 8
REFINEMENT_MAX_DIMENSION = 1920
GUIDED_FILTER_RADIUS = 8
GUIDED_FILTER_EPSILON = 0.001
PYTHON_MIN = (3, 11)
PACKAGES = (
    "numpy>=2,<3",
    "onnxruntime>=1.20",
    "Pillow>=11",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as stream:
        json.dump(value, stream, separators=(",", ":"), sort_keys=True)
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path)


def runtime_python(data_dir: Path) -> Path:
    return data_dir / "runtime" / ".venv" / "bin" / "python"


def model_dir(data_dir: Path) -> Path:
    return data_dir / "models" / MODEL_NAME


def model_entry_point(data_dir: Path) -> Path:
    return model_dir(data_dir) / MODEL_FILES[0][0]


def verify_model(data_dir: Path) -> bool:
    directory = model_dir(data_dir)
    for name, size, checksum in MODEL_FILES:
        path = directory / name
        if not path.is_file() or path.stat().st_size != size or sha256_file(path) != checksum:
            return False
    return True


def system_ready() -> bool:
    try:
        import numpy, onnxruntime, PIL
    except Exception:
        return False
    return True


def runtime_ready(data_dir: Path) -> bool:
    if system_ready():
        return True
    python = runtime_python(data_dir)
    if not python.is_file():
        return False
    result = subprocess.run(
        [str(python), "-c", "import numpy, onnxruntime, PIL"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def emit(value: dict[str, object]) -> None:
    print(json.dumps(value, separators=(",", ":"), sort_keys=True), flush=True)


def model_url(name: str) -> str:
    return f"https://huggingface.co/{MODEL_REPO}/resolve/{MODEL_REVISION}/onnx/{name}?download=true"


def open_model_url(request: urllib.request.Request):
    # The only network access in the plugin: the one-off model download the user
    # starts from the panel. Errors surface in the panel.
    return urllib.request.urlopen(request, timeout=60)  # caelestia-audit: allow-network


def download_model(data_dir: Path) -> None:
    directory = model_dir(data_dir)
    directory.mkdir(parents=True, exist_ok=True)
    for name, size, checksum in MODEL_FILES:
        destination = directory / name
        if destination.is_file() and destination.stat().st_size == size:
            continue
        temporary = destination.with_suffix(destination.suffix + ".part")
        temporary.unlink(missing_ok=True)
        request = urllib.request.Request(
            model_url(name),
            headers={"User-Agent": "Caelestia-Wallpaper-Depth/1.0"},
        )
        try:
            with open_model_url(request) as response, temporary.open("wb") as stream:
                while chunk := response.read(1024 * 1024):
                    stream.write(chunk)
            if temporary.stat().st_size != size:
                raise RuntimeError(
                    f"{name}: size mismatch, expected {size} bytes, received {temporary.stat().st_size}"
                )
            if sha256_file(temporary) != checksum:
                raise RuntimeError(f"{name}: checksum mismatch")
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
    if not verify_model(data_dir):
        raise RuntimeError("model validation failed after download")


def setup(data_dir: Path) -> None:
    operation_path = data_dir / "setup-operation.json"
    atomic_json(
        operation_path,
        {"state": "running", "startedAt": int(time.time()), "modelSize": MODEL_SIZE},
    )
    if sys.version_info[:2] < PYTHON_MIN:
        raise RuntimeError("Python 3.11 or newer is required")
    runtime_dir = data_dir / "runtime"
    venv = runtime_dir / ".venv"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    if not runtime_ready(data_dir):
        subprocess.run(
            [sys.executable, "-m", "venv", "--clear", str(venv)],
            stdin=subprocess.DEVNULL,
            check=True,
        )
        subprocess.run(
            [
                str(runtime_python(data_dir)),
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "--no-input",
                "--no-user",
                "--only-binary=:all:",
                *PACKAGES,
            ],
            stdin=subprocess.DEVNULL,
            check=True,
        )
    if not verify_model(data_dir):
        download_model(data_dir)
    if not runtime_ready(data_dir) or not verify_model(data_dir):
        raise RuntimeError("setup validation failed")
    status_payload = {
        "ready": True,
        "modelRevision": MODEL_REVISION,
        "modelSha256": MODEL_SHA256,
        "modelSize": MODEL_SIZE,
        "packages": list(PACKAGES),
    }
    atomic_json(data_dir / "setup.json", status_payload)
    atomic_json(
        operation_path,
        {
            "state": "ready",
            "finishedAt": int(time.time()),
            "modelRevision": MODEL_REVISION,
            "modelSize": MODEL_SIZE,
        },
    )
    emit(status_payload)


def status(data_dir: Path) -> None:
    emit(
        {
            "ready": runtime_ready(data_dir) and verify_model(data_dir),
            "runtimeReady": runtime_ready(data_dir),
            "modelReady": verify_model(data_dir),
            "modelRevision": MODEL_REVISION,
            "modelSize": MODEL_SIZE,
            "python": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        }
    )


def inference_size(source_width: int, source_height: int) -> tuple[int, int]:
    scale = max(INPUT_SIZE / source_width, INPUT_SIZE / source_height)
    width = max(
        INPUT_SIZE,
        round(source_width * scale / MODEL_PATCH_SIZE) * MODEL_PATCH_SIZE,
    )
    height = max(
        INPUT_SIZE,
        round(source_height * scale / MODEL_PATCH_SIZE) * MODEL_PATCH_SIZE,
    )
    return width, height


def smoothstep(values, low: float, high: float):
    import numpy as np

    if high <= low:
        return (values >= high).astype(np.float32)
    scaled = np.clip((values - low) / (high - low), 0.0, 1.0)
    return scaled * scaled * (3.0 - 2.0 * scaled)


def box_mean(values, radius: int):
    import numpy as np

    padded = np.pad(values, ((radius, radius), (radius, radius)), mode="edge")
    integral = np.pad(padded, ((1, 0), (1, 0)), mode="constant")
    integral = np.cumsum(integral, axis=0, dtype=np.float64)
    integral = np.cumsum(integral, axis=1, dtype=np.float64)
    diameter = radius * 2 + 1
    total = (
        integral[diameter:, diameter:]
        - integral[:-diameter, diameter:]
        - integral[diameter:, :-diameter]
        + integral[:-diameter, :-diameter]
    )
    total *= 1.0 / (diameter * diameter)
    return total.astype(np.float32)


def refine_depth(source_rgb, depth):
    import numpy as np
    from PIL import Image

    source_width, source_height = source_rgb.size
    scale = min(1.0, REFINEMENT_MAX_DIMENSION / max(source_width, source_height))
    refinement = (
        max(1, round(source_width * scale)),
        max(1, round(source_height * scale)),
    )
    guide_image = source_rgb.convert("L")
    if guide_image.size != refinement:
        guide_image = guide_image.resize(refinement, Image.Resampling.LANCZOS)
    guide = np.asarray(guide_image, dtype=np.float32) / np.float32(255.0)
    coarse = np.asarray(
        Image.fromarray(depth).resize(refinement, Image.Resampling.BICUBIC),
        dtype=np.float32,
    )

    mean_guide = box_mean(guide, GUIDED_FILTER_RADIUS)
    mean_depth = box_mean(coarse, GUIDED_FILTER_RADIUS)
    correlation_guide = box_mean(guide * guide, GUIDED_FILTER_RADIUS)
    correlation_cross = box_mean(guide * coarse, GUIDED_FILTER_RADIUS)
    variance_guide = correlation_guide - mean_guide * mean_guide
    covariance = correlation_cross - mean_guide * mean_depth
    coefficient_a = covariance / (variance_guide + np.float32(GUIDED_FILTER_EPSILON))
    coefficient_b = mean_depth - coefficient_a * mean_guide
    refined = np.clip(
        box_mean(coefficient_a, GUIDED_FILTER_RADIUS) * guide
        + box_mean(coefficient_b, GUIDED_FILTER_RADIUS),
        0.0,
        1.0,
    ).astype(np.float32)

    if refinement != (source_width, source_height):
        refined = np.asarray(
            Image.fromarray(refined).resize((source_width, source_height), Image.Resampling.BICUBIC),
            dtype=np.float32,
        )
    return refined


def prune(directory: Path, maximum: int, suffix: str) -> None:
    if not directory.is_dir():
        return
    files = sorted(
        (path for path in directory.iterdir() if path.is_file() and path.suffix == suffix),
        key=lambda path: path.stat().st_mtime_ns,
        reverse=True,
    )
    for path in files[maximum:]:
        path.unlink(missing_ok=True)


def inference_session(data_dir: Path):
    import onnxruntime as ort

    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    # Naming the thread counts keeps onnxruntime from failing to pin threads
    # inside the shell's session and settles on a predictable cost.
    options.intra_op_num_threads = max(1, min(8, os.cpu_count() or 4))
    options.inter_op_num_threads = 1
    return ort.InferenceSession(
        str(model_entry_point(data_dir)),
        sess_options=options,
        providers=["CPUExecutionProvider"],
    )


def background_cut(values, bins: int = 256) -> float:
    """Cut just above the depth plateau that the empty background occupies.

    Sky, haze and other flat backdrop regions collapse into one narrow, very tall
    histogram peak; everything the viewer reads as scenery sits above it. Cutting
    just past that peak keeps subjects in front without letting the backdrop
    through, and it adapts to how close the subject happens to be — a portrait
    subject sits at 0.35, a distant mountain at 0.08, and the same rule covers both.
    """
    import numpy as np

    histogram, edges = np.histogram(values, bins=bins, range=(0.0, 1.0))
    centers = (edges[:-1] + edges[1:]) / 2
    peak = int(np.argmax(histogram))
    if histogram[peak] == 0:
        return 0.06
    keep = histogram[peak] * 0.15
    upper = peak
    while upper + 1 < len(histogram) and histogram[upper + 1] >= keep:
        upper += 1
    return float(min(0.35, max(0.06, centers[upper] + 0.01)))


def generate(
    data_dir: Path,
    wallpaper: Path,
    feather: float,
    auto_threshold: bool = False,
    coverage: float | None = None,
    threshold: float | None = None,
) -> None:
    import fcntl
    import numpy as np
    from PIL import Image

    if not wallpaper.is_file():
        raise RuntimeError("wallpaper is missing or unreadable")
    if not verify_model(data_dir):
        raise RuntimeError("model is missing or failed checksum validation; run setup again")
    if not auto_threshold and coverage is None and threshold is None:
        raise RuntimeError("a threshold mode is required")
    if coverage is not None:
        coverage = min(1.0, max(0.001, coverage))
    if threshold is not None:
        threshold = min(1.0, max(0.0, threshold))
    feather = min(0.5, max(0.0, feather))
    started = time.monotonic()
    wallpaper_hash = sha256_file(wallpaper)
    cache_key = f"{wallpaper_hash}-{MODEL_SHA256[:16]}-d{DEPTH_PIPELINE_VERSION}-i{INPUT_SIZE}"
    depth_dir = data_dir / "cache" / "depth"
    mask_dir = data_dir / "cache" / "masks"
    depth_dir.mkdir(parents=True, exist_ok=True)
    mask_dir.mkdir(parents=True, exist_ok=True)
    depth_path = depth_dir / f"{cache_key}.npy"
    if auto_threshold:
        cut_key = "auto"
    elif coverage is not None:
        cut_key = f"c{coverage:.4f}"
    else:
        cut_key = f"t{threshold:.4f}"
    mask_key = f"{cache_key}-v{MASK_PIPELINE_VERSION}-{cut_key}-f{feather:.4f}"
    mask_path = mask_dir / f"{mask_key}.png"
    meta_path = mask_dir / f"{mask_key}.json"
    lock_path = data_dir / "runtime" / "generate.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    cut = threshold
    actual_coverage = 0.0

    with lock_path.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache_hit = depth_path.is_file()
        with Image.open(wallpaper) as source:
            source_rgb = source.convert("RGB")
            source_width, source_height = source_rgb.size
            if source_width <= 0 or source_height <= 0:
                raise RuntimeError("wallpaper has invalid dimensions")
            model_width, model_height = inference_size(source_width, source_height)
            if cache_hit:
                depth = np.load(depth_path, allow_pickle=False)
                if depth.shape != (model_height, model_width):
                    depth_path.unlink(missing_ok=True)
                    cache_hit = False
            if not cache_hit:
                resized = source_rgb.resize((model_width, model_height), Image.Resampling.BICUBIC)
                pixels = np.asarray(resized, dtype=np.float32) / np.float32(255.0)
                pixels = (pixels - np.array([0.485, 0.456, 0.406], dtype=np.float32)) / np.array(
                    [0.229, 0.224, 0.225], dtype=np.float32
                )
                tensor = np.transpose(pixels, (2, 0, 1))[None, ...]
                session = inference_session(data_dir)
                input_name = session.get_inputs()[0].name
                prediction = session.run(None, {input_name: tensor})[0]
                depth = np.asarray(prediction, dtype=np.float32).squeeze()
                if depth.shape != (model_height, model_width):
                    raise RuntimeError(
                        f"unexpected model output shape: {depth.shape}; "
                        f"expected {(model_height, model_width)}"
                    )
                del session
                minimum = float(np.min(depth))
                maximum = float(np.max(depth))
                if not np.isfinite(minimum) or not np.isfinite(maximum) or maximum <= minimum:
                    raise RuntimeError("model returned an invalid depth map")
                depth = (depth - minimum) / (maximum - minimum)
                with tempfile.NamedTemporaryFile("wb", dir=depth_dir, delete=False) as stream:
                    np.save(stream, depth, allow_pickle=False)
                    temporary_depth = Path(stream.name)
                os.replace(temporary_depth, depth_path)

            if mask_path.is_file():
                with Image.open(mask_path) as cached_mask:
                    if cached_mask.size != (source_width, source_height) or cached_mask.mode != "RGBA":
                        mask_path.unlink(missing_ok=True)
                        meta_path.unlink(missing_ok=True)
            if not mask_path.is_file():
                full_size_depth = refine_depth(source_rgb, depth)
                if auto_threshold:
                    cut = background_cut(full_size_depth)
                elif coverage is not None:
                    cut = float(np.quantile(full_size_depth, 1.0 - coverage))
                half_feather = feather * 0.5
                alpha = smoothstep(full_size_depth, cut - half_feather, cut + half_feather)
                opacity = np.rint(alpha * 255.0).astype(np.uint8)
                white = np.full_like(opacity, 255)
                alpha_image = Image.fromarray(np.dstack([white, white, white, opacity]), "RGBA")
                with tempfile.NamedTemporaryFile("wb", dir=mask_dir, delete=False) as stream:
                    alpha_image.save(stream, format="PNG", optimize=True)
                    temporary_mask = Path(stream.name)
                os.replace(temporary_mask, mask_path)
                actual_coverage = float((alpha > 0.5).mean())
                atomic_json(meta_path, {"cut": cut, "coverage": actual_coverage})
            else:
                # Cached mask: report what it actually covers so the panel can show it.
                with Image.open(mask_path) as cached_mask:
                    actual_coverage = float((np.asarray(cached_mask)[:, :, 3] > 127).mean())
                try:
                    cached_meta = json.loads(meta_path.read_text())
                except (OSError, ValueError):
                    cached_meta = {}
                cut = cached_meta.get("cut", cut)
                actual_coverage = float(cached_meta.get("coverage", actual_coverage))

        prune(depth_dir, 8, suffix=".npy")
        prune(mask_dir, 32, suffix=".png")
        for orphan in mask_dir.glob("*.json"):
            if not orphan.with_suffix(".png").is_file():
                orphan.unlink(missing_ok=True)

    emit(
        {
            "cacheHit": cache_hit,
            "coverage": round(actual_coverage, 4),
            "cut": round(cut, 4) if cut is not None else -1.0,
            "elapsedMs": round((time.monotonic() - started) * 1000),
            "height": source_height,
            "maskPath": str(mask_path),
            "modelRevision": MODEL_REVISION,
            "wallpaperPath": str(wallpaper),
            "width": source_width,
        }
    )


def clear_cache(data_dir: Path) -> None:
    shutil.rmtree(data_dir / "cache", ignore_errors=True)
    emit({"cleared": True})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True, type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("setup")
    subparsers.add_parser("status")
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--wallpaper", required=True, type=Path)
    generate_parser.add_argument("--auto-threshold", action="store_true")
    generate_parser.add_argument("--coverage", type=float)
    generate_parser.add_argument("--threshold", type=float)
    generate_parser.add_argument("--feather", required=True, type=float)
    subparsers.add_parser("clear-cache")
    args = parser.parse_args()
    if args.command == "generate" and not args.auto_threshold and args.coverage is None and args.threshold is None:
        parser.error("generate needs --auto-threshold, --coverage or --threshold")
    return args


def main() -> int:
    args = parse_args()
    data_dir = args.data_dir.expanduser().resolve()
    venv_python = runtime_python(data_dir)
    if args.command != "setup" and not system_ready() and venv_python.is_file():
        if Path(sys.executable) != venv_python:
            os.execv(venv_python, [str(venv_python), *sys.argv])
    try:
        if args.command == "setup":
            setup(data_dir)
        elif args.command == "status":
            status(data_dir)
        elif args.command == "generate":
            generate(
                data_dir,
                args.wallpaper.expanduser(),
                args.feather,
                auto_threshold=args.auto_threshold,
                coverage=args.coverage,
                threshold=args.threshold,
            )
        elif args.command == "clear-cache":
            clear_cache(data_dir)
        return 0
    except Exception as error:  # Keep the QML-facing failure one line and actionable.
        if args.command == "setup":
            atomic_json(
                data_dir / "setup-operation.json",
                {"state": "error", "finishedAt": int(time.time()), "message": str(error)},
            )
        print(str(error), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
