#!/bin/bash
#
# Transcribe audio livestream by feeding ffmpeg output to whisper.cpp at regular intervals
#

set -eo pipefail

url="http://a.files.bbci.co.uk/media/live/manifesto/audio/simulcast/hls/nonuk/sbr_low/ak/bbc_world_service.m3u8"
fmt=aac # the audio format extension of the stream (TODO: auto detect)
step_s=30
model="base.en"
language="en"  # Default language is English
max_duration=0  # Default: no duration limit (0 means unlimited)
verbosity=1  # Default: log everything
print_openai=0  # Default is off (0)

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
    echo "Usage: $0 stream_url [step_s] [model] [language] [max_duration] [verbosity] [print_openai]"
    echo ""
    echo "  Example:"
    echo "    $0 $url $step_s $model $language $max_duration $verbosity $print_openai"
    echo ""
    echo "No url specified, using default: $url"
else
    url="$1"
fi

if [[ $# -ge 2 ]]; then step_s="$2"; fi
if [[ $# -ge 3 ]]; then model="$3"; fi
if [[ $# -ge 4 ]]; then language="$4"; fi
if [[ $# -ge 5 ]]; then max_duration="$5"; fi
if [[ $# -ge 6 ]]; then verbosity="$6"; fi
if [[ $# -ge 7 ]]; then print_openai="$7"; fi  

log() {
    if [ "$verbosity" -gt 0 ]; then
        echo "$@"
    fi
}

# # Debug parameters
# verbosity=1
# log "[+] Parameters:"
# log "  url: $url"
# log "  step_s: $step_s"
# log "  model: $model"
# log "  language: $language"
# log "  max_duration: $max_duration"
# log "  verbosity: $verbosity"
# log "  print_openai: $print_openai"

models=( "tiny.en" "tiny" "base.en" "base" "small.en" "small" "medium.en" "medium" "large-v1" "large-v2" "large-v3" "large-v3-turbo" )

list_models() {
    printf "\n"
    printf "  Available models:"
    for model in "${models[@]}"; do
        printf " $model"
    done
    printf "\n\n"
}

if [[ ! " ${models[@]} " =~ " ${model} " ]]; then
    log "Invalid model: $model"?
    list_models
    exit 1
fi

running=1
trap "running=0" SIGINT SIGTERM

log "[+] Transcribing stream with model '$model', language '$language', step_s $step_s (press Ctrl+C to stop):"

if [ "$max_duration" -gt 0 ]; then
    log "[+] Limiting audio input to $max_duration seconds"
    ffmpeg -loglevel quiet -y -re -probesize 32 -i $url -c copy -t $max_duration /tmp/whisper-live0.${fmt} &
else
    ffmpeg -loglevel quiet -y -re -probesize 32 -i $url -c copy /tmp/whisper-live0.${fmt} &
fi

if [ $? -ne 0 ]; then
    log "Error: ffmpeg failed to capture audio stream"
    exit 1
fi

log "Buffering audio. Please wait..."
sleep $(($step_s))

set +e

i=0
SECONDS=0
while [ $running -eq 1 ]; do
    err=1
    while [ $err -ne 0 ]; do
        if [ $i -gt 0 ]; then
            ffmpeg -loglevel quiet -v error -noaccurate_seek -i /tmp/whisper-live0.${fmt} -y -ar 16000 -ac 1 -c:a pcm_s16le -ss $(($i*$step_s-1)).5 -t $step_s /tmp/whisper-live.wav 2> /tmp/whisper-live.err
        else
            ffmpeg -loglevel quiet -v error -noaccurate_seek -i /tmp/whisper-live0.${fmt} -y -ar 16000 -ac 1 -c:a pcm_s16le -ss $(($i*$step_s)) -t $step_s /tmp/whisper-live.wav 2> /tmp/whisper-live.err
        fi
        err=$(cat /tmp/whisper-live.err | wc -l)
    done

    if [ "$print_openai" -eq 1 ]; then
        ./build/bin/whisper-cli \
            -t 8 \
            -m ./models/ggml-${model}.bin \
            -f /tmp/whisper-live.wav \
            --language $language \
            -poai 2> /tmp/whispererr
    else
        ./build/bin/whisper-cli \
            -t 8 \
            -m ./models/ggml-${model}.bin \
            -f /tmp/whisper-live.wav \
            --language $language \
            --no-timestamps \
            -otxt 2> /tmp/whispererr | tail -n 1
    fi

    while [ $SECONDS -lt $((($i+1)*$step_s)) ]; do
        sleep 1
    done
    ((i=i+1))

    if [ "$max_duration" -gt 0 ] && [ $SECONDS -ge $max_duration ]; then
        log "Max duration reached, stopping stream."
        break
    fi
done

if [ "$verbosity" -gt 0 ]; then
    killall -v ffmpeg
    killall -v whisper-cli
else
    killall -v ffmpeg &>/dev/null
    killall -v whisper-cli &>/dev/null
fi