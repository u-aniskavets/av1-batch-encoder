# av1-batch-encoder
Two Bash scripts for **Linux** that batch re-encode videos to AV1 using `libsvtav1` with 10-bit color (`yuv420p10le`).

* `reencode_av1_simple.sh` — for a handful of files.
* `reencode_av1_full.sh` — an automated "batch machine" for large collections: recursive scan, auto downscale/FPS limit, two-pass encoding and a final size/efficiency summary.

Both scripts are built around the same ffmpeg idea:

* `-c:v libsvtav1` — AV1 encoder (SVT-AV1) on CPU;
* `-pix_fmt yuv420p10le` — YUV 4:2:0, 10-bit;
* `-movflags +faststart` — better streaming/seek.

Everything else is automation: walking directories, probing resolution/FPS, deciding whether to downscale or limit FPS, choosing audio handling, and sorting "problem" files into dedicated folders.

---

## Supported platforms

* Written for **Linux** with:

  * `bash`
  * GNU coreutils (`stat -c%s`, `find ... -print0`, etc.)
  * `ffmpeg` + `ffprobe`
* On **Windows**, you can run them via **WSL** (Ubuntu or another Linux distribution inside WSL).
* They are **not guaranteed** to work on Windows or macOS out of the box, because of Linux/GNU-specific tools and flags.

---

## Installation (Ubuntu)

You need `ffmpeg` with AV1 support (`libsvtav1`) and extra codec libraries:

```bash
sudo apt update
sudo apt install -y \
  ffmpeg \
  libavcodec-extra \
  libavformat-extra \
  libavfilter-extra \
  libaom0 \
  libsvtav1
```

These packages install `ffmpeg` plus additional codecs, including AV1 and the `libsvtav1` CPU encoder.

> On other Linux distributions the package names/commands will differ, but the idea is the same: install `ffmpeg` with AV1/libsvtav1 support.

---

## Quick AV1 ffmpeg test

Before using the scripts, run a minimal AV1 test in a folder where you have `original.mp4`:

```bash
ffmpeg -i original.mp4 -c:v libsvtav1 -pix_fmt yuv420p10le -c:a copy -movflags +faststart original_av1_test.mp4
```

This one-liner:

* reads `original.mp4`;
* re-encodes **video only** to AV1 (`libsvtav1`, `yuv420p10le`);
* keeps resolution, FPS and audio as-is (`-c:a copy`);
* uses `-movflags +faststart` for faster start/seek;
* writes `original_av1_test.mp4`.

If it finishes without errors and the new file plays fine, your ffmpeg AV1 setup is ready.

---

## Preparing the scripts

Place `reencode_av1_simple.sh` and `reencode_av1_full.sh` in the same directory and make them executable:

```bash
chmod +x reencode_av1_simple.sh
chmod +x reencode_av1_full.sh
```

From now on you can run them as:

```bash
./reencode_av1_simple.sh ...
./reencode_av1_full.sh ...
```

---

## Core ffmpeg idea

Internally, both scripts use ffmpeg in a way that is roughly equivalent to:

```bash
ffmpeg -i input.mp4 \
  -threads 0 \
  -vf "scale=...,fps=..." \
  -c:v libsvtav1 -preset 6 -crf 32 \
  -pix_fmt yuv420p10le \
  -c:a aac -b:a 128k \
  -movflags +faststart \
  output_av1.mp4
```

Key points:

* `-c:v libsvtav1` — AV1 encoder (SVT-AV1) on **CPU**.
* `-pix_fmt yuv420p10le`:

  * YUV **4:2:0** chroma subsampling (standard video format, good compatibility);
  * 10-bit color (less banding/posterization, better dark scenes).
* `-movflags +faststart` — moves metadata to the beginning of the file for faster playback start and seeking.
* `-threads 0` in the full script tells ffmpeg to use **all available CPU cores/threads**. More cores = higher throughput.

Scaling and FPS limiting are implemented via `-vf`:

* downscaling only if needed (shorter side above a threshold);
* limiting FPS only if original FPS is higher than the configured limit.

---

## Script: `reencode_av1_simple.sh`

### What it does

A lightweight helper for one or more files passed as arguments:

