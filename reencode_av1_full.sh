#!/usr/bin/env bash
set -euo pipefail

# Disable SVT-AV1 library info logs
export SVT_LOG=0

# ===================== DEFAULT SETTINGS =====================
# Default maximum resolution for the shorter side in pixels (2nd argument)
DEFAULT_MAX_DIM=720
# Default maximum FPS limit (can be overridden by 3rd argument)
DEFAULT_FPS_LIMIT=45

# SVT-AV1 quality (0 = best/lossless, 63 = worst/smallest)
SVT_CRF="${SVT_CRF:-32}"
# SVT-AV1 speed/quality preset (0 = best quality/slowest, 13 = fastest/lowest quality)
SVT_PRESET="${SVT_PRESET:-7}"

# Stronger pass settings (more aggressive)
SVT_CRF_STRONGER="${SVT_CRF_STRONGER:-45}"
SVT_PRESET_STRONGER="${SVT_PRESET_STRONGER:-5}"
# ============================================================

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 /path/to/source_folder [max_short_side_px] [fps_limit]"
    echo "Example: $0 /videos 720 45"
    exit 1
fi

SRC_DIR="${1%/}"
if [ ! -d "$SRC_DIR" ]; then
    echo "Source folder not found: $SRC_DIR"
    exit 1
fi

# Allow overriding MAX_DIM and FPS_LIMIT via arguments
MAX_DIM="${2:-$DEFAULT_MAX_DIM}"
FPS_LIMIT="${3:-$DEFAULT_FPS_LIMIT}"

# Basic sanity checks for numeric arguments (must be positive integers)
if ! [[ "$MAX_DIM" =~ ^[0-9]+$ ]] || [ "$MAX_DIM" -le 0 ]; then
    echo "max_short_side_px must be a positive integer, got: $MAX_DIM"
    exit 1
fi
if ! [[ "$FPS_LIMIT" =~ ^[0-9]+$ ]] || [ "$FPS_LIMIT" -le 0 ]; then
    echo "fps_limit must be a positive integer, got: $FPS_LIMIT"
    exit 1
fi

# Output and auxiliary directories.
# Special handling for SRC_DIR="." to avoid names like "._av1".
if [ "$SRC_DIR" = "." ]; then
    OUT_DIR="./av1_output"
    FAILED_DIR="./av1_failed_originals"
    LARGER_OUT_DIR="./av1_larger_output"
    STRONGER_ENC_DIR="./av1_needs_stronger_encoding"
else
    OUT_DIR="${SRC_DIR}_av1"
    FAILED_DIR="${SRC_DIR}_failed_originals"
    LARGER_OUT_DIR="${SRC_DIR}_larger_output"
    STRONGER_ENC_DIR="${SRC_DIR}_needs_stronger_encoding"
fi

# Temporary directory for stronger-pass outputs
TMP_DIR="$OUT_DIR/.tmp_stronger"

# Remember which service directories existed before the script started
if [ -d "$OUT_DIR" ]; then
    OUT_DIR_PRE_EXISTING=1
else
    OUT_DIR_PRE_EXISTING=0
fi

if [ -d "$FAILED_DIR" ]; then
    FAILED_DIR_PRE_EXISTING=1
else
    FAILED_DIR_PRE_EXISTING=0
fi

if [ -d "$LARGER_OUT_DIR" ]; then
    LARGER_OUT_DIR_PRE_EXISTING=1
else
    LARGER_OUT_DIR_PRE_EXISTING=0
fi

if [ -d "$STRONGER_ENC_DIR" ]; then
    STRONGER_ENC_DIR_PRE_EXISTING=1
else
    STRONGER_ENC_DIR_PRE_EXISTING=0
fi

if [ -d "$TMP_DIR" ]; then
    TMP_DIR_PRE_EXISTING=1
else
    TMP_DIR_PRE_EXISTING=0
fi

echo "Source folder           : $SRC_DIR"
echo "Final AV1 output folder : $OUT_DIR"
echo "Failed originals dir    : $FAILED_DIR"
echo "Larger output dir       : $LARGER_OUT_DIR"
echo "Needs stronger enc. dir : $STRONGER_ENC_DIR"
echo "Max short side          : ${MAX_DIM} px"
echo "FPS limit               : ${FPS_LIMIT} fps"
echo "SVT-AV1 CRF (main)      : ${SVT_CRF}"
echo "SVT-AV1 preset (main)   : ${SVT_PRESET}"
echo "SVT-AV1 CRF (stronger)  : ${SVT_CRF_STRONGER}"
echo "SVT-AV1 preset(stronger): ${SVT_PRESET_STRONGER}"
echo

