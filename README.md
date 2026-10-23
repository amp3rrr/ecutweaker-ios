# EcuTweaker for iOS

An iOS port of [cedricp/ecutweaker](https://github.com/cedricp/ecutweaker): DDT4All ECU screens
on an iPhone/iPad through an ELM327-compatible adapter.

* **Links:** Bluetooth LE, Apple MFi (External Accessory), Wi-Fi (TCP 35000).
  Classic Bluetooth SPP is not usable by iOS apps, and USB is not supported.
* **Database:** the DDT4All `ecu.zip` (JSON version, with `db.json` inside). It is not included.
* **Features:** the same as the Android app: project/vehicle filter, ECU type list, CAN/KWP
  auto-identification, DDT screens (displays, inputs, buttons, pictures), auto-reload, DTC
  read/clear, soft flow control (CFC0), CAN timeout and default diagnostic session settings, log.

## Layout

| Path | What |
|---|---|
| `Sources/EcuCore/` | Platform-independent port of the Java `ecu` module and `ElmBase`: `Ecu`, `Layout`, `EcuDatabase`, `ZipFileSystem`, `IsoTP`, `ElmSession`, plus `ScreenController` and `ScanController` (the logic of ScreenActivity and MainActivity, without UI). |
| `App/` | The SwiftUI app: the BLE, MFi and Wi-Fi links, views and `Info.plist`. |
| `Tests/EcuCoreTests/` | `swift test` suite, which runs on Linux and macOS. |
| `tools/oracle/` | Regenerates the reference data by running the **original Java classes**. |
| `project.yml` | XcodeGen spec for the iOS app. |

### How the port was verified

`OracleTests` runs the original Java `Ecu.java` (from cedricp/ecutweaker) and the Swift port on
the same random frames and input values, for four real ECU files (CAN, KWP2000, little-endian
UCH). The Swift port must reproduce the Java output exactly: decoded values, encoded frames
(including the Java `HashMap` order in which overlapping fields are written), the SDS table and
number formatting. `ElmSessionTests` and `ControllerTests` drive the whole stack against an
ELM327/ECU simulator: ISO-TP multi-frame in both directions, soft flow control, KWP, timeouts,
screens, buttons, DTC read/clear, and old and UDS identification.

### Intentional differences from the Android code (bug fixes)

* ISO-TP first frame: Java used `header.substring(0, 3)`, which corrupted every request of 8
  bytes or more. Consecutive-frame numbering now wraps at 16.
* `snat_ext` was stored in the 11-bit RX map, which broke CAN scans of ECUs that have both
  addresses.
* Identification now follows DDT4All's matching. In the Java code the partial match lost a
  single candidate, and the UDS (22F1xx) method crashed with an NPE.
* CFC0 (soft flow control): an infinite loop on `NO DATA`, the echo of the flow-control frame,
  and the error text reported in place of the request.
* Without CFC0, an intermediate consecutive frame answered `NO DATA` was reported as an error.
* A negative value written to a scaled field is now two's complement of the field width. Java
  wrote the top bits.
* `IsoTPDecode` errors are no longer truncated to an empty string.
* Changing screens no longer drops a pending bus initialisation.
* `format: "bin"` shows the number, as DDT4All does. Java printed `bin123`.
* `ecu.zip` is read through its central directory, so no `ecu.idx` index file is needed.

## Getting `ecu.zip` onto the iPhone

The app looks for `ecu.zip` in its Documents folder:

1. Open **Files → On My iPhone → EcuTweaker** and put `ecu.zip` there. From a PC you can also use
   Apple Devices (or iTunes) → File Sharing.
2. Or use **Import ecu.zip…** in the app (iCloud Drive, Downloads, Google Drive…).
3. Or use **Share → EcuTweaker** on the file.

## Building and installing

### Without a Mac (GitHub Actions + Sideloadly)

1. Every push to `main` runs the **Build** workflow: tests, then an unsigned
   `EcuTweaker-unsigned.ipa` built on a macOS runner and published as the **latest** pre-release
   (Releases → *Latest build*).
2. Install it with [Sideloadly](https://sideloadly.io) on Windows, signing with your Apple ID.
   With a free Apple ID the app must be re-signed every 7 days. Your data (ecu.zip, settings) is
   kept as long as you install over the existing app.

### TestFlight (paid Apple Developer account)

The **TestFlight** workflow (manual run, or push a `v*` tag) archives the app, signs it with the
team's distribution certificate through an App Store Connect API key, and uploads the build.
Internal testers then install it from the TestFlight app. No App Review is needed, and builds
last 90 days.

One-time setup:

1. In App Store Connect, go to **Users and Access → Integrations → App Store Connect API** and
   create a *Team key* with the **Admin** role. Write down the Key ID and the Issuer ID, and
   download `AuthKey_XXXX.p8`.
2. Go to **Certificates, IDs & Profiles → Identifiers** and register the App ID, using your own
   bundle id (e.g. `pl.amp3rrr.ecutweaker`). Then go to **Apps → +** and create the app record
   with that bundle id.
3. In GitHub, open **Settings → Secrets and variables → Actions** and add:
   * variables `APPLE_TEAM_ID` and `BUNDLE_ID`;
   * secrets `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`. For `ASC_KEY_P8`, paste the whole
     content of the .p8 file.
4. Go to **Actions → TestFlight → Run workflow**. After about 10–20 minutes of processing, the
   build appears in App Store Connect → TestFlight. Add yourself as an internal tester.

### With a Mac

```sh
brew install xcodegen
xcodegen generate
open EcuTweaker.xcodeproj   # set your team under Signing & Capabilities, then Run on the iPhone
```

### Core tests (Linux or macOS)

```sh
swift test
```

## MFi adapters (vLinker FS/MC+ "for iOS", OBDLink MX+…)

iOS only lets an app talk to MFi accessories whose **protocol string** is listed in
`App/Info.plist` → `UISupportedExternalAccessoryProtocols`. `com.obdlink` is known. The Vgate
entries are guesses, because Vgate does not publish its string.

How to get the real string: download the IPA of an app that supports your adapter (for example
Car Scanner) with [ipatool](https://github.com/majd/ipatool). Use `ipatool search "Car Scanner"`
to find its bundle id, then `ipatool purchase` and `ipatool download`. Unzip it and read `UISupportedExternalAccessoryProtocols`
in `Payload/*.app/Info.plist`. The plist is not encrypted, but it may be in binary format;
`plutil -p` or Python's `plistlib` can read it. Add the string to `App/Info.plist` and rebuild.

The app's **Adapter → MFi → Diagnostics** section lists the declared strings and every accessory
iOS reports, with its protocols.

The accessory manufacturer only has to whitelist an app for the App Store. Sideloaded or
development builds can use any declared protocol.

## BLE adapters

The app recognises the usual UART-over-GATT layouts:

* `FFF0/FFF1/FFF2`
* `FFE0/FFE1`
* `18F0/2AF0/2AF1`
* the Vgate `E7810A71…/BEF8D6C9…`

It also has a generic fallback: any service with a notify characteristic and a write characteristic.

## License

GPL-3.0, like the original EcuTweaker (© Cédric Paille and contributors). See `LICENSE`.
This project is not affiliated with any vehicle manufacturer. It is for education and research only.