* Usage: `./reencode_av1_simple.sh video1.mp4 video2.mkv ...`
* For each input file it:

  * optionally downscales to `MAX_DIM` on the **shorter side**, preserving aspect ratio (and keeping even dimensions for 4:2:0);
  * optionally caps FPS to `FPS_LIMIT` if original FPS is higher;
  * encodes video to AV1: `-c:v libsvtav1`, `-pix_fmt yuv420p10le`, 10-bit;
  * re-encodes audio to AAC at `AUDIO_BR` bitrate;
  * writes a new file named like `original_av1_<dim>px_<fps>fps_p<preset>_crf<crf>.mp4`.

### Usage examples

1. **Simplest case (one file)**

```bash
./reencode_av1_simple.sh original.mp4
```

Uses defaults: `MAX_DIM=720`, `FPS_LIMIT=45`, `SVT_CRF=32`, `SVT_PRESET=6`, `AUDIO_BR=128k`.

2. **Better quality (larger files, slower encoding)**

```bash
SVT_CRF=26 SVT_PRESET=4 ./reencode_av1_simple.sh original.mp4
```

* Lower CRF (26 vs 32) → better visual quality, higher bitrate.
* Lower preset value (4 vs 6) → slower but more efficient encoding.

3. **Stronger compression (smaller files, lower quality)**

```bash
MAX_DIM=480 FPS_LIMIT=30 SVT_CRF=40 SVT_PRESET=8 ./reencode_av1_simple.sh original.mp4
```

* Downscale to ~480p on the shorter side.
* Limit FPS to 30.
* Higher CRF (40) + faster preset (8) → smaller files and faster encoding, at the cost of quality.

### Tunable environment variables

You configure `reencode_av1_simple.sh` via environment variables:

| Variable     | Default | Meaning                                                               |
| ------------ | ------- | --------------------------------------------------------------------- |
| `MAX_DIM`    | `720`   | Maximum size of the **shorter** side, in pixels.                      |
| `FPS_LIMIT`  | `45`    | FPS cap; original FPS above this is reduced to this value.            |
| `SVT_CRF`    | `32`    | AV1 quality (0 = best, 63 = worst; lower = better quality).           |
| `SVT_PRESET` | `6`     | SVT-AV1 speed/quality preset (0 = best/slowest, 13 = fastest/lowest). |
| `AUDIO_BR`   | `128k`  | AAC audio bitrate in the output file.                                 |

---

## Script: `reencode_av1_full.sh`

### What it does

A fully automated batch encoder for large folders of mixed video files:

1. **Recursively scans** the source directory for video files (mp4, mkv, avi, mov, webm, etc.).
2. For each video it:

   * uses `ffprobe` to read width, height and FPS;
   * decides whether to **downscale** to `MAX_DIM` on the shorter side;
   * decides whether to **limit FPS** to `FPS_LIMIT`;
   * decides whether to **copy audio** or **re-encode to AAC 128k** based on original audio bitrate;
   * encodes video to AV1 (`libsvtav1`, `yuv420p10le`, `-threads 0`) and saves the result.
3. **Compares file sizes**:

   * if the AV1 result is **smaller** than the original → counts as successful and is included in final statistics;
   * if the AV1 result is **larger** than the original → moved to a special "larger output" folder, and the original is queued for a "stronger" second pass.
4. **Runs a second, stronger pass**:

   * for all "problem" originals, encodes again with more aggressive settings (`SVT_CRF_STRONGER`, `SVT_PRESET_STRONGER`);
   * if the stronger result becomes smaller than the original → stored as the final AV1, and the first attempt is replaced;
   * if it is still not better than the original → the AV1 file stays in the "larger output" folder and the original copy remains in its "needs stronger encoding" folder.
5. At the end, prints a **Summary** with:

   * total files found;
   * how many successfully encoded to AV1;
   * how many failed entirely;
   * total input size, total encoded size, and overall size savings;
   * total elapsed time.

### Output folders

Assuming you run:

```bash
./reencode_av1_full.sh /home/user/videos
```

the script uses these folders:

* `/home/user/videos_av1/` — **final AV1 outputs** after all passes.
* `/home/user/videos_failed_originals/` — originals that failed to encode (corrupt/unreadable, missing metadata, etc.).
* `/home/user/videos_larger_output/` — AV1 files that ended up **larger** than the originals, even after stronger encoding.
* `/home/user/videos_needs_stronger_encoding/` — copies of originals that required (or still require) stronger encoding.

If the source directory is `.` (current directory), names are adjusted to:

* `./av1_output`
* `./av1_failed_originals`
* `./av1_larger_output`
* `./av1_needs_stronger_encoding`

### Usage examples

1. **Basic run**

```bash
./reencode_av1_full.sh /home/user/videos
```

* Processes all supported videos under `/home/user/videos` recursively.
* Uses defaults: `MAX_DIM=720`, `FPS_LIMIT=45`, `SVT_CRF=32`, `SVT_PRESET=7`, `SVT_CRF_STRONGER=45`, `SVT_PRESET_STRONGER=5`.

2. **Explicit max resolution and FPS via arguments**

```bash
./reencode_av1_full.sh /home/user/videos 1080 60
```

* Max shorter side: `1080` pixels.
* FPS cap: `60`.

3. **Adjust main and stronger pass quality/speed via environment variables**

```bash
SVT_CRF=30 SVT_PRESET=6 \
SVT_CRF_STRONGER=40 SVT_PRESET_STRONGER=8 \
./reencode_av1_full.sh /home/user/videos
```

* Main pass: CRF 30, preset 6.
* Stronger pass: CRF 40, preset 8 (more aggressive compression, faster, lower quality).

### Quality/speed parameters for `reencode_av1_full.sh`

The full script uses environment variables for both passes:

| Variable              | Default | Used in                      |
| --------------------- | ------- | ---------------------------- |
| `SVT_CRF`             | `32`    | Main pass AV1 CRF            |
| `SVT_PRESET`          | `7`     | Main pass SVT-AV1 preset     |
| `SVT_CRF_STRONGER`    | `45`    | Stronger pass AV1 CRF        |
| `SVT_PRESET_STRONGER` | `5`     | Stronger pass SVT-AV1 preset |

---

## `simple` vs `full` at a glance

* **`reencode_av1_simple.sh`**

  * Best for a few videos you know you want to transcode.
  * Straightforward: apply max resolution/FPS and AV1 settings to listed files.
  * No recursion, no size comparison logic.

* **`reencode_av1_full.sh`**

  * Designed for **large libraries**.
  * Recursive directory walk, per-file probing of resolution/FPS/audio.
  * Two-pass AV1 encoding with size comparison and detailed stats.
  * Automatically separates failed, oversized and "needs stronger encoding" files into dedicated folders.

---

## Encoding details & SVT-AV1 tuning

### CRF (`SVT_CRF`, `SVT_CRF_STRONGER`)

SVT-AV1 uses a constant-rate-factor scale:

- **Range:** `0–63`
  - `0`  – highest quality (very large files, near “visually lossless”).
  - `63` – strongest compression (poor quality, tiny files).
- **Lower CRF → better quality, higher bitrate.**  
- **Higher CRF → stronger compression, more artifacts, smaller size.**

Practical ranges for real-world use:

- **24–30** – very high quality; good when storage is cheap and quality matters.
- **30–36** – balanced quality vs size; a good default range for most content.
- **36–45** – aggressive space saving; artifacts may be visible on complex scenes.
- **>45** – “extreme savings” territory, only useful for very specific use-cases (previews, tiny archives, etc.).

The defaults in these scripts are chosen as a compromise for **large batch re-encoding**, not for absolute maximum quality or maximum compression at any cost.

### Preset (`SVT_PRESET`, `SVT_PRESET_STRONGER`)

The preset controls the speed/efficiency trade-off of the encoder:

- **Range:** `0–13`
  - `0`  – slowest, most efficient compression (best quality per bitrate).
  - `13` – fastest, least efficient (higher bitrate for the same quality).
- At the same CRF:
  - **Lower preset → slower, but better compression.**
  - **Higher preset → faster, but worse compression.**

Rule-of-thumb ranges:

- **0–3** – “archival” territory: only makes sense if you truly don’t care about encode time.
- **4–7** – good balance between speed and efficiency for everyday use.
- **8–13** – fast modes for huge libraries and quick re-encodes when CPU time is more important than absolute compression efficiency.

> **Author’s note:** in practice, presets below `2` are usually not worth it for batch encoding.  
> Even at `SVT_PRESET=2`, encoding can already be **very slow on a 14-core CPU**. Consider staying in the `4–8` range unless you explicitly want ultra-slow, ultra-efficient encodes.

In the scripts:

- `SVT_PRESET` is used for the **main pass**.
- `SVT_PRESET_STRONGER` is used for the **second, “stronger” pass**, which you can tune either to:
  - be **slower but more efficient** (better quality at similar size), or
  - be **faster and more aggressive** (smaller size at the cost of quality).