# ---------------- Helper functions ----------------

format_bytes() {
    # Format bytes as human-readable value using integer units.
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        printf "%d GiB" $((bytes / 1073741824))
    elif [ "$bytes" -ge 1048576 ]; then
        printf "%d MiB" $((bytes / 1048576))
    elif [ "$bytes" -ge 1024 ]; then
        printf "%d KiB" $((bytes / 1024))
    else
        printf "%d B" "$bytes"
    fi
}

format_duration() {
    # Format seconds as HH:MM:SS.
    local total=$1
    local h=$((total / 3600))
    local m=$(((total % 3600) / 60))
    local s=$((total % 60))
    printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

copy_to_failed() {
    # Copy original file to FAILED_DIR preserving relative path.
    local in_file="$1"
    local rel_path="$2"
    local failed_target="$FAILED_DIR/$rel_path"
    mkdir -p "$(dirname "$failed_target")"
    cp -f "$in_file" "$failed_target"
}

print_file_time() {
    # Print elapsed time for a single file based on its start time.
    local start=$1
    local elapsed=$((SECONDS - start))
    echo "Time for this file      : $(format_duration "$elapsed")"
    echo
}

# ---------------- Global counters ----------------

SECONDS=0  # Global script timer

TOTAL_FILES=0
TOTAL_INPUT_BYTES=0
CURRENT_FILE_INDEX=0

ENCODED_FILES=0
FAILED_FILES=0

TOTAL_ORIG_BYTES_PROCESSED=0
TOTAL_NEW_BYTES_PROCESSED=0
TOTAL_SAVED_BYTES=0

STRONGER_TOTAL_FILES=0
STRONGER_CURRENT_INDEX=0

# ---------------- Function to process a single file (main pass) ----------------

process_main_file() {
    local in_file="$1"

    # Skip if not a regular file
    [ -f "$in_file" ] || return 0

    CURRENT_FILE_INDEX=$((CURRENT_FILE_INDEX + 1))
    local file_start=$SECONDS

    local rel_path
    if [ "$SRC_DIR" = "." ]; then
        rel_path="${in_file#./}"
    else
        rel_path="${in_file#$SRC_DIR/}"
    fi

    local base_name="${rel_path%.*}"
    local out_file="$OUT_DIR/${base_name}.mp4"

    # Get original file size in bytes
    local orig_size
    orig_size=$(stat -c%s "$in_file" 2>/dev/null || echo 0)

    local total_elapsed_str
    total_elapsed_str=$(format_duration "$SECONDS")
    echo "=== [main ${CURRENT_FILE_INDEX}/${TOTAL_FILES}, total elapsed: ${total_elapsed_str}] ${rel_path} ==="

    # If output already exists, skip re-encode
    if [ -f "$out_file" ]; then
        echo "Output already exists, skipping re-encode."
        print_file_time "$file_start"
        return 0
    fi

    # 1) Probe video parameters
    local width height fps_str
    width=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width \
        -of csv=p=0 "$in_file" 2>/dev/null || true)
    height=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=height \
        -of csv=p=0 "$in_file" 2>/dev/null || true)
    fps_str=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=avg_frame_rate \
        -of csv=p=0 "$in_file" 2>/dev/null || true)

    if [ -z "$width" ] || [ -z "$height" ] || [ -z "$fps_str" ] || [ "$fps_str" = "0/0" ]; then
        echo "Could not read video parameters. Marking as failed and copying original to FAILED_DIR (original remains in place)."
        copy_to_failed "$in_file" "$rel_path"
        FAILED_FILES=$((FAILED_FILES + 1))
        print_file_time "$file_start"
        return 0
    fi

    if ! [[ "$width" =~ ^[0-9]+$ ]] || ! [[ "$height" =~ ^[0-9]+$ ]] || ! [[ "$fps_str" =~ ^[0-9]+(/[0-9]+)?$ ]]; then
        echo "Invalid video parameters (width/height/fps). Marking as failed."
        copy_to_failed "$in_file" "$rel_path"
        FAILED_FILES=$((FAILED_FILES + 1))
        print_file_time "$file_start"
        return 0
    fi

    # FPS parsing: support both "num/den" and simple "num"
    local fps_num fps_den
    if [[ "$fps_str" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        fps_num="${BASH_REMATCH[1]}"
        fps_den="${BASH_REMATCH[2]}"
        if [ "$fps_den" -eq 0 ]; then
            echo "Invalid FPS denominator (0). Marking as failed."
            copy_to_failed "$in_file" "$rel_path"
            FAILED_FILES=$((FAILED_FILES + 1))
            print_file_time "$file_start"
            return 0
        fi
    else
        fps_num="$fps_str"
        fps_den=1
    fi

    # 2) Decide if we need to downscale
    local min_dim
    if [ "$width" -lt "$height" ]; then
        min_dim="$width"
    else
        min_dim="$height"
    fi

    local scale_filter
    if [ "$min_dim" -gt "$MAX_DIM" ]; then
        if [ "$width" -le "$height" ]; then
            scale_filter="scale=${MAX_DIM}:-2"
        else
            scale_filter="scale=-2:${MAX_DIM}"
        fi
    else
        scale_filter="scale=trunc(iw/2)*2:trunc(ih/2)*2"
    fi

    # 3) FPS limiting (if original FPS > FPS_LIMIT)
    local fps_filter=""
    if [ "$fps_num" -gt 0 ] && [ $((fps_num)) -gt $((FPS_LIMIT * fps_den)) ]; then
        fps_filter="fps=${FPS_LIMIT}"
    fi

    # Build video filter chain
    local vf_filter
    vf_filter="$scale_filter"
    if [ -n "$fps_filter" ]; then
        vf_filter="${vf_filter},${fps_filter}"
    fi

    # 4) Audio handling
    local audio_bitrate
    local -a audio_opts=()

    audio_bitrate=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=bit_rate \
        -of csv=p=0 "$in_file" 2>/dev/null || true)

    if [ -z "$audio_bitrate" ]; then
        audio_opts=(-an)
    else
        if [[ "$audio_bitrate" =~ ^[0-9]+$ ]]; then
            if [ "$audio_bitrate" -gt 128000 ]; then
                audio_opts=(-c:a aac -b:a 128k)
            elif [ "$audio_bitrate" -gt 0 ]; then
                audio_opts=(-c:a copy)
            else
                audio_opts=(-c:a copy)
            fi
        else
            audio_opts=(-c:a copy)
        fi
    fi

    mkdir -p "$(dirname "$out_file")"

    # 5) Encode with libsvtav1 (main pass)
    if ! ffmpeg -hide_banner -loglevel error -stats -y \
        -i "$in_file" \
        -threads 0 \
        -vf "$vf_filter" \
        -c:v libsvtav1 -preset "$SVT_PRESET" -crf "$SVT_CRF" \
        -pix_fmt yuv420p10le \
        -movflags +faststart \
        "${audio_opts[@]}" \
        "$out_file"
    then
        echo "Encoding failed (CPU path). Marking as failed."
        copy_to_failed "$in_file" "$rel_path"
        rm -f "$out_file"
        FAILED_FILES=$((FAILED_FILES + 1))
        print_file_time "$file_start"
        return 0
    fi

    # 6) Compare file sizes and compute compression statistics
    local new_size
    new_size=$(stat -c%s "$out_file" 2>/dev/null || echo 0)

    if [ "$orig_size" -gt 0 ] && [ "$new_size" -gt 0 ]; then
        local saved=$((orig_size - new_size))
        local saved_pct=$((saved * 100 / orig_size))
        local dir_word
        if [ "$saved" -ge 0 ]; then
            dir_word="smaller"
        else
            saved_pct=$((-saved_pct))
            dir_word="larger"
        fi
        echo "New size                : $new_size bytes ($(format_bytes "$new_size")), ${saved_pct}% ${dir_word}"
    else
        echo "New size                : $new_size bytes ($(format_bytes "$new_size"))"
    fi

    # If result is larger than original, move output and copy original for stronger encoding
    if [ "$new_size" -gt "$orig_size" ]; then
        local larger_target="$LARGER_OUT_DIR/${base_name}.mp4"
        mkdir -p "$(dirname "$larger_target")"
        mv -f "$out_file" "$larger_target"

        local stronger_target="$STRONGER_ENC_DIR/$rel_path"
        mkdir -p "$(dirname "$stronger_target")"
        cp -f "$in_file" "$stronger_target"
        # Do NOT update global size statistics here; they will be updated only if stronger pass succeeds.
    else
        ENCODED_FILES=$((ENCODED_FILES + 1))
        TOTAL_ORIG_BYTES_PROCESSED=$((TOTAL_ORIG_BYTES_PROCESSED + orig_size))
        TOTAL_NEW_BYTES_PROCESSED=$((TOTAL_NEW_BYTES_PROCESSED + new_size))
        TOTAL_SAVED_BYTES=$((TOTAL_SAVED_BYTES + (orig_size - new_size)))
    fi

    print_file_time "$file_start"
}

