import asyncio
import subprocess
import sys
import os
import json
import argparse
from pathlib import Path

async def transcribe_audio(audio_chunk, model, language, print_openai, whispercpp_root_path):
    """
    Transcribe audio using whisper-cli from a specified WhisperCpp root path.

    Args:
        audio_chunk (bytes): The audio chunk to transcribe.
        model (str): The model to use for transcription (e.g., "small").
        language (str): The language of the audio.
        whispercpp_root_path (str): The root path to WhisperCpp, used to locate whisper-cli.

    Returns:
        dict: The transcription result as a dictionary, or None if an error occurs.
    """
    temp_audio_path = "/tmp/temp_audio.wav"  # Path for temporary audio storage
    
    # Write audio_chunk to a temporary file
    with open(temp_audio_path, "wb") as f:
        f.write(audio_chunk)
    
    # Construct the path to whisper-cli
    whisper_cli_path = os.path.join(whispercpp_root_path, "build", "bin", "whisper-cli")

    # Construct the path to model
    model_path = os.path.join(whispercpp_root_path, f"models/ggml-{model}.bin")
    
    # Run whisper-cli as a subprocess
    command = (
        f"{whisper_cli_path} {temp_audio_path} --model {model_path} --language {language} --print-openai {print_openai}"
    )

    process = await asyncio.create_subprocess_shell(
        command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )

    stdout, stderr = await process.communicate()

    if stderr:
        print(f"[stderr] {stderr.decode().strip()}")

    if stdout:
        try:
            transcription = json.loads(stdout.decode().strip())
            return transcription
        except json.JSONDecodeError:
            print("[Error] Failed to parse JSON output from whisper-cli.")
            return None


