#!/bin/bash
# Regenerate the small, synthetic playback fixtures; no copyrighted media needed.
set -euo pipefail
cd "$(dirname "$0")/../Tests/MediaPlaybackTests/Fixtures"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'color=black:s=640x360:r=24,drawbox=x=0:y=0:w=iw:h=60:color=red:t=fill' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' -i english.srt -i styled.ass \
    -map 0:v -map 1:a -map 2:s -map 3:s -t 6 -c:v mpeg4 -q:v 5 -c:a aac -c:s copy \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title=English \
    -metadata:s:s:1 language=jpn -metadata:s:s:1 title=Styled -disposition:s:0 default tracks.mkv
ffmpeg -hide_banner -loglevel error -y -i tracks.mkv -map 0:v -map 0:a -map 0:s:0 \
    -c copy -c:s mov_text tracks.mp4
ffmpeg -hide_banner -loglevel error -y -i tracks.mkv -map 0:a -map 0:s:0 -c copy audio.mka
ffmpeg -hide_banner -loglevel error -y -i tracks.mkv -map 0:a -c copy audio.m4a
ffmpeg -hide_banner -loglevel error -y -display_rotation:v:0 90 -i tracks.mp4 \
    -map 0:v -map 0:a -c copy rotated.mp4

# Distinct tones, a non-first default, and an unlabelled track exercise audio selection.
ffmpeg -hide_banner -loglevel error -y -i tracks.mkv \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000' \
    -f lavfi -i 'sine=frequency=1320:sample_rate=48000' \
    -map 0:v -map 0:a -map 1:a -map 2:a -map 0:s -t 6 -c copy -c:a:1 aac -c:a:2 aac \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title=English \
    -metadata:s:a:1 language=jpn -metadata:s:a:1 title=Japanese \
    -metadata:s:a:2 language=und -disposition:a:0 0 -disposition:a:1 default -disposition:a:2 0 audio-tracks.mkv
ffmpeg -hide_banner -loglevel error -y -i audio-tracks.mkv -map 0:a -c copy audio-tracks.m4a
ffmpeg -hide_banner -loglevel error -y -i tracks.mkv -map 0:v -c copy silent.mkv
