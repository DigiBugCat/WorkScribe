# Plaud BLE SDK: native Mac experiment

This isolated lab adapts the official Plaud iOS SDK 1.0.13 from
`Plaud-AI/plaud-sdk-public`, revision
`8d7541e503cb96043e8629624aa6cee0241daa03`, for Apple-silicon macOS.
It does not change the main WorkScribe app; the lab compiles and uses the same
`Sources/WorkScribe/Runtime.swift` inference pipeline in process.

## Verified

- The original BLE binary rejects normal macOS linking because its Mach-O
  platform is iOS. A copied binary retargeted to macOS loads and runs natively.
  The original SDK is left unchanged.
- Native CoreBluetooth discovers a physical Note Pro, completes its signed
  handshake and cloud binding, and reconnects after an app restart.
- Developer OAuth, a user session stored in macOS Keychain, and the documented
  device-key/signature endpoints work from the native app.
- Native SDK RSA generation, PEM import, and encryption/decryption round-trip
  pass. Authenticated ChaCha encryption, tamper rejection, stream alignment,
  incremental Ogg framing/CRC, and actual native Opus decoding pass local tests.
- The lab compiles with WorkScribe's existing NVIDIA speech runtime in process.
  A physical Note Pro streamed audio into that runtime and produced a local
  transcript, with no helper process or localhost service.

## Current hardware checkpoint

After the user removed the device from the main Plaud app, native BLE binding
and cloud registration succeeded. The app reached `first_handshake: ok` and
received device state. The previous RSA failure occurred while the recorder
was still bound to the main app; that failure did not recur after removal.

The recorder multiplexes Opus audio and a separate metadata stream in Ogg.
The lab now demultiplexes by logical-stream serial, verifies page CRCs and
sequence numbers, and sends only the Opus stream to the decoder. The initial
fixed-packet decoder rejected metadata; simply accepting variable packet sizes
was insufficient because metadata must not enter an audio decoder at all.

The final live test decoded 792 audio packets / 15.84 seconds of 16 kHz mono,
16-bit PCM and produced a nonempty local transcript. The recorder stopped,
inference finished, and the SDK confirmed the final transfer. An independent
FFmpeg decode produced the same 253,440 samples, with waveform correlation
0.999993. See `hardware-verification.json` for the exact local evidence path.
A prior retained capture also decoded correctly after demultiplexer repair.

Normal reconnect follows the SDK's signed handshake and then cloud binding.
The recovery-only `GET /sdk/binding` flag reported true for the lab's own
existing binding, so using it as a normal reconnect gate was incorrect. No
force-clear, depair, or recovery bypass is implemented.

The server-issued RSA pair is validated locally before connecting. Diagnostics
retain only fixed event labels, packet counts, and GATT metadata. Test audio
and decoded compressed payloads remain in the private local capture folder;
keys and tokens are not recorded there.

## Reproduce

Obtain the official SDK from https://github.com/Plaud-AI/plaud-sdk-public.
SDK binaries have a separate proprietary license and are not checked in.

```sh
python3 experiments/plaud-macos/probe.py --sdk-root /path/to/plaud-sdk-public/sdk/ios
python3 experiments/plaud-macos/build-lab.py --sdk-root /path/to/plaud-sdk-public/sdk/ios
python3 experiments/plaud-macos/test-native.py
```

The default output is `~/Library/Caches/WorkScribe/PlaudNativeLab`, outside the
synced repository to avoid Finder extended attributes invalidating signatures.
Open `Plaud Mac Lab.app` there. The speech models and runtime libraries must
already exist in the WorkScribe build expected by `build-lab.py`.

The lab authenticates using an existing authorized developer client, scans,
prepares the selected recorder, and connects using the normal signed handshake.
It invokes cloud binding only after the matching device's successful BLE bind
callback. A separately started test records for 15 seconds and passes decoded
PCM directly into the existing speech engine. This complete path was verified
on the physical Note Pro; it remains an isolated lab, not a change to the main
app UX.

Status and locally captured test output go under
`~/Library/Application Support/WorkScribePlaudLab`. Only the user-token session
is persisted in Keychain; the developer client secret is not persisted.

## Product follow-up beyond this native-path proof

- Wire the adapter into the main app after coordination with its UX owner.
- Verify sustained sessions, radio-drop recovery, and timestamp accuracy.
- Add session renewal for ongoing use; the lab currently restores an unexpired
  user token from Keychain or accepts developer credentials again.

Wi-Fi transfer and firmware management are outside this live-BLE proof.
