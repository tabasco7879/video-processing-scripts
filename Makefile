SHELL := /usr/bin/env bash
.ONESHELL:
.SHELLFLAGS := -uo pipefail -c

# Capture positional folder argument (e.g. `make compress my_folder` or `make clean my_folder`)
TARGET_ARG := $(word 2,$(MAKECMDGOALS))
FOLDER ?= $(if $(TARGET_ARG),$(TARGET_ARG),.)

.PHONY: all compress clean help $(TARGET_ARG)

all: help

# No-op rule so GNU Make doesn't complain about the positional folder argument
ifneq ($(TARGET_ARG),)
$(TARGET_ARG):
	@:
endif

help:
	@echo "Usage:"
	@echo "  make compress [foldername]   Compress 4K H.264 MP4 videos and log to CSV"
	@echo "  make clean [foldername]      Delete original source files listed in the CSV log"

compress:
	@folder=$$(realpath -- "$(FOLDER)") || exit 1
	output_dir="$$folder/compressed"
	csv_file="$$output_dir/compression_log.csv"

	for tool in ffmpeg ffprobe nvidia-smi; do
		command -v "$$tool" >/dev/null 2>&1 || {
			echo "Missing required tool: $$tool" >&2
			exit 1
		}
	done

	[[ -d "$$folder" ]] || {
		echo "Folder does not exist: $$folder" >&2
		exit 1
	}

	nvidia-smi >/dev/null 2>&1 || {
		echo "NVIDIA GPU unavailable." >&2
		exit 1
	}

	mkdir -p -- "$$output_dir"

	if [[ ! -e "$$csv_file" ]]; then
		printf 'original_path,compressed_path\n' > "$$csv_file"
	fi

	csv_escape() {
		local value="$${1//\"/\"\"}"
		printf '"%s"' "$$value"
	}

	while IFS= read -r -d '' input; do
		codec=$$(ffprobe -v error -select_streams v:0 \
			-show_entries stream=codec_name \
			-of default=noprint_wrappers=1:nokey=1 "$$input") || continue

		height=$$(ffprobe -v error -select_streams v:0 \
			-show_entries stream=height \
			-of default=noprint_wrappers=1:nokey=1 "$$input") || continue

		[[ "$$codec" == "h264" && "$$height" == "2160" ]] || continue

		relative_path="$${input#"$$folder"/}"
		relative_dir=$$(dirname -- "$$relative_path")
		filename="$${input##*/}"

		target_dir="$$output_dir/$$relative_dir"
		mkdir -p -- "$$target_dir"

		output="$$target_dir/$${filename%.*}_hevc.mp4"

		if [[ -e "$$output" ]]; then
			echo "Skipping existing output: $$output"
			continue
		fi

		temp=$$(mktemp --tmpdir="$$target_dir" '.encode-XXXXXXXX.mp4') || exit 1

		echo "Compressing: $$input"

		if ffmpeg -nostdin -hide_banner -y \
			-hwaccel cuda -hwaccel_output_format cuda -i "$$input" \
			-map 0:v:0 -map '0:a?' \
			-c:v hevc_nvenc -preset p6 -tune hq \
			-rc vbr -b:v 6M -maxrate 12M -bufsize 24M \
			-c:a copy -tag:v hvc1 -movflags +faststart \
			"$$temp"; then

			source_size=$$(stat -c %s -- "$$input")
			output_size=$$(stat -c %s -- "$$temp")

			if (( output_size < source_size )); then
				mv -- "$$temp" "$$output"

				{
					csv_escape "$$input"
					printf ','
					csv_escape "$$output"
					printf '\n'
				} >> "$$csv_file"

				echo "Saved: $$output"
				echo "Bytes: $$source_size -> $$output_size"
			else
				rm -f -- "$$temp"
				echo "Discarded output: not smaller than original."
			fi
		else
			rm -f -- "$$temp"
			echo "Encoding failed: $$input" >&2
			exit 1
		fi
	done < <(
		find "$$folder" \
			-type d -name compressed -prune -o \
			-type f -iname '*.mp4' -print0
	)

	echo "Compression completed."
	echo "CSV log: $$csv_file"

clean:
	@folder=$$(realpath -- "$(FOLDER)") || exit 1
	csv_file="$$folder/compressed/compression_log.csv"

	[[ -f "$$csv_file" ]] || {
		echo "CSV log not found: $$csv_file" >&2
		exit 1
	}

	removed=0
	skipped=0
	line_num=0

	while IFS= read -r line || [[ -n "$$line" ]]; do
		line="$${line%$$'\r'}"
		(( line_num += 1 ))
		# Skip CSV header
		if (( line_num == 1 )) && [[ "$$line" == "original_path,compressed_path" ]]; then
			continue
		fi
		[[ -z "$$line" ]] && continue

		if [[ "$$line" =~ ^\"(([^\"]|\"\")*)\",\"(([^\"]|\"\")*)\"$$ ]]; then
			original_path="$${BASH_REMATCH[1]//\"\"/\"}"
			compressed_path="$${BASH_REMATCH[3]//\"\"/\"}"
		else
			echo "Skipping malformed CSV line $$line_num: $$line" >&2
			continue
		fi

		if [[ ! -s "$$compressed_path" ]]; then
			echo "Skipping deletion (compressed output missing or empty): $$compressed_path" >&2
			(( skipped += 1 ))
			continue
		fi

		if [[ -e "$$original_path" ]]; then
			rm -f -- "$$original_path"
			echo "Deleted source: $$original_path"
			(( removed += 1 ))
		else
			echo "Source already removed: $$original_path"
			(( skipped += 1 ))
		fi
	done < "$$csv_file"

	echo "Clean completed. Deleted: $$removed, Skipped: $$skipped."
