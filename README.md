# Modpack updater

This project downloads the latest Flan's modpack ZIP for you.

## What you get

```text
   modpack installer\
   ├── update-modpack.bat
   └── app\
      ├── update-modpack.ps1
      └── updater-config.json
```

The ZIP is saved in a `download` folder next to these files. It is not saved
in the normal Windows Downloads folder, and it is not extracted automatically.

## How to use it

1. Keep the files together in the same folder.
2. Double-click `update-modpack.bat`.
3. Wait for the download to finish.
4. Open the ZIP from the `download` folder and extract it into your Minecraft
   instance folder.

The download folder opens automatically when the update succeeds. If there is
an error, the terminal stays open so you can read the message.
