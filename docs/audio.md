# Choose where sound plays

For a Mac desktop extended onto the TV, choose the built-in speakers or the available AirPlay output in **Remote**'s audio picker. The list uses the output names macOS exposes. Refresh it after connecting or disconnecting AirPlay. Selecting an output changes macOS's default media output; the alerts output remains separate.

If an output is missing or macOS rejects the change, use the menu-bar **Sound settings** action, then choose **Output**. A TV can be discoverable for video before its audio endpoint is available. On the October 9, 2026 connected setup, the picker switched the default output to the built-in speakers, confirmed by a separate Core Audio read, then restored the TV output. Audible playback still needs a listening check.

For **Video → Show on TV**, the player window remains on the Mac's extended desktop and audio follows macOS's selected media output. This lets you choose available Mac or TV speakers independently of where the window appears.

The **TV Video** window's native **AirPlay** picker offers a separate AVPlayer media route that can send video and sound to a receiver. Direct external media playback was not active in the observed session. Confirm the player's status reads **AirPlay media output**, then verify the picture and sound on the TV before relying on this route. An externally playing video's sound follows that media route; changing the Mac's default output alone does not establish that it changed. Apple documents [video routing from a Mac](https://support.apple.com/guide/mac-help/stream-video-and-audio-with-airplay-mchld7e543a0/26/mac/26).

## Mac and TV together

macOS can create a **Multi-Output Device** in Audio MIDI Setup. If both the Mac speakers and connected AirPlay output are available and selectable there:

1. Open Audio MIDI Setup and show the Audio Devices window.
2. Click **+ → Create Multi-Output Device**.
3. Select **Use** for the built-in speakers and the AirPlay output, then choose a primary device.
4. Select that multi-output device in Sound settings and listen at low volume before relying on it.

Apple documents the [multi-output procedure for macOS Tahoe](https://support.apple.com/en-ie/guide/audio-midi-setup/ams7c093f372/3.6/mac/26), but that documentation does not guarantee synchronized Mac-speaker and Fire TV AirPlay playback. This combination has not been tested here. Wireless buffering may produce an audible echo; if it does, return to a single output. The companion does not automatically create or modify aggregate devices.

The native picker uses public [Core Audio output-device properties](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultoutputdevice). It can select only endpoints macOS currently exposes. It does not implement per-app routing or independent delay compensation.
