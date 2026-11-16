# Dance Camera

Start in **Music**. Connect to Navidrome to search songs and browse albums and playlists. Tap a title to play or use the queue button to add it to Up next. The library also offers the iPhone’s Music picker and audio from Files. Navidrome credentials stay in memory for the session.

**Speed** changes playback immediately from 0.50× to 2.00× in 0.01× steps while preserving pitch. Tap the number to reset. Each song remembers its speed. The camera opens when you tap **Dance camera**, and playback continues across takes.

## Recording

- Leave **Finish at original song tempo** off to save the camera and the music at the speed you performed. The audio comes from the same stream of samples that the player sends toward the speaker or headphones. The microphone stays off.
- Turn that option on before recording to save the dance at the original musical tempo. For example, ten seconds at 0.80× becomes eight seconds in Photos. For an uninterrupted song at one speed, the app uses the original music when timing or a content match establishes its position. With song or speed changes it retimes the recorded mix in sections.
- Stop the take and allow Photos additions when iOS asks. Photos receives the completed video automatically. If access or storage prevents delivery, the app holds the video for **Retry saving to Photos**. Previous builds’ clips can be moved with the one-time migration button. Existing copies you previously saved to Photos may appear twice if you migrate them.
- If a saved take pops or skips, tap **Share latest audio report** in Music or on the camera screen. The text file identifies the soundtrack used and counts gaps, overlaps, and corrected timestamps. Earlier reports are in the app's **Documents/Audio Reports** folder.
- The MP4 description **Live performed audio** identifies a take saved at the playback speed you heard. **Decoded song audio** identifies a take assembled from the original song. **Captured mixer audio** identifies a restored take that used the performance recording.
- Keep AirPods connected throughout a take. Output latency correction is automatic. The camera chooses the highest supported capture preset up to 4K. Export preserves compressed camera frames and orientation.

## TikTok LIVE on iPhone

Choose a song, tempo and camera lens. Open **Dance camera → LIVE** and tap the round button under **Start screen broadcast**. If iOS lists TikTok, select it and confirm **Start Broadcast** when ready. If TikTok requires its own LIVE setup, use **TikTok → + → LIVE → Mobile gaming**, start the screen share there, and switch back to Dance Camera. TikTok controls when your audience can watch. [Apple’s broadcast picker](https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview) · [TikTok screen sharing on iPhone](https://apps.apple.com/id/iphone/story/id1853849325)

Tap **Full Screen** on the camera preview to hide the studio. **Fill** uses the entire display and crops some of the picture on tall phones. **Fit** keeps the whole camera frame. Tap the picture for host controls. **Song** shows the current title and artist when available, including a paused indicator. You can play or pause from the same panel. The panel hides after five seconds or when you tap **Hide**. **Exit Full Screen** returns to the studio. TikTok shares whatever is visible while the controls are open.

For your voice, tap the picture, choose **Mic**, and open the round iPhone broadcast control. Use **Microphone** there when offered, or use TikTok’s LIVE audio controls if TikTok manages the mic. To rehearse privately, use **Screen Recording** in Control Center and listen to the result in Photos. End a TikTok LIVE in TikTok. [Apple’s microphone control](https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview/showsmicrophonebutton)

## Music sources

For the iPhone Music library, select a downloaded track with an unprotected audio asset, such as an eligible synced file or purchase. The picker can report media access as unavailable under a host without Music permission. Apple Music subscription recordings are protected. Navidrome and local audio support the complete playback and recording workflow. [Apple media item asset URLs](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/asseturl) · [Protected media assets](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/hasprotectedasset)

## Build and verification

A push to `main` builds the unsigned iPhone IPA, runs the audio and video checks on GitHub Actions, and publishes `DanceCamera-v<version>.ipa`. Import the IPA into LiveContainer on iOS 18.2 or later.

### Release versions

Each published IPA uses a single `MAJOR.MINOR.PATCH` version in its filename, release title and tag. Set `MARKETING_VERSION` in both Xcode target configurations to request a release. Use a patch for a compatible fix and a minor version for a new feature. During 0.x development, describe breaking changes with a minor release. From 1.0.0 onward, increment the major version for a breaking change. [Semantic Versioning](https://semver.org/)

CI chooses the version before compiling. If the configured version has already shipped, the next commit gets the next patch. Retrying the same commit reuses its release. The Windows receiver verifies the IPA against GitHub's SHA-256 and places it in the **Dance Camera** folder on the PC share.

CI feeds an MP3 to the decoder in chunks, exercises mixer sample-clock continuity with jitter and a dropped block, and checks exported frame bytes, rotation, signed offsets, and variable-speed audio and video. On hardware, compare the same song from Files and Navidrome, change speed during a take, check a slow-network recovery on AirPods, and play the original saved by Photos.