### What the scripts actually do

- **Video:**
  - `-c:v libsvtav1` – AV1 encoding via SVT-AV1 (CPU).
  - `-pix_fmt yuv420p10le` – YUV 4:2:0, 10-bit color depth (less banding, better dark scenes).
  - Scaling and FPS limiting are applied **only when needed**:
    - resolution downscaled if the shorter side is above `MAX_DIM`,
    - FPS reduced if it exceeds `FPS_LIMIT`.

- **Audio:**
  - `reencode_av1_simple.sh` always re-encodes audio to AAC at `AUDIO_BR`.
  - `reencode_av1_full.sh` decides per file whether to copy audio or re-encode to AAC 128k, based on the original bitrate.

- **Multithreading:**
  - The full script uses `-threads 0`, letting ffmpeg use **all available CPU cores/threads**, which significantly improves throughput on multi-core CPUs.

---

## Hardware AV1 encoding and GPUs

These scripts are built for **CPU-based** AV1 encoding via `libsvtav1`. However, if you have a GPU with hardware AV1 encoding support, using those hardware encoders (via ffmpeg or other tools) is often more attractive:

* much higher encoding speed;
* potentially better visual quality at the same bitrate;
* potentially smaller output size at similar quality.

AV1 hardware encoding is generally available only on relatively recent GPUs (roughly 2022 and newer). Examples of GPU families with AV1 encode support:

* **NVIDIA** — starting from **GeForce RTX 40 Series (Ada)**, including **RTX 50 Series (Blackwell)** and newer generations.
* **AMD** — starting from **Radeon RX 7000 Series (RDNA 3)** and newer (including future RDNA 4-based cards).
* **Intel** — all discrete **Intel Arc A-Series (Alchemist)**, **B-Series (Battlemage)** and later generations.

This repository does not use GPU encoders directly, but the directory traversal and file-selection logic can be reused or adapted for ffmpeg commands based on `av1_nvenc`, `av1_qsv`, and similar hardware encoders.

---

## AV1 vs H.264

**Advantages of AV1:**

* Better compression efficiency: similar visual quality at significantly lower bitrates compared to H.264.
* Modern codec with increasing support among streaming platforms and services.
* Designed as a royalty-free / open codec, unlike H.264 which is tied to patent pools.

**Drawbacks and current friction points:**

* Codec packaging and licensing on Linux can be confusing: AV1 support may require extra packages and configuration (thumbnails, previewers, etc.).
* Thumbnails/previews are not yet as "transparent" as for H.264:

  * some phones won’t generate thumbnails for AV1 at all, while H.264 just works;
  * on Windows 11, thumbnails usually appear automatically (if the right codecs are installed);
  * social networks have uneven AV1 preview support: some handle it, some do not.

**Bottom line:** AV1 is excellent for **archiving and saving disk space**, but in terms of plug-and-play support in all players, gallery apps and thumbnail generators, it still lags behind ubiquitous H.264.

---

## Why use these scripts instead of a GUI converter?

These scripts provide a few clear advantages over generic converters and GUI tools:

* **Mass processing** of entire folders and nested directories in one go.
* Ability to define **maximum resolution** and **FPS cap** per collection, not per file.
* Automatic separation of tricky cases:

  * files that failed to encode;
  * AV1 files that ended up larger than originals;
  * originals that need stronger encoding.
* Flexible control of the **quality vs speed** trade-off through CRF and preset, for **both** the main and stronger passes.
* Simple, readable entry points: one or two straightforward parameters instead of long, fragile ffmpeg command lines.

---

## Example Summary output

A real-world `reencode_av1_full.sh` run on Ubuntu might end with something like:

```text
Summary:
 Total files found               : 675
 Successfully encoded (final AV1): 672
 Failed files (no encode at all) : 3
 Total input size                : 4499932596 bytes (4 GiB)

 Processed original size (final) : 4485772683 bytes (4 GiB)
 Total encoded size (final)      : 1755831145 bytes (1 GiB)
 Overall size change (final)     : -2729941538 bytes (2 GiB), 60% smaller
 Total elapsed time              : 02:37:45
```

This makes it easy to see how much space you’ve saved, how many files were handled successfully, and how long the full batch run took.

## License

This project is licensed under the MIT License.
