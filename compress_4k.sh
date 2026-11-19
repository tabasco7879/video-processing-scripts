
#!/usr/bin/env bash
set -uo pipefail

auto_yes=0
folder="."

for arg in "$@"; do
    case "$arg" in
        -y|--yes)
            auto_yes=1
            ;;
        *)
            folder="$arg"
            ;;
    esac
done

# Convert input directory to an absolute path.
folder=$(realpath -- "$folder") || exit 1

output_dir="$folder/compressed"
csv_file="$output_dir/compression_log.csv"

for tool in ffmpeg ffprobe nvidia-smi; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing required tool: $tool" >&2
        exit 1
    }
done

[[ -d "$folder" ]] || {
    echo "Folder does not exist: $folder" >&2
    exit 1
}

nvidia-smi >/dev/null 2>&1 || {
    echo "NVIDIA GPU unavailable." >&2
    exit 1
}

mkdir -p -- "$output_dir"

# Initialize CSV only if it doesn't exist.
if [[ ! -e "$csv_file" ]]; then
    printf 'original_path,compressed_path\n' > "$csv_file"
fi

# Properly escape CSV fields.
csv_escape() {
    local value="${1//\"/\"\"}"
    printf '"%s"' "$value"
}

confirm_action() {
    local prompt="$1"
    if (( auto_yes == 1 )); then
        return 0
    fi
    local reply
    read -r -p "$prompt [y/N]: " reply < /dev/tty || return 1
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Load existing CSV records: original_path -> compressed_path
declare -A logged_outputs=()
line_num=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    (( line_num += 1 ))
    if (( line_num == 1 )) && [[ "$line" == "original_path,compressed_path" ]]; then
        continue
    fi
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^\"(([^\"]|\"\")*)\",\"(([^\"]|\"\")*)\"$ ]]; then
        orig_path="${BASH_REMATCH[1]//\"\"/\"}"
        comp_path="${BASH_REMATCH[3]//\"\"/\"}"
        logged_outputs["$orig_path"]="$comp_path"
    fi
done < "$csv_file"

verify_compressed() {
    local src="$1"
    local dst="$2"
    [[ -s "$dst" ]] || return 1

    local dst_codec dst_height src_size dst_size
    dst_codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$dst" 2>/dev/null) || return 1

    dst_height=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=height \
        -of default=noprint_wrappers=1:nokey=1 "$dst" 2>/dev/null) || return 1

    src_size=$(stat -c %s -- "$src") || return 1
    dst_size=$(stat -c %s -- "$dst") || return 1

    [[ "$dst_codec" == "hevc" && "$dst_height" == "2160" ]] && (( dst_size < src_size ))
}

# Search recursively, excluding the compressed directory.
while IFS= read -r -u 3 -d '' input; do

    codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$input") || continue

    height=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=height \
        -of default=noprint_wrappers=1:nokey=1 "$input") || continue

    # Only compress H.264 videos with height 2160.
    [[ "$codec" == "h264" && "$height" == "2160" ]] || continue

    # Calculate relative path from root folder.
    relative_path="${input#"$folder"/}"

    # Extract relative directory and filename.
    relative_dir=$(dirname -- "$relative_path")
    filename="${input##*/}"

    # Recreate directory structure under compressed/.
    target_dir="$output_dir/$relative_dir"
    mkdir -p -- "$target_dir"

    output="$target_dir/${filename%.*}_hevc.mp4"

    if [[ -n "${logged_outputs["$input"]:-}" ]]; then
        logged_output="${logged_outputs["$input"]}"
        if verify_compressed "$input" "$logged_output"; then
            echo "Skipping verified compressed output: $logged_output"
            continue
        else
            echo "Verification failed for logged output: $logged_output"
            if ! confirm_action "Re-encode $input?"; then
                echo "Skipping re-encode: $input"
                continue
            fi
        fi
    fi

    # Temporary file in the same target directory.
    temp=$(mktemp --tmpdir="$target_dir" \
        '.encode-XXXXXXXX.mp4') || exit 1

    echo "Compressing: $input"

    if ffmpeg -nostdin -hide_banner -y \
        -hwaccel cuda -hwaccel_output_format cuda -i "$input" \
        -map 0:v:0 -map '0:a?' \
        -c:v hevc_nvenc -preset p6 -tune hq \
        -rc vbr -b:v 6M -maxrate 12M -bufsize 24M \
        -c:a copy -tag:v hvc1 -movflags +faststart \
        "$temp"; then

        source_size=$(stat -c %s -- "$input")
        output_size=$(stat -c %s -- "$temp")

        if (( output_size < source_size )); then

            mv -- "$temp" "$output"

            # Append successful compression to CSV if not already recorded.
            if [[ "${logged_outputs["$input"]:-}" != "$output" ]]; then
                {
                    csv_escape "$input"
                    printf ','
                    csv_escape "$output"
                    printf '\n'
                } >> "$csv_file"
                logged_outputs["$input"]="$output"
            fi

            echo "Saved: $output"
            echo "Bytes: $source_size -> $output_size"

        else
            rm -f -- "$temp"
            echo "Discarded output: not smaller than original."
        fi
    else
        rm -f -- "$temp"
        echo "Encoding failed: $input" >&2
        exit 1
    fi

done 3< <(
    find "$folder" \
        -type d -name compressed -prune -o \
        -type f -iname '*.mp4' -print0
)

echo "Compression completed."
echo "CSV log: $csv_file"
