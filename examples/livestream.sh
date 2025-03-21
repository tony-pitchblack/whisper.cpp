#!/bin/bash
#
# Transcribe audio livestream by feeding ffmpeg output to whisper.cpp at regular intervals
#

set -eo pipefail
shopt -s expand_aliases
alias time='/usr/bin/time'

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

if [[ $# -ge 2 ]]; then step_s="$2"; fi
if [[ $# -ge 3 ]]; then model="$3"; fi
if [[ $# -ge 4 ]]; then language="$4"; fi
if [[ $# -ge 5 ]]; then max_duration="$5"; fi
if [[ $# -ge 6 ]]; then verbosity="$6"; fi
if [[ $# -ge 7 ]]; then print_openai="$7"; fi  

if [ -n "$1" ]; then
    url="$1"
    if [ "$verbosity" -gt 0 ]; then
        echo "Using stream URL: $url"
    fi
else
    if [ "$verbosity" -gt 0 ]; then
        echo "Usage: $0 stream_url [step_s] [model] [language] [max_duration] [verbosity] [print_openai]"
        echo ""
        echo "  Example:"
        echo "    $0 $url $step_s $model $language $max_duration $verbosity $print_openai"
        echo ""
        echo "No stream URL specified, using default: $url"
    fi
fi

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
    ffmpeg -loglevel quiet -y -re -probesize 100000 -i $url -c copy -t $max_duration /tmp/whisper-live0.${fmt} &
else
    ffmpeg -loglevel quiet -y -re -probesize 100000 -i $url -c copy /tmp/whisper-live0.${fmt} &
fi

if [ $? -ne 0 ]; then
    log "Error: ffmpeg failed to capture audio stream"
    exit 1
fi

log -e "Buffering $step_s seconds of audio...\n"
sleep $(($step_s))

set +e

i=0
processed_time=0
start_time=$SECONDS  # Start tracking the elapsed time from the script start

while [ $running -eq 1 ]; do
    ffmpeg_start_time=$SECONDS
    err=1
    while [ $err -ne 0 ]; do
        if [ $i -gt 0 ]; then
            ffmpeg -loglevel quiet -v error -noaccurate_seek -i /tmp/whisper-live0.${fmt} -y -ar 16000 -ac 1 -c:a pcm_s16le -ss $(($i * $step_s - 1)).5 -t $step_s /tmp/whisper-live.wav 2> /tmp/whisper-live.err
        else
            ffmpeg -loglevel quiet -v error -noaccurate_seek -i /tmp/whisper-live0.${fmt} -y -ar 16000 -ac 1 -c:a pcm_s16le -ss $(($i * $step_s)) -t $step_s /tmp/whisper-live.wav 2> /tmp/whisper-live.err
        fi
        err=$(cat /tmp/whisper-live.err | wc -l)
    done

    ffmpeg_loop_time=$(($SECONDS - ffmpeg_start_time))
    if [ "$verbosity" -gt 0 ]; then
        formatted_ffmpeg_loop_time=$(date -u -d @$ffmpeg_loop_time +'%H:%M:%S')
        echo "ffmpeg loop time: $formatted_ffmpeg_loop_time"
    fi

    # if [ "$verbosity" -gt 0 ]; then
    #     redirect_out = "2>&1"
    # else
    #     redirect_out = ""
    # fi

    # TODO: debug whisper-cli not outputting to stdout
    if [ "$print_openai" -eq 1 ]; then
        time -f "whisper-cli time: %E" \
            bash -c "./build/bin/whisper-cli \
                -t 8 \
                -m ./models/ggml-${model}.bin \
                -f /tmp/whisper-live.wav \
                --language $language \
                -poai > /tmp/whispererr 2>&1"
        # > /dev/stderr
    else
        time -f "whisper-cli time: %E" \
            bash -c "./build/bin/whisper-cli \
                -t 8 \
                -m ./models/ggml-${model}.bin \
                -f /tmp/whisper-live.wav \
                --language $language \
                -otxt > /tmp/whispererr 2>&1"
        # > /dev/stderr
    fi

    processed_time=$((processed_time + step_s))
    elapsed_time=$((SECONDS - start_time))

    # Print time
    if [ "$verbosity" -gt 0 ]; then
        # Convert seconds to h:m:s format using date
        formatted_processed_time=$(date -u -d @$processed_time +'%H:%M:%S')
        formatted_elapsed_time=$(date -u -d @$elapsed_time +'%H:%M:%S')

        echo "Processed time: $formatted_processed_time"
        echo -e "Elapsed time: $formatted_elapsed_time\n"
    fi

    # End if reached max file duration
    if [ "$max_duration" -gt 0 ] && [ $processed_time -ge $max_duration ]; then
        if [ "$verbosity" -gt 0 ]; then
            echo -e "\nMax file duration reached, stopping stream.\n"
        fi

        break
    fi

    # Wait until the next step
    while [ $((SECONDS - start_time)) -lt $((($i + 1) * $step_s)) ]; do
        sleep 1
    done
    ((i = i + 1))
done

# TODO: remove killing nonexistent processes
if [ "$verbosity" -gt 0 ]; then
    killall -v ffmpeg
    killall -v whisper-cli
    echo -e '\n'
else
    killall -v ffmpeg &>/dev/null
    killall -v whisper-cli &>/dev/null
fi