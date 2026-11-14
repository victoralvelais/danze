# Dance Camera

The `dance` project agent maintains this iPhone app. Choose a song from Navidrome, record a dancer while the phone plays it, and save a portrait MP4 with the same song on its audio track.

Each push to `main` builds `DanceCamera.ipa` with GitHub Actions. On an iPhone running iOS 18.2 or later, open the successful run's **Artifacts**, download the IPA, and import it using **+** in LiveContainer. [LiveContainer import guide](https://livecontainer.github.io/docs/installation/standalone#installing-apps)

## Record a clip

1. Open Dance Camera and allow camera access.
2. Tap **Choose from Navidrome**. Enter the server URL your phone uses, including its port and any base path. Connect with your username and password, or choose **API key** if your server offers one. Use HTTPS when available. For a local HTTP server, use its local hostname or private IP and allow local network access when iOS asks. Sign-in details stay in app memory for the session. [Navidrome API compatibility](https://www.navidrome.org/docs/developers/subsonic-api/)
3. Search by song, artist or album, then tap a song. The app prepares a temporary audio file on the iPhone before recording. Once the title appears on the camera screen, the phone can record and export the whole take offline. **Files** also accepts an audio file already on the phone.
4. Tap **Record take** and then **Stop and save**, or let the song finish. The app uses the first recorded frame and scheduled playback time to align the video with the music. [Apple capture timing](https://developer.apple.com/documentation/avfoundation/avcapturefileoutputrecordingdelegate/fileoutput(_:didstartrecordingto:startpts:from:))
5. Open **Saved clips** to play a take, share the MP4, or explicitly save a copy to Photos. In a native install, the original is in **Files → On My iPhone → Dance Camera → Takes**. In LiveContainer, use **Saved clips → Share → Save to Files**. Photos permission is only requested when saving that extra copy.

## Device verification

Connect using your own server, search for a familiar song, let preparation finish, then disconnect Wi-Fi and cellular before recording. Record a short take with visible movements on the beat. Open the saved MP4 and compare start and end alignment on the phone speaker and on the intended Bluetooth route. Reject Photos permission and verify the original still opens in Files. Also try an empty search result, an incorrect password, an interrupted download, and two consecutive takes.
