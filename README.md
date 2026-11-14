# Dance Camera

Play music from Navidrome while the rear camera is ready. Press **Record take** at any point to save a portrait clip with the music you heard during that take. You can also record a silent clip before you choose a song. The app records the digital soundtrack and leaves the microphone off.

## Record a clip

1. Allow camera access. **Navidrome** opens your music library. Enter your server URL including any base path, then connect with your account or API key. Use HTTPS for a remote server. The app also supports a local HTTP hostname or private address. Sign-in details stay in memory for the session. [Navidrome API compatibility](https://www.navidrome.org/docs/developers/subsonic-api/)
2. Tap a song to stream it, or use the queue button beside a song to add it to playback. Audio buffers as it plays. **Files** can open a local audio file. Play, pause, or skip from the camera screen.
3. Tap **Record take**, then **Stop and save**. Playback can continue across takes. You can pause, resume, or change the song during a take. The app aligns the music you heard with the first camera frame and accounts for the output route’s reported latency.
4. The camera chooses 4K when supported, then 1080p or the next available preset. Saving encodes the soundtrack to AAC and copies the compressed video into the MP4. The save message shows the capture dimensions. [Apple capture presets](https://developer.apple.com/documentation/avfoundation/avcapturesession/preset/hd4k3840x2160) · [Apple passthrough export](https://developer.apple.com/documentation/avfoundation/avassetexportpresetpassthrough)
5. Open **Clips** to play the original, share it, or save a copy to Photos. In LiveContainer, **Share → Save to Files** also exports a copy.

## Check timing on your iPhone

Connect your AirPods, play a song with a sharp beat and record a visible tap on that beat after playback has started. Check the original in **Clips**. If the sound comes before the movement, open **Audio sync** and increase the shift. If it comes after the movement, decrease it. Adjust in small steps and record again. The app remembers the setting for each output. Switching headphones during a take ends the take.

For a streaming check, start a longer song and make two short clips at different points. Pause and resume during one take, and test another without choosing music. A network stall can leave silence while the video continues. Check the dimensions in the save message and compare quality using the original in Files or Photos.

## Build

The `dance` project agent maintains this iPhone app. Each successful build on `main` publishes `DanceCamera.ipa` to a versioned GitHub Release. After a push from the configured Windows checkout, the project download helper saves that release to `release/v<version>-build.<number>/DanceCamera.ipa`. On iOS 18.2 or later, import the IPA using **+** in LiveContainer. [LiveContainer import guide](https://livecontainer.github.io/docs/installation/standalone#installing-apps)
