# Dance Camera

Start in **Music**. Connect to Navidrome to search songs and browse albums and playlists. Tap a title to play or use the queue button to add it to Up next. The library also offers the iPhone’s Music picker and audio from Files. Navidrome credentials stay in memory for the session.

**Speed** changes playback immediately from 0.50× to 2.00× in 0.01× steps while preserving pitch. Tap the number to reset. Each song remembers its speed. The camera opens when you tap **Dance camera**, and playback continues across takes.

## Recording

- Leave **Finish at original song tempo** off to save the movement and music exactly as performed. The soundtrack comes from the live mixer, including pauses and speed changes. The microphone stays off.
- Turn that option on before recording to dance to a slowed or sped-up track and save it at the original musical tempo. The app tracks speed changes while recording, then retimes both the music and the camera frames when it saves. For example, ten seconds of dancing at 0.80× becomes eight seconds in Photos. Silent stretches normally keep their real-time duration.
- Stop the take and allow Photos additions when iOS asks. Photos receives the completed video automatically. If access or storage prevents delivery, the app holds the video for **Retry saving to Photos**. Previous builds’ clips can be moved with the one-time migration button. Existing copies you previously saved to Photos may appear twice if you migrate them.
- Keep AirPods connected throughout a take. Output latency correction is automatic. The camera chooses the highest supported capture preset up to 4K. Export preserves compressed camera frames and orientation.

## Music sources

For the iPhone Music library, select a downloaded track with an unprotected audio asset, such as an eligible synced file or purchase. The picker can report media access as unavailable under a host without Music permission. Apple Music subscription recordings are protected. Navidrome and local audio support the complete playback and recording workflow. [Apple media item asset URLs](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/asseturl) · [Protected media assets](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/hasprotectedasset)

## Build and verification

The dedicated project agent is `dance`. A push to `main` builds the unsigned iPhone IPA on GitHub Actions, runs synthetic audio and video checks, and publishes a versioned release. Pushes from the configured Windows checkout download the matching IPA to `release/v<version>-build.<number>/DanceCamera.ipa`. Import it into LiveContainer on iOS 18.2 or later.

CI feeds an MP3 to the decoder in chunks, exercises mixer sample-clock continuity with jitter and a dropped block, and checks exported frame bytes, rotation, signed offsets, and variable-speed audio and video. On hardware, compare the same song from Files and Navidrome, change speed during a take, check a slow-network recovery on AirPods, and play the original saved by Photos.
