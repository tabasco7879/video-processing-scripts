
#!/usr/bin/env bash
set -uo pipefail

folder="${1:-.}"

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

# Search recursively, excluding the compressed directory.
while IFS= read -r -d '' input; do

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

    if [[ -e "$output" ]]; then
        echo "Skipping existing output: $output"
        continue
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

            # Append successful compression to CSV.
            {
                csv_escape "$input"
                printf ','
                csv_escape "$output"
                printf '\n'
            } >> "$csv_file"

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

done < <(
    find "$folder" \
        -type d -name compressed -prune -o \
        -type f -iname '*.mp4' -print0
)

echo "Compression completed."
echo "CSV log: $csv_file"
