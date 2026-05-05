# nox

A native macOS app that lives in the notch and turns it into a tiny control surface for the things you do all day. Voice notes, music, file drops, screenshots, downloads, calendar nudges. Built in Swift and SwiftUI.

**Site:** https://trynox.app
**Download:** https://github.com/left-society/nox/releases/latest

## What it does

Hover over the notch and the panel blooms open. Move your cursor away and it folds back into the hardware notch like nothing was there.

A few of the things you can do from it:

- **Voice notes.** Hold the Fn key (or any hotkey you set) and talk. nox transcribes locally with Whisper, polishes the text with Groq if you give it a key, and pastes it at your cursor in any app. Audio never leaves your Mac unless you opt into cloud cleanup.
- **Now playing.** When music is playing in Spotify, Apple Music, YouTube, SoundCloud, or any other audio source, the notch shows the artwork and a clean transport row. Tap the artwork to jump back to the source.
- **Drop anything.** Drag a file, image, or video over the notch and the panel splits into two zones, one to save into nox, one to AirDrop. Drop a YouTube link and it offers to download the video.
- **System glances.** Charging plug in, screenshot saved, AirDrop received, Bluetooth device connected, calendar event starting in two minutes, timer countdown. Each one fades a small pill into the notch and clears itself when it is done.
- **Notes, images, videos, files.** The expanded panel has tabs for whatever you have collected. Notes use a real markdown editor with a clean popout window. Images and videos thumbnail in a grid. Files stage as a clipboard you can drag back out.
- **Lock screen card.** When the screen is locked, a glass card with the current track sits on top. The hardware media keys still work.

## Built with

- Swift 5.9 and SwiftUI on macOS 13 and up
- AppKit for the notch panel window, drag and drop routing, and the global Fn hotkey
- WhisperKit for on device transcription
- Sparkle 2 for auto updates
- Groq, OpenAI, or Gemini APIs (optional, for transcript cleanup)

## Updates

The app polls `appcast.xml` daily and updates itself in place. You do not have to download a new DMG every time.

Every release is signed with Apple's Developer ID, notarized and stapled, and additionally signed with a Sparkle EdDSA key whose public half is baked into the app. A download that has been tampered with at the CDN or replaced on the server gets rejected before installing.

**Appcast:** https://trynox.app/appcast.xml
