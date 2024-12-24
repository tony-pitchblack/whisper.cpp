#!/bin/bash
#
# Transcribe audio livestream by feeding ffmpeg output to whisper.cpp at regular intervals
# Idea by @semiformal-net
# ref: https://github.com/ggerganov/whisper.cpp/issues/185
#

set -eo pipefail

url="http://a.files.bbci.co.uk/media/live/manifesto/audio/simulcast/hls/nonuk/sbr_low/ak/bbc_world_service.m3u8"
fmt=aac # the audio format extension of the stream (TODO: auto detect)
step_s=30
model="base.en"
language="en"  # Default language is English
max_duration=0  # Default: no duration limit (0 means unlimited)

check_requirements()
{
    if ! command -v ./build/bin/whisper-cli &>/dev/null; then
        echo "whisper.cpp main executable is required (make)"
        exit 1
    fi

    if ! command -v ffmpeg &>/dev/null; then
        echo "ffmpeg is required (https://ffmpeg.org)"
        exit 1
    fi
}

check_requirements


if [ -z "$1" ]; then
    echo "Usage: $0 stream_url [step_s] [model] [language] [max_duration]"
    echo ""
    echo "  Example:"
    echo "    $0 $url $step_s $model $language $max_duration"
    echo ""
    echo "No url specified, using default: $url"
else
    url="$1"
fi

if [ -n "$2" ]; then
    step_s="$2"
fi

if [ -n "$3" ]; then
    model="$3"
fi

if [ -n "$4" ]; then
    language="$4"  # Set the language if provided
fi

if [ -n "$5" ]; then
    max_duration="$5"  # Set the maximum audio duration if provided
fi

# Whisper models
models=( "tiny.en" "tiny" "base.en" "base" "small.en" "small" "medium.en" "medium" "large-v1" "large-v2" "large-v3" "large-v3-turbo" )

# list available models
function list_models {
    printf "\n"
    printf "  Available models:"
    for model in "${models[@]}"; do
        printf " $model"
    done
    printf "\n\n"
}

if [[ ! " ${models[@]} " =~ " ${model} " ]]; then
    printf "Invalid model: $model\n"
    list_models

    exit 1
fi

running=1

trap "running=0" SIGINT SIGTERM

printf "[+] Transcribing stream with model '$model', language '$language', step_s $step_s (press Ctrl+C to stop):\n\n"

# Apply the max_duration option if it's set
if [ "$max_duration" -gt 0 ]; then
    printf "[+] Limiting audio input to $max_duration seconds\n"
    ffmpeg -loglevel quiet -y -re -probesize 32 -i $url -c copy -t $max_duration /tmp/whisper-live0.${fmt} &
else
    # No limit on audio duration
    ffmpeg -loglevel quiet -y -re -probesize 32 -i $url -c copy /tmp/whisper-live0.${fmt} &
fi

if [ $? -ne 0 ]; then
    printf "Error: ffmpeg failed to capture audio stream\n"
    exit 1
fi

printf "Buffering audio. Please wait...\n\n"
sleep $(($step_s))

# do not stop script on error
set +e

i=0
SECONDS=0
while [ $running -eq 1 ]; do
    # extract the next piece from the main file above and transcode to wav. -ss sets start time and nudges it by -0.5s to catch missing words (??)
    err=1
    while [ $err -ne 0 ]; do
        if [ $i -gt 0 ]; then
            ffmpeg -loglevel quiet -v error -noaccurate_seek -i /tmp/whisper-live0.${fmt} -y -ar 16000 -ac 1 -c:a pcm_s16le -ss $(($i*$step_s-1)).5 -t $step_s /tmp/whisper-live.wav 2> /tmp/whisper-live.err
        else
            ffmpeg -loglevel quiet -v error -noaccurate_seek -i /tmp/whisper-live0.${fmt} -y -ar 16000 -ac 1 -c:a pcm_s16le -ss $(($i*$step_s)) -t $step_s /tmp/whisper-live.wav 2> /tmp/whisper-live.err
        fi
        err=$(cat /tmp/whisper-live.err | wc -l)
    done

    ./build/bin/whisper-cli -t 8 -m ./models/ggml-${model}.bin -f /tmp/whisper-live.wav --language $language --no-timestamps -otxt 2> /tmp/whispererr | tail -n 1

    while [ $SECONDS -lt $((($i+1)*$step_s)) ]; do
        sleep 1
    done
    ((i=i+1))

    # Stop if max_duration is reached
    if [ "$max_duration" -gt 0 ] && [ $SECONDS -ge $max_duration ]; then
        echo "Max duration reached, stopping stream."
        break
    fi
done

killall -v ffmpeg
killall -v whisper-cli