# ---------------- Function to process a single file (stronger pass) ----------------

process_stronger_file() {
    local stronger_copy="$1"

    [ -f "$stronger_copy" ] || return 0

    STRONGER_CURRENT_INDEX=$((STRONGER_CURRENT_INDEX + 1))
    local file_start=$SECONDS

    local rel_path
    rel_path="${stronger_copy#$STRONGER_ENC_DIR/}"

    local total_elapsed_str
    total_elapsed_str=$(format_duration "$SECONDS")
    echo "=== [stronger ${STRONGER_CURRENT_INDEX}/${STRONGER_TOTAL_FILES}, total elapsed: ${total_elapsed_str}] ${rel_path} ==="

    local orig_path
    if [ "$SRC_DIR" = "." ]; then
        orig_path="./$rel_path"
    else
        orig_path="$SRC_DIR/$rel_path"
    fi

    local base_name="${rel_path%.*}"
    local first_try_path="$LARGER_OUT_DIR/${base_name}.mp4"
    local stronger_out_path="$OUT_DIR/${base_name}.mp4"
    mkdir -p "$TMP_DIR"
    local stronger_tmp_path="$TMP_DIR/${base_name}__stronger_tmp.mp4"

    if [ ! -f "$orig_path" ]; then
        echo "Original file not found for stronger pass: $orig_path"
        echo "Leaving first attempt and stronger copy as-is."
        print_file_time "$file_start"
        return 0
    fi

    if [ ! -f "$first_try_path" ]; then
        echo "First attempt file not found for stronger pass: $first_try_path"
        echo "Leaving stronger copy as-is."
        print_file_time "$file_start"
        return 0
    fi

    local orig_size
    orig_size=$(stat -c%s "$orig_path" 2>/dev/null || echo 0)

    # Probe video parameters from original
    local width height fps_str
    width=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width \
        -of csv=p=0 "$orig_path" 2>/dev/null || true)
    height=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=height \
        -of csv=p=0 "$orig_path" 2>/dev/null || true)
    fps_str=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=avg_frame_rate \
        -of csv=p=0 "$orig_path" 2>/dev/null || true)

    if [ -z "$width" ] || [ -z "$height" ] || [ -z "$fps_str" ] || [ "$fps_str" = "0/0" ]; then
        echo "Could not read video parameters for stronger pass. Leaving first attempt and stronger copy as-is."
        print_file_time "$file_start"
        return 0
    fi

    if ! [[ "$width" =~ ^[0-9]+$ ]] || ! [[ "$height" =~ ^[0-9]+$ ]] || ! [[ "$fps_str" =~ ^[0-9]+(/[0-9]+)?$ ]]; then
        echo "Invalid video parameters for stronger pass. Leaving first attempt and stronger copy as-is."
        print_file_time "$file_start"
        return 0
    fi

    # FPS parsing
    local fps_num fps_den
    if [[ "$fps_str" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        fps_num="${BASH_REMATCH[1]}"
        fps_den="${BASH_REMATCH[2]}"
        if [ "$fps_den" -eq 0 ]; then
            echo "Invalid FPS denominator (0) for stronger pass. Leaving files as-is."
            print_file_time "$file_start"
            return 0
        fi
    else
        fps_num="$fps_str"
        fps_den=1
    fi

    # Downscale decision
    local min_dim
    if [ "$width" -lt "$height" ]; then
        min_dim="$width"
    else
        min_dim="$height"
    fi

    local scale_filter
    if [ "$min_dim" -gt "$MAX_DIM" ]; then
        if [ "$width" -le "$height" ]; then
            scale_filter="scale=${MAX_DIM}:-2"
        else
            scale_filter="scale=-2:${MAX_DIM}"
        fi
    else
        scale_filter="scale=trunc(iw/2)*2:trunc(ih/2)*2"
    fi

    # FPS limiting
    local fps_filter=""
    if [ "$fps_num" -gt 0 ] && [ $((fps_num)) -gt $((FPS_LIMIT * fps_den)) ]; then
        fps_filter="fps=${FPS_LIMIT}"
    fi

    # Build video filter chain
    local vf_filter
    vf_filter="$scale_filter"
    if [ -n "$fps_filter" ]; then
        vf_filter="${vf_filter},${fps_filter}"
    fi

    # Audio handling (same rules as main pass, based on original)
    local audio_bitrate
    local -a audio_opts=()

    audio_bitrate=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=bit_rate \
        -of csv=p=0 "$orig_path" 2>/dev/null || true)

    if [ -z "$audio_bitrate" ]; then
        audio_opts=(-an)
    else
        if [[ "$audio_bitrate" =~ ^[0-9]+$ ]]; then
            if [ "$audio_bitrate" -gt 128000 ]; then
                audio_opts=(-c:a aac -b:a 128k)
            elif [ "$audio_bitrate" -gt 0 ]; then
                audio_opts=(-c:a copy)
            else
                audio_opts=(-c:a copy)
            fi
        else
            audio_opts=(-c:a copy)
        fi
    fi

    mkdir -p "$(dirname "$stronger_out_path")"
    mkdir -p "$(dirname "$stronger_tmp_path")"

    # Stronger pass encode to temporary file
    if ! ffmpeg -hide_banner -loglevel error -stats -y \
        -i "$orig_path" \
        -threads 0 \
        -vf "$vf_filter" \
        -c:v libsvtav1 -preset "$SVT_PRESET_STRONGER" -crf "$SVT_CRF_STRONGER" \
        -pix_fmt yuv420p10le \
        -movflags +faststart \
        "${audio_opts[@]}" \
        "$stronger_tmp_path"
    then
        echo "Stronger encoding failed (CPU path). Leaving first attempt and stronger copy as-is."
        rm -f "$stronger_tmp_path"
        print_file_time "$file_start"
        return 0
    fi

    # Compare size of stronger encode with original
    local new_size2
    new_size2=$(stat -c%s "$stronger_tmp_path" 2>/dev/null || echo 0)

    if [ "$orig_size" -gt 0 ] && [ "$new_size2" -gt 0 ]; then
        local saved2=$((orig_size - new_size2))
        local saved2_pct=$((saved2 * 100 / orig_size))
        local dir_word2
        if [ "$saved2" -ge 0 ]; then
            dir_word2="smaller"
        else
            saved2_pct=$((-saved2_pct))
            dir_word2="larger"
        fi
        echo "New size                : $new_size2 bytes ($(format_bytes "$new_size2")), ${saved2_pct}% ${dir_word2}"
    else
        echo "New size                : $new_size2 bytes ($(format_bytes "$new_size2"))"
    fi

    if [ "$new_size2" -lt "$orig_size" ]; then
        # Scenario A: stronger encode is finally smaller than original
        mv -f "$stronger_tmp_path" "$stronger_out_path"
        rm -f "$first_try_path"
        rm -f "$stronger_copy"

        ENCODED_FILES=$((ENCODED_FILES + 1))
        TOTAL_ORIG_BYTES_PROCESSED=$((TOTAL_ORIG_BYTES_PROCESSED + orig_size))
        TOTAL_NEW_BYTES_PROCESSED=$((TOTAL_NEW_BYTES_PROCESSED + new_size2))
        TOTAL_SAVED_BYTES=$((TOTAL_SAVED_BYTES + (orig_size - new_size2)))
    else
        # Scenario B: even stronger encode is not better than original.
        # Keep the original copy in STRONGER_ENC_DIR and update the AV1 file in LARGER_OUT_DIR.
        mv -f "$stronger_tmp_path" "$first_try_path"
        echo "Stronger encode not better than original. Keeping latest AV1 in LARGER_OUT_DIR and original copy in STRONGER_ENC_DIR."
    fi

    print_file_time "$file_start"
}

