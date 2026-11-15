# Dance Camera

Start in **Music**. Connect to Navidrome to search songs and browse albums and playlists. Tap a title to play or use the queue button to add it to Up next. The library also offers the iPhone’s Music picker and audio from Files. Navidrome credentials stay in memory for the session.

**Speed** changes playback immediately from 0.50× to 2.00× in 0.01× steps while preserving pitch. Tap the number to reset. Each song remembers its speed. The camera opens when you tap **Dance camera**, and playback continues across takes.

## Recording

- Leave **Finish at original song tempo** off to save the movement and music at the speed used during the take. When the app can verify an uninterrupted song against the camera clock, it uses the decoded song. It uses the recorded mixer output for pauses, speed changes, and uncertain timing. The microphone stays off.
- Turn that option on before recording to dance to a slowed or sped-up track and save it at the original musical tempo. The app tracks speed changes while recording, then retimes both the music and the camera frames when it saves. For example, ten seconds of dancing at 0.80× becomes eight seconds in Photos. Silent stretches normally keep their real-time duration.
- Stop the take and allow Photos additions when iOS asks. Photos receives the completed video automatically. If access or storage prevents delivery, the app holds the video for **Retry saving to Photos**. Previous builds’ clips can be moved with the one-time migration button. Existing copies you previously saved to Photos may appear twice if you migrate them.
- If a saved take pops or skips, tap **Share latest audio report** in Music or on the camera screen. The text file identifies the soundtrack used and counts gaps, overlaps, and corrected timestamps. Earlier reports are in the app's **Documents/Audio Reports** folder.
- Keep AirPods connected throughout a take. Output latency correction is automatic. The camera chooses the highest supported capture preset up to 4K. Export preserves compressed camera frames and orientation.

## Music sources

For the iPhone Music library, select a downloaded track with an unprotected audio asset, such as an eligible synced file or purchase. The picker can report media access as unavailable under a host without Music permission. Apple Music subscription recordings are protected. Navidrome and local audio support the complete playback and recording workflow. [Apple media item asset URLs](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/asseturl) · [Protected media assets](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/hasprotectedasset)

## Build and verification

A push to `main` builds the unsigned iPhone IPA, runs the audio and video checks on GitHub Actions, and publishes `DanceCamera-v<version>-build.<number>.ipa`. Import the IPA into LiveContainer on iOS 18.2 or later.

### Release versions

The app's release version is `MAJOR.MINOR.PATCH`. When shipping a user-facing change, set `MARKETING_VERSION` in both the Debug and Release target settings. Starting at 0.12.0, use 0.12.1 for a compatible fix and 0.13.0 for a new feature. During 0.x development, use a minor release for breaking changes and describe the compatibility impact. From 1.0.0 onward, increment the major version for a breaking change. CI sets the separate `CFBundleVersion` build number from its run number. [Semantic Versioning](https://semver.org/)

The first successful build of a version publishes a stable tag such as `v0.12.0`. Later pushes with the same marketing version publish development prereleases such as `v0.12.0-build.14`. The published stable IPA keeps its original filename and contents. The Windows checkout keeps verified IPAs under `release/<tag>/`.

CI feeds an MP3 to the decoder in chunks, exercises mixer sample-clock continuity with jitter and a dropped block, and checks exported frame bytes, rotation, signed offsets, and variable-speed audio and video. On hardware, compare the same song from Files and Navidrome, change speed during a take, check a slow-network recovery on AirPods, and play the original saved by Photos.
