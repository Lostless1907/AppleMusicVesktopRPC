# Apple Music → Vesktop RPC

A small, open-source macOS bridge that reads the currently playing track from the native Music app and publishes it as Discord Rich Presence through Vesktop's integrated arRPC/IPC interface.

**Status: early prototype.** Tested build instructions are provided, but compatibility depends on your Vesktop version and settings. Contributions and issue reports are welcome.

## Features

- Reads the current track, artist, album, playback state and position from Music.app using AppleScript.
- Publishes a “Listening” activity through Discord IPC.
- Looks up album artwork using Apple's public iTunes Search API and passes the image URL as the large Rich Presence asset.
- Clears the activity when playback stops.
- No Discord bot, token, or paid service.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+
- Vesktop with **Rich Presence via arRPC** enabled
- A Discord application ID (the default in this repository is `1565358520541519912`; replace it with your own if desired)

## Build and run

```sh
swift build -c release
swift run -c release
```

To use a different Discord application ID:

```sh
APPLE_MUSIC_RPC_APP_ID="YOUR_APPLICATION_ID" swift run -c release
```

The app connects to `$TMPDIR/discord-ipc-0`. Start Vesktop first. On first use, macOS may ask for permission for the program to control Music.app. Approve it in **System Settings → Privacy & Security → Automation**.

Stop with `Ctrl-C`.

## How it works

1. AppleScript queries Music.app every three seconds.
2. When a track changes, the client searches Apple's iTunes Search API for a matching cover image.
3. The client sends a Discord RPC `SET_ACTIVITY` command over the local IPC socket.
4. Playback stop clears the activity.

## Troubleshooting

- **No IPC connection:** ensure Vesktop is open and the built-in arRPC/Rich Presence option is enabled. The IPC socket is typically located at `$TMPDIR/discord-ipc-0`.
- **Music metadata unavailable:** open Music.app and start playback; approve macOS Automation permission if prompted.
- **No cover:** some library-only, imported, or regional tracks may not match the public iTunes catalog. The activity should still show text.
- **Activity does not show:** this is an early prototype. Open an issue with macOS and Vesktop versions and the console output. Do not include tokens or private account data.

## Privacy

Track title, artist and album are read locally from Music.app. When a track changes, its metadata is sent as a query to Apple's iTunes Search API to find artwork. The resulting artwork URL is sent to Discord/Vesktop as part of Rich Presence. No telemetry is implemented.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgements

- [OpenAsar/arRPC](https://github.com/OpenAsar/arrpc) for documenting the custom-client integration used by Vesktop.
- [Discord Rich Presence RPC](https://discord.com/developers/docs/topics/rpc)
- [Apple iTunes Search API](https://performance-partners.apple.com/search-api)
