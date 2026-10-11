# Lumen Player for Apple TV

A minimal tvOS app that plays one URL through `KSVideoPlayerView`, with `ProAVPlayer` as the first engine and `KSMEPlayer` as the fallback. It exists to test the remux engine on a real Apple TV, including TrueHD Atmos and DTS:X tracks converted to APAC.

## Build and install

Use macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Signing stays out of the project: pass your team and a bundle identifier it can sign.

```sh
cd Examples/LumenPlayer
LUMEN_DEVELOPMENT_TEAM="TEAM_ID" LUMEN_BUNDLE_ID="com.example.lumen" ./build-and-install.sh "DEVICE_ID"
```

`xcrun devicectl list devices` shows the Apple TV's identifier. The script generates the project, builds the app with the repository's Lumen and installs it.

## Run

The app reads its configuration from the launch environment. With `devicectl`, prefix each variable with `DEVICECTL_CHILD_`:

| Variable | Meaning |
|---|---|
| `LUMEN_URL` | The media to play, such as a media server's direct-play URL |
| `LUMEN_TITLE` | Optional title for the player interface |
| `LUMEN_START` | Optional start time in seconds |
| `LUMEN_LOG` | `info` to log the engines' decisions, such as a fallback from APAC to FLAC |
| `OS_ACTIVITY_DT_MODE` | `enable` to mirror the log to the console |

For Jellyfin, with an API key in `KEY` and the item and media source ID in `ID`:

```sh
export DEVICECTL_CHILD_LUMEN_URL="https://jellyfin.example.com/Videos/$ID/stream?static=true&MediaSourceId=$ID&ApiKey=$KEY"
export DEVICECTL_CHILD_LUMEN_START=420
xcrun devicectl device process launch --device "DEVICE_ID" --terminate-existing --console "com.example.lumen"
```

Keep the key out of shell history and logs. Use the server's HTTPS address with a certificate the Apple TV trusts: over plain HTTP the key travels unencrypted.
