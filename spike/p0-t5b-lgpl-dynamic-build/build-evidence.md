# P0-T5b 构建方式证据（自动提取自 /tmp/p0t5b-build/build-v3.log）

> 用途：LGPL 合规材料要求提供「构建方式」。本文件是从**实际产出该产物的那次构建**日志中提取的原始命令行。
> 生成时间：2026-10-13 12:42:22

## 1. mpv（libmpv）的 meson 配置

```
meson
setup
--cross-file=/private/tmp/p0t5b-build/mpvkit/dist/libmpv/ios/scratch/arm64/crossFile.meson
-Dlibmpv=true
-Ddefault_library=shared
-Dgl=enabled
-Dplain-gl=enabled
-Diconv=enabled
-Duchardet=enabled
-Dvulkan=enabled
-Dmoltenvk=enabled
-Djavascript=disabled
-Dzimg=disabled
-Djpeg=disabled
-Dvapoursynth=disabled
-Drubberband=disabled
-Dgpl=false
-Dlibbluray=enabled
-Dcplayer=false
-Dvideotoolbox-gl=disabled
-Dvideotoolbox-pl=enabled
-Dswift-build=disabled
-Daudiounit=enabled
-Davfoundation=enabled
-Dcoreaudio=disabled
-Dlua=disabled
-Dios-gl=enabled
```

## 2. FFmpeg 的 configure 行（ios-arm64）