# ---------------- Collect file list (main pass) ----------------

declare -a FILE_LIST=()

while IFS= read -r -d '' f; do
    FILE_LIST+=("$f")
done < <(find "$SRC_DIR" -type f \
    \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.vob" -o -iname "*.gif" \) \
    -print0)

TOTAL_FILES=${#FILE_LIST[@]}

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "No matching video files found. Nothing to do."
    script_elapsed=$SECONDS
    echo "Total elapsed time      : $(format_duration "$script_elapsed")"
    exit 0
fi

# Calculate total input size
for f in "${FILE_LIST[@]}"; do
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    TOTAL_INPUT_BYTES=$((TOTAL_INPUT_BYTES + size))
done

echo "Found video files        : $TOTAL_FILES"
echo "Total input size         : $TOTAL_INPUT_BYTES bytes ($(format_bytes "$TOTAL_INPUT_BYTES"))"
echo

# ---------------- Main processing loop (first pass) ----------------

for f in "${FILE_LIST[@]}"; do
    process_main_file "$f"
done

# ---------------- Stronger pass (second pass) ----------------

declare -a STRONGER_LIST=()

if [ -d "$STRONGER_ENC_DIR" ]; then
    while IFS= read -r -d '' sf; do
        STRONGER_LIST+=("$sf")
    done < <(find "$STRONGER_ENC_DIR" -type f -print0)
fi

STRONGER_TOTAL_FILES=${#STRONGER_LIST[@]}

if [ "$STRONGER_TOTAL_FILES" -gt 0 ]; then
    echo "Starting stronger pass for $STRONGER_TOTAL_FILES file(s)..."
    echo
    for sf in "${STRONGER_LIST[@]}"; do
        process_stronger_file "$sf"
    done
else
    echo "No files need stronger encoding."
    echo
fi

# ---------------- Cleanup service directories if they were created and are empty ----------------

cleanup_dir_if_empty() {
    local dir="$1"
    local pre_existing="$2"
    if [ "$pre_existing" -eq 0 ] && [ -d "$dir" ]; then
        local any
        any=$(find "$dir" -type f -print -quit 2>/dev/null || true)
        if [ -z "$any" ]; then
            rm -rf "$dir"
        fi
    fi
}

cleanup_dir_if_empty "$OUT_DIR" "$OUT_DIR_PRE_EXISTING"
cleanup_dir_if_empty "$FAILED_DIR" "$FAILED_DIR_PRE_EXISTING"
cleanup_dir_if_empty "$LARGER_OUT_DIR" "$LARGER_OUT_DIR_PRE_EXISTING"
cleanup_dir_if_empty "$STRONGER_ENC_DIR" "$STRONGER_ENC_DIR_PRE_EXISTING"
cleanup_dir_if_empty "$TMP_DIR" "$TMP_DIR_PRE_EXISTING"

# ---------------- Final summary ----------------

script_elapsed=$SECONDS

echo "All done."
echo
echo "Summary:"
echo " Total files found               : $TOTAL_FILES"
echo " Successfully encoded (final AV1): $ENCODED_FILES"
echo " Failed files (no encode at all) : $FAILED_FILES"
echo " Total input size                : $TOTAL_INPUT_BYTES bytes ($(format_bytes "$TOTAL_INPUT_BYTES"))"

echo
echo " Processed original size (final) : $TOTAL_ORIG_BYTES_PROCESSED bytes ($(format_bytes "$TOTAL_ORIG_BYTES_PROCESSED"))"
echo " Total encoded size (final)      : $TOTAL_NEW_BYTES_PROCESSED bytes ($(format_bytes "$TOTAL_NEW_BYTES_PROCESSED"))"

if [ "$TOTAL_ORIG_BYTES_PROCESSED" -gt 0 ]; then
    local_saved_pct=$((TOTAL_SAVED_BYTES * 100 / TOTAL_ORIG_BYTES_PROCESSED))
    saved_abs=${TOTAL_SAVED_BYTES#-}
    if [ "$TOTAL_SAVED_BYTES" -ge 0 ]; then
        echo " Overall size change (final)     : -${saved_abs} bytes ($(format_bytes "$saved_abs")), ${local_saved_pct}% smaller"
    else
        echo " Overall size change (final)     : +${saved_abs} bytes ($(format_bytes "$saved_abs")), $((-local_saved_pct))% larger"
    fi
else
    echo " Overall size change (final)     : N/A (no successfully stored AV1 files)"
fi

echo " Total elapsed time              : $(format_duration "$script_elapsed")"
echo
echo "Final AV1 output folder          : $OUT_DIR"
echo "Failed originals folder          : $FAILED_DIR"
echo "Larger output folder             : $LARGER_OUT_DIR"
echo "Needs stronger encoding folder   : $STRONGER_ENC_DIR"