async def stream_and_transcribe(
    stream_url, step_s, model, language, max_duration, verbosity, print_openai, whispercpp_root_path
):
    """
    Main function to stream audio and transcribe it using WhisperCpp.

    Args:
        stream_url (str): The URL of the audio stream.
        step_s (int): Step in seconds for audio streaming.
        model (str): Model to use for transcription.
        language (str): Language for transcription.
        max_duration (int): Maximum duration for the stream.
        verbosity (int): Verbosity level for logs.
        print_openai (int): Whether to print OpenAI-style output.
        whispercpp_root_path (str): Root path of WhisperCpp to locate whisper-cli.
    """
    print(f"Streaming from URL: {stream_url}")
    print(f"Step: {step_s}s, Model: {model}, Language: {language}, Max Duration: {max_duration}s")
    
    # Simulate audio streaming with placeholder logic
    # Replace this with actual streaming and chunking logic if required
    for _ in range(max_duration // step_s):
        # Simulate getting a new audio chunk (replace this with real streaming data)
        audio_chunk = b"fake_audio_data"  # Placeholder binary data

        # Transcribe the audio chunk
        transcription = await transcribe_audio(audio_chunk, model, language, print_openai, whispercpp_root_path)

        # Print the transcription result
        if transcription:
            print(json.dumps(transcription, indent=2, ensure_ascii=False))
        
        # Wait for the next step
        await asyncio.sleep(step_s)

async def stream_and_transcribe(
    stream_url, step_s, model, language, max_duration, verbosity, print_openai, whispercpp_root_path
):
    """
    Stream audio from a URL and transcribe it using WhisperCpp.
    """
    print(f"Streaming from URL: {stream_url}")
    print(f"Step: {step_s}s, Model: {model}, Language: {language}, Max Duration: {max_duration}s")

    # Temporary file paths
    live_audio_path = "/tmp/whisper-live0.wav"  # Use WAV for better streaming handling
    processed_audio_path = "/tmp/whisper-live.wav"
    whisper_cli_path = os.path.join(whispercpp_root_path, "build/bin/whisper-cli")
    model_path = os.path.join(whispercpp_root_path, f"models/ggml-{model}.bin")

    # Start ffmpeg for live streaming
    ffmpeg_command = [
        "ffmpeg",
        "-loglevel", "quiet",
        "-y",  # Overwrite file
        "-re",  # Real-time streaming
        "-probesize", "32",
        "-i", stream_url,
        "-ar", "16000",  # Ensure consistent sample rate
        "-ac", "1",  # Mono audio
        "-c:a", "pcm_s16le",
        live_audio_path,
    ]
    if max_duration > 0:
        ffmpeg_command.extend(["-t", str(max_duration)])

    ffmpeg_process = subprocess.Popen(ffmpeg_command)
    print("[+] Buffering audio. Please wait...")
    await asyncio.sleep(step_s)

    i = 0
    try:
        while True:
            # Calculate segment start time
            start_time = i * step_s

            # Extract segment using ffmpeg
            ffmpeg_segment_command = [
                "ffmpeg",
                "-loglevel", "quiet",
                "-v", "error",
                "-noaccurate_seek",
                "-i", live_audio_path,
                "-y",
                "-ar", "16000",
                "-ac", "1",
                "-c:a", "pcm_s16le",
                "-ss", str(start_time),
                "-t", str(step_s),
                processed_audio_path,
            ]
            segment_process = subprocess.run(ffmpeg_segment_command, stderr=subprocess.PIPE)

            if segment_process.returncode != 0:
                print(f"Error extracting segment: {segment_process.stderr.decode()}")
                # Break the loop if extraction fails consistently
                break

            # Transcribe the segment
            whisper_command = [
                whisper_cli_path,
                "-t", "8",
                "-m", model_path,
                "-f", processed_audio_path,
                "--language", language,
            ]
            if print_openai:
                whisper_command.append("-poai")
            else:
                whisper_command.extend(["--no-timestamps", "-otxt"])

            try:
                whisper_output = subprocess.check_output(whisper_command, stderr=subprocess.PIPE)
                if not print_openai:
                    transcription = whisper_output.decode().strip().split("\n")[-1]
                    print(transcription)
                else:
                    print(whisper_output.decode().strip())
            except subprocess.CalledProcessError as e:
                print(f"Error during transcription: {e.stderr.decode()}")
                break

            # Wait for the next step or exit if max_duration is reached
            i += 1
            await asyncio.sleep(step_s)

            if max_duration > 0 and i * step_s >= max_duration:
                print("[+] Max duration reached, stopping stream.")
                break
    finally:
        # Clean up
        ffmpeg_process.terminate()
        if os.path.exists(live_audio_path):
            os.remove(live_audio_path)
        if os.path.exists(processed_audio_path):
            os.remove(processed_audio_path)


def main():
    parser = argparse.ArgumentParser(description="Run the Whisper streaming transcription script.")
    
    # Define arguments matching whisper_streaming.py
    parser.add_argument("stream_url", type=str, help="The URL of the stream.")
    parser.add_argument("--step_s", type=int, default=15, help="Step in seconds for the stream.")
    parser.add_argument("--model", type=str, default="small", help="Model to use.")
    parser.add_argument("--language", type=str, default="ru", help="Language of the stream.")
    parser.add_argument("--max_duration", type=int, default=60, help="Maximum duration for the stream.")
    parser.add_argument("--verbosity", type=int, default=0, help="Verbosity level.")
    parser.add_argument("--print_openai", type=int, default=1, help="Whether to print OpenAI output.")
    parser.add_argument("--whispercpp_root_path", type=str, help="Path to the WhisperCpp root directory.")

    args = parser.parse_args()

    # Set default path for whispercpp_root_path if not provided
    if not args.whispercpp_root_path:
        args.whispercpp_root_path = os.path.expanduser("~/whisper.cpp")
    
    # Run the asyncio event loop
    asyncio.run(
        stream_and_transcribe(
            args.stream_url,
            args.step_s,
            args.model,
            args.language,
            args.max_duration,
            args.verbosity,
            args.print_openai,
            args.whispercpp_root_path
        )
    )


if __name__ == "__main__":
    main()