```
/private/tmp/p0t5b-build/mpvkit/dist/FFmpeg-n9.0.2/configure --prefix=/private/tmp/p0t5b-build/mpvkit/dist/FFmpeg/ios/thin/arm64 --disable-armv5te --disable-armv6 --disable-armv6t2 --disable-bzlib --disable-gray --disable-iconv --disable-linux-perf --disable-shared --disable-small --disable-symver --disable-xlib --enable-cross-compile --enable-libxml2 --enable-optimizations --enable-pic --enable-runtime-cpudetect --enable-static --enable-thumb --pkg-config-flags=--static --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages --enable-avcodec --enable-avformat --enable-avutil --enable-network --enable-swresample --enable-swscale --disable-devices --disable-outdevs --disable-indevs --disable-amf --disable-d3d11va --disable-d3d12va --disable-dxva2 --disable-vaapi --disable-vdpau --enable-securetransport --disable-muxers --enable-muxer=flac --enable-muxer=dash --enable-muxer=hevc --enable-muxer=m4v --enable-muxer=matroska --enable-muxer=mov --enable-muxer=mp4 --enable-muxer=mpegts --enable-muxer=webm* --disable-encoders --enable-encoder=aac --enable-encoder=alac --enable-encoder=flac --enable-encoder=pcm* --enable-encoder=movtext --enable-encoder=mpeg4 --enable-encoder=h264_videotoolbox --enable-encoder=hevc_videotoolbox --enable-encoder=prores --enable-encoder=prores_videotoolbox --enable-protocols --disable-demuxers --enable-demuxer=aac --enable-demuxer=ac3 --enable-demuxer=aiff --enable-demuxer=amr --enable-demuxer=ape --enable-demuxer=asf --enable-demuxer=ass --enable-demuxer=av1 --enable-demuxer=avi --enable-demuxer=caf --enable-demuxer=concat --enable-demuxer=dash --enable-demuxer=data --enable-demuxer=dv --enable-demuxer=eac3 --enable-demuxer=flac --enable-demuxer=flv --enable-demuxer=h264 --enable-demuxer=hevc --enable-demuxer=hls --enable-demuxer=live_flv --enable-demuxer=loas --enable-demuxer=m4v --enable-demuxer=matroska --enable-demuxer=mov --enable-demuxer=mp3 --enable-demuxer=mpeg* --enable-demuxer=ogg --enable-demuxer=rm --enable-demuxer=rtsp --enable-demuxer=rtp --enable-demuxer=srt --enable-demuxer=webvtt --enable-demuxer=vc1 --enable-demuxer=wav --enable-demuxer=webm_dash_manifest --enable-bsfs --disable-decoders --enable-decoder=av1 --enable-decoder=dca --enable-decoder=dxv --enable-decoder=ffv1 --enable-decoder=ffvhuff --enable-decoder=flv --enable-decoder=h263 --enable-decoder=h263i --enable-decoder=h263p --enable-decoder=h264 --enable-decoder=hap --enable-decoder=hevc --enable-decoder=huffyuv --enable-decoder=indeo5 --enable-decoder=mjpeg --enable-decoder=mjpegb --enable-decoder=mpeg* --enable-decoder=mts2 --enable-decoder=prores --enable-decoder=mpeg4 --enable-decoder=mpegvideo --enable-decoder=rv10 --enable-decoder=rv20 --enable-decoder=rv30 --enable-decoder=rv40 --enable-decoder=snow --enable-decoder=svq3 --enable-decoder=tscc --enable-decoder=txd --enable-decoder=wmv1 --enable-decoder=wmv2 --enable-decoder=wmv3 --enable-decoder=vc1 --enable-decoder=vp6 --enable-decoder=vp6a --enable-decoder=vp6f --enable-decoder=vp7 --enable-decoder=vp8 --enable-decoder=vp9 --enable-decoder=aac* --enable-decoder=ac3* --enable-decoder=adpcm* --enable-decoder=alac* --enable-decoder=amr* --enable-decoder=ape --enable-decoder=cook --enable-decoder=dca --enable-decoder=dolby_e --enable-decoder=eac3* --enable-decoder=flac --enable-decoder=mp1* --enable-decoder=mp2* --enable-decoder=mp3* --enable-decoder=opus --enable-decoder=pcm* --enable-decoder=truehd --enable-decoder=tta --enable-decoder=vorbis --enable-decoder=wma* --enable-decoder=ass --enable-decoder=ccaption --enable-decoder=dvbsub --enable-decoder=dvdsub --enable-decoder=mpl2 --enable-decoder=movtext --enable-decoder=pgssub --enable-decoder=srt --enable-decoder=ssa --enable-decoder=subrip --enable-decoder=xsub --enable-decoder=webvtt --disable-filters --enable-filter=aformat --enable-filter=amix --enable-filter=anull --enable-filter=aresample --enable-filter=areverse --enable-filter=asetrate --enable-filter=atempo --enable-filter=atrim --enable-filter=bwdif --enable-filter=delogo --enable-filter=equalizer --enable-filter=estdif --enable-filter=firequalizer --enable-filter=format --enable-filter=fps --enable-filter=hflip --enable-filter=hwdownload --enable-filter=hwmap --enable-filter=hwupload --enable-filter=idet --enable-filter=lenscorrection --enable-filter=lut* --enable-filter=negate --enable-filter=null --enable-filter=overlay --enable-filter=palettegen --enable-filter=paletteuse --enable-filter=pan --enable-filter=rotate --enable-filter=scale --enable-filter=setpts --enable-filter=superequalizer --enable-filter=transpose --enable-filter=trim --enable-filter=vflip --enable-filter=volume --enable-filter=w3fdif --enable-filter=yadif --enable-filter=avgblur_vulkan --enable-filter=blend_vulkan --enable-filter=bwdif_vulkan --enable-filter=chromaber_vulkan --enable-filter=flip_vulkan --enable-filter=gblur_vulkan --enable-filter=hflip_vulkan --enable-filter=nlmeans_vulkan --enable-filter=overlay_vulkan --enable-filter=vflip_vulkan --enable-filter=xfade_vulkan --disable-debug --enable-stripping --enable-optimizations --disable-large-tests --ignore-tests=TESTS --arch=aarch64 --target-os=darwin --enable-neon --enable-asm --disable-programs --enable-libfreetype --enable-libharfbuzz --enable-libfribidi --enable-libass --enable-filter=ass --enable-filter=subtitles --enable-vulkan --enable-lcms2 --enable-libplacebo --enable-filter=libplacebo --enable-libdav1d --enable-decoder=libdav1d --enable-libuavs3d --enable-decoder=libuavs3d
```

## 3. libmpv 的最终链接（静态链入的库清单）

只列静态库，证明哪些库被链入 —— **无 gnutls / nettle / gmp**：

```
libMoltenVK.a
libass.a
libavcodec.a
libavdevice.a
libavfilter.a
libavformat.a
libavutil.a
libbluray.a
libdav1d.a
libdovi.a
libfreetype.a
libfribidi.a
libharfbuzz.a
liblcms2.a
libplacebo.a
libshaderc_combined.a
libswresample.a
libswscale.a
libuavs3d.a
libuchardet.a
libunibreak.a
```

## 4. 许可相关开关的存在性检查

| 开关 | 是否出现在本次构建 |
| --- | --- |
| `--enable-version3` | 未出现 |
| `--enable-gmp` | 未出现 |
| `--enable-gnutls` | 未出现 |
| `--enable-securetransport` | **出现** |
| `--enable-openssl` | 未出现 |
| `-Dgpl=false` | **出现** |
| `-Ddefault_library=shared` | **出现** |
