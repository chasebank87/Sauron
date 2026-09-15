# Sauron Audio (virtual loopback)

Sauron ships an AudioServerPlugIn, **Sauron Audio**, so meeting apps can play into a virtual cable. Sauron captures that stream as the Speex far-end reference, replays it on your real speakers, and subtracts it from the mic (“You”) lane.

## Setup

1. Build the driver (Debug apps need this in Resources):

```bash
./scripts/build-sauron-audio-driver.sh
```

Release packaging runs the same script with your `CODE_SIGN_IDENTITY` when set to Developer ID.

2. Open **Settings → Devices → Install Sauron Audio…** (admin password). This copies:

`Sauron.app/Contents/Resources/Drivers/SauronAudio.driver`  
→ `/Library/Audio/Plug-Ins/HAL/SauronAudio.driver`

and restarts `coreaudiod`.

3. In Zoom / Teams / Meet / FaceTime, set **Speaker** to **Sauron Audio** (not your built-in speakers).

4. In Sauron, pick **Play meeting through** (hardware speakers or headphones).

5. Start recording. You should hear the meeting via Sauron’s replay; live You captions should shed speaker echo.

## Troubleshooting

- Device missing after install: Settings → **Reload Core Audio…**, or log out / reboot.
- Silence in the meeting: confirm the meeting app’s speaker is **Sauron Audio**, and Sauron’s playback device is a real output (not Sauron Audio).
- Echo remains without the driver: Speex falls back to ScreenCaptureKit / process-tap far-end; headphones are still the most reliable workaround.
- Driver signing: Apple Silicon requires a valid signature. Local builds ad-hoc sign; notarized releases use Developer ID.

## Architecture

```
Meeting app → Sauron Audio (HAL) → VirtualDeviceCapture
                                      ├─ Speex ingestFarEnd
                                      ├─ Others / system file
                                      └─ HardwareAudioPlayer → speakers
Mic (SCK) → Speex processNearEnd → You / mic file
```

Do not set the system default output to Sauron Audio unless you intend every Mac sound to go through Sauron.
