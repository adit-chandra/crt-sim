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
